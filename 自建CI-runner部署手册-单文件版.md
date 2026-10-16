# 自建 GitHub Actions CI runner —— 部署手册（单文件版）

> 本文由 `playbook/` 下的分章文件自动拼装（`bash scripts/make-single.sh` 重新生成）。
> **要改内容请改分章文件**，别改这一份，否则两版会漂移。
>
> 一套通用做法：怎么判一台机器够不够、怎么装、怎么改 workflow、怎么接线、怎么验、怎么运维。
> 所有数字都来自一次真实落地（一台 4 核 / 7.5 GiB 机器 + 一个 pnpm monorepo）；
> 凡标「参考项目」处是举例，不是要求。

---

## 15 分钟快速开始

```bash
# 1. 判这台机够不够（只读）
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load

# 2. 装机 + 注册 + 加固（幂等）
GH_REPO=owner/repo GH_TOKEN=<一次性PAT> \
RUNNER_LABELS=self-hosted,linux,x64,ci \
CI_APP_PORTS="3100 3101" CI_LABEL=com.myorg.ci=1 \
CI_FIXEDWORK_BASELINE=<上一步给的 p50> \
bash scripts/bootstrap.sh

# 3. 自检
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh

# 4. ★ 改 workflow —— 没有脚本，必须人读一遍第 05 章
#    改完之前**不要**打开开关，否则第 2 个 PR 就会红

# 5. 接线
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'

# 6. 连开**两个**测试 PR，再手动触发一次定时 workflow
```

**第 4 步是唯一不能跳的人工步骤。** 前三步是机器配置；第 4 步是把仓库里那些
「只在一次性 VM 上成立」的写法找出来改掉——那才是失败真正会发生的地方。

---

## 目录

- [01 决策：要不要自建](#01-决策要不要自建)
- [02 选机与验收](#02-选机与验收)
- [03 装机与注册](#03-装机与注册)
- [04 加固](#04-加固)
- [05 workflow 改造：常驻 runner 上会坏掉的托管假设](#05-workflow-改造常驻-runner-上会坏掉的托管假设)
- [06 接线与回退](#06-接线与回退)
- [07 验证](#07-验证)
- [08 运维与容量](#08-运维与容量)
- [09 踩坑记录](#09-踩坑记录)

---

## 01 决策：要不要自建

先说结论的形状：**自建 runner 通常不是省钱方案。** 如果你的动机是省钱，先把这一章的账算完再决定。

### 1.1 先把「省多少」算清楚

GitHub Actions 的计费模型有两条容易算错的地方：

1. **每个 job 单独向上取整到整分钟，再求和**——不是按 workflow 墙钟算。
   一个 6 秒的 job 和一个 59 秒的 job 都记 1 分钟。job 越多、越短，取整损耗占比越高。
2. **自托管 runner 不消耗 included minutes**，所以「搬走哪些 workflow」直接等于「省多少分钟」。

拿真实数据算，别拿配置猜（脚本见 `scripts/analysis/`，从 `/actions/runs/{id}/jobs` 取
`started_at`/`completed_at` 自己算——`/timing` 端点在当前计费平台下返回全 0，不能用）：

```
月计费分钟 = Σ(每个 workflow 的月 run 数 × 该 workflow 每 run 的计费分钟)
每 run 计费分钟 = Σ(每个 job 的 ceil(秒数/60))     # 注意是每 job 各自取整
```

> **参考项目**：现配置外推 **2280 计费分钟/月**，免费额度 2000 ⇒ 超 **280 分钟**
> ⇒ 按 Linux 2 核 $0.006/分钟计，**$1.68/月**。而机器月租 €7–14。
> **纯算钱是亏的。**

### 1.2 那为什么还值得做

因为省钱不是它买的东西。它买的是**「额度不会在你最忙的那天突然合上」**。

免费额度 2000 分钟听起来很多，换算一下：按每 run 10 计费分钟算，**只够约 200 个 PR-run**。
一个 4 人小队在冲刺周很容易一天跑掉 30–35 个 PR。

> **参考项目**：额度于 2026-08-21 10:27 UTC 耗尽，直到 09-01 才重置。
> 那 10.5 天里 GitHub 仍然接受触发但**不分配 runner**，job 在 1–6 秒内失败。
> 结果：**85 个已合并的 PR 里，52 个（61%）从来没有跑过一次真实的 CI。**
>
> 这才是自建要解决的问题。$1.68 是噪音。

### 1.3 什么时候**不该**自建

| 情形 | 为什么不该 |
|---|---|
| **公开仓库** | fork PR 会在你的机器上执行任意代码，而 `docker` 组 ≈ 宿主 root。GitHub 官方明确不建议。 |
| **机器还跑着别的东西** | CI 会独占宿主端口、写满磁盘、触发 OOM。**共享 dockerd 上一次 ENOSPC 不是 CI 变红，是你的业务一起写不进去。** 要自建就用专机。 |
| **没人愿意长期维护它** | 它需要清理、监控、告警、版本升级。托管 runner 这些都不用管。 |
| **额度还很宽裕** | 先做免费优化（合并 job、砍重复触发、路径门控）。那些通常能砍掉 50%，而且零风险。 |
| **团队分布在多时区、峰值连续** | 单机 N=1 的排队会累积。先算清楚（见 08 章的仿真方法）。 |

### 1.4 决策清单

全部为「是」才继续：

- [ ] 仓库是私有的，或你能接受 fork PR 的代码执行风险
- [ ] 有一台**专用**机器（不跑业务、不跑别人的数据）
- [ ] 已经做完免费优化，额度仍然吃紧
- [ ] 有人负责它的运维（清理、监控、升级）
- [ ] 接受「N=1 时 job 会排队」——先用 08 章的方法算一遍你的峰值

---


---

## 02 选机与验收

一条命令给结论：

```bash
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load
```

它只读、不装任何东西，末尾打印 **GO / NO-GO**。下面解释它查的每一项**为什么**这么查——
因为阈值可以按你的项目改，但**测法不能**。

### 2.1 CPU 与内存：按「单 job 实测峰值」定，不要拍脑袋

唯一可靠的定法是**在候选机上把你的 CI 真跑一遍**，逐步量峰值 RSS 与 CPU 核秒
（`scripts/analysis/step.sh` 用 cgroup 量，比 `/usr/bin/time` 准——后者对多进程只取单进程最大值）。

> **参考项目**（单 job 峰值 RSS）：
> typecheck **3663 MB**（全场最高）｜ lint 1731 MB ｜ test 1596 MB ｜ Metro 1271 MB ｜ e2e 623 MB
> CPU：test 3.73 核 / typecheck 3.31 核 / Metro 3.34 核 —— **单个 job 就几乎吃满 4 核**
>
> ⇒ 单 job 峰值 ≈ 3.7 GB + 服务容器 0.6 GB + 系统 0.5 GB ≈ **4.8 GiB**
> ⇒ 7.57 GiB 的机器**只能跑 1 个并发 job**

**N=2 的诱惑要用实验拒绝，不要用估算。** 我们真的注册了两个 runner 让两个 job 并发跑了两次：

| 第几次 | 结果 |
|---|---|
| 1 | `Error: Test timed out in 5000ms` —— **CPU 饥饿**打红了一条固定超时的测试（同一条在三次单 job 运行里全绿） |
| 2 | `Out of memory: Killed process (node) ... Exit status 137` —— **内核 OOM 杀掉了 tsc**，触发者是**另一个 job 的 redis 容器** |

**两次并发、两种不同的失败模式** ⇒ N=2 产生的是**不确定性红叉**，比慢更糟：
它会让团队养成「重跑一次就好了」的习惯，那是 CI 可信度崩塌的起点。

注意第 1 次**不是内存问题**。所以「加内存就能 N=2」是错的——CPU 那一半先到。

### 2.2 swap：不是否决项，但它决定了别的

`swap = 0` 意味着内存超限时是 **OOM kill 而不是变慢**。这不是要你加 swap
（CI 场景快速失败通常好过换页颠簸），而是意味着：

- `MemoryMax` 必须设，否则一个失控的 job 会拖垮整机
- `OOMScoreAdjust` 必须设，否则**内核按 RSS 挑受害者，可能挑中 sshd 而不是 CI**

### 2.3 端口：撞了不是变红，是连错库

CI 的 `services:` 容器会**独占宿主端口**。如果这台机上已经有东西占着 6379，
后果不是「CI 起不来」，而是**CI 连到那个 Redis 上去**——测试会通过，数据会被污染。

装机前必须查空：`ss -ltn` 对照你项目的端口清单。

### 2.4 连通性：四条阈值各管一件事

| 阈值 | 管什么 |
|---|---|
| 成功率 ≥ 98% | 会不会**直接失败**。CI 里一次网络失败 = 一个红叉 + 一次重跑 |
| connect p95 < 300 ms | TCP 握手，反映**路由质量与物理距离**，与服务端负载无关 |
| TTFB p95 < 1500 ms | 端到端（含 TLS、服务端处理、限流排队） |
| **抖动比 (p95/p50) < 3** | 最容易被忽略、也最重要：绝对值好但抖动大 = 偶发长尾 = **随机红叉** |

要测的端点至少这些（少一个都可能在装完之后才发现）：

```
github.com                     actions/checkout 拉代码、下载 action
api.github.com                 runner 长轮询领 job、回传结果、gh api
ghcr.io                        Immutable Actions 把 action 本身存在这里
registry.npmjs.org             依赖
registry-1.docker.io           服务容器与基础镜像的 manifest
auth.docker.io                 上面那个的鉴权
```
官方 allowlist 里还有 `*.actions.githubusercontent.com`（pipelines/vstoken/results-receiver）、
`codeload.github.com`、`objects.githubusercontent.com`——它们通常和上面几个同路径，
**而且一次成功的真实 runner run 比任何 curl 探针都更能证明它们通**。

> ⚠️ **两个统计口径的坑**：
> ① 探针默认 `curl -4`，但很多机器是双栈且 DNS 对 Docker/npm **优先返回 IPv6**——
>    生产实际走的那条栈可能你根本没测。`preflight.sh` 两族都测。
> ② 成功率要**把 5xx 计为失败**。宽口径（任何 HTTP 响应都算成功）会把对端故障算成绿。
>    参考项目实测：满载轮 400 样本里 `api.github.com` 有 **6 次 504** 密集落在 3 分钟窗口内，
>    宽口径报 100%，严格口径是 **98.50%** —— 刚过 98% 的线。
>    **p95 对 400 样本里的 6 个事件在数学上不可见**，所以 "PASS" 只能读作「链路质量达标」，
>    不能读作「不会有偶发失败」。

### 2.5 CPU 争抢：先确认仪器能不能用

**这是本章最容易被跳过、也最容易搞错的一条。**

很多云的宿主**不向 guest 暴露 `KVM_FEATURE_STEAL_TIME`**（CPUID `0x40000001` 的 bit5）。
此时 `/proc/stat` 的 steal 列**结构性恒为 0**——不是「测出来是 0」，是「根本没接线」。
任何基于 `%st` 的监控在这种机器上都是**永久假绿灯**。

```bash
# preflight.sh 会自动查这一位。手工查：
python3 -c "
import os,struct
fd=os.open('/dev/cpu/0/cpuid',os.O_RDONLY)   # 需要先 modprobe cpuid
eax=struct.unpack('<IIII',os.pread(fd,16,0x40000001))[0]
print(hex(eax), 'STEAL_TIME bit5 =', (eax>>5)&1)"
```

> **参考项目**：`eax=0x0100005b`，**bit5 = 0** ⇒ steal 不可观测。
> 我第一轮把「steal 全程 0.00%」当成了「无争抢」的证据——**那 1855 个样本全是同义反复**。

**替代仪器：定长任务墙钟。** 同样的活干 N 遍，被邻居抢核就会变慢。

```
n=30  p50=0.51s  max=0.52s  max/p50=1.02   ⇒ 无实质争抢
判读：CV < 5% 且 max/p50 < 1.15
```
⚠️ 必须是**定量**负载。别用 `openssl speed -seconds N`——它是**定时**的，墙钟恒等于 N，等于没测。
`preflight.sh` 用固定次数的 sha256。

把这个 p50 记下来**当基线**，装机后交给 `ci-health.sh` 每小时采点，超过基线 1.4 倍就是争抢信号。

### 2.6 磁盘：看增量，不只看水位

自建 runner 上最大的磁盘增长源是 **BuildKit build cache**，不是镜像。
关键实测（Docker 29 + containerd 快照器）：

```
带 -t 重复构建同一镜像 3 次（每次改一行源码）：
  磁盘每次 +1.29 GB      悬空镜像恒为 0        ← 不是悬空镜像的锅
docker image  prune  →  回收 0 MB
docker buildx prune  →  回收 5896 MB          ← 攒了几天后的一次性回收量，不是持续效果（见下）
docker volume prune  →  回收 634 MB           ← services 容器的匿名卷，约 70 MB/run
```

> ⚠️ **上线一个月后更正**：`buildx prune --filter until=24h` 在持续负载下几乎删不到东西（缓存 24 小时内都被用过），
> 已从清理钩子里删掉。缓存的上限靠 daemon.json 的 GC 策略（4.1 节）。

容量估算——**别用「基线 + 日增」**，它只描述第一周：
```
稳态已用 ≈ 系统与工具链 + 在用镜像 + min(Max Used, 缓存工作集) + Docker 以外的东西
稳态可用 ≈ max(Min Free, 盘总量 − 上式)
```
> **参考项目**：第一周 13.7 GB / 74.8 GiB = 18%，原稿把这个当成了稳态。实际第四周稳定在约 49 GB / 68%，
> 可用空间停在 GC 的 Min Free（20 GiB）附近不再下降。详见 08 章 8.2。

**别把「不清理会盘满」当成清理的理由**——BuildKit 自己有 GC 兜底，缓存不会无限长。
真正的理由是：①缓存被反复驱逐导致构建退化；②**匿名卷不在 BuildKit 管辖内，Docker 以外的东西更没人管，那两部分才是无上界的**。

### 2.7 一张最低要求表（起点，按项目调）

| 项 | 建议下限 | 依据 |
|---|---|---|
| CPU | 单 job 实测峰值核数 + 1 | 参考项目单 job 吃 3.7 核 ⇒ 4 核 |
| 内存 | 单 job 实测峰值 × 1.5 | 参考项目 4.8 GiB ⇒ ≥7 GiB |
| 磁盘 | 基线 + 日增 × 7 | 参考项目 8.1 + 5.6×7 ≈ 47 GB ⇒ 74.8 GiB 有余 |
| swap | 无所谓，但影响配置 | 见 2.2 |
| 网络 | 四条阈值全过 | 见 2.4 |

---


---

## 03 装机与注册

一条命令：

```bash
GH_REPO=owner/repo \
GH_TOKEN=<一次性 PAT> \
RUNNER_NAME=ci-$(hostname -s) \
RUNNER_LABELS=self-hosted,linux,x64,ci \
CI_APP_PORTS="3100 3101" \
CI_FIXEDWORK_BASELINE=0.51 \
PNPM_VERSION=11.21.0 \
bash scripts/bootstrap.sh
```

`bootstrap.sh` 是**幂等**的：重复跑不会破坏已有配置，只补齐缺的
（已在一台配置完成的机器上重跑验证：12 项关键状态逐字节相同，只有注释文本被标准化）。

下面解释它做的每件事**为什么**要那么做。

### 3.1 参数怎么定

| 变量 | 怎么定 | 参考项目取值 |
|---|---|---|
| `RUNNER_LABELS` | 至少一个项目专属标签，别只用 `self-hosted` | `myproj-ci` |
| `RUNNER_MEM_MAX` | 单 job 实测峰值 × 1.3 | `6G`（峰值 4.8 GiB） |
| `CI_APP_PORTS` | CI 里在**宿主**上监听的端口（不是容器端口） | `3100 3101`（e2e 拉起的 API） |
| `CI_LABEL` | **必须与 workflow 里 `docker run --label` 的值逐字一致**，清理脚本靠它认领容器 | `com.myorg.ci=1` |
| `CI_FIXEDWORK_BASELINE` | `preflight.sh --with-load` 给的 p50 | `0.51` |
| `BUILDKIT_MAX_USED` / `MIN_FREE` | 按盘大小定，别用出厂默认 | `20GB` / `20GB` |

### 3.2 工具链：托管 runner 预装了约 100 个工具，自建的什么都没有

这是最容易被低估的一条。**装之前先 grep 你的 workflow 用了什么**：

```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|python3|zstd|unzip)\b' .github/workflows/ | sort -u
```

> **参考项目**：`gh` 缺失会让 `pr-meta.yml:42` 的 `gh api ... > file` **硬失败**
> （没有 `|| ` 兜底，而 Actions 跑 `bash -e`）。另外三处有兜底，会**静默降级**——
> 路径门控退化成全跑、nightly 恒跑、直推检出跳过。**你会以为门禁还在跑，其实已经不在。**

`bootstrap.sh` 装的基线：`ca-certificates curl gnupg jq git tar unzip zstd psmisc python3`
+ Docker CE + Node + gh。`psmisc` 是为了 `fuser`（清理孤儿进程要用）。

**Node 用官方 tarball 装到 `/opt/node`**，不用发行版包——那是给 runner 自身和运维脚本用的；
workflow 里的 `actions/setup-node` 仍会自己管版本。

### 3.3 runner 用户：`docker` 组 ≈ 免密宿主 root

`services:` 容器、`docker build`、`docker run` 都要 docker 权限，所以 runner 用户必须在 `docker` 组。
**而 `docker` 组等价于免密 root**（`docker run -v /:/host` 就能读写整个文件系统）。

这条没法绕开（除非上 rootless dockerd，那是另一套工程）。要理解的是它的含义：

> **任何能让 CI 执行代码的人，就能拿到这台机器的 root。**
> 私有仓里这是「所有有 push 权限的协作者」——可接受。
> 但它也包括**被投毒的第三方 action**，所以 05 章的供应链那条不是洁癖。

### 3.4 注册：用一次性 token，别留常驻凭据

```bash
# registration token 有效期 1 小时，用完即弃
REG=$(curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$GH_REPO/actions/runners/registration-token" | jq -r .token)
sudo -u runner ./config.sh --unattended --url "https://github.com/$GH_REPO" \
  --token "$REG" --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work --replace
```

`GH_TOKEN` 只在这一刻用一次换 registration token，**脚本不会把它写到任何文件里**。
建议用 fine-grained PAT，只给目标仓库的 `Administration: read&write`，用完撤销。

### 3.5 ⚠️ 不要加 `--ephemeral`

通行做法会建议开它（一 job 一进程，跑完自动注销重注册）。**在这个形态下不要开。**

```
config.sh --help:  "let the service un-configure the runner after the job finishes"
bin/RunnerService.js:  "Runner listener exit with 0 return code, stop the service, no retry needed."
```

也就是说：跑完一个 job 后 runner **自己注销并把服务停掉**。`Restart=always` 把服务拉起来也没用——
它已经没有注册信息了。要回来必须拿一个新的 registration token，**等于必须在机器上常驻管理员凭据**，
与「用完撤销 token」直接冲突。

而一次没被发现的注销 = **最长 24 小时全员 CI 停摆**（GitHub 对排队 job 的自动取消是 24 小时，
而回退开关**救不了已排队的 job**）。

想要每个 job 干净的环境，用 `ACTIONS_RUNNER_HOOK_JOB_STARTED` 钩子拿，代价是 0（见 04 章）。

### 3.6 目录布局

```
/opt/actions-runner/          runner 本体
├── .env                      两个钩子的挂载点（JOB_STARTED / JOB_COMPLETED）
├── .runner .credentials*     注册信息（**别备份、别进快照** —— 见 09 章）
├── hooks/ci-cleanup.sh       清理脚本
└── _work/                    工作区，跨 job 复用（这正是自建比托管快的原因）
    ├── <repo>/<repo>/        checkout 落点
    ├── _temp/                $RUNNER_TEMP —— 每 job 新建并清理
    └── _tool/                setup-node 等的工具缓存（约 200 MB，跨 job 复用）
/opt/node/                    Node 运行时
/usr/local/bin/ci-health.sh   健康采点
```

---


---

## 04 加固

`bootstrap.sh` 已经做了这一章的大部分。这里解释每条**为什么**——因为其中有几条的直觉是反的。

### 4.1 Docker 守护进程

```json
{
  "builder": { "gc": { "enabled": true, "policy": [
    { "all": true, "reservedSpace": "10GB", "maxUsedSpace": "20GB", "minFreeSpace": "20GB" }
  ] } },
  "live-restore": true
}
```

**BuildKit GC 上限**：出厂默认在小盘上太松（实测 Max Used **55.88 GiB** / Min Free 13.97 GiB）。

> ⚠️ **踩过的坑**：`"defaultKeepStorage": "10GB"` 这个写法**只映射到 Reserved Space**，
> 会把 `Min Free` 保护**丢掉**。而顶层直接写 `reservedSpace`/`maxUsedSpace`/`minFreeSpace`
> 会被**静默忽略**（daemon 无报错，回落出厂值）。**必须用 `policy` 数组**，写全三个参数。
> 改完用 `docker buildx inspect default | grep -A6 'rule#0'` 确认三项都在。

**`live-restore: true`**：不开的话，一次 dockerd 重启（比如 unattended-upgrades 触发的）
会把当前 job 的 `services` 容器**当场全灭**，而报错会指向业务代码——排查方向完全错。

### 4.2 别让自动升级打断 job

Ubuntu 的 `unattended-upgrades` 默认每日跑，`needrestart` 的 APT 钩子默认 `-m u`（自动重启受影响服务）。

> ⚠️ **一个反直觉的细节**：`docker` **已经在出厂免打扰名单里**
> （`/etc/needrestart/needrestart.conf` 的 `override_rc` 里有 `qr(^docker) => 0`），
> 但 **`containerd` 不在**——而 Docker 29 的镜像与容器都由 containerd 承载。
> 所以只需补 containerd 一条：

```perl
# /etc/needrestart/conf.d/90-ci-containerd.conf
$nrconf{override_rc}->{qr(^containerd)} = 0;
$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;   # runner 自己（2026-10 补）
```

（我第一版写了 docker + containerd 两条，其中 docker 那条是多余的。查一下你的机器再写。）

> ⚠️ **runner 服务本身也要豁免**（上线后第 25 天补）。2026-10-02 06:06，一次 libssl 自动安全更新
> 让 needrestart 把 runner 服务在 job 中途重启了，那个 job 当场被取消，只能重跑。
> 豁免的代价是 runner 继续用旧库直到下次重启 —— 所以要配一条运维纪律：**每月找个没有 job 的时候重启一次机器**
> （见 08 章 8.6）。`unattended-upgrades` 默认 `Automatic-Reboot "false"`，不会自己重启机器，这点不用改。

### 4.3 runner 的 systemd 加固

出厂 unit 的 `[Service]` 段**只有** `ExecStart` / `User` / `WorkingDirectory` / `KillMode` / `KillSignal`。
也就是说 **`Restart` 默认是 `no`——listener 一死就永久死着**，
而 GitHub 侧的 `online` 状态有分钟级延迟，你不会立刻发现。

```ini
[Unit]
After=docker.service docker.socket
Wants=docker.service
StartLimitIntervalSec=0        # ← 缺这行等于白写，见下

[Service]
Restart=always
RestartSec=10
OOMScoreAdjust=800
MemoryAccounting=yes
MemoryMax=6G
```

四条各有理由：

- **`After=docker`**：出厂 unit 不写这个依赖。实测 runner 就绪比 dockerd 只晚 1.3 秒且完全无序
  ——重启后可能先接到 job 再有 docker。
- **`StartLimitIntervalSec=0`**：systemd 默认 `StartLimitBurst=5` / `Interval=10s`。
  不关掉的话 `Restart=always` 在连续失败 5 次后会被打成 `failed` 并**停止重试**。
  **只写 `Restart=always` 是不够的**，这是最容易漏的一行。
- **`OOMScoreAdjust=800`**：swap=0 的机器上 OOM 是 kill 不是变慢，而内核按 RSS 挑受害者、
  **不知道谁是客人**。这一行让 CI 先死，别把 sshd 带走。
- **`MemoryMax`**：一个失控的 job 只杀死自己。
  ⚠️ 它只管 runner 进程树；**CI 起的容器是 dockerd 的子进程，逃在外面**，
  要靠 `--cgroup-parent` 或给服务容器加 `--memory` 才管得住。

验证：`systemctl show <unit> -p Restart -p StartLimitIntervalUSec -p MemoryMax -p OOMScoreAdjust`

### 4.4 清理：三处都要挂

```
ACTIONS_RUNNER_HOOK_JOB_STARTED     ← 主力
ACTIONS_RUNNER_HOOK_JOB_COMPLETED   ← 顺手
ci-cleanup.timer（每日）             ← 兜底
```

**为什么 `JOB_STARTED` 是主力**：它在**下一个** job 开始前跑，不管上一个是怎么结束的。
我原来写的理由是「`JOB_COMPLETED` 在 job 被 `cancel-in-progress` 取消时根本不执行」——
**上线一个月的数据推翻了这句**：38 个被取消的 job **两个钩子都执行了**（runner 2.33x）。
真正跑不到 `JOB_COMPLETED` 的是两种少见情况：job 在初始化阶段就被取消、runner 服务被停掉。
结论不变（`JOB_STARTED` 仍是更可靠的那个），理由要改。

**为什么还要 timer**：两个钩子在 **runner 进程被杀**时都不执行。

清理脚本的关键（`scripts/ci-cleanup.sh`），上线一个月（约 2200 个 job）后的实际作用：

| 命令 | 作用 | 说明 |
|---|---|---|
| `docker volume prune` | **每个 job 约 70 MB** | **唯一持续在回收的一步**。service 容器被 runner 用不带 `-v` 的 `rm --force` 删掉，留下匿名卷（主要是 PGDATA） |
| `docker image prune`（悬空）+ 按 CI 标签的 `-a` | 换 pin 后的旧版本 | 带标签那条要 workflow 的 `docker build` 打标才匹配得到，否则匹配 0 个 |
| ~~`docker buildx prune --filter until=24h`~~ | **已删** | 原表写它回收 5896 MB 是「主力」——那是攒了几天之后**一次性**清掉的量。持续负载下缓存 24 小时内都被用过，它几乎删不到东西，只在空闲一天以上后把缓存清空、让下一次构建变冷。缓存上限靠 4.1 节 daemon.json 里的 GC 策略 |
| `fuser -k <app_ports>/tcp` | — | 上一次 run 的宿主孤儿进程（见 05 章「假绿」那条） |

> ⚠️ **钩子要防「撞上正在跑的 job」**。runner 自己调钩子时本机只有这一个 job，没问题；
> 但每日 timer、`verify.sh`、手工执行都可能正好撞上一个在跑的 job，而钩子会删掉它的容器、杀掉它的 e2e 进程。
> 脚本开头的守卫：父进程不是 `Runner.Worker` 且有 `Runner.Worker` 在跑，就直接退出。
> 判断「有没有 job」要用 `pgrep -x Runner.Worker`（按进程名精确匹配），别用 `-f`——
> 后者匹配整条命令行，有人在 `grep Runner.Worker` 时就会误判。
>
> timer 的 unit 要写 `User=runner`：钩子文件归 runner 所有、runner 可写，不该以 root 执行它。

> ⚠️ **绝不裸 `docker system prune`、绝不用不带 label 的 `-a`**。
> 那会连基础镜像一起删，把「稳态 Docker Hub 消耗 ≈0」变回每次冷拉。

### 4.5 挡住 CI 读云 metadata

云 metadata 服务（`169.254.169.254`）对 CI job 与容器**都是可达的**，里面常有初始 root 口令、
公钥、网络配置。两条规则，一条管容器、一条管宿主进程：

```bash
iptables -I DOCKER-USER -d 169.254.169.254 -j DROP
iptables -I OUTPUT -d 169.254.169.254 -m owner --uid-owner $(id -u runner) \
         -j REJECT --reject-with icmp-port-unreachable
netfilter-persistent save
```

**两条都要**：`DOCKER-USER` 只管容器流量，而 **CI job 的 shell 是宿主进程**，`DOCKER-USER` 管不到它。
root 仍可读（cloud-init 要用）。

> **参考项目**：metadata 的 `vendor_data` 里确实有 cloud-init 写的 root 口令，容器内能取出来。
> 不过与 `/etc/shadow` 的 hash 逐位比对后**不匹配**——口令在 cloud-init 之后已被改过，
> 泄露的是陈旧凭据。所以这条是**纵深防御**，不是正在流血的洞。（比对是必须做的一步，
> 提出这条的人没做，直接判了「阻塞」。）

### 4.6 SSH：唯一可能把你锁在门外的动作

`bootstrap.sh` **默认不做**这条，要 `--harden-ssh` 才执行。

**做之前必须查一件事：这台机上的人现在是怎么登录的。**

```bash
journalctl -u ssh --since "-30d" --no-pager | grep -oE "Accepted (publickey|password)" | sort | uniq -c
stat -c '%y' /root/.ssh/authorized_keys      # 公钥是什么时候装的
```
把两者对时间线：如果口令登录**全部发生在公钥装上之前**，说明那些人已经切到公钥了，可以关。
如果**公钥装上之后仍有口令登录**，说明有人还在用口令——**不能关**，先让他们配公钥。

> **参考项目**：8 次口令登录全在 `09-06 14:18–14:54`，而 `authorized_keys` 写于 `14:54:52`
> （他登进来就是为了装公钥）。此后 11 次登录全是 publickey，零口令。⇒ 可以关。

```
# /etc/ssh/sshd_config.d/00-hardening.conf
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
```

> ⚠️ 文件名**必须以 `00-` 开头**：`sshd_config.d` 是**首次出现者胜**，
> 必须排在 cloud-init 写的 `50-cloud-init.conf`（里面是 `PasswordAuthentication yes`）之前。

**执行纪律**：`sshd -t` → `systemctl reload ssh`（reload 不踢现有连接）→ `sshd -T` 确认
→ **另开一个终端验证能登入** → 才算完成。

```bash
ssh -o PasswordAuthentication=no root@<IP>   # 强制不用口令，能进说明公钥这条路通
```

进不去就在**当前还活着的会话里**回滚：
```bash
rm -f /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh
```

如果你担心「改完之后、验证之前」会话就断了，可以挂一个安全网：`scripts/ssh-guard.sh`
配一个 3 分钟的 timer，**只有在「一条 SSH 会话都不剩」时才回滚**——你正常连着时它不会乱动，
而你真被踢下线且进不来时它会自愈。

```bash
install -m 0755 scripts/ssh-guard.sh /usr/local/bin/ssh-guard.sh
touch /root/.ssh-hardening-unconfirmed          # 「还没确认」的标记
# 配一个 OnUnitActiveSec=3min 的 systemd timer 跑它
# 你验证能登入之后：rm 掉标记文件 + 停掉 timer，加固即永久生效
```

### 4.7 云防火墙：唯一挡得住 Docker 的那一层

**这一条脚本做不了，必须去云厂商控制台配。**

为什么不能只靠宿主 ufw：**Docker 会自己往 iptables 写 DNAT 规则，结构性地绕过 ufw**。
「我在防火墙封了 3000」在容器端口这种形态下多半是假的。云防火墙在虚拟机外面，Docker 改不了。

它挡的是**容器端口绑回环也盖不住的东西**：CI 里在**宿主**上监听的进程
（比如 e2e 直接 `spawn` 起来的应用服务器）。那不是容器，没有 `-p` 可以绑。

配置：**入方向只放行 22**（建议限来源 IP），出方向全放。

对 CI 的影响：**零**。runner 是**出站**长轮询去 GitHub 领活，不需要任何入站端口。
但要知道：以后想在这台机上跑任何对外服务，得回控制台加规则。

---


---

## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

**这一章是整本手册最可迁移的部分。** 前面几章换个云厂商就要调，这一章对任何仓库都成立。

托管 runner 每个 job 一台**全新的一次性 VM**：`/tmp` 是空的、容器名没人用过、端口没人占、
磁盘是干净的、跑完即焚。几乎每个仓库的 workflow 里都沉淀了一批依赖这些性质的写法——
它们在托管上永远不会出问题，**所以也永远不会被发现**。

下面十一条，每条给：**怎么自查 → 失败长什么样 → 怎么改**。
建议直接当 checklist 逐条过一遍你的 workflow。

---

### ① 固定容器名

**自查**
```bash
grep -rn -- '--name ' .github/workflows/ ; grep -rc 'docker rm\|docker stop' .github/workflows/
```
起了容器但 `docker rm` 出现 0 次 = 命中。

**失败长什么样**
```
docker: Error response from daemon: Conflict.
The container name "/minio" is already in use by container "7eb4689c...".
```
**第 2 个 run 就红**，而且报错跟代码毫无关系。

更硬的一种：**同一个 run 里的两个 job 用同一个写死的名字**。托管上它们是两台独立 VM，永不相干；
N=1 的自建机上两个 job 串行同机，第一个不清理 ⇒ 第二个**必然**冲突。这不是概率问题。

**怎么改**
```yaml
env:
  # 唯一到 run × attempt × job 三级：
  #  · run_attempt 是真判据 —— re-run 时 run_id 不变
  #  · github.job 不可省 —— 同一个 run 里的两个 job 只到 run 级仍会自撞
  SVC_NAME: myservice-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}
  CI_LABEL: com.myorg.ci=1          # 与 bootstrap.sh 的 CI_LABEL 完全一致
steps:
  - run: |
      docker rm -fv "$SVC_NAME" 2>/dev/null || true     # 起前幂等
      docker run -d --name "$SVC_NAME" --label "$CI_LABEL" ...
  - if: always()                                         # 取消/失败也要清
    run: docker rm -fv "$SVC_NAME" 2>/dev/null || true
```
- **`--label` 的值必须和 bootstrap.sh 的 `CI_LABEL` 一模一样**，清理钩子第 1 步按它删「上一个 job 没删掉的容器」。
  （本模板原来写的是 `--label ci=1`，跟任何 `CI_LABEL` 都对不上。）
- **`rm -fv` 不是 `rm -f`**：镜像声明了 `VOLUME`（minio、postgres、redis、prometheus 都声明了）就会建匿名卷，
  `-v` 才会连卷一起删。本模板原来写的是 `rm -f`，参考项目照抄后每个 job 漏 1 个卷。
  **`docker run --rm` 救不了**：实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下——
  `--rm` 只在容器自己退出或被 `docker stop` 时生效。
- 钩子**不是**只按 label 过滤：第 6 步是一条不带过滤的 `docker volume prune`（本模板原来说「绝不裸 prune」，不对）。
  它是匿名卷的兜底；workflow 侧写对 `-v`，就不必依赖它。service 容器的卷见 ⑫。

---

### ② 服务端口默认绑 `0.0.0.0`

**自查**
```bash
grep -rn "ports:" .github/workflows/ | grep -v "127.0.0.1"
```

**失败长什么样**
不会失败——**这才是问题**。它只是把你的数据库开在公网上。

> **实测**：`ports: ['5433:5432']` + 明文 `POSTGRES_PASSWORD` ⇒
> check-host.net 的四个境外节点**全部成功建立 TCP 连接**并收到 Postgres 认证响应。
> 而宿主的 `ufw` 是 inactive 也无所谓——**Docker 的 DNAT 本来就绕过它**。

**怎么改**
```yaml
services:
  postgres:
    ports: ['127.0.0.1:5433:5432']    # runner 把三段式原样透传给 docker create（已实测）
```
效果：localhost 可连、公网 `Connection refused`。

---

### ③ 固定 `/tmp` 路径

**自查**
```bash
grep -rn '/tmp/' .github/workflows/
```

**失败长什么样**（三种，第三种最危险）
1. **权限**：文件属于别的用户 ⇒ `tee: /tmp/x.log: Permission denied` 硬失败。
2. **并发**：两个 job 写同一路径 ⇒ 断言读到别人的数据。
3. **陈旧读取（静默假绿）**：写文件那步失败了，而**上一次 run 留下的同名文件**里
   恰好有你 grep 的那个字符串 ⇒ 断言**通过**。一条本该发现问题的检查，
   悄悄变成永远绿的摆设。托管上不可能发生，常驻机器上是一句 `rm` 之差。

**怎么改**：一律用 `$RUNNER_TEMP`（runner 每 job 新建并清理，托管与自建行为一致）。
```yaml
- run: mycmd | tee "$RUNNER_TEMP/out.log" && grep -q "expected" "$RUNNER_TEMP/out.log"
```

---

### ④ 依赖预装工具

**自查**
```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|zstd|unzip)\b' .github/workflows/ | sort -u
# 然后在 runner 上：for c in <上面这些>; do command -v $c || echo "缺 $c"; done
```

**失败长什么样**——**分两级，第二级更麻烦**：
- 命令**没有** `||` 兜底 ⇒ 硬失败（`bash -e`），至少你看得见。
- 命令**有** `|| fallback` ⇒ **静默降级**。路径门控退化成全跑、定时任务恒跑、某个检出被跳过。
  **你会以为门禁还在跑，其实已经不在了。**

**怎么改**：装上；并把工具清单写进你的 bootstrap，别靠记忆。

---

### ⑤ 依赖「全新文件系统」的缓存语义反转

**自查**：workflow 里有 `actions/cache` 或 `setup-*` 的 `cache:` 选项。

**在托管上**它是必需的（VM 每次都是空的）。
**在常驻机器上**它变成**净负担**——把本地已经有的东西传到云上再传回来。

> **实测**：`actions/setup-node` 的 `cache: pnpm` 每 run 从 GitHub 缓存服务恢复 **~218 MB**，
> setup-node 步骤 **11–12 秒**；去掉后 **1 秒**，而 `pnpm install` 仍是 6 秒（本地 store 常驻）。
> 净省约 10 秒/run + 218 MB 流量。

**怎么改**——但先想清楚回退：
去掉它，回落托管时每个 job 要多付一次冷装（~52 秒）。想两头兼得的条件写法是**做不成的**：

```yaml
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # ❌ 不成立
# GitHub 表达式里 && / || 返回操作数的值，而空串是 falsy：
# CI_RUNNER 已设 → (CI_RUNNER && '') = '' → '' 是 falsy → ('' || 'pnpm') = 'pnpm'
# 永远产出 'pnpm'。写 'none' 之类会让 setup-node 直接报错。
```
所以：**要么接受 10 秒，要么接受回退时慢**。参考项目选了保留（10 秒占单 run 的 3%）。

---

### ⑥ 清理钩子在 job 被取消时不执行

见 04 章 4.4。这里只强调自查点：**你的 workflow 里有 `cancel-in-progress: true` 吗？**
有的话，任何写在最后一步的清理都会被跳过。用 `if: always()`，并在 runner 侧挂 `JOB_STARTED` 钩子兜底。

---

### ⑦ `timeout-minutes` 的语义反转

**托管上**它是「这个 job 最多烧多少钱」，跑飞了只烧自己那台一次性 VM。
**N=1 的自建 runner 上**它变成「**全组 CI 停摆的上界**」——一个卡死的 job 独占唯一的 runner，
后面所有 PR 一起等。

**自查**
```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> **参考项目**：现值是实测时长的 **8–150 倍**
> （lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。
> 一次 ci run 最坏占用 15+15+30+30 = **90 分钟**。按「实测 p95 × 4」重设后是 **29 分钟**。

⚠️ `timeout-minutes` **只从 job 开始执行才计时，排队不计**——它管不了「机器宕机导致排队 24 小时」，
那是哨兵的活（06 章）。

---

### ⑧ job 级并行的假设

**托管上**多个 job 并行免费（各自一台 VM）。**N=1 上它们串行排队**，
每多一个 job 就多付一次脚手架。

但**别急着合并 job**。先量两个数：

```
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```
> **参考项目**：托管上脚手架 ≈ **52 秒/job**（合并 4→1 省 156 秒）；
> 自建机上只有 ≈ **16 秒/job**（合并只省 48 秒）——因为常驻机器上依赖早就在盘上了。
> **收益缩水 3 倍**，而代价（文档同步、required check 粒度、回退时降级）一点没少。

**判断方法**：用真实事件时间戳做排队仿真（08 章），比较「合并 job」与「别的提速手段」的实际收益。
参考项目的结论是：合并 job 与「修 Dockerfile 层序 + 去 cache」**等效**（最忙那天 11.7 vs 11.2 分钟），
而后者不动一行文档。**先做后者。**

---

### ⑨ 孤儿进程导致的假绿（最阴的一条）

**自查**：workflow / 测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？
如果就绪判据只是 `curl <url>`，而**不校验回答者是不是自己刚起的那个进程**，就命中。

**失败长什么样**
```
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在**孤儿**上
```
> **实测**：用一个孤儿进程占住端口后跑 e2e，**221 条里 220 条通过**，
> 唯一那条红叉还指向认证代码而非真实病因。换一个状态不敏感的孤儿就是**全绿**。
> 也就是说：**整套 e2e 跑在上一次 run 的代码上，而 CI 是绿的。**

孤儿从哪来：`teardown` 只有一行 `proc.kill()`，而 job 被取消时它**不执行**；
runner 的 `KillMode=process` 也不杀子进程。

**怎么改**（三层，至少做前两层）
```ts
// ① 起之前先确认端口没被占 —— 用裸 TCP 连接，不依赖对方回什么
async function assertPortFree(port: number) {
  const busy = await new Promise<boolean>((res) => {
    const s = connect({ port, host: '127.0.0.1' });
    const done = (v: boolean) => { s.destroy(); res(v); };
    s.setTimeout(2000);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error',   () => done(false));
  });
  if (busy) throw new Error(`端口 ${port} 已被占用——多半是上一次 run 的孤儿进程。先清掉再跑。`);
}
```
```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
fuser -k 3100/tcp 3101/tcp 2>/dev/null || true
```
③ 云防火墙挡住这些宿主端口（它们不是容器，`-p 127.0.0.1` 管不到）。

---

### ⑩ 宿主进程绑 `0.0.0.0`

②只管容器。**测试直接 spawn 起来的应用进程是宿主进程**，没有 `-p` 可以绑。

**自查**：`grep -rn "0\.0\.0\.0\|listen(" <你的应用入口>`

**怎么改**：优先靠**云防火墙**（04 章 4.7）——因为它不走 DOCKER 链，主机/云防火墙对它有效。
改应用代码的绑定地址也行，但要先确认不会破坏容器形态（容器内必须绑 `0.0.0.0`
才能被发布端口触达），并且别和仓库已有的绑定地址约定打架。

---

### ⑪ 供应链：爆炸半径变了

**自查**
```bash
grep -rhoE 'uses: [^ ]+' .github/workflows/ | sort -u    # 有几个钉在浮动 major tag 上
grep -rn 'image:' .github/workflows/ | grep -v '@sha256'  # 有几个镜像没钉 digest
```

**为什么在自建上更要紧**：同一个「上游 tag 被重指向」事故，
在托管上是**泄露一台一次性 VM**，在你的机器上是**宿主 root**（因为 runner 在 `docker` 组）。

**怎么改**：action 钉 commit SHA + 开 dependabot；镜像钉 digest。

### ⑫ 匿名卷：service 容器和自己起的容器都会留（上线一个月后补）

**自查**
```bash
docker volume ls -q | wc -l                       # 在一台常驻 runner 上看；钩子没在跑的话会一直涨
grep -rn 'docker rm -f ' .github/workflows/ tools/ | grep -v -- '-fv'   # 应为空
```

**机制**：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；
删容器时不带 `-v` 卷就留下。两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | **runner 自己**，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，改 `rm -fv`（见 ①） |

参考项目每个用到数据库的 job 漏 3 个卷（postgres + redis + minio），约 70 MB，大头是 PGDATA。
清理钩子的 `docker volume prune` 每个 job 前后都在回收，所以那台机器上卷数始终是 0——
**但这是钩子在兜底，不是 workflow 写对了**。换一台没装钩子的常驻 runner，卷数就会一直涨。

**怎么改**：给 service 容器挂 tmpfs，卷从源头就不产生（2026-10-16 在参考机上实测：postgres 正常启动、
`docker inspect` 的 Mounts 为空、删容器后新增卷 0 个）：
```yaml
services:
  postgres:
    image: pgvector/pgvector:0.8.7-pg18@sha256:...
    options: >-
      --tmpfs /var/lib/postgresql:size=1g
      --health-cmd "pg_isready -U app" ...
  redis:
    image: redis:7-alpine
    options: --tmpfs /data:size=64m
```
⚠️ **tmpfs 的路径必须是镜像声明的 VOLUME 路径**，用 `docker image inspect <镜像> --format '{{json .Config.Volumes}}'` 查。
postgres 18 的镜像声明的是 `/var/lib/postgresql`，**不是**大家熟悉的 `/var/lib/postgresql/data`（那是 16 及以前的）。
写错了不报错，只是卷照样建、照样漏。tmpfs 占内存（参考项目约 50–120 MB/job），记在容器的 cgroup 上，
不在 runner 的 MemoryMax 里，但没有 swap 的机器上它占的是真内存，`size=` 必须写。

**顺带**：`docker build` 也打上 `--label "$CI_LABEL"`，清理钩子才能删掉过期的 CI 镜像（不打标时那条匹配 0 个）。

---

### 改造完的自查

```bash
grep -rn -- '--name '        .github/workflows/ | grep -v 'run_id'      # 应为空
grep -rn 'ports:'            .github/workflows/ | grep -v '127.0.0.1'  # 应为空
grep -rn '/tmp/'             .github/workflows/                        # 应为空或已确认无害
grep -rc 'if: always()'      .github/workflows/*.yml                   # 清理步骤应该有
grep -rn 'docker rm -f '     .github/workflows/ | grep -v -- '-fv'      # 应为空（⑫）
```

---


---

## 06 接线与回退

**顺序不能反**：先改完 05 章的 workflow 并合进 main，**再**打开开关。
反过来做的话，第 2 个 PR 就会红。

### 6.1 开关的形状

不要把 `runs-on` 写死成自建标签——那样切回托管要开 PR、等 review、等 CI，
而你需要它的时候正是机器出事的时候。用仓库变量：

```yaml
runs-on: ${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}
```

- 变量**没设** ⇒ `fromJSON('"ubuntu-latest"')` ⇒ 落托管，**行为与改造前逐字相同**
- 变量**设了** ⇒ 落自建

这意味着**可以先把改造合进 main、观察几天、再决定什么时候切**。

```bash
# 开
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'
# 关
gh variable delete CI_RUNNER --repo owner/repo
```

### 6.2 ⚠️ 变量值必须是合法 JSON

```bash
gh variable set CI_RUNNER --body 'ubuntu-latest'      # ❌ 裸字符串
```
失败形态**非常难查**：不是「回退没生效」，而是

> **整个 workflow 解析失败、产生 0 个 job、run 直接红，而且页面上没有任何 job 可以点开。**

正确写法：数组 `'["self-hosted","linux","x64","ci"]'`，单值要带引号 `'"ubuntu-latest"'`。

### 6.3 开关**救不了已经排队的 job**

实测：停掉 runner 让 job 进入 `queued`，然后删掉变量——
**t+20/40/60/80/100/120 秒，那个 job 全部仍是 `queued`，纹丝不动。** runner 恢复后才跑掉。

而 GitHub 对排队 job 的自动取消是 **24 小时**。也就是说：**机器半夜挂了，全组 PR 卡到你醒**。
`timeout-minutes` 帮不上忙——它只从 job **开始执行**才计时。

**切回时的正确动作**：
```bash
gh variable delete CI_RUNNER --repo owner/repo                       # 1. 新 run 立刻走托管
gh run list --status queued --json databaseId -q '.[].databaseId' \
  | xargs -r -I{} gh run cancel {} --repo owner/repo                 # 2. 取消卡住的排队 run
# 3. 在各 PR 上 Re-run，或推一个空 commit
```

### 6.4 哨兵：机器挂了要有人知道

N=1 是单点，而上面那条说明「挂了」的代价是 24 小时。所以必须有告警。

> ⚠️ **一个流传很广但付不起的方案**：「配一个跑在托管上的哨兵，每 13 分钟查排队队列」。
> 按每 job 向上取整计费，那是 **3323 计费分钟/月——比整个免费额度（2000）还多**。
> 一个为了省额度而做的自托管方案，配一个吃掉全部额度的哨兵，是自相矛盾的。

| 频率 | run/月 | 计费分/月 |
|---|---|---|
| 每 13 分钟 | 3323 | **3323** ❌ |
| 每 30 分钟 | 1440 | 1440 ❌ |
| 每小时 | 720 | 720 ⚠️ |
| 每 6 小时 | 120 | 120 ✅ |

**推荐做法：两层，主层不花 GitHub 分钟。**

**① 主：机器侧 dead-man's-switch（0 计费分钟）**
用任意免费心跳服务（healthchecks.io / UptimeRobot / Better Stack）：
```ini
# /etc/systemd/system/ci-heartbeat.service
[Service]
Type=oneshot
# 只有 runner 服务真的在跑时才上报 —— 机器活着但 runner 死了也要能发现
ExecStart=/bin/bash -c 'systemctl is-active --quiet <runner-unit> && curl -fsS -m 10 --retry 3 https://hc-ping.com/<UUID> >/dev/null'
```
配一个 5 分钟的 timer。覆盖：机器宕机、网络断、runner 进程死。

**② 兜底：搭已有 workflow 的车（0 新增计费 run）**
如果你有一个每个 PR 都跑、且**留在托管上**的轻 workflow（比如元数据校验），
在它末尾加一个 `if: always()` 的 step：

```yaml
- name: 自建 runner 排队哨兵
  if: always()
  env: { GH_TOKEN: "${{ github.token }}" }
  run: |
    now=$(date -u +%s); stuck=0
    for t in $(gh api "repos/${{ github.repository }}/actions/runs?status=queued&per_page=50" \
               --jq '.workflow_runs[].created_at' 2>/dev/null); do
      [ $(( now - $(date -u -d "$t" +%s) )) -gt 900 ] && stuck=$((stuck+1))
    done
    [ "$stuck" -gt 0 ] && echo "::warning::有 $stuck 个 run 排队超过 15 分钟——自建 runner 可能已下线"
    exit 0    # 哨兵绝不让宿主 workflow 变红 —— 它是金丝雀，不是门禁
```
局限：只在有人开 PR 时才跑，静默期不覆盖——那段靠 ①。

> ⚠️ **查排队队列，别查 `/actions/runners` 的 online 状态**。
> 实测 `systemctl stop` runner 之后，那个字段**仍然显示 online**（分钟级延迟），是不可靠信号。

### 6.5 留一个 workflow 在托管上

建议**不要把所有 workflow 都搬过去**。留一个每 PR 都跑的轻 workflow 在 `ubuntu-latest`：

- 它是**托管金丝雀**——自建机死了它照样给结果，你一眼能看出是「机器挂了」还是「代码错了」
- 它是挂哨兵最便宜的位置（6.4 ②）
- 如果它依赖某个只在托管上预装的工具，留着就不用在自建机上复刻

> **参考项目**：`pr-meta.yml` 钉死 `ubuntu-latest`——它只要 10 秒，
> 搬过去反而要排在 5 分钟的重 job 后面；而且它是全仓唯一一处没有 `||` 兜底的 `gh api`。

### 6.6 上线动作

```bash
# 1. 确认 runner 在线且空闲
gh api repos/OWNER/REPO/actions/runners --jq '.runners[]|{name,status,busy}'

# 2. 合入改好的 workflow（此时变量未设 ⇒ 行为与合并前逐字相同，先验证这一步不改变任何东西）

# 3. 打开开关
gh variable set CI_RUNNER --repo OWNER/REPO --body '["self-hosted","linux","x64","ci"]'

# 4. 开一个空改动的测试 PR，确认各 check 都出现、都落到你的 runner、都绿
#    ★ 再开第二个 PR —— 那才是验证「容器名冲突」修复的地方
```

---


---

## 07 验证

装完不等于好了。这一章是**怎么证明它真的好了**。

一条命令跑机器侧的全部检查：

```bash
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh
```

**重启之后也跑这一条就够了**——它逐项核对开机恢复路径是否真的自愈了。

> ⚠️ **它不是纯只读的**。「钩子实跑」那条会真的执行一次清理钩子：删带 CI 标签的容器、删 minio、
> 杀 e2e 端口上的进程。有 job 在跑时执行就是把那个 job 打断。所以脚本会先看有没有 `Runner.Worker` 进程，
> 有就把这条和「无残留容器」标成 **SKIP**。看到 SKIP 说明当时机器在忙，等空闲再跑一次拿完整结果。
> （这个脚本原来自称「只读」，08 章又把它列为日常巡检——2026-10-16 才发现两者叠在一起是个陷阱。）

### 7.1 `verify.sh` 查什么

| 分组 | 项 | 不通过意味着 |
|---|---|---|
| 服务与开机自启 | docker / containerd / runner 三个 unit `active + enabled` | 重启后回不来 |
| runner 加固 | `Restart=always`、`StartLimitIntervalSec=0`、`MemoryMax`、`OOMScoreAdjust≥500`、`After=docker` | 见 04 章各条的后果 |
| Docker | `live-restore=true`、BuildKit GC 有 **Max Used 与 Min Free 两项** | 只有 Reserved 说明你用了 `defaultKeepStorage`，Min Free 保护丢了 |
| 清理与监控 | **钩子按 `bash -e` 实跑一次能退出 0**（有 job 时 SKIP）、钩子带运行中 job 守卫、占位符已替换、清理脚本在、**两个钩子都挂**、timer active 且以 runner 身份运行、监控量的是 `/var/lib/containerd`、磁盘阈值与 GC 对齐、告警推送已配 | 钩子在 `-e` 下非零 = **每个 job 全红**（见下方 ⚠️）；没守卫 = timer 撞上 job 会删它的容器；阈值没对齐 = 每小时误报；没配推送 = 告警没人看 |
| 部署参数与系统更新 | `/etc/ci-runner.env` 存在且与钩子的 CI 标签一致、needrestart 豁免 runner、有没有待重启的更新 | 参数没落盘 = 下次重新部署静默改回默认值；没豁免 = 安全更新在 job 中途重启 runner |
| 网络加固 | DOCKER-USER + OUTPUT 两条 metadata 规则、已持久化、**实拨容器验证** | 少一条就有一条路通 |
| SSH | 口令登录是否关闭 | — |
| 干净度 | 无残留容器（有 job 时 SKIP）、匿名卷没有累积、磁盘余量 | 清理没生效 |
| GitHub 侧 | runner `online` | 注册或网络问题 |

> ⚠️ **为什么「清理与监控」那一行的第一项是「实跑一次」而不是「文件在不在」**
>
> 2026-09-07 到 09-14，这台机器连续 7 天、21 个 job 全部失败，而**这张表当时报 24 PASS / 0 FAIL**。
>
> 原因是那三条钩子检查全是**结构性**的——查文件可执行、查 `.env` 挂了两个变量、查 timer active。
> 三条都 PASS，三条也都**没说错**。没有一条执行过那个钩子。
>
> 而 runner 调钩子时会**强加 `-e`**，钩子非零退出就把 job 判失败（详见 09 章 A11）。
> 「装上了」和「真能用」之间隔着一次真实调用，这张表当时站在错误的那一侧。
>
> **推广到所有自检**：凡是「非零退出会产生后果」的东西，自检必须**用调用方完全相同的方式执行它一次**。
> 检查它存在，等于没检查。

### 7.2 机器侧之外：必须用真实 PR 验的四件事

`verify.sh` 验不了这些，只能开 PR：

**① 第一个测试 PR：check 落到自建机且全绿**
```bash
gh api repos/OWNER/REPO/actions/runs/<id>/jobs --jq '.jobs[]|"\(.name) \(.conclusion) \(.runner_name)"'
```
要看到 `runner_name` 是你的 runner 名，不是 `GitHub Actions ####`。

**② 第二个测试 PR：这才是验容器名冲突修复的地方**
第一个 PR 绿不能证明什么——**改之前也是第一个绿、第二个红**。必须连开两个。

**③ 手动触发定时任务：验「同一个 run 内两个 job 自撞」**
如果你有一个 workflow 里有两个 job 都起同名容器（很常见），
`workflow_dispatch` 触发一次，确认**两个 job 都绿**。

> ⚠️ **必须 `workflow_dispatch`，不能等 schedule 自己跑。**
> 省钱型的 nightly 通常前面挂了一道 gate（「空转的夜不跑」）。gate 在
> `event != schedule` 时恒 `run=true`，而 schedule + 无新提交时 `run=false`，
> **会把重活 job 全部跳过**。等一夜你只会拿到一个「gate 绿了、别的没跑」的假绿，
> 而它在 GitHub 上和真绿长得一模一样。
> 修完东西要验证，永远手动触发。

**④ 开关双向**
- 变量未设时开 PR ⇒ 应落 `ubuntu-latest`
- 变量设了再开 PR ⇒ 应落你的 runner

> **参考项目的实际验证记录**：
> 前两个 PR（开关变量未设）→ 运行者显示 `GitHub Actions ####`；
> 后两个 PR（开关变量已设）→ 显示自建 runner 名。
> 四个 check：lint 52s / typecheck 73s / build 31s / verify 189s，全绿。
> nightly 手动触发：gate 4s + regression 189s + selftests 258s，两个起同名容器的 job **都绿**。

### 7.3 破坏性验证（值得做一次）

这些是「保护措施到底有没有用」的直接检验：

**runner 自愈**
```bash
kill -9 $(systemctl show <runner-unit> -p MainPID --value)
# 期望：10–30 秒内自动拉起，MainPID 变了
```
> 实测 30 秒内回来。改之前（`Restart=no`）是永久死着。

**公网暴露**（在 CI 跑着服务容器时，或手动起一个同样绑法的容器）
```bash
# 用外部节点探，别在本机探自己的公网 IP —— 那只走本地路由栈，证明不了外部可达性
curl -s -H "Accept: application/json" "https://check-host.net/check-tcp?host=<你的IP>:5433&max_nodes=4"
```
> 实测修复前四个境外节点全部成功连上并收到 Postgres 认证响应；修复后全部 `Connection refused`。

**孤儿进程假绿**（如果你的测试有「起进程 + 轮询健康端点」的模式）
```bash
# 先用一个进程占住端口，再跑测试。期望：当场失败并指名道姓，而不是跑出一堆绿
```
> 实测修复前 **220/221 通过**（测的是孤儿），修复后**退出码 1 + 明确报错**。

**开机恢复**——见下。

### 7.4 重启演练

**这是唯一必须承担一次中断的验证，但它验的是最要紧的东西**：机器重启后能不能自己回来。

注意一个容易忽略的事实：**docker 和 runner 通常是开机之后才装的**，
所以「开机自启」这条路径在你主动重启一次之前，**从来没有被执行过**。
三个 unit 都 `enabled` 只证明配置对，不证明顺序对、不证明 iptables 规则持久化了。

```bash
# 重启前：记基线
systemctl is-enabled docker containerd <runner-unit>
iptables -S | grep -c 169.254.169.254
systemctl list-timers --no-pager | grep ci-

sudo reboot

# 回来之后：一条命令
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh
```

⚠️ 如果你的 CI 助手/终端就跑在这台机上，**重启会把它一起杀掉**——所以把重启排在最后一步。

---


---

## 08 运维与容量

### 8.1 容量：用仿真，别套公式

最常见的错误是套 `ρ = λ × S`（到达率 × 服务时长）然后按 M/M/1 算排队。
**在有 `cancel-in-progress` 的仓库里这个模型是错的**——同分支的新 push 会取消**排队中和正在跑的**旧 run，
所以「更多的到达」不等于「更多的工作」，它很大程度上是**替换**。

正确做法：拿真实事件时间戳做仿真（`scripts/analysis/queue_sim.py`）。

```python
import sys; sys.path.insert(0,'scripts/analysis')
from queue_sim import ts, simulate
events = [(ts(r['created_at']), r['name'], r['head_branch']) for r in runs]   # 从 /actions/runs 拿
svc    = {'ci': 305, 'main-post-merge': 276, 'pr-meta': 12}                    # 本机实测的服务时长
r = simulate(events, svc)
```

**两个必须注意的口径**（都是踩过的）：

**① 别剔除「额度耗尽期」的 run。** 那些 run 代表**真实需求**，只是当时没分配到 runner。
剔掉它们等于用「被服务量」预测「需求量」，是幸存者偏差。
> 参考项目：剔除后按整点分桶算得峰值 **8 run/小时**；含死 run 用滚动窗口重算是 **20**。差 2.5 倍。

**② 事件流可能需要「重建」。** 如果某个 workflow 是最近才加的，早期日期里它的事件数是 0，
拿那些日子比较「给它加 job 的代价」会得到**平凡为真**的结论。
> 参考项目：初版结论「把 selftest 挂到合并后 workflow **零排队成本**」是**语料假象**——
> 被仿真的三天里那个 workflow 还不存在。把早期的 `push→main` 重标之后重跑，
> 真实代价是最忙那天最长排队 15.5 → **22.3 分钟**。

**仿真能回答的问题**（这些都不该拍脑袋）：
- N 该是几
- 要不要合并 job（比较它与别的提速手段的实际收益）
- 能不能把某个检查加到 PR 路径上
- 团队扩到 N 人时会怎样
- 需求回弹（CI 恢复后大家推得更勤）会不会顶穿

> **参考项目**（历史最忙日，中位/p90/**最长**，分钟）：
> | 场景 | 结果 |
> |---|---|
> | 现状（2 人） | 1.8 / 9.7 / **15.5** |
> | 需求回弹 1.9× | 1.8 / 10.1 / **22.7** |
> | 团队 4 人 | 4.6 / 18.4 / **37.1** |
> | 团队 8 人 | 17.0 / 81.5 / **122.8** ← 该加第二台机器了 |
>
> 天花板约在 **4 人**。8 人要加的是**第二台机器**，不是第二个 runner（N=2 同机已实验证伪）。

### 8.2 磁盘：三个来源，一个不管另外两个

| 来源 | 谁管 | 不管会怎样 |
|---|---|---|
| BuildKit build cache | **daemon.json 的 GC 策略**（Reserved / Max Used / Min Free） | 缓存长到 Max Used 或把可用空间压到 Min Free 为止，然后 GC 开始驱逐 |
| 匿名卷（services 容器的数据） | **只有** `docker volume prune`（清理钩子每个 job 前后各一次） | **无上界**，约 70 MB/job |
| 镜像 | 悬空的由钩子清；**换掉的旧 pin 没人清**，要人工退役 | 慢慢攒，参考项目一个月攒了约 2 GB |
| Docker 以外 | 没人管 | IDE 远程服务端、旧检出、包管理器缓存……参考项目一个月涨了约 8 GB |

**「不清理会盘满」通常是错的**——BuildKit 的 GC 兜底，缓存不会无限长。
**但匿名卷不在 BuildKit 管辖内，Docker 以外的东西更没人管，那两部分才是真正无上界的。**

**上线一个月的实测**（参考项目，75 GB 盘，GC 设 Reserved 10 GiB / Max Used 20 GiB / Min Free 20 GiB，约 2200 个 job）：

| 时间 | 已用 | 可用 | 说明 |
|---|---|---|---|
| 第 1 周 | ~18 GB | ~57 GB | 原稿写的「稳态 13.7 GB / 18%」是这个阶段，**不是稳态** |
| 第 4 周 | ~49 GB（68%） | ~23.5 GB，连续 5 天不再下降 | 真正的稳态：BuildKit 缓存长满约 20 GiB，被 Min Free 顶住 |
| 清理之后 | ~39 GB（54%） | ~34 GB | 删掉 IDE 旧服务端 2.8 GB、旧检出与 pnpm store 3.4 GB、不再引用的镜像 2.0 GB |

稳态估算公式（比「基线 + 日增」可靠）：
```
稳态已用 ≈ 系统与工具链 + 在用镜像 + min(Max Used, 缓存工作集) + Docker 以外的东西
稳态可用 ≈ max(Min Free, 盘总量 − 上式)
```
缓存工作集由构建频率与层序决定（见 8.4）；它填满 Max Used 之后，**可用空间会停在 Min Free 附近，这是设计行为，不是告警**。

监控要点（`scripts/ci-health.sh`）：
- 量 **`/var/lib/containerd`**，不是 `/var/lib/docker`。Docker 29 默认用 containerd 快照器，
  实测 containerd 2.6 G vs docker 115 M——量错目录会低估约 10 倍，是另一种假绿灯。
- 匿名卷在 `/var/lib/docker/volumes`，**单独量**。
- **磁盘阈值从 Min Free 推，不要拍脑袋**。原版写死 WARN < 40 GB、CRIT < 20000 MB：前者在设计稳态下
  每小时都响（一个月 309 次，没人看），后者只比 Min Free（20480 MiB）低 480 MiB。
  现在 WARN = Min Free + 1 GiB（GC 已经顶到底线、开始被 Docker 以外的增长挤压），CRIT = 10 GiB。
  bootstrap 自动从 `BUILDKIT_MIN_FREE` 算出来写进 `/etc/cron.d/ci-health`。
- **告警要送到人**。只写本机 journal 等于没告警。`/etc/ci-health.env` 里配 `CI_ALERT_WEBHOOK`
  （飞书自定义机器人）后，告警集合一变化就推送，持续存在的每 24 小时提醒一次。
- 失败连续计数**只算跑在本机上的 run**。统计全仓库会把 GitHub 托管的检查（PR 标题之类）也算进来。
- 看**增量**不只看水位：日增超过预期两倍就该查是不是哪个构建的层序坏了。

> ⚠️ **CI 机上别常驻开发工具，或者把它们算进磁盘和内存预算**。参考机上 VS Code 远程服务端每次客户端升级
> 就多一份（约 650 MB），一个月攒了 5 份；它和 AI 助手一起常驻约 2–3 GB 内存，而这台机没有 swap、
> runner 又被设成 OOM 时第一个被杀。偶尔连上来排查可以，用完断开。

### 8.3 CPU 争抢监控

**先确认 steal 能不能用**（02 章 2.5）。不能用就采**定长任务墙钟**，
超过基线 1.4 倍报警。`ci-health.sh` 已经这么做了。

⚠️ 共享 vCPU 的邻居会变。今天不拥挤只说明此刻，所以这是**常态化采点**，不是上线前查一次。

### 8.4 构建缓存的层序（性价比最高的一次性优化）

常驻 runner 上，Dockerfile 的层序从「无所谓」变成「最贵的一步」。

**自查**：`COPY <源码>` 是不是排在 `RUN <装依赖>` 之前？

> **参考项目**：`COPY apps/api` 在 `RUN pnpm install` 之前 ⇒ 改任何一行 api 源码都重装整棵依赖树。
> 温缓存实测 **62.4 秒 / +1045 MB**，而它命中 **59.1%** 的 PR。
> 把源码 COPY 挪到 install 之后：**1.4 秒 / +8 MB**（快 45 倍、磁盘少 140 倍），镜像大小不变。

改法（先 COPY manifest，装依赖，再 COPY 源码）：
```dockerfile
COPY package.json lockfile ./
COPY packages/*/package.json ./packages/     # 各 workspace 的 manifest
RUN <装依赖>                                  # ← 只在 lockfile/manifest 变时失效
COPY packages ./packages                     # ← 源码在后面
COPY apps ./apps
```
⚠️ **必须实测三件事**再合：①构建成功；②改一行源码后温重建 <10 秒；③**镜像连真依赖起得来**
（`docker run` 起容器打健康端点，不只是 `import` 一下）。

**上线一个月后的复盘：层序改对了，缓存依据还没改对**（参考项目，2026-10）

上面的改法把源码挪到了 install 之后，但 install 层的缓存依据是**整份清单**，不只是 lockfile。两件事让它重新退化：

1. **根 `package.json` 里有 `scripts`**。团队每加一个 npm 脚本，install 层就作废。参考项目 9 月下旬起根 `package.json`
   被改了 55 次，**50 次只改了 scripts**，同期 lockfile 只变了 7 次。两周里 api 镜像冷构建 89/177 次。
2. **按应用传的构建参数放在 install 前面**（`ARG APP_FILTER` + `--filter ${APP_FILTER}`）。api 和 worker 两个镜像
   于是各存一份 install 层——实测两份内容只差 15 个文件条目（共约 99,000），是**同一份依赖存了两遍**。
   BuildKit 缓存 23.6 GB 里 98% 是这些 install 层。

改法：
```dockerfile
# ① install 不带按应用的参数：所有 node 应用共用一份依赖层
RUN pnpm install --frozen-lockfile --filter @app/api... --filter @app/worker... --filter <root>
ARG APP_FILTER          # 需要的话放到 install 之后
# ② 缓存依据去掉 scripts：前置阶段把各 package.json 的 scripts 字段删掉再 COPY 进来做 install，
#    install 之后在源码层再 COPY 一次完整的 package.json
```
⚠️ 别指望 `pnpm fetch` + `--offline` 解决：实测冷构建 65 秒里下载只占约 13 秒，大头是**导出和解包** 1.15 GB 的
node_modules 层（约 50 秒）。只有「别让它失效」和「别存两份」管用。

收益要说实话：这**不是正确性问题**。参考项目上它值每周约 1 小时 runner 时间（CI 总时长的约 3.6%），
以及让 BuildKit 的 Max Used 可以从 20 GiB 降下来、腾出 10 GB 以上磁盘。**先改 Dockerfile，再降 Max Used**，
顺序反过来只会让构建更冷。

### 8.5 什么时候该加第二台机器

信号（任一命中就该算账了）：
- 排队等待的 p90 超过单 run 时长
- 团队规模翻倍（用 8.1 的仿真验，别猜）
- 想把重检查加进 PR 路径但仿真显示会顶穿

**加的是第二台机器，不是第二个 runner。** 同机 N=2 已被实验证伪
（CPU 饥饿 flake + OOM，两种不同的失败模式）。

如果一定要在同机加第二个 runner，前置条件（通常都不满足）：
① 修掉所有固定超时的测试；② 第二个 runner 打独立 label，**只接秒级、无 DB、无 docker build 的活**；
③ 独立 `_work` 与端口；④ **必须复测**。

### 8.6 日常巡检

```bash
bash scripts/verify.sh                    # 全面自检（有 job 在跑时部分项会 SKIP，空闲时再跑拿完整结果）
tail -20 /var/log/ci-health.log           # 采点趋势：可用空间、job 连续失败、runner 内存峰值
docker system df                          # 磁盘构成
systemctl list-timers | grep ci-          # 清理与监控 timer 还活着吗
```

**每月一次，找个没有 job 的时候**（`pgrep -x Runner.Worker` 为空）：

1. **重启机器**。needrestart 已经豁免了 runner（4.2 节），安全更新装上了但 runner 还在用旧库，
   内核更新更是必须重启才生效。参考机上线 5 周没重启过，攒了 3 个新内核和一次 libc6。
   先 `systemctl stop <runner 服务>` 再重启，免得刚好接到一个 job。`live-restore` 与 `Restart=always` 会让一切自己回来，
   回来后跑 `verify.sh`。重启后 `apt autoremove --purge` 清掉旧内核。
2. **退役旧镜像**。workflow 换了 pin 之后旧版本没人删（钩子只删悬空的和打了 CI 标签的）：
   ```bash
   docker images --digests          # 对照 workflow 里实际引用的 image@sha256，删掉不再引用的
   docker image rm <旧镜像>          # 不带 -f：还有容器在用的话 Docker 会拒绝
   ```
   ⚠️ 别用 `docker image prune -a --filter until=...` 代劳：until 按镜像**创建**时间算，
   一个两年前构建、今天还在用的 pin 会被删掉。
3. **看一眼 Docker 以外的增长**：`du -sh /root/.vscode-server /root/.cursor-server /home/*/.cache` 之类。
   VS Code 远程服务端可以只留正在用的那一份（`ls ~/.vscode-server/cli/servers/`，进程在用的那个之外都能删）。

---


---

## 09 踩坑记录

分两部分：**A. 环境的坑**（下次换机器还会遇到）、**B. 我们自己判断错的地方**（方法论的坑，更值钱）。

---

## A. 环境的坑

### A1. `defaultKeepStorage` 会把 Min Free 保护丢掉

```json
{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"10GB"}}}
```
看起来对，实际上它**只映射到 Reserved Space**，出厂的 `Min Free Space` 保护没了。
而把 `reservedSpace`/`maxUsedSpace`/`minFreeSpace` 直接写在 `gc` 顶层会被**静默忽略**
（daemon 不报错，回落出厂值）。**必须用 `policy` 数组。**

**怎么发现**：改完用 `docker buildx inspect default | grep -A6 'rule#0'` 看三项在不在。

### A2. Docker 29 用 containerd 快照器，镜像不在 `/var/lib/docker`

```
/var/lib/docker      115M
/var/lib/containerd  2.6G      ← 96% 的字节在这里
```
所有 `du /var/lib/docker` 的磁盘监控在这种形态下是**假绿灯**（低估约 10 倍）。
匿名卷倒是在 `/var/lib/docker/volumes`，要单独量。

### A3. `Restart=always` 不加 `StartLimitIntervalSec=0` 等于白写

systemd 默认 `StartLimitBurst=5` / `Interval=10s`。连续失败 5 次后 unit 被打成 `failed` 并**停止重试**。
而 runner 出厂 unit **根本没有 `Restart=`**（默认 `no`）——进程一死就永久死着。

### A4. `--ephemeral` 与「不留常驻凭据」互斥

`config.sh --help` 原文是 "let **the service** un-configure the runner"，
`bin/RunnerService.js` 对 0 退出的处理是 "stop the service, **no retry needed**"。
跑完一个 job 后 runner 自己注销**并停掉服务**，`Restart=always` 也拉不回来（它已经没有注册信息了）。
要回来必须有常驻的管理员凭据。**在小团队专机上，它引入的风险大于买到的隔离。**

### A5. `needrestart` 的出厂名单里有 docker、没有 containerd

别不查就写两条。`grep -n 'docker\|containerd' /etc/needrestart/needrestart.conf` 先看一眼。

### A6. GitHub `schedule` 的派发延迟是小时级

18 次真实触发实测：**中位 97 分钟、p90 267 分钟、最大 483 分钟**。
名义「北京 05:47」实际中位落在 **07:24**，最差到过 13:50。

含义：① 靠 cron 精确控制「几点跑」是做不到的；② 需要低延迟检出的检查**别挂 schedule**，
挂 push 触发（实测排队→开始 **1 秒**）。

### A7. 常驻 runner 上缓存 pull 不扣 Docker Hub 配额

实测：3 次已缓存 `docker pull` + 2 次全 CACHED `docker build` + 1 次 `--pull=false`，
计数**一格未动**（命中 "version checks do not count towards usage"）。

⇒ 稳态消耗 ≈ 0。要防的**不是配额不够**，是「什么会把稳态 0 变回冷拉」：
清盘脚本写狠了、浮动 tag 被上游重指向。

⚠️ 另外：dockerd 可能走 **IPv6**（`getent ahosts registry-1.docker.io` 看首选地址族）。
Docker Hub 按 IPv4 地址**或** IPv6 /64 分别计数，但客户端不能选——
所以「有两份配额」是错觉，真正要盯的是它实际走的那一族。

### A8. `sshd_config.d` 是「首次出现者胜」

加固文件名必须排在 cloud-init 写的 `50-cloud-init.conf`（里面是 `PasswordAuthentication yes`）之前。
用 `00-` 前缀。

### A9. 云 metadata 对容器**和**宿主进程都可达，要两条规则

`DOCKER-USER` 只管容器流量。**CI job 的 shell 是宿主进程**，得用 `OUTPUT` + `-m owner --uid-owner`。

### A10. 别在本机探自己的公网 IP 来验证防火墙

那只走本地路由栈，证明不了外部可达性。用外部节点（如 check-host.net 的多地探测）。

### A11. runner 调 job 钩子时**强加 `-e`**，钩子里任何一条非零就让 job 全红

**2026-09-07 事故，代价：连续 7 天、21 个 job、100% 失败。**

runner 执行 job 钩子的真实命令是（Worker diag 原文）：

```
Arguments: '-e /opt/actions-runner/hooks/ci-cleanup.sh'
```

`ci-cleanup.sh` 第 16 行写的是 `set -uo pipefail`——**不含 `-e`**，但那关不掉外部传进来的 `-e`。两者叠加后，脚本里任何一条命令非零退出都会当场中止全篇，末尾那句 `exit 0   # 清理失败绝不让 job 变红` 根本执行不到。

实际引爆点是第 7 步：

```bash
ls -dt bin.* 2>/dev/null | grep -vx "$cb" | tail -n +2 | xargs -r rm -rf
```

机器上不存在 `bin.*` → `ls` 退出 2 → `grep` 无输入退出 1 → `pipefail` 把管道判为 1 → 中止。**一个纯粹的「没有垃圾要清理」的正常状态，触发了全线故障。**

三个必须记住的细节：

1. **GitHub 网页日志会骗你。** 它打印 `shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}`，但那是 `ScriptHandler.PrepareExecution` 的装饰性 banner；钩子走的是 `GetScriptArgumentsFormat("sh")` = `-e {0}` 分支。**以 `_diag/Worker_*.log` 里的 `Arguments:` 为准。**
2. **两个钩子指向同一个文件时，故障面加倍。** `JOB_COMPLETED` 带 `always()`，前面全跳过它照样跑，**单独就足以让 job 变红**。只修 `JOB_STARTED` 等于没修。
3. **温和的修法都不管用。** 只给出事那两行加 `|| true` → 仍然红（第 1 步 `docker ps | xargs` 也是管道）；改成 `set +o pipefail` → 仍然红（第 4 步是裸命令，`-e` 照杀）。

**正确修法**——在 `set -uo pipefail` 之后补两行：

```bash
set +e                # 解除外部强加的 -e
trap 'exit 0' EXIT    # 兜底：连 set -u 触发的中止也吃掉
```

**通用教训**：**写 job 钩子时，永远假设调用方会加 `-e`。** 钩子的契约是「非零 = 让 job 失败」，所以清理类钩子必须自己保证退出 0，不能依赖脚本末尾的 `exit 0`。

### A12. `sed` 把占位符和「判断占位符有没有被替换」的守卫一起换掉了

同一次事故里发现的第二个 bug，静默了同样久。

```bash
# ci-cleanup.sh
APP_PORTS="__CI_APP_PORTS__"                              # 18 行
if [ ... ] && [ "$APP_PORTS" != "__CI_APP_PORTS__" ]; then # 30 行，守卫
```

```bash
# bootstrap.sh：逐行替换，两行都会被换到
sed -e "s#__CI_APP_PORTS__#${CI_APP_PORTS}#" ...
```

替换完变成 `[ "3100 3101" != "3100 3101" ]` ——**恒假**。整个「杀上一次 run 遗留的宿主孤儿进程」永远不执行，而它防的正是本文件自己注释里写的那种假绿（e2e 跑在上一次 run 的代码上、221 条里 220 条通过）。

**教训**：**守卫不能拿被替换的值和替换目标比。** 改判前缀，`sed` 换不到它：

```bash
if [ -n "${APP_PORTS// /}" ] && [ "${APP_PORTS#__CI_}" = "$APP_PORTS" ]; then
```

### A13. 自动安全更新会在 job 中途重启 runner 服务

**2026-10-02 06:06，上线第 25 天。**

```
06:05:55  Starting apt-daily-upgrade.service
06:06:00  unattended-upgrade：libssl3t64 / openssl 3.0.13-0ubuntu3.15 → 3.16
06:06:05  Stopping actions.runner.…service      ← needrestart 判定它用了旧 libssl
```

当时正在跑的 job（`adal-fixtures (2)`）当场被取消，只能重跑。A5 只豁免了 containerd，
**runner 服务本身也在 needrestart 的自动重启范围里**，而它恰恰是最不能在 job 中途重启的那个。

**修法**：`$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;`（bootstrap.sh 已加）。
代价是 runner 继续用旧库，所以要配「每月空闲时重启」（08 章 8.6）。

**教训**：豁免名单要按「job 依赖的常驻进程」逐个过，不是只看容器运行时。

### A14. 匿名卷：`docker rm -f` 留卷、`--rm` 救不了、runner 删 service 容器也留卷

镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷。删容器时：

| 删法 | 卷 |
|---|---|
| `docker rm -f`（不带 `-v`） | **留下** |
| `docker run -d --rm` 起、`docker rm -f` 删 | **留下**（实测。`--rm` 只在容器自己退出或 `docker stop` 时生效） |
| `docker rm -fv` | 删掉 |
| runner 删 `services:` 容器（`docker rm --force <id>`） | **留下** —— workflow 管不到这条命令 |

参考项目每个用数据库的 job 留 3 个（postgres + redis + minio），约 70 MB，大头是 PGDATA。
清理钩子的 `docker volume prune` 一直在兜底，一个月约 2200 个 job 后卷数仍是 0——
但这是钩子的功劳，换一台没装钩子的常驻 runner 就会一直涨。

**从源头不产生**：步骤里起的容器改 `rm -fv`；service 容器在 `options:` 里挂 `--tmpfs <VOLUME 路径>`。
⚠️ 路径要用镜像实际声明的：postgres 18 是 `/var/lib/postgresql`，**不是** `/var/lib/postgresql/data`。
写错了不报错，卷照漏。（05 章 ⑫）

**为什么 playbook 自己漏了**：05 章 ① 的模板就写的 `docker rm -f`，参考项目照抄了。

---

## B. 我们自己判断错的地方

这部分比 A 更值钱——**它们是方法论的坑，换个环境还会以别的面目出现**。

### B1. 把「恒为 0 的计数器」当成了证据

我采了 1855 个 `steal=0` 的样本，报告「无 CPU 争抢」。
**那些样本全是同义反复**——宿主根本没暴露 `KVM_FEATURE_STEAL_TIME`，那一列结构性恒 0。

**教训**：拿到「全是 0」的观测时，**先证明这个仪器在这台机器上能读出非 0**，再解释这个 0。
我当时的直觉是对的（我加了一条时延交叉验证），但没有走完最后一步去查 CPUID。

### B2. GiB / GB 单位错，还倒打一耙

我写「7751 MB（**非** 8 GB）」「74.8 GiB（**非** 80 GB）」，说同事的数字不准。
实际 7751 MiB = **8.13 GB**、裸盘 **81.92 GB**——厂商标称没错，**错的是我**。

**教训**：`free -m` / `df -BM` 的「MB」其实是 **MiB**。跨口径比较前先统一。
指出别人数字有误之前，先确认自己的换算。

### B3. 探针没跑完就下结论

我在采样脚本还在跑的时候就统计并写进报告（207/400 样本），报「全部 100% 成功」。
跑满后发现 `api.github.com` 有 **6 次 504** 密集落在 3 分钟窗口内，严格口径成功率是 **98.50%**。

**教训**：异步采集的作业，**统计前先确认它结束了**（比对预期样本数）。

### B4. 用被压制过的历史预测未来需求

算峰值到达率时，我剔除了「额度耗尽期」那 205 个未分配 runner 的 run——理由是它们「没真跑」。
但它们**代表真实需求**。剔掉之后峰值从 20 变成 8，低估 2.5 倍。

**教训**：区分「被服务量」与「需求量」。用前者预测容量必然乐观。

### B5. 用错模型：M/M/1 不建模 cancel-in-progress

我按 `ρ=λS` 算出「排队 10.7 分钟」，而真实事件仿真给出的是完全不同的画面。
公式假设每个到达都要完整服务一遍，而这个仓的同分支新 push 会**取消**旧 run——是替换不是叠加。

**教训**：套排队公式前，先确认系统的取消/合并语义与模型假设一致。有真实时间戳就直接仿真。

### B6. 语料假象：拿「那个东西还不存在」的日子做对照

我用仿真得出「把某检查挂到合并后 workflow **零排队成本**」，因为四天的等待分布逐格相同。
**那三天里那个 workflow 根本还没上线**，事件数是 0——「给不存在的 job 加活」当然没变化。
重建事件流后真实代价是最忙那天 15.5 → **22.3 分钟**。

**教训**：对照实验里，先确认**被比较的东西在那个时间窗里存在**。

### B7. 建议了一个「付不起」的方案

我照搬了「每 13 分钟查一次排队队列」的哨兵建议，没算成本。
按每 job 向上取整计费那是 **3323 计费分钟/月——比整个免费额度还多**。

**教训**：任何「定时轮询」的建议，先乘一遍频率再说。

### B8. 建议了一个会自相矛盾的开关（`--ephemeral`）

我按通行做法建议开 `--ephemeral`，同时又建议「用完撤销 PAT」。
读了 runner 源码才发现两者互斥（见 A4）。

**教训**：涉及「自动重新注册」的机制，去读它到底靠什么重新注册。

### B9. 监控脚本量错了目录

写完监控才发现量的是 `/var/lib/docker`（见 A2）。**是 verify.sh 自己把这个 bug 抓出来的**——
这是「写一个会失败的自检」的价值：它检查的是**你以为你配好了的东西**。

### B10. 三道检测同时失明：**我们全程在测「存在」，从没测过「能用」**

B9 那句话要打个折。verify.sh 抓到了 B9，却对 A11 完全失明——**而 A11 让 CI 瘫了 7 天**。

事故期间这台机器的全部信号：

| 信号 | 读数 | 为什么是假的 |
|---|---|---|
| `systemctl is-active` | `active` | 服务确实活着，它只是接一个红一个 |
| `systemctl --failed` | 0 个 | 同上 |
| `ci-health.sh` × 170 次/7 天 | 全部 `runner=active` | 只采**存活**，不采**产出** |
| `verify.sh` | **24 PASS / 0 FAIL** | 三条钩子检查全是结构性的 |
| GitHub 上的 `main` | passing | 09-07 之后没人 push，那个绿从没被重新检验 |

verify.sh 当时问的三个问题是：

```bash
[ -x "$RUNNER_HOME/hooks/ci-cleanup.sh" ]              # 文件在不在、可不可执行
grep -c '^ACTIONS_RUNNER_HOOK_JOB_' "$RUNNER_HOME/.env" # 变量挂没挂
systemctl is-active ci-cleanup.timer                    # timer 起没起
```

**三条全 PASS，而且全是对的**——文件确实在、变量确实挂了、timer 确实在跑。
没有一条问过那个唯一要紧的问题：**「它到底能不能正常退出？」**

`bootstrap.sh` 犯的是同一个错的另一种形态：它把钩子装好、挂好、起好 timer，**然后一次都没跑过它**。多花 0.2 秒就能发现。

**教训（比 A11 值钱得多）**：

> **结构检查 ≠ 执行检查。** 「装上了」和「真能用」之间隔着一次真实调用。
> 凡是有「非零退出会产生后果」契约的东西——钩子、健康探针、`ExecStartPre`——
> 自检必须**用调用方的完全相同的方式执行它一次**，而不是检查它存在。

还有一条推论，关于**监控的选型**：

> **存活指标（liveness）永远不能替代产出指标（outcome）。**
> `is-active` 在这 7 天里每一次都返回了正确答案。问题是我们问错了问题。
> 现在 ci-health.sh 加了 `jobs=streak=N`（最近连续失败次数），
> 它在故障第 3 天就会报 CRIT。补这一条的成本是 15 行 shell。

最后一层讽刺值得记下来：MSN-0035 正是**在故障开始那天**以「已完成 / 关键假设 12 成立 / 24 PASS 0 FAIL」收尾的。
**验收通过和系统可用，在那一刻是两件事，而我们只测了前者。**

### B11. 告警阈值拍脑袋 → 设计稳态下每小时误报 → 没人看 → 真告警也没人看

`ci-health.sh` 原来写死：可用 < 40 GB 报 WARN，< 20000 MB 报 CRIT。而 BuildKit GC 的 Min Free 设的是 20 GiB——
缓存会一直长到可用空间只剩 20 GiB 为止，**那就是设计稳态**。结果：

- WARN 从第 4 周起**每小时**响，一个月 309 次；
- CRIT 只比 GC 底线（20480 MiB）低 480 MiB，稍一波动就会误报；
- 这些告警只写本机 journal，没有任何人或系统在读。06 章说的心跳告警也从没部署；
- 同期真正的 3 次 CRIT（job 连续失败）同样没人看到，其中 10-08 那次还是误报：
  统计的是全仓库的 run，把 GitHub 托管的 PR 标题检查失败也算了进来。

**教训**：
> **阈值从系统自己的设计平衡点推出来，不要从「感觉多少算少」推。** 一个在正常状态下就会响的告警，
> 会训练所有人忽略它——包括它真正该响的那一次。
> **告警的定义包括它送到谁手里。** 写进本机日志的告警，等于没有告警。

### B12. 把管理员 token 落在了 CI 机上（2026-09-14 修 A11 时由我引入）

给 `ci-health.sh` 加 job 产出采样时，我把**注册 runner 用的那个 PAT** 写进了 `/etc/ci-health.env`，
理由是「文件 0600、只有 root 能读」。那是一个 classic token，权限包括 `admin:org`、`delete_repo`、`workflow`。

**0600 在 CI 机上不是边界**：runner 在 docker 组里（≈ root），任何 CI job——包括 `pnpm install` 时
某个依赖的 postinstall 脚本——都可以 `docker run -v /etc:/h …` 读到它。同一个 token 还嵌在机器上
几个 git 检出的 remote URL 里。另外它有过期日，过期后采样会静默退化。

**修法**：bootstrap 不再把 `GH_TOKEN` 写进任何文件；采样改用单独的 `CI_HEALTH_GH_TOKEN`
（fine-grained，只授权这一个仓库，`Actions: read`）；采样失败（401/403）会告警而不是静默跳过。
已部署的机器要撤销旧 token、换上只读 token、删掉 `/etc/ci-health.env` 里的 `GH_TOKEN` 行。

**教训**：
> **CI 机上没有「只有 root 能读」这回事。** 落在这台机器磁盘上的任何东西，都要按「CI job 读得到」来设计。
> 给监控用的凭据，按它真正需要的最小权限单独申请，不要顺手复用手边最大的那个。

### B13. 把一次性回收量当成持续效果

原稿测了一次 `docker buildx prune --filter until=24h`，回收 5896 MB，于是在三处文档里写它是清理「主力」。
那是攒了几天缓存之后**一次性**清掉的量。上线后持续负载下，缓存 24 小时内都被用过，它每次只能删 0.05–0.07 GB；
真正卡住缓存上限的是 daemon.json 的 GC。反过来，表里写着「回收 0 MB」的 `image prune` 在换镜像 pin 之后开始有用，
而真正一直在干活的 `volume prune`（每个 job 约 70 MB）被排在了最后。

**教训**：
> **清理措施的效果要按稳态下的速率量，不是按攒了一阵之后清一次的总量量。** 前者告诉你它每天在做什么，
> 后者只告诉你它第一次跑的时候有多少东西可删。

### B14. 自检脚本自称只读，却会打断正在跑的 job（2026-09-14 由我引入）

修 A11 时我给 `verify.sh` 加了「真的执行一次钩子」这条检查（B10 的教训），却没改脚本头上「只读，不改任何东西」那句。
而钩子会删 CI 容器、杀 e2e 端口——08 章又把 `verify.sh` 列为日常巡检。有 job 时跑一次，那个 job 就被打断。
每日 timer 也有同样的问题。

修的时候又踩了两个**测试本身**的坑，值得记下：

- 用 `pgrep -f Runner.Worker` 判断「有没有 job」，结果匹配到了**我自己测试命令的命令行**，空闲时也判成忙。改 `pgrep -x`。
- 测试副本放在 `/tmp` 并 `chown` 给了 runner；Ubuntu 默认 `fs.protected_regular=2`，**root 也不能覆盖写**粘滞目录里
  别的用户的文件，于是之后每次重新生成都静默失败，测的一直是最早那个旧版本——有一轮「通过」是假的。

**教训**：
> **给一个「只读」工具加主动探测，要么加守卫，要么改掉它的名字和说明。** 两边的说法不一致就是陷阱。
> **测试通过时先确认它测到的是新代码**（比如 grep 一下被测文件里有没有你刚加的那行），尤其是测试结果和预期一致的时候。

### B15. 部署脚本幂等，但参数不落盘

`bootstrap.sh` 号称幂等、可以重跑，但 `CI_LABEL`、`CI_APP_PORTS`、基线这些参数只在命令行上传一次，哪里都没存。
参考机的实际值跟默认值全都不同。谁要是哪天直接重跑 `bootstrap.sh`，清理钩子就换成默认标签（按标签清理全部落空）、
孤儿端口清理被关掉、争抢告警归零——而且什么都不报错。

**修法**：参数落盘到 `/etc/ci-runner.env`，重跑时作为默认值读回；`verify.sh` 核对钩子里的标签与落盘值一致。

**教训**：
> **「可以重跑」的前提是「重跑时知道上次是怎么跑的」。** 幂等说的是操作，不是参数。

---

## C. 有争议但我没采纳的建议

记下来是因为它们听起来都很有道理，而拒绝的理由是数据。

| 建议 | 为什么没采纳 |
|---|---|
| **把 4 个 job 合并成 1 个** | 三个独立方案都这么建议，论证也对（N=1 上 job 只排队不并行）。但仿真显示它买到的排队改善与「修 Dockerfile 层序 + 去 cache」**等效**（11.7 vs 11.2 分钟），而后者不动一行文档、不破坏回退时的并行。在提速之上再合并只多买 2.2–2.6 分钟，不值 10 处文档改动。 |
| **`docker image prune` 是清理主力** | 实测回收 **0 MB**。Docker 29 重打同名 tag 不留悬空镜像。（原文接着说「主力是 `buildx prune`」——这半句也错了，见 B13：持续负载下真正一直在回收的是 `volume prune`，缓存上限靠 GC。） |
| **metadata 泄露 root 口令 = 阻塞项** | 机制属实，但把口令与 `/etc/shadow` 的 hash 逐位比对后**不匹配**——是陈旧凭据。降级为「高」。**判定「凭据泄露」之前先验证那个凭据还有效。** |
| **零下载的 `docker build` 也扣 Docker Hub 配额** | 试着复现，**没能复现**（6 次操作计数一格未动）。记录在案但不采纳。 |

---


---

## 附：脚本清单

| 脚本 | 干什么 |
|---|---|
| `scripts/preflight.sh` | 候选机自检 → GO/NO-GO。只读 |
| `scripts/bootstrap.sh` | 装机 + 注册 + 加固。`--harden-ssh` 才动 SSH，`--skip-runner` 跳过注册。**幂等** |
| `scripts/verify.sh` | 装完 / 重启后自检，输出 PASS/FAIL 表。基本只读：会试跑一次清理钩子，有 job 在跑时自动跳过 |
| `scripts/ci-cleanup.sh` | 清理钩子（bootstrap 装到 runner 的 hooks/） |
| `scripts/ci-health.sh` | 每小时健康采点（bootstrap 装到 /usr/local/bin/） |
| `scripts/analysis/` | 调研期测量工具：连通性采样、**排队仿真**、单步资源画像 |

## 附：脚本被测到什么程度

| 路径 | 验证方式 | 状态 |
|---|---|---|
| `bootstrap.sh` 幂等重跑 | 在已配置完成的机器上完整重跑 | ✅ 退出码 0，12 项关键状态逐字节相同 |
| `bootstrap.sh` 从零安装（工具链段） | 干净 `ubuntu:24.04` 容器 | ✅ docker / node / gh / psmisc 全部从零装成 |
| `bootstrap.sh` 加固段（需 systemd） | 容器里测不了 | ⚠️ 仅在已有机器上验证过效果，首次全新安装请盯输出 |
| runner 全新注册路径 | 需真 token 与真仓库 | ⚠️ 未自动化验证（本次走的是「已注册，跳过」分支） |
| `preflight.sh` / `verify.sh` | 本机实跑 | ✅ 13 PASS+2 WARN / 24 PASS+0 FAIL |

## 附：手册没做、必须你自己做的两件事

1. **云防火墙**：只有云厂商控制台能配。它是唯一挡得住「Docker 自建 DNAT 绕过宿主 ufw」的那一层。
2. **撤销注册用的 PAT**：registration token 是一次性的，但你换它用的那个 PAT 不是。
