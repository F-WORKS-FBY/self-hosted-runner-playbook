# 自建 GitHub Actions CI runner 部署手册（单文件版）

> 这份文件由仓库里的分章文件自动拼成，用 `bash scripts/make-single.sh` 重新生成。
> 要改内容请改分章文件，不要改这一份，否则两个版本会对不上。
>
> 手册讲一套通用做法：怎么判断一台机器够不够用、怎么装、怎么改 workflow、怎么接线、怎么验证、怎么运维。
> 里面的数字都来自一次真实落地（一台 4 核、7.5 GiB 内存的机器，跑一个 pnpm monorepo 的 CI）。
> 写着「参考项目」的地方是举例，不是要求。

---

## 15 分钟快速开始

```bash
# 1. 判断这台机器够不够用（只读）
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load

# 2. 装机、注册、加固（可以重复跑；参数会存到 /etc/ci-runner.env，下次重跑不用再传）
GH_REPO=owner/repo GH_TOKEN=<一次性PAT> \
RUNNER_LABELS=self-hosted,linux,x64,ci \
CI_APP_PORTS="3100 3101" CI_LABEL=com.myorg.ci=1 \
CI_FIXEDWORK_BASELINE=<上一步给的 p50> \
bash scripts/bootstrap.sh
#    可选：CI_HEALTH_GH_TOKEN=<只读 token>        监控「本机 job 是否连续失败」用
#          CI_ALERT_WEBHOOK=<飞书机器人地址>  CI_ALERT_SECRET=<签名密钥>   告警推送到飞书群

# 3. 自检
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh

# 4. 改 workflow：没有脚本，必须有人读一遍第 05 章
#    改完之前不要打开开关，否则第 2 个 PR 就会失败

# 5. 接线
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'

# 6. 连开两个测试 PR，再手动触发一次定时 workflow
```

第 4 步是唯一不能跳过的人工步骤。前三步配置的是机器；第 4 步要找出仓库里那些只在一次性 VM 上才成立的写法并改掉，CI 出问题大多出在这里。

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

这一章帮你判断要不要自建 runner。结论先说：**自建 runner 通常不是省钱方案。** 如果你的动机是省钱，先把本章的账算完再决定。

### 1.1 先把「省多少」算清楚

先用真实数据算出每月的计费分钟，再看自建能省下多少。GitHub Actions 的计费模型有两处容易算错：

1. 每个 job 单独向上取整到整分钟，再求和，而不按 workflow 墙钟计。一个 6 秒的 job 和一个 59 秒的 job 都记 1 分钟。job 越多、越短，取整损耗的占比越高。
2. 自托管 runner 不消耗 included minutes（套餐内含的免费额度）。所以搬走哪些 workflow，就直接省下这些 workflow 的分钟数。

计算方法：

- 用真实数据算，不要按配置估。脚本见 `scripts/analysis/`。
- 从 `/actions/runs/{id}/jobs` 取 `started_at`/`completed_at`，自己算时长。
- 不要用 `/timing` 端点。它在当前计费平台下返回全 0。

```text
月计费分钟 = Σ(每个 workflow 的月 run 数 × 该 workflow 每 run 的计费分钟)
每 run 计费分钟 = Σ(每个 job 的 ceil(秒数/60))     # 注意是每 job 各自取整
```

> 参考项目：按现配置外推为 2280 计费分钟/月，免费额度 2000，超出 280 分钟。按 Linux 2 核 $0.006/分钟计，费用为 $1.68/月。而机器月租 €7–14。只算钱的话，自建是亏的。

### 1.2 为什么仍然值得做

自建的主要收益是：CI 不会因为免费额度在团队最忙的那天突然用完而跑不起来。

免费额度 2000 分钟看起来不少，换算一下：按每 run 10 计费分钟算，只够约 200 个 PR-run（一个 PR 触发的一次完整 CI 运行）。一个 4 人小队在冲刺周很容易一天跑掉 30–35 个 PR。

> 参考项目：额度于 2026-08-21 10:27 UTC 耗尽，直到 09-01 才重置。这 10.5 天里，GitHub 仍然接受触发，但不分配 runner，job 在 1–6 秒内失败。结果是 **85 个已合并的 PR 里，52 个（61%）从来没有跑过一次真实的 CI。**

自建要解决的就是这个问题。相比之下，每月 $1.68 的超额费用可以忽略。

### 1.3 什么时候不该自建

遇到下面任一情形，不建议自建：

| 情形 | 原因 |
|---|---|
| 公开仓库 | fork PR 会在你的机器上执行任意代码，而 `docker` 组约等于宿主 root。GitHub 官方明确不建议。 |
| 机器还跑着别的东西 | CI 会独占宿主端口、写满磁盘、触发 OOM。见表下说明。 |
| 没人愿意长期维护 | 它需要清理、监控、告警、版本升级。托管 runner 不需要管这些。 |
| 额度还很宽裕 | 先做免费优化（合并 job、砍重复触发、路径门控）。通常能砍掉 50%，而且零风险。 |
| 团队分布在多时区、峰值连续 | 单机（N=1）的排队会累积。先算清楚（见 08 章 8.1 的仿真方法）。 |

关于共享机器：如果 CI 和业务共用一个 dockerd，一次 ENOSPC（磁盘写满）除了让 CI 变红，业务也会一起写不进去。要自建就用专机。

### 1.4 决策清单

下面五项全部为「是」，才继续往下做：

1. 仓库是私有的，或你能接受 fork PR 的代码执行风险。
2. 有一台专用机器（不跑业务、不跑别人的数据）。
3. 已经做完免费优化，额度仍然吃紧。
4. 有人负责它的运维（清理、监控、升级）。
5. 接受「N=1 时 job 会排队」。先用 08 章 8.1 的方法算一遍你的峰值。

---

## 02 选机与验收

本章说明怎么判断一台候选机能不能用作 CI runner。一条命令就能给出结论：

```bash
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load
```

这个脚本只读，不安装任何东西，最后打印 GO / NO-GO。下面逐项解释它查什么、为什么这样查。阈值可以按你的项目调整，测法不能改。

### 2.1 CPU 与内存：按单 job 实测峰值来定

CPU 和内存的配置要以单个 job 的实测峰值为依据，不要靠估算。

唯一可靠的做法：在候选机上把你的 CI 完整跑一遍，逐步测量峰值 RSS 和 CPU 核秒。

- 用 `scripts/analysis/step.sh` 测。它基于 cgroup 统计，比 `/usr/bin/time` 准。
- `/usr/bin/time` 遇到多进程时只取单个进程的最大值，会低估。

参考项目的单 job 峰值 RSS：

| job | 峰值 RSS |
|---|---|
| typecheck | 3663 MB |
| lint | 1731 MB |
| test | 1596 MB |
| Metro | 1271 MB |
| e2e | 623 MB |

typecheck 的 3663 MB 是全场最高。CPU 方面，test 3.73 核、typecheck 3.31 核、Metro 3.34 核，单个 job 就几乎用满 4 核。

按此估算：单 job 峰值 ≈ 3.7 GB + 服务容器 0.6 GB + 系统 0.5 GB ≈ 4.8 GiB。因此 7.57 GiB 的机器只能跑 1 个并发 job。

**能不能跑 2 个并发 job（N=2），要用实验确认，不要用估算。** 参考项目实际注册了两个 runner，让两个 job 并发跑了两次，结果如下：

| 第几次 | 报错 | 原因 |
|---|---|---|
| 1 | `Error: Test timed out in 5000ms` | CPU 饥饿 |
| 2 | `Out of memory: Killed process (node) ... Exit status 137` | 内核 OOM 杀掉了 tsc |

- 第 1 次：CPU 饥饿导致一条固定超时的测试失败。同一条测试在三次单 job 运行里全部通过。
- 第 2 次：内核 OOM 杀掉了 tsc，触发 OOM 的是另一个 job 的 redis 容器。

两次并发出现了两种不同的失败。这说明 N=2 会带来不确定的红叉（同一份代码时红时绿），这比慢更糟。它会让团队习惯「重跑一次就好了」，CI 的可信度从这里开始下降。

注意：第 1 次失败与内存无关。所以「加内存就能跑 N=2」不成立，CPU 会先成为瓶颈。

### 2.2 swap：不是否决项，但决定了两项配置

swap 为 0 不影响这台机能否选用，但会决定两项必须做的配置。

`swap = 0` 时，内存超限的结果是 OOM kill，而不会变慢。这里不要求加 swap，CI 场景下快速失败通常好过换页颠簸。需要做的是：

- 必须设 `MemoryMax`，否则一个失控的 job 会拖垮整机。
- 必须设 `OOMScoreAdjust`，否则内核按 RSS 挑选要杀的进程，可能杀掉 sshd 而不是 CI。

### 2.3 端口：被占用时 CI 会连错库

端口被占用时，CI 照样能起来，但会连到占着端口的那个服务上。测试照常通过，数据却会被污染。

原因：CI 的 `services:` 容器会独占宿主端口。如果这台机上已经有程序占着 6379，CI 就会连到那个 Redis 上。

做法：装机前必须确认端口空闲。用 `ss -ltn` 对照你项目的端口清单检查。

### 2.4 连通性：四条阈值各管一件事

连通性用四条阈值判断，每条管一件事：

| 阈值 | 管什么 |
|---|---|
| 成功率 ≥ 98% | 会不会直接失败 |
| connect p95 < 300 ms | TCP 握手，反映路由质量与物理距离 |
| TTFB p95 < 1500 ms | 端到端（含 TLS、服务端处理、限流排队） |
| 抖动比 (p95/p50) < 3 | 偶发长尾 |

- 成功率：CI 里一次网络失败就是一个红叉加一次重跑。
- connect p95：与服务端负载无关。
- 抖动比：最容易被忽略，也最重要。绝对值好但抖动大，意味着偶发长尾，表现为随机红叉。

要测的端点至少包括下面这些。少测一个，问题都可能到装完之后才暴露。

```text
github.com                     actions/checkout 拉代码、下载 action
api.github.com                 runner 长轮询领 job、回传结果、gh api
ghcr.io                        Immutable Actions 把 action 本身存在这里
registry.npmjs.org             依赖
registry-1.docker.io           服务容器与基础镜像的 manifest
auth.docker.io                 上面那个的鉴权
```

官方 allowlist 里还有 `*.actions.githubusercontent.com`（pipelines/vstoken/results-receiver）、`codeload.github.com`、`objects.githubusercontent.com`。它们通常和上面几个走同一路径。一次成功的真实 runner run 比任何 curl 探针都更能证明它们是通的。

统计口径上有两个坑：

① IP 协议族。探针默认用 `curl -4`，但很多机器是双栈，而且 DNS 对 Docker/npm 优先返回 IPv6。生产实际走的那条栈可能根本没测到。`preflight.sh` 对两个协议族都测。

② 5xx 的计法。成功率要把 5xx 计为失败。宽口径（收到任何 HTTP 响应都算成功）会把对端故障也算成通过。参考项目实测：满载轮 400 个样本里，`api.github.com` 有 6 次 504，集中在 3 分钟窗口内。宽口径报 100%，严格口径是 98.50%，刚过 98% 的线。

另外，400 个样本里的 6 个事件在数学上不会体现在 p95 上。所以 PASS 只能理解为「链路质量达标」，不能理解为「不会有偶发失败」。

### 2.5 CPU 争抢：先确认仪器能不能用

这一节说明为什么在很多云主机上不能用 steal 时间判断 CPU 争抢，以及改用什么方法。这是本章最容易被跳过、也最容易搞错的一项。

很多云的宿主不向 guest 暴露 `KVM_FEATURE_STEAL_TIME`（CPUID `0x40000001` 的 bit5）。这时 `/proc/stat` 的 steal 列结构上恒为 0：内核根本拿不到这项数据，这个 0 不是测出来的。**任何基于 `%st` 的监控在这种机器上都是永久的假绿**。假绿指检查本该报警或失败，却显示正常；这里就是指标一直正常，实际什么也没测到。

检查方法如下：

```bash
# preflight.sh 会自动查这一位。手工查：
python3 -c "
import os,struct
fd=os.open('/dev/cpu/0/cpuid',os.O_RDONLY)   # 需要先 modprobe cpuid
eax=struct.unpack('<IIII',os.pread(fd,16,0x40000001))[0]
print(hex(eax), 'STEAL_TIME bit5 =', (eax>>5)&1)"
```

参考项目测得 `eax=0x0100005b`，bit5 = 0，steal 不可观测。第一轮测试曾把「steal 全程 0.00%」当作「无争抢」的证据。由于 steal 列恒为 0，那 1855 个样本得出 0.00% 是必然的，什么也证明不了。

替代方法是测定长任务的墙钟时间。同样的活干 N 遍，如果被邻居抢核，就会变慢。

```text
n=30  p50=0.51s  max=0.52s  max/p50=1.02   ⇒ 无实质争抢
判读：CV < 5% 且 max/p50 < 1.15
```

注意：必须用定量负载，也就是固定工作量。不要用 `openssl speed -seconds N`：它是定时的，墙钟恒等于 N，测了等于没测。`preflight.sh` 用的是固定次数的 sha256。

把这个 p50 记下来作为基线。装机后由 `ci-health.sh` 每小时采点，超过基线 1.4 倍就是争抢信号。

### 2.6 磁盘：看增量，不只看水位

判断磁盘够不够，要看增长量，不能只看当前用了多少。

自建 runner 上最大的磁盘增长来源是 BuildKit build cache，镜像不是主因。关键实测（Docker 29 + containerd 快照器）：

```text
带 -t 重复构建同一镜像 3 次（每次改一行源码）：
  磁盘每次 +1.29 GB      悬空镜像恒为 0        ← 不是悬空镜像的锅
docker image  prune  →  回收 0 MB
docker buildx prune  →  回收 5896 MB          ← 攒了几天后的一次性回收量，不是持续效果（见下）
docker volume prune  →  回收 634 MB           ← services 容器的匿名卷，约 70 MB/run
```

> 上线一个月后的更正：`buildx prune --filter until=24h` 删除的是 24 小时没被用到的缓存。实际被删的常常是整层几 GB 的依赖层（lockfile 一换，或者安静了一晚上），删完后下一次构建就是冷的。而这些空间 GC 在需要时本来就会回收。这条命令已从清理钩子里删掉。缓存的上限靠 daemon.json 的 GC 策略控制（4.1 节）。

估算容量时不要用「基线 + 日增」，这个算法只描述第一周。按稳态估算：

```text
稳态已用 ≈ 系统与工具链 + 在用镜像 + min(Max Used, 缓存工作集) + Docker 以外的东西
稳态可用 ≈ max(Min Free, 盘总量 − 上式)
```

参考项目的实际情况：

- 上线前测得 13.7 GB / 74.8 GiB = 18%，原稿把这个当成了稳态。
- 实际 10-12～10-16 稳定在约 47–49 GB / 65–68%。缓存长到 Max Used（20 GiB）后停住，可用空间约 23 GiB，不再下降。详见 08 章 8.2。

管磁盘的理由不是「不清理会盘满」。BuildKit 自己有 GC 兜底，缓存不会无限增长。真正要关心的是两件事：

① 盘给小了，GC 为了守住 Min Free 会反复驱逐缓存，构建就从温缓存退回冷构建。参考项目一次冷构建比温构建多约 65 秒。

② 匿名卷不在 BuildKit 管辖范围内，Docker 以外的东西更没有任何机制管理。**这两部分没有上界**，要靠清理钩子和定期运维（08 章 8.6）。

### 2.7 一张最低要求表（起点，按项目调）

下表汇总各项的最低要求。它只是起点，按你的项目调整。

| 项 | 建议下限 | 依据 |
|---|---|---|
| CPU | 单 job 实测峰值核数 + 1 | 参考项目单 job 吃 3.7 核 ⇒ 4 核 |
| 内存 | 单 job 实测峰值 × 1.5 | 参考项目 4.8 GiB ⇒ ≥7 GiB |
| 磁盘 | 按 2.6 的稳态公式估算，可用空间要高于 GC 的 Min Free | 参考项目稳态已用约 47–49 GB，74.8 GiB 的盘稳态可用约 23 GiB，高于 Min Free 20 GiB |
| swap | 无所谓，但影响配置 | 见 2.2 |
| 网络 | 四条阈值全过 | 见 2.4 |

---

## 03 装机与注册

本章用 `scripts/bootstrap.sh` 一条命令完成装机和 runner 注册，后面各节逐项说明脚本每一步为什么这样做。

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

`bootstrap.sh` 是幂等的：重复运行不会破坏已有配置，只补齐缺少的部分。已在一台配置完成的机器上重跑验证过：12 项关键状态逐字节相同，只有注释文本被标准化。

### 3.1 参数怎么定

| 变量 | 怎么定 | 参考项目取值 |
|---|---|---|
| `RUNNER_LABELS` | 至少一个项目专属标签，不要只用 `self-hosted` | `myproj-ci` |
| `RUNNER_MEM_MAX` | 单 job 实测峰值 × 1.3 | `6G`（峰值 4.8 GiB） |
| `CI_APP_PORTS` | CI 在宿主上监听的端口，不填容器端口 | `3100 3101`（e2e 拉起的 API） |
| `CI_LABEL` | 与 workflow 里 `docker run --label` 的值逐字一致 | `com.myorg.ci=1` |
| `CI_FIXEDWORK_BASELINE` | `preflight.sh --with-load` 给出的 p50 | `0.51` |
| `BUILDKIT_MAX_USED` / `MIN_FREE` | 按盘大小定，不用出厂默认值 | `20GB` / `20GB` |

注意：`CI_LABEL` 必须和 workflow 里 `docker run --label` 的值逐字一致。清理钩子（`scripts/ci-cleanup.sh`，见 04 章 4.4）靠这个标签认领容器。

### 3.2 工具链：托管 runner 预装约 100 个工具，自建 runner 什么都没有

自建 runner 上缺工具，是装机时最容易被低估的问题。安装前先查清 workflow 用到了哪些命令：

```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|python3|zstd|unzip)\b' .github/workflows/ | sort -u
```

缺工具的后果分两种。以参考项目缺 `gh` 为例：

- 硬失败：`pr-meta.yml:42` 的 `gh api ... > file` 没有 `|| ` 兜底，而 Actions 用 `bash -e` 运行，这一步会直接失败。
- 静默降级（命令失败被兜底吞掉，job 不报错，但行为已经变了）：另外三处有兜底，结果是路径门控退化成全跑、nightly 恒跑、直推检出跳过。

静默降级时，门禁看起来还在跑，实际上已经不起作用。

`bootstrap.sh` 安装的基线：

- 软件包：`ca-certificates curl gnupg jq git tar unzip zstd psmisc python3`。其中 `psmisc` 用于提供 `fuser`，清理孤儿进程时要用。
- 另外安装 Docker CE、Node 和 gh。

Node 用官方 tarball 装到 `/opt/node`，不用发行版的包。这份 Node 供 runner 自身和运维脚本使用；workflow 里的 `actions/setup-node` 仍然自己管理版本。

### 3.3 runner 用户：`docker` 组 ≈ 免密宿主 root

runner 用户必须加入 `docker` 组，而 `docker` 组等价于免密的宿主 root。

- 必须加入的原因：`services:` 容器、`docker build`、`docker run` 都需要 docker 权限。
- 等价于 root 的原因：`docker run -v /:/host` 就能读写整个文件系统。

除非改用 rootless dockerd（那是另一套工程），否则这一点没法绕开。需要清楚它意味着什么：

**任何能让 CI 执行代码的人，都能拿到这台机器的 root。**

- 在私有仓里，这指所有有 push 权限的协作者，可以接受。
- 它也包括被投毒的第三方 action。05 章 ⑪ 的供应链措施防的就是这种情况，有实际必要。

### 3.4 注册：用一次性 token，不留常驻凭据

注册时用一次性 PAT 换取 registration token，不在机器上留常驻凭据。

```bash
# registration token 有效期 1 小时，用完即弃
REG=$(curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$GH_REPO/actions/runners/registration-token" | jq -r .token)
sudo -u runner ./config.sh --unattended --url "https://github.com/$GH_REPO" \
  --token "$REG" --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work --replace
```

- `GH_TOKEN` 只在这一步用一次，用来换取 registration token。脚本不会把它写进任何文件。
- 建议用 fine-grained PAT，只授予目标仓库的 `Administration: read&write` 权限，用完撤销。

### 3.5 不要加 `--ephemeral`

在这套部署形态下，注册时不要加 `--ephemeral`。通行做法会建议开启它（一个 job 一个进程，跑完自动注销再重新注册），这里不适用。

runner 自带的说明如下：

```text
config.sh --help:  "let the service un-configure the runner after the job finishes"
bin/RunnerService.js:  "Runner listener exit with 0 return code, stop the service, no retry needed."
```

也就是说，runner 跑完一个 job 后会自己注销，并把服务停掉。之后：

1. `Restart=always` 把服务拉起来也没用，因为它已经没有注册信息了。
2. 要恢复，必须拿一个新的 registration token。这意味着机器上必须常驻管理员凭据，和「用完撤销 token」的做法直接冲突。

一次没被发现的注销，会造成**最长 24 小时全员 CI 停摆**。原因有两点：

- GitHub 对排队 job 的自动取消时限是 24 小时。
- 回退开关救不了已经排队的 job。

如果需要每个 job 都有干净的环境，用 `ACTIONS_RUNNER_HOOK_JOB_STARTED` 钩子实现，代价是 0（见 04 章 4.4）。

### 3.6 目录布局

装机完成后，相关文件的位置如下：

```text
/opt/actions-runner/          runner 本体
├── .env                      两个钩子的挂载点（JOB_STARTED / JOB_COMPLETED）
├── .runner .credentials*     注册信息（别备份、别进快照，原因见下）
├── hooks/ci-cleanup.sh       清理脚本
└── _work/                    工作区，跨 job 复用（这正是自建比托管快的原因）
    ├── <repo>/<repo>/        checkout 落点
    ├── _temp/                $RUNNER_TEMP —— 每 job 新建并清理
    └── _tool/                setup-node 等的工具缓存（约 200 MB，跨 job 复用）
/opt/node/                    Node 运行时
/usr/local/bin/ci-health.sh   健康采点
```

注意：`.runner` 和 `.credentials*` 是注册信息，不要备份，也不要放进快照。`.credentials` 和 `.credentials_rsaparams` 里是这台 runner 的身份凭据（含 RSA 私钥）：拿到这两个文件的人可以冒充这台 runner 去领 job，而 job 能读到仓库的 secrets；把快照恢复到另一台机器上，还会出现两台机器用同一个身份抢 job 的情况。

---

## 04 加固

`bootstrap.sh` 已经完成了这一章的大部分操作。本章逐条说明每项配置的理由，其中有几条和直觉相反。

### 4.1 Docker 守护进程

daemon.json 里要有这两项：

```json
{
  "builder": { "gc": { "enabled": true, "policy": [
    { "all": true, "reservedSpace": "10GB", "maxUsedSpace": "20GB", "minFreeSpace": "20GB" }
  ] } },
  "live-restore": true
}
```

#### BuildKit GC 上限

出厂默认值对小盘来说太松，实测 Max Used 为 55.88 GiB，Min Free 为 13.97 GiB。

写法上踩过两个坑：

- `"defaultKeepStorage": "10GB"` 只映射到 Reserved Space，会丢掉 `Min Free` 保护。
- 在顶层直接写 `reservedSpace`/`maxUsedSpace`/`minFreeSpace` 会被静默忽略。daemon 不报错，回落到出厂值。

所以**必须用 `policy` 数组，三个参数写全**。

改完后确认三项都在：

```bash
docker buildx inspect default | grep -A6 'rule#0'
```

#### `live-restore: true`

不开的话，dockerd 一旦重启（比如由 unattended-upgrades 触发），当前 job 的 `services` 容器会当场全部被杀掉。这时报错会指向业务代码，排查方向会完全错。

### 4.2 别让自动升级打断 job

本节要防的是：自动升级在 job 中途重启 containerd 或 runner 服务，把 job 打断。

Ubuntu 的 `unattended-upgrades` 默认每日运行。`needrestart` 的 APT 钩子默认 `-m u`，即自动重启受影响的服务。

出厂配置已经豁免了 `docker`：`/etc/needrestart/needrestart.conf` 的 `override_rc` 里有 `qr(^docker) => 0`。但 `containerd` 不在名单里，而 Docker 29 的镜像与容器都由 containerd 承载。所以要补上 containerd 一条，再加上 runner 服务自身：

```perl
# /etc/needrestart/conf.d/90-ci-containerd.conf
$nrconf{override_rc}->{qr(^containerd)} = 0;
$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;   # runner 自己（2026-10 补）
```

注意：本手册第一版写了 docker 和 containerd 两条，其中 docker 那条是多余的。写之前先查一下你机器上的出厂名单。

#### runner 服务本身也要豁免

这一条是上线第 25 天出事后，于 2026-10-16 补上的。

- 2026-10-02 06:06，一次 libssl 自动安全更新让 needrestart 在 job 中途重启了 runner 服务。
- 那个 job 当场被打断，GitHub 上记为 Failed，只能重跑。经过见 09 章 A13。

豁免的代价是 runner 会一直用旧库，直到下次重启。所以要配一条运维纪律：**每月找一个没有 job 的时间重启一次机器**（见 08 章 8.6）。

`unattended-upgrades` 默认 `Automatic-Reboot "false"`，不会自己重启机器，这一项不用改。

### 4.3 runner 的 systemd 加固

出厂 unit 的 `[Service]` 段只有 `ExecStart` / `User` / `WorkingDirectory` / `KillMode` / `KillSignal` 这几项。也就是说 `Restart` 默认是 `no`，listener 一旦退出就再也不会起来。GitHub 侧的 `online` 状态有分钟级延迟，你不会立刻发现。

在 unit 里加上这些：

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

四条各自的理由：

- `After=docker`：出厂 unit 不写这个依赖。实测 runner 就绪只比 dockerd 晚 1.3 秒，而且两者完全无序。重启后 runner 可能先接到 job，docker 才起来。
- `StartLimitIntervalSec=0`：systemd 默认 `StartLimitBurst=5` / `Interval=10s`。不关掉的话，`Restart=always` 在连续失败 5 次后会被标成 `failed` 并停止重试。**只写 `Restart=always` 是不够的**，这是最容易漏的一行。
- `OOMScoreAdjust=800`：swap=0 的机器上，内存不够时进程会被 OOM kill，不会只是变慢。内核按 RSS 挑要杀的进程，不知道哪些是 CI 这样的「客人」。这一行让 CI 先被杀，别把 sshd 带走。
- `MemoryMax`：一个失控的 job 只杀死自己。

注意：`MemoryMax` 只管 runner 进程树。CI 起的容器是 dockerd 的子进程，不在这个范围内。要管住它们，得用 `--cgroup-parent`，或者给服务容器加 `--memory`。

验证：

```bash
systemctl show <unit> -p Restart -p StartLimitIntervalUSec -p MemoryMax -p OOMScoreAdjust
```

### 4.4 清理：三处都要挂

清理钩子 `scripts/ci-cleanup.sh` 要同时挂在三个地方：

```text
ACTIONS_RUNNER_HOOK_JOB_STARTED     ← 主力
ACTIONS_RUNNER_HOOK_JOB_COMPLETED   ← 顺手
ci-cleanup.timer（每日）             ← 兜底
```

#### 为什么 `JOB_STARTED` 是主力

它在下一个 job 开始前运行，不管上一个 job 是怎么结束的。

本章旧版给的理由是「`JOB_COMPLETED` 在 job 被 `cancel-in-progress` 取消时根本不执行」。上线后的数据推翻了这个说法：最近两周（`_diag` 只保留 14 天）里，38 个被取消的 job 都执行了两个钩子（runner 2.337.0）。

`JOB_COMPLETED` 真正跑不到的是两种少见情况：

- job 在初始化阶段就被取消；
- runner 服务被停掉。

结论不变，`JOB_STARTED` 仍是更可靠的那个，只是理由要改成上面这样。

#### 为什么还要 timer

runner 进程被杀时，两个钩子都不执行。

#### 脚本里各条命令的实际作用

脚本里的关键命令，以及上线一个月（约 2200 个 job）后的实际作用：

| 命令 | 作用 | 状态 |
|---|---|---|
| `docker volume prune` | 回收匿名卷；workflow 没挂 tmpfs 时，每个起 service/minio 的 job 约 70 MB | 保留（兜底） |
| `docker image prune`（悬空）+ 按 CI 标签的 `-a` | 同一个 tag 拉到新版本后留下的旧版本 | 保留 |
| `docker buildx prune --filter until=24h` | — | 已删 |
| `fuser -k <app_ports>/tcp` | 上一次 run 的宿主孤儿进程 | 保留 |

各条说明：

- `docker volume prune`：回收匿名卷。runner 删 service 容器时用的是不带 `-v` 的 `rm --force`，会留下匿名卷（主要是 PGDATA）。workflow 没挂 tmpfs 时，每个 job 都靠这一步回收；挂了之后就不再产生这些卷（05 章 ⑫，参考项目 10-16 已改），这一步只作兜底。脚本删带 CI 标签的容器和名字以 minio 开头的容器时带 `-v`，runner 被杀后留下的这两类容器连卷一起删。
- `docker image prune`：用 digest 钉住的旧 pin 不算悬空，清不掉，要人工退役（08 章 8.6）。按 CI 标签的那条，要 workflow 的 `docker build` 打了标签才匹配得到，否则匹配 0 个。
- `docker buildx prune --filter until=24h`：已从脚本删除。旧版表格写它回收 5896 MB、是「主力」，但那是攒了几天之后一次性清掉的量。它删的是 24 小时没被用到的缓存，实际常常是整层几 GB 的依赖层（换了 lockfile，或者安静了一晚上），删完下一次构建就是冷的。这些空间在需要时 GC 本来就会回收。缓存上限靠 4.1 节 daemon.json 里的 GC 策略控制。
- `fuser -k <app_ports>/tcp`：清掉上一次 run 留在宿主上的孤儿进程，见 05 章 ⑨。这种情况属于「假绿」（检查本该失败，却显示通过）：测试实际跑在上一次 run 留下的孤儿进程上，CI 却显示通过。

#### 钩子不能撞上正在跑的 job

runner 自己调用钩子时，本机只有这一个 job，没有问题。但每日 timer、`verify.sh`、手工执行都可能正好撞上一个在跑的 job，这时钩子会删掉它的容器、杀掉它的 e2e 进程。

防护做法：

- 脚本开头有一道守卫：父进程不是 `Runner.Worker`，且有 `Runner.Worker` 在跑，就直接退出。
- 判断有没有 job 要用 `pgrep -x Runner.Worker`（按进程名精确匹配），别用 `-f`。`-f` 匹配整条命令行，有人正在执行 `grep Runner.Worker` 时就会误判。
- timer 的 unit 要写 `User=runner`。钩子文件归 runner 所有、runner 可写，不应以 root 执行它。

> 注意：**绝不裸跑 `docker system prune`，绝不用不带 label 的 `-a`**。这样会连基础镜像一起删掉，让「稳态 Docker Hub 消耗 ≈0」变回每次冷拉。

### 4.5 挡住 CI 读云 metadata

本节用两条 iptables 规则，阻止 CI 读取云 metadata 服务。

云 metadata 服务（`169.254.169.254`）对 CI job 和容器都是可达的，里面常有初始 root 口令、公钥、网络配置。两条规则一条管容器，一条管宿主进程：

```bash
iptables -I DOCKER-USER -d 169.254.169.254 -j DROP
iptables -I OUTPUT -d 169.254.169.254 -m owner --uid-owner $(id -u runner) \
         -j REJECT --reject-with icmp-port-unreachable
netfilter-persistent save
```

两条都要。`DOCKER-USER` 只管容器流量，而 CI job 的 shell 是宿主进程，`DOCKER-USER` 管不到它。

root 仍然可以读 metadata（cloud-init 要用）。

> 参考项目的情况：metadata 的 `vendor_data` 里确实有 cloud-init 写入的 root 口令，在容器内能取出来。但与 `/etc/shadow` 的 hash 逐位比对后不匹配：口令在 cloud-init 之后已被改过，泄露的是陈旧凭据。所以这条规则属于纵深防御，要防的并不是一个正在造成损失的漏洞。
>
> 判断严重程度时，比对是必须做的一步。最初提出这条时没有做比对，直接定成了「阻塞」。

### 4.6 SSH：唯一可能把你锁在门外的动作

SSH 加固是本章唯一可能把你锁在门外的操作。`bootstrap.sh` 默认不做这一条，要加 `--harden-ssh` 才执行。

#### 动手前：查登录方式

动手前必须先查一件事：这台机上的人现在是怎么登录的。

```bash
journalctl -u ssh --since "-30d" --no-pager | grep -oE "Accepted (publickey|password)" | sort | uniq -c
stat -c '%y' /root/.ssh/authorized_keys      # 公钥是什么时候装的
```

把两者按时间线对一下：

- 口令登录全部发生在公钥装上之前：说明那些人已经切到公钥，可以关。
- 公钥装上之后仍有口令登录：说明有人还在用口令，不能关，先让他们配公钥。

> 参考项目：8 次口令登录全在 `09-06 14:18–14:54`，而 `authorized_keys` 写于 `14:54:52`（他登进来就是为了装公钥）。此后 11 次登录全是 publickey，零口令。结论：可以关。

#### 写配置

```text
# /etc/ssh/sshd_config.d/00-hardening.conf
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
```

注意：文件名必须以 `00-` 开头。`sshd_config.d` 里同一项以首次出现的为准，这个文件必须排在 cloud-init 写的 `50-cloud-init.conf`（里面是 `PasswordAuthentication yes`）之前。

#### 生效与验证

按顺序执行，最后一步通过才算完成：

1. `sshd -t`
2. `systemctl reload ssh`（reload 不踢现有连接）
3. `sshd -T` 确认
4. **另开一个终端验证能登入**

第 4 步的验证命令：

```bash
ssh -o PasswordAuthentication=no root@<IP>   # 强制不用口令，能进说明公钥这条路通
```

进不去的话，在当前还活着的会话里回滚：

```bash
rm -f /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh
```

#### 可选的安全网

如果担心改完之后、验证之前会话就断了，可以挂一个安全网：用 `scripts/ssh-guard.sh` 配一个 3 分钟的 timer。它只在一条 SSH 会话都不剩时才回滚：

- 你正常连着时，它不会动配置；
- 你真被踢下线且进不来时，它会自动回滚，自行恢复。

```bash
install -m 0755 scripts/ssh-guard.sh /usr/local/bin/ssh-guard.sh
touch /root/.ssh-hardening-unconfirmed          # 「还没确认」的标记
# 配一个 OnUnitActiveSec=3min 的 systemd timer 跑它
# 你验证能登入之后：rm 掉标记文件 + 停掉 timer，加固即永久生效
```

### 4.7 云防火墙：唯一挡得住 Docker 的那一层

云防火墙必须去云厂商控制台配置，脚本做不了。

不能只靠宿主 ufw 的原因：Docker 会自己往 iptables 写 DNAT 规则，从结构上绕过 ufw。对容器端口来说，「在防火墙封了 3000」多半不生效。云防火墙在虚拟机外面，Docker 改不了它。

它挡的是容器端口绑回环也盖不住的部分，也就是 CI 里在宿主上监听的进程，比如 e2e 直接 `spawn` 起来的应用服务器。这类进程不是容器，没有 `-p` 可以绑。

配置：**入方向只放行 22**（建议限来源 IP），出方向全放。

对 CI 的影响为零。runner 是出站长轮询去 GitHub 领活，不需要任何入站端口。但要注意：以后想在这台机上跑任何对外服务，得回控制台加规则。

---

## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

本章列出 workflow 里依赖托管 runner 特性的写法，以及在自建常驻 runner 上该怎么改。这是整本手册里最可迁移的部分：前面几章的内容换个云厂商就要调整，本章的内容对任何仓库都适用。

托管 runner 给每个 job 分配一台全新的一次性 VM：

- `/tmp` 是空的；
- 容器名没被用过；
- 端口没被占用；
- 磁盘是干净的；
- job 跑完，VM 就销毁。

几乎每个仓库的 workflow 里都积累了一批依赖这些性质的写法。它们在托管 runner 上不会出问题，所以也一直没有暴露出来。

本章用到的两个说法：

- N=1：只有一台自建 runner，所有 job 在这台机器上串行排队。
- 假绿：检查本该失败，结果却显示通过。

下面 ①–⑪ 共十一条，每条按「怎么自查 → 失败是什么样 → 怎么改」组织；⑫ 是上线一个月后补充的。建议把它们当作 checklist，对照你的 workflow 逐条检查。章末有一组汇总命令，改完后用来确认。

---

### ① 固定容器名

workflow 里用写死的名字起容器、又没有删掉它时，在常驻机器上第 2 个 run 就会因为重名而失败。

自查：

```bash
grep -rn -- '--name ' .github/workflows/ ; grep -rc 'docker rm\|docker stop' .github/workflows/
```

起了容器、但 `docker rm` 出现 0 次，就是命中。

失败时的报错：

```text
docker: Error response from daemon: Conflict.
The container name "/minio" is already in use by container "7eb4689c...".
```

第 2 个 run 就会失败，而且报错和代码改动无关。

同一个 run 里的两个 job 用同一个写死的名字时更严重，冲突是必然的，与概率无关：

- 托管 runner 上，两个 job 在两台独立 VM 上，互不影响。
- N=1 的自建机上，两个 job 在同一台机器上串行。第一个 job 不清理，第二个 job 一定冲突。

怎么改：

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

要点：

- **`--label` 的值必须和 bootstrap.sh 里的 `CI_LABEL` 完全一致。** 清理钩子第 1 步按这个 label 删除上一个 job 没删掉的容器。本模板原来写的是 `--label ci=1`，和任何 `CI_LABEL` 都对不上。
- 删除容器用 `rm -fv`，不用 `rm -f`。镜像声明了 `VOLUME` 时（minio、postgres、redis、prometheus 都声明了），Docker 会建匿名卷，带 `-v` 才会连卷一起删。本模板原来写的是 `rm -f`，参考项目沿用了这个模板，原来每个起 minio 的 job 漏 1 个卷（10-16 已改，见 ⑫）。
- `docker run --rm` 解决不了漏卷。实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下。`--rm` 只在容器自己退出或被 `docker stop` 时生效。
- `rm -fv` 只在清理步骤真的跑了时有用。runner 进程被杀时 `if: always()` 也不执行，容器留给钩子删。更稳的是在镜像的 VOLUME 路径挂 tmpfs，一开始就不建卷，写法和注意事项见 ⑫。
- 清理钩子并非只按 label 过滤。它的第 6 步是一条不带过滤的 `docker volume prune`，用来兜底回收匿名卷（本模板原来说「绝不裸 prune」，这个说法不对）。workflow 里写对了，就不必依赖它。service 容器的卷见 ⑫。

---

### ② 服务端口默认绑 `0.0.0.0`

`ports:` 只写 `宿主端口:容器端口` 时，端口绑在 `0.0.0.0` 上，服务会直接暴露到公网。

自查：

```bash
grep -rn "ports:" .github/workflows/ | grep -v "127.0.0.1"
```

失败是什么样：CI 不会失败，所以也不会提醒你。它只是把你的数据库开放到了公网上。

> 实测：`ports: ['5433:5432']` 加明文 `POSTGRES_PASSWORD`，check-host.net 的四个境外节点全部成功建立 TCP 连接，并收到 Postgres 的认证响应。当时宿主的 `ufw` 是 inactive，但这不影响结论：Docker 的 DNAT 本来就绕过 ufw。

怎么改：

```yaml
services:
  postgres:
    ports: ['127.0.0.1:5433:5432']    # runner 把三段式原样透传给 docker create（已实测）
```

确认：localhost 可以连上，从公网连接返回 `Connection refused`。

---

### ③ 固定 `/tmp` 路径

写死的 `/tmp/...` 路径在常驻机器上会被多个 job 共用，会出三类问题。

自查：

```bash
grep -rn '/tmp/' .github/workflows/
```

失败是什么样（第三种最危险）：

1. 权限：文件属于别的用户，`tee: /tmp/x.log: Permission denied`，步骤直接失败。
2. 并发：两个 job 写同一个路径，断言读到别的 job 的数据。
3. 读到陈旧文件，静默假绿：写文件那一步失败了，但上一次 run 留下的同名文件里恰好有你要 grep 的字符串，断言因此通过。这条检查本该发现问题，结果变成永远通过的摆设。托管 runner 上不可能发生；在常驻机器上，只差一句 `rm`。

怎么改：一律用 `$RUNNER_TEMP`。runner 为每个 job 新建并清理这个目录，托管和自建的行为一致。

```yaml
- run: mycmd | tee "$RUNNER_TEMP/out.log" && grep -q "expected" "$RUNNER_TEMP/out.log"
```

---

### ④ 依赖预装工具

workflow 里用到的命令行工具，自建机上不一定装了。

自查：

```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|zstd|unzip)\b' .github/workflows/ | sort -u
# 然后在 runner 上：for c in <上面这些>; do command -v $c || echo "缺 $c"; done
```

失败分两级，第二级更麻烦：

- 命令后面没有 `||` 兜底：步骤直接失败（`bash -e`），至少能看到。
- 命令后面有 `|| fallback`：静默降级。表现为路径门控退化成全跑、定时任务每次都跑、某个检出被跳过。**门禁看起来还在跑，实际已经失效。**

怎么改：把缺的工具装上，并把工具清单写进你的 bootstrap，不要靠记忆。

---

### ⑤ 依赖「全新文件系统」的缓存：在常驻机器上变成负担

常驻机器上，缓存从必需变成了净负担；但去掉它会让回退到托管 runner 时变慢，需要取舍。

自查：workflow 里有 `actions/cache`，或者 `setup-*` 的 `cache:` 选项。

为什么会这样：

- 托管 runner 上缓存是必需的，因为 VM 每次都是空的。
- 常驻机器上它是净负担：把本地已经有的东西传到云上，再传回来。

> 实测：`actions/setup-node` 的 `cache: pnpm` 每个 run 从 GitHub 缓存服务恢复约 218 MB，setup-node 步骤耗时 11–12 秒。去掉后是 1 秒，`pnpm install` 仍是 6 秒（本地 store 常驻）。每个 run 净省约 10 秒和 218 MB 流量。

怎么改：先想清楚回退。去掉缓存后，回落到托管 runner 时每个 job 要多付一次冷装（约 52 秒）。想用条件表达式两头兼顾，做不到：

```yaml
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # ❌ 不成立
# GitHub 表达式里 && / || 返回操作数的值，而空串是 falsy：
# CI_RUNNER 已设 → (CI_RUNNER && '') = '' → '' 是 falsy → ('' || 'pnpm') = 'pnpm'
# 永远产出 'pnpm'。写 'none' 之类会让 setup-node 直接报错。
```

所以只能二选一：要么接受每个 run 多 10 秒，要么接受回退时变慢。参考项目选择保留缓存（10 秒占单个 run 的 3%）。

---

### ⑥ workflow 最后一步的清理在 job 被取消时不执行

job 被取消时，写在最后一步、又没带 `if: always()` 的清理步骤会被跳过。

自查：你的 workflow 里有没有 `cancel-in-progress: true`？有的话，检查清理步骤是否带了 `if: always()`。

怎么改：

- 清理步骤加 `if: always()`。
- 在 runner 侧挂 `JOB_STARTED` 钩子兜底。

说明：runner 侧的 `JOB_COMPLETED` 钩子在 job 被取消时其实会执行。它跑不到的情况有两种：job 在初始化阶段就被取消；runner 服务被停掉。详见 04 章 4.4。

---

### ⑦ `timeout-minutes` 的含义变了

在 N=1 的自建 runner 上，`timeout-minutes` 决定了一个卡死的 job 最多能让全组 CI 停多久，所以要对照实测时长重新检查。

| 环境 | `timeout-minutes` 的含义 | job 跑飞的后果 |
|---|---|---|
| 托管 runner | 这个 job 最多烧多少钱 | 只烧掉自己那台一次性 VM |
| N=1 自建 runner | 全组 CI 停摆的上界 | 独占唯一的 runner，后面所有 PR 一起等 |

自查：

```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> 参考项目：现值是实测时长的 8–150 倍（lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。一次 ci run 最坏占用 15+15+30+30 = 90 分钟。按「实测 p95 × 4」重设后是 29 分钟。

注意：`timeout-minutes` 从 job 开始执行才计时，排队时间不算。机器宕机导致排队 24 小时这种情况它管不了，要靠哨兵（06 章 6.4）。

---

### ⑧ job 级并行的假设

要不要为 N=1 合并 job，先量再决定：合并 job 在自建机上的收益比在托管上小得多。

- 托管 runner 上，多个 job 并行是免费的（各自一台 VM）。
- N=1 上，它们串行排队，每多一个 job 就多付一次脚手架。

不要急着合并 job。先量两个数，即托管和自建机上各自的每 job 脚手架时间：

```text
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```

> 参考项目：托管上脚手架约 52 秒/job（合并 4→1 省 156 秒）；自建机上只有约 16 秒/job（合并只省 48 秒），因为常驻机器上依赖早就在盘上了。收益缩水 3 倍，而代价（文档同步、required check 粒度、回退时降级）一点没少。

判断方法：用真实事件时间戳做排队仿真（08 章 8.1），比较「合并 job」和其他提速手段的实际收益。

参考项目的结论：合并 job 与「修 Dockerfile 层序 + 去 cache」效果相当（最忙那天 11.7 vs 11.2 分钟），而后者不用改任何文档。**先做后者。**

---

### ⑨ 孤儿进程导致的假绿

测试依赖的后台进程如果是上一次 run 遗留的孤儿进程，测试会跑在旧代码上，CI 却可能显示通过。

自查：workflow 或测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？如果就绪判据只是 `curl <url>`，不校验应答的是不是自己刚起的那个进程，就是命中。

失败是什么样：

```text
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在**孤儿**上
```

> 实测：用一个孤儿进程占住端口后跑 e2e，221 条里 220 条通过，唯一失败的那条还指向认证代码，而不是真实原因。换一个对状态不敏感的孤儿进程，结果就是全绿。

**也就是说，整套 e2e 跑在上一次 run 的代码上，而 CI 是绿的。**

孤儿进程的来源：

- `teardown` 只有一行 `proc.kill()`，而 job 被取消时它不执行。
- runner 的 `KillMode=process` 也不杀子进程。

怎么改：分三层，至少做前两层。

第一层（代码注释中的 ①）：起进程之前，先确认端口没被占用。

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

第二层（代码注释中的 ②）：在 runner 的 `JOB_STARTED` 钩子里清掉孤儿进程。

```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
fuser -k 3100/tcp 3101/tcp 2>/dev/null || true
```

第三层：用云防火墙挡住这些宿主端口。它们不是容器，`-p 127.0.0.1` 管不到。

---

### ⑩ 宿主进程绑 `0.0.0.0`

② 只管容器。测试直接 spawn 起来的应用进程是宿主进程，没有 `-p` 可以绑，需要另外处理。

自查：`grep -rn "0\.0\.0\.0\|listen(" <你的应用入口>`

怎么改：

- 优先靠云防火墙（04 章 4.7）。宿主进程不走 DOCKER 链，所以主机防火墙和云防火墙对它都有效。
- 也可以改应用代码的绑定地址，但要先确认两点：不会破坏容器形态（容器内必须绑 `0.0.0.0` 才能被发布端口访问到）；不和仓库已有的绑定地址约定冲突。

---

### ⑪ 供应链：爆炸半径变了

同样的供应链事故，在自建 runner 上的影响范围比托管大得多，所以 action 和镜像都要钉死。

自查：

```bash
grep -rhoE 'uses: [^ ]+' .github/workflows/ | sort -u    # 有几个钉在浮动 major tag 上
grep -rn 'image:' .github/workflows/ | grep -v '@sha256'  # 有几个镜像没钉 digest
```

为什么在自建上更要紧：同样是「上游 tag 被重新指向」的事故，在托管 runner 上泄露的是一台一次性 VM，在你的机器上泄露的是宿主 root（因为 runner 在 `docker` 组里）。

怎么改：

- action 钉 commit SHA，并开启 dependabot。
- 镜像钉 digest。

---

### ⑫ 匿名卷：service 容器和自己起的容器都会留（上线一个月后补）

常驻机器上，CI 容器留下的匿名卷如果没有清理钩子兜底，会不断累积。凡是镜像声明了 VOLUME 的容器，都在那个路径挂 tmpfs；自己起的容器删除时再用 `rm -fv`。

自查：

```bash
docker volume ls -q | wc -l                       # 在一台常驻 runner 上看；钩子没在跑的话会一直涨
grep -rn 'docker rm -f ' .github/workflows/ tools/ | grep -v -- '-fv'   # 应为空
```

机制：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；删容器时不带 `-v`，卷就留下。卷有两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | runner 自己，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，挂 tmpfs，删除时用 `rm -fv`（见 ①） |

参考项目里，每个用到数据库的 job 原来漏 3 个卷（postgres + redis + minio），约 70 MB，大头是 PGDATA；跑了监控冒烟的 build job 还会给 prometheus 漏 1 个（改了监控配置时跑；碰到 packages/、lockfile、根 package.json 等共享面，或手动触发时也全跑）。那台机器上卷数始终是 0，因为清理钩子的 `docker volume prune` 在每个 job 前后都在回收。这是钩子在兜底，workflow 本身并没有写对。换一台没装钩子的常驻 runner，卷数就会一直涨。

参考项目 2026-10-16 按下面的写法改完（metta-app #269）：postgres、redis、minio、prometheus 都挂 tmpfs，起这些容器的 job 都在起完后核对没挂卷。合并前在 runner 上记了约 15 分钟 `docker events`，覆盖 nightly 的两个 job 和 build job 的两个冒烟，这些容器照常建了又删，期间没有新建卷。

怎么改：给 service 容器挂 tmpfs，从源头上不产生卷。2026-10-16 在参考机上实测：postgres 正常启动，`docker inspect` 的 Mounts 为空，删容器后新增卷 0 个。

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

注意：**tmpfs 的路径必须是镜像声明的 VOLUME 路径**，用 `docker image inspect <镜像> --format '{{json .Config.Volumes}}'` 查。

- postgres 18 的镜像声明的是 `/var/lib/postgresql`，不是常见的 `/var/lib/postgresql/data`。后者是 17 及以前的路径；18 起 PGDATA 在 `/var/lib/postgresql/<大版本>/docker`。
- 路径写错不会报错，只是卷照样建、照样漏。
- tmpfs 占内存（参考项目约 50–120 MB/job）。它记在容器的 cgroup 上，不在 runner 的 MemoryMax 里；但在没有 swap 的机器上它占的是真内存，所以 `size=` 必须写。
- 镜像以非 root 用户运行时，tmpfs 要加 `mode=1777`。prometheus 以 nobody 运行，不加的话报 `/prometheus/queries.active: permission denied`，起不来。postgres、redis 的入口脚本会先以 root 改属主，不用加。
- 步骤里起的容器同样挂：`docker run -d ... --tmpfs /data:size=256m <minio 镜像> server /data`。参考机上实测 minio 在 tmpfs 上写 20 MB 对象、读回逐字节一致。

钩子每个 job 都清卷，tmpfs 路径写错、漏了卷也看不出来。所以在起完容器后加一步核对，有 `volume` 类型的挂载就让 job 失败：

```yaml
- name: 容器没有挂卷
  env:
    IDS: ${{ job.services.postgres.id }} ${{ job.services.redis.id }}
  run: |
    out=$(docker inspect -f '{{.Name}}{{range .Mounts}}{{if eq .Type "volume"}} {{.Destination}}{{end}}{{end}}' $IDS "$SVC_NAME")
    echo "$out"
    if [ "$(wc -l <<<"$out")" -ne 3 ]; then echo "::error::应核对 3 个容器"; exit 1; fi
    if grep -q ' ' <<<"$out"; then echo "::error::上面带路径的容器挂了 docker 卷"; exit 1; fi
```

数量也要核：service 改了名字时 `job.services.<名字>.id` 是空串，少核一个容器也不会报错。

另外，`docker build` 也要打上 `--label "$CI_LABEL"`，清理钩子才能删掉过期的 CI 镜像；不打标签时，钩子里那条清理匹配到 0 个镜像。标签漏打也不报错，参考项目让每个 build 带 `--iidfile "$RUNNER_TEMP/ci-images/<名字>"`（先 `mkdir -p "$RUNNER_TEMP/ci-images"`），再加一步遍历这些文件核对标签。

参考项目还在 job 末尾的 `if: always()` 清理里加了一条 `docker image prune -f --filter "label=$CI_LABEL"`（不带 `-a`，只删悬空的，带 tag 的当前版本留着），防的是固定 tag 重建后旧版本变成悬空镜像。这是经典镜像存储的行为；Docker 29 + containerd 快照器上带 `-t` 重建，旧版本直接被删、不留悬空镜像（02 章 2.6 实测，10-16 复测相同），所以在这类机器上这一条只是保险。

---

### 改造完的自查

改完后跑下面这组命令确认，每行末尾的注释是期望结果。

```bash
grep -rn -- '--name '        .github/workflows/ | grep -v 'run_id'      # 应为空
grep -rn 'ports:'            .github/workflows/ | grep -v '127.0.0.1'  # 应为空
grep -rn '/tmp/'             .github/workflows/                        # 应为空或已确认无害
grep -rc 'if: always()'      .github/workflows/*.yml                   # 清理步骤应该有
grep -rn 'docker rm -f '     .github/workflows/ | grep -v -- '-fv'      # 应为空（⑫）
grep -rn -- '--tmpfs'        .github/workflows/                        # 每个声明了 VOLUME 的镜像都应有一条（⑫）
grep -rn '容器没有挂卷'       .github/workflows/                        # 起了这些容器的 job 都应有这一步（⑫）
```

---

## 06 接线与回退

本章讲怎样用一个仓库变量把 CI 在自建 runner 和 GitHub 托管 runner（下文简称「托管」）之间切换，切回托管时要补做哪些动作，以及 runner 下线时怎样及时收到告警。

**先把 05 章改好的 workflow 合进 main，再打开开关。** 顺序反过来的话，第 2 个 PR 就会红。

### 6.1 开关的形状

`runs-on` 用仓库变量控制，不要写死成自建 runner 的标签。

写死的问题：切回托管要开 PR、等 review、等 CI。而需要切回的时候，正是机器出故障的时候。

用下面这种写法：

```yaml
runs-on: ${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}
```

| 变量状态 | 表达式结果 | job 落在哪里 |
|---|---|---|
| 未设置 | `fromJSON('"ubuntu-latest"')` | 托管，行为与改造前逐字相同 |
| 已设置 | `fromJSON` 解析后的变量值 | 自建 runner |

因此可以先把改造合进 main，观察几天，再决定什么时候切换。

开关命令：

```bash
# 开
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'
# 关
gh variable delete CI_RUNNER --repo owner/repo
```

### 6.2 变量值必须是合法 JSON

`CI_RUNNER` 的值会被 `fromJSON` 解析，写成裸字符串会出错。错误示例：

```bash
gh variable set CI_RUNNER --body 'ubuntu-latest'      # ❌ 裸字符串
```

这种错误很难排查。现象和「回退没生效」不同，具体是：

- 整个 workflow 解析失败，产生 0 个 job。
- run 直接变红。
- 页面上没有任何 job 可以点开查看。

正确写法：

- 多个标签写成数组：`'["self-hosted","linux","x64","ci"]'`
- 单个值要带引号：`'"ubuntu-latest"'`

### 6.3 开关救不了已经排队的 job

删掉变量只影响新 run。已经处于 `queued` 状态的 job 不会改去托管，会继续排队到 runner 恢复，所以切回时要手动取消再重跑。

实测过程：

1. 停掉 runner，让 job 进入 `queued`。
2. 删掉变量。
3. 在 t+20/40/60/80/100/120 秒检查，那个 job 一直是 `queued`，没有任何变化。
4. runner 恢复后，这个 job 才被执行。

GitHub 对排队 job 的自动取消时间是 24 小时。如果机器半夜宕机，全组的 PR 会一直卡到有人醒来处理。

`timeout-minutes` 帮不上忙，它从 job 开始执行时才计时，排队时间不算。

切回托管时按下面的步骤操作：

```bash
gh variable delete CI_RUNNER --repo owner/repo                       # 1. 新 run 立刻走托管
gh run list --status queued --json databaseId -q '.[].databaseId' \
  | xargs -r -I{} gh run cancel {} --repo owner/repo                 # 2. 取消卡住的排队 run
# 3. 在各 PR 上 Re-run，或推一个空 commit
```

### 6.4 哨兵：机器挂了要有人知道

自建 runner 下线时必须有告警。这里的「哨兵」指定期检查 runner 是否正常、发现异常就发出提醒的机制。

原因：只有一台自建机器（N=1）就是单点，而 6.3 说明了它挂掉的代价是 24 小时。

注意：在托管上跑高频定时哨兵，费用承受不了。

一个流传很广的方案是「配一个跑在托管上的哨兵，每 13 分钟查一次排队队列」。它的费用问题如下：

- 托管按每个 job 向上取整计费，这样每月要 3323 计费分钟。
- 这已经超过整个免费额度（2000 分钟）。
- 改用自建 runner 本来是为了节省额度，这样的哨兵会把额度全部用掉，两者矛盾。

不同频率的费用如下：

| 频率 | run/月 | 计费分/月 | 结论 |
|---|---|---|---|
| 每 13 分钟 | 3323 | 3323 | 不可行 |
| 每 30 分钟 | 1440 | 1440 | 不可行 |
| 每小时 | 720 | 720 | 慎用 |
| 每 6 小时 | 120 | 120 | 可以 |

推荐做法：哨兵分两层，主层不花 GitHub 分钟。

#### ① 主层：机器侧 dead-man's-switch（0 计费分钟）

dead-man's-switch 指机器定期向外部服务发心跳，心跳停了由外部服务告警。可以用任意免费心跳服务，例如 healthchecks.io、UptimeRobot、Better Stack。

服务单元示例：

```ini
# /etc/systemd/system/ci-heartbeat.service
[Service]
Type=oneshot
# 只有 runner 服务真的在跑时才上报 —— 机器活着但 runner 死了也要能发现
ExecStart=/bin/bash -c 'systemctl is-active --quiet <runner-unit> && curl -fsS -m 10 --retry 3 https://hc-ping.com/<UUID> >/dev/null'
```

再给它配一个 5 分钟的 timer。这一层能发现以下情况：

- 机器宕机
- 网络断开
- runner 进程退出

#### ② 兜底层：挂在已有 workflow 上（0 新增计费 run）

前提：你有一个每个 PR 都跑、并且留在托管上的轻量 workflow，例如元数据校验。

做法：在这个 workflow 末尾加一个 `if: always()` 的 step：

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

局限：只有在有人开 PR 时才会运行，没有 PR 的时段覆盖不到。这段时间靠 ① 主层。

> 注意：判断 runner 是否下线要查排队队列，不要查 `/actions/runners` 返回的 online 状态。实测 `systemctl stop` runner 之后，这个字段仍然显示 online，有分钟级的延迟，不能作为可靠信号。

### 6.5 留一个 workflow 在托管上

建议不要把所有 workflow 都搬到自建 runner。留一个每个 PR 都跑的轻量 workflow 在 `ubuntu-latest` 上，好处有三点：

- 它可以当作托管侧的金丝雀（不受自建机器影响的对照组）。自建机器挂了，它照样出结果，一眼就能分清是机器挂了还是代码有错。
- 它是挂哨兵成本最低的位置（见 6.4 ②）。
- 如果它依赖某个只在托管上预装的工具，留在托管上就不用在自建机器上再装一遍。

> 参考项目：`pr-meta.yml` 固定在 `ubuntu-latest`。它只需要 10 秒，搬到自建 runner 上反而要排在 5 分钟的重 job 后面。另外，它是全仓唯一一处没有 `||` 兜底的 `gh api` 调用。

### 6.6 上线动作

按下面四步上线。第 2 步合入后变量还没设置，行为应与合并前完全相同，先确认这一点再打开开关。

```bash
# 1. 确认 runner 在线且空闲
gh api repos/OWNER/REPO/actions/runners --jq '.runners[]|{name,status,busy}'

# 2. 合入改好的 workflow（此时变量未设 ⇒ 行为与合并前逐字相同，先验证这一步不改变任何东西）

# 3. 打开开关
gh variable set CI_RUNNER --repo OWNER/REPO --body '["self-hosted","linux","x64","ci"]'

# 4. 开一个空改动的测试 PR，确认各 check 都出现、都落到你的 runner、都绿
#    ★ 再开第二个 PR —— 那才是验证「容器名冲突」修复的地方
```

注意：第 4 步还要再开第二个 PR，「容器名冲突」的修复要在第二个 PR 上才能验证。

---

## 07 验证

本章说明装完之后怎么确认 runner 真的可用：先跑机器侧自检脚本，再用真实 PR 验证，然后做破坏性验证和重启演练。

机器侧的全部检查用一条命令跑完：

```bash
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh
```

重启之后也只需要跑这一条。它会逐项核对开机恢复路径是否真的自愈。

> 注意：`verify.sh` 不是纯只读的。
>
> 「钩子实跑」这一项会真的执行一次清理钩子：删带 CI 标签的容器、删 minio、杀 e2e 端口上的进程。有 job 在跑时执行，会打断那个 job。
>
> 因此脚本会先检查有没有 `Runner.Worker` 进程。如果有，就把「钩子实跑」和「无残留容器」两项标为 SKIP。看到 SKIP，说明当时机器在忙，等空闲后再跑一次，拿到完整结果。
>
> 背景：这个脚本原来自称「只读」，08 章又把它列为日常巡检。两者叠在一起是个陷阱，2026-10-16 才发现。

### 7.1 `verify.sh` 查什么

`verify.sh` 按下表分组检查。

| 分组 | 检查项 | 不通过意味着 |
|---|---|---|
| 服务与开机自启 | docker / containerd / runner 三个 unit `active + enabled` | 重启后回不来 |
| runner 加固 | `Restart=always`、`StartLimitIntervalSec=0`、`MemoryMax`、`OOMScoreAdjust≥500`、`After=docker` | 见 04 章各条的后果 |
| Docker | `live-restore=true`；BuildKit GC 有 Max Used 与 Min Free 两项 | 见表下说明 |
| 清理与监控 | 共 9 项，见表下说明 | 见表下说明 |
| 部署参数与系统更新 | `/etc/ci-runner.env` 存在且与钩子的 CI 标签一致；needrestart 豁免 runner；有没有待重启的更新 | 见表下说明 |
| 网络加固 | DOCKER-USER + OUTPUT 两条 metadata 规则；已持久化；实拨容器验证 | 少一条就有一条路通 |
| SSH | 口令登录是否关闭 | — |
| 干净度 | 无残留容器（有 job 时 SKIP）；匿名卷没有累积；磁盘余量 | 清理没生效 |
| GitHub 侧 | runner `online` | 注册或网络问题 |

Docker 组：如果 BuildKit GC 只有 Reserved，说明你用了 `defaultKeepStorage`，Min Free 保护就丢了。

清理与监控组的 9 个检查项：

- 钩子按 `bash -e` 实跑一次能退出 0（有 job 时 SKIP）
- 钩子带运行中 job 守卫
- 占位符已替换
- 清理钩子文件就位
- 两个钩子都挂
- timer active 且以 runner 身份运行
- 监控量的是 `/var/lib/containerd`
- 磁盘阈值与 GC 对齐
- 告警推送已配

这一组不通过的后果：

| 不通过的项 | 后果 |
|---|---|
| 钩子在 `-e` 下非零退出 | 每个 job 全红（原因见下文） |
| 钩子没有 job 守卫 | timer 撞上 job 时会删它的容器 |
| 阈值没与 GC 对齐 | 每小时误报 |
| 没配告警推送 | 告警没有接收方 |

部署参数与系统更新组不通过的后果：

- 参数没落盘：下次重新部署时会静默改回默认值。
- needrestart 没豁免 runner：安全更新会在 job 中途重启 runner。

#### 为什么「清理与监控」的第一项要实跑钩子

2026-09-07 到 09-14，这台机器连续 7 天、21 个 job 全部失败，而这张表当时报的是 24 PASS / 0 FAIL。

原因是当时的三条钩子检查都是结构性的：

- 查文件可执行
- 查 `.env` 挂了两个变量
- 查 timer active

三条都 PASS，结论也都没错，但没有一条执行过那个钩子。

runner 调用钩子时会强加 `-e`，钩子非零退出就会把 job 判为失败（详见 09 章 A11）。钩子「装上了」和「真能用」之间差一次真实调用，当时的检查只验证了前者。

这条规则适用于所有自检：**凡是非零退出会产生后果的东西，自检必须用与调用方完全相同的方式执行它一次。** 只检查它存在，等于没检查。

### 7.2 机器侧之外：必须用真实 PR 验的四件事

下面四件事 `verify.sh` 验不了，只能开 PR 验证。

#### ① 第一个测试 PR：check 落到自建机且全绿

```bash
gh api repos/OWNER/REPO/actions/runs/<id>/jobs --jq '.jobs[]|"\(.name) \(.conclusion) \(.runner_name)"'
```

输出里的 `runner_name` 应该是你的 runner 名，而不是 `GitHub Actions ####`。

#### ② 第二个测试 PR：验证容器名冲突的修复

只开一个 PR 证明不了修复有效：修复之前也是第一个 PR 绿、第二个红。所以必须连开两个。

#### ③ 手动触发定时任务：验证「同一个 run 内两个 job 自撞」

如果某个 workflow 里有两个 job 都起同名容器（这很常见），用 `workflow_dispatch` 触发一次，确认两个 job 都绿。

> 注意：必须用 `workflow_dispatch` 手动触发，不能等 schedule 自己跑。
>
> 省钱型的 nightly 前面通常挂了一道 gate（「空转的夜不跑」）。这道 gate 在 `event != schedule` 时恒为 `run=true`；在 schedule 触发且没有新提交时为 `run=false`，会把重活 job 全部跳过。
>
> 所以等一夜，你只会拿到一个「gate 绿了、别的没跑」的假绿（check 显示通过，但该验的内容并没有执行）。它在 GitHub 上和真绿看起来一模一样。
>
> 修完东西要验证，一律手动触发。

#### ④ 开关双向

- 变量未设时开 PR ⇒ 应落 `ubuntu-latest`
- 变量设了再开 PR ⇒ 应落你的 runner

#### 参考项目的实际验证记录

| 验证 | 结果 |
|---|---|
| 前两个 PR（开关变量未设） | 运行者显示 `GitHub Actions ####` |
| 后两个 PR（开关变量已设） | 显示自建 runner 名 |
| 四个 check | lint 52s / typecheck 73s / build 31s / verify 189s，全绿 |
| nightly 手动触发 | gate 4s + regression 189s + selftests 258s |

nightly 手动触发时，两个起同名容器的 job 都绿。

### 7.3 破坏性验证（建议做一次）

这一节直接检验各项保护措施到底有没有用。

#### runner 自愈

```bash
kill -9 $(systemctl show <runner-unit> -p MainPID --value)
# 期望：10–30 秒内自动拉起，MainPID 变了
```

实测 30 秒内恢复。修改前（`Restart=no`）runner 会一直停着，不会再起来。

#### 公网暴露

在 CI 跑着服务容器时验证，或者手动起一个绑法相同的容器再验证。

```bash
# 用外部节点探，别在本机探自己的公网 IP —— 那只走本地路由栈，证明不了外部可达性
curl -s -H "Accept: application/json" "https://check-host.net/check-tcp?host=<你的IP>:5433&max_nodes=4"
```

实测结果：

- 修复前：四个境外节点全部成功连上，并收到 Postgres 认证响应。
- 修复后：全部 `Connection refused`。

#### 孤儿进程假绿

适用于测试里有「起进程 + 轮询健康端点」模式的项目。

```bash
# 先用一个进程占住端口，再跑测试。期望：当场失败并指名道姓，而不是跑出一堆绿
```

实测结果：

- 修复前：220/221 通过，测到的其实是孤儿进程。
- 修复后：退出码 1，并给出明确报错。

#### 开机恢复

见 7.4。

### 7.4 重启演练

重启演练验证机器重启后能不能自己回来。这是本章唯一需要承担一次中断的验证，但它验的是最要紧的东西。

容易忽略的一点：docker 和 runner 通常是机器开机之后才装的，所以在你主动重启一次之前，「开机自启」这条路径从来没有被执行过。三个 unit 都 `enabled` 只能证明配置对，证明不了启动顺序对，也证明不了 iptables 规则已经持久化。

```bash
# 重启前：记基线
systemctl is-enabled docker containerd <runner-unit>
iptables -S | grep -c 169.254.169.254
systemctl list-timers --no-pager | grep ci-

sudo reboot

# 回来之后：一条命令
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh
```

**注意：如果你的 CI 助手或终端就跑在这台机上，重启会把它一起杀掉，所以把重启排在最后一步。**

---

## 08 运维与容量

本章讲上线之后的长期工作：怎么估算排队和容量、磁盘和 CPU 怎么监控、构建缓存怎么优化、什么时候该加机器，以及日常和每月的巡检步骤。

### 8.1 容量：用仿真，别套公式

估算排队时间和 runner 数量，要拿真实事件做仿真，不要套排队公式。

最常见的错误是套 `ρ = λ × S`（到达率 × 服务时长），再按 M/M/1 模型算排队。**在有 `cancel-in-progress` 的仓库里，这个模型不成立。** 原因如下：

- 同分支的新 push 会取消旧 run，排队中的和正在跑的都会被取消。
- 所以到达的 run 变多，不等于要做的工作变多。新 run 有很大一部分是在替换旧 run。

做法：拿真实事件的时间戳做仿真，脚本是 `scripts/analysis/queue_sim.py`。

```python
import sys; sys.path.insert(0,'scripts/analysis')
from queue_sim import ts, simulate
events = [(ts(r['created_at']), r['name'], r['head_branch']) for r in runs]   # 从 /actions/runs 拿
svc    = {'ci': 305, 'main-post-merge': 276, 'pr-meta': 12}                    # 本机实测的服务时长
r = simulate(events, svc)
```

#### 仿真时要注意的两个口径

下面两个口径，参考项目都出过错。

① 不要剔除「额度耗尽期」的 run。

这些 run 代表真实需求，只是当时没分配到 runner。剔掉它们，等于用「被服务量」去预测「需求量」，属于幸存者偏差。

> 参考项目：剔除这些 run 后按整点分桶，算得峰值是 8 run/小时。把这些没跑成的 run（死 run）算进去、改用滚动窗口重算，峰值是 20。两者差 2.5 倍。

② 事件流可能需要「重建」。

如果某个 workflow 是最近才加的，早期日期里它的事件数是 0。拿这些日子去比较「给它加 job 的代价」，得到的结论会平凡为真：那些日子里它本来就没有事件，加 job 自然显得没有代价。

> 参考项目：初版结论是「把 selftest 挂到合并后 workflow 零排队成本」。这个结论是数据造成的假象（语料假象）：被仿真的三天里，那个 workflow 还不存在。把早期的 `push→main` 事件重新标注后重跑，真实代价是最忙那天的最长排队从 15.5 分钟变成 22.3 分钟。

#### 仿真能回答的问题

下面这些决策都应该用仿真来回答，不要凭感觉估：

- N 该是几
- 要不要合并 job（比较它与别的提速手段的实际收益）
- 能不能把某个检查加到 PR 路径上
- 团队扩到 N 人时会怎样
- 需求回弹（CI 恢复后大家推得更勤）会不会顶穿（超出单机容量）

参考项目的仿真结果如下。数据取历史最忙的一天，单位是分钟。

| 场景 | 中位 | p90 | 最长 |
|---|---|---|---|
| 现状（2 人） | 1.8 | 9.7 | 15.5 |
| 需求回弹 1.9× | 1.8 | 10.1 | 22.7 |
| 团队 4 人 | 4.6 | 18.4 | 37.1 |
| 团队 8 人 | 17.0 | 81.5 | 122.8 |

结论：

- 天花板约在 4 人。
- 到 8 人时该加第二台机器。在同一台机器上加第二个 runner（N=2）的方案已经被实验证伪，见 8.5。

### 8.2 磁盘：各类占用分别由谁清理

磁盘占用来自 Docker 内的三个来源（BuildKit 缓存、匿名卷、镜像），再加上 Docker 以外的文件。它们各自由不同的机制清理，一个机制不会替其他来源兜底。BuildKit 缓存有 GC 兜底，不会无限增长；真正没有上界的是匿名卷和 Docker 以外的文件。

| 来源 | 由谁清理 | 不清理的后果 |
|---|---|---|
| BuildKit build cache | `daemon.json` 的 GC 策略 | 长到上限后由 GC 驱逐 |
| 匿名卷（services 容器的数据） | 只有 `docker volume prune` | workflow 没挂 tmpfs 时无上界，约 70 MB/job |
| 镜像 | 悬空的由钩子清；换掉的旧 pin 要人工退役 | 慢慢累积，参考项目一个月约 2 GB |
| Docker 以外 | 无 | 参考项目一个月涨了约 6 GiB |

表格补充说明：

- BuildKit 的 GC 策略有三个参数：Reserved / Max Used / Min Free。缓存会一直增长，直到长到 Max Used，或者把可用空间压到 Min Free，然后 GC 开始驱逐。
- `docker volume prune` 由清理钩子在每个 job 前后各执行一次。service 容器留下的匿名卷只有它会清，BuildKit 的 GC 不管卷；workflow 给这些容器挂上 tmpfs 后就不再产生（05 章 ⑫）。
- 换掉的旧 pin 不会被自动清理，退役步骤见 8.6。
- Docker 以外的增长包括 IDE 远程服务端、旧检出、包管理器缓存等。约 6 GiB 这个数，是 `ci-health` 采样里「可用 + containerd」之和的减少量。

所以「不清理就会盘满」这个判断通常不对。要盯的是匿名卷和 Docker 以外的增长。

#### 上线一个月的实测

测量条件：参考项目，75 GB 盘，GC 设为 Reserved 10 GiB / Max Used 20 GiB / Min Free 20 GiB，期间约 2200 个 job。

| 时间 | 已用 | 可用 |
|---|---|---|
| 上线第一周（09-07～09-13） | ~15 GiB（~20%） | ~57 GiB |
| 10-12～10-16 | ~47–49 GB（65–68%） | ~23 GiB |
| 清理之后 | ~39 GB（54%） | ~34 GB |

各阶段说明：

- 上线第一周：原稿写的「稳态 13.7 GB / 18%」是上线前测的，并非稳态。
- 10-12～10-16：这才是真正的稳态。可用空间连续 5 天不再下降。BuildKit 缓存长到 Max Used（20 GiB）后停住，可用空间比 Min Free 还高约 3 GiB。
- 清理之后：删掉了 IDE 旧服务端 2.8 GB、旧检出与 pnpm store 3.4 GB、不再引用的镜像 2.0 GB。

#### 稳态估算

用下面的公式估算稳态，比「基线 + 日增」可靠：

```text
稳态已用 ≈ 系统与工具链 + 在用镜像 + min(Max Used, 缓存工作集) + Docker 以外的东西
稳态可用 ≈ max(Min Free, 盘总量 − 上式)
```

缓存工作集由构建频率与层序决定（见 8.4）。它填满 Max Used 之后就不再增长，可用空间会停在一个稳定值上。**这是设计行为，不该触发告警。**

Min Free 是另一条线。只有在盘更小、或者 Docker 以外的增长把可用空间挤到 Min Free 附近时，GC 才会为了保底而驱逐缓存。这种情况才值得告警。

#### 监控要点

监控脚本是 `scripts/ci-health.sh`。要点如下：

- 量 `/var/lib/containerd`，不要量 `/var/lib/docker`。Docker 29 默认用 containerd 快照器，实测 containerd 占 2.6 G，docker 目录只有 115 M。量错目录会低估约 10 倍，监控就成了假绿（指标显示正常，实际没量到真实占用）。
- 匿名卷在 `/var/lib/docker/volumes`，要单独量。
- 磁盘阈值从 Min Free 推算。原版写死的两个阈值都有问题：
  - WARN < 40 GB：在设计稳态下每小时都会触发，一个月响了 309 次，没有送达任何人。
  - CRIT < 20000 MB：只比 Min Free（20480 MiB）低 480 MiB。
  - 现在的阈值：WARN = Min Free + 1 GiB，对应可用空间被挤到 Min Free 附近、GC 开始为保底驱逐缓存的时刻；CRIT = 10 GiB。
  - bootstrap 会从 `BUILDKIT_MIN_FREE` 自动算出阈值，写进 `/etc/cron.d/ci-health`。
- 告警要送到人。只写本机 journal 等于没有告警。在 `/etc/ci-health.env` 里配置 `CI_ALERT_WEBHOOK`（飞书自定义机器人）后，告警集合一有变化就推送，持续存在的告警每 24 小时提醒一次。
- 失败连续计数只统计跑在本机上的 run。如果统计全仓库，会把 GitHub 托管的检查（PR 标题之类）也算进来。
- 除了水位，也要看增量。日增超过预期两倍时，检查是不是哪个构建的层序坏了。

> 注意：CI 机上不要常驻开发工具；要常驻，就把它们算进磁盘和内存预算。参考机上，VS Code 远程服务端每次客户端升级就多一份（约 650 MB），一个月攒了 5 份。它和 AI 助手一起常驻约占 2–3 GB 内存，而这台机器没有 swap，runner 又被设成 OOM 时第一个被杀。偶尔连上来排查可以，用完断开。

### 8.3 CPU 争抢监控

CPU 争抢要常态化采点监控，上线前查一次不够。

1. 先确认 steal 指标能不能用（见 02 章 2.5）。
2. 不能用的话，就采集定长任务的墙钟时间，超过基线 1.4 倍时报警。`ci-health.sh` 已经按这个方式实现。

注意：共享 vCPU 的邻居会变。今天不拥挤，只能说明此刻不拥挤。

### 8.4 构建缓存的层序（性价比最高的一次性优化）

Dockerfile 的层序原本无所谓，换到常驻 runner 上之后，成了构建里最贵的一步。

自查：`COPY <源码>` 是不是排在 `RUN <装依赖>` 之前？

参考项目的情况：`COPY apps/api` 在 `RUN pnpm install` 之前，改任何一行 api 源码都会重装整棵依赖树。而这种改动命中 59.1% 的 PR。把源码 COPY 挪到 install 之后，温缓存实测对比如下：

| 层序 | 温重建耗时 | 磁盘增量 |
|---|---|---|
| 源码 COPY 在 install 之前 | 62.4 秒 | +1045 MB |
| 源码 COPY 在 install 之后 | 1.4 秒 | +8 MB |

改后快 45 倍、磁盘少 140 倍，镜像大小不变。

改法是先 COPY manifest，再装依赖，最后 COPY 源码：

```dockerfile
COPY package.json lockfile ./
COPY packages/*/package.json ./packages/     # 各 workspace 的 manifest
RUN <装依赖>                                  # ← 只在 lockfile/manifest 变时失效
COPY packages ./packages                     # ← 源码在后面
COPY apps ./apps
```

合并前必须实测三件事：

- ① 构建成功；
- ② 改一行源码后，温重建 <10 秒；
- ③ 镜像连真依赖起得来：用 `docker run` 起容器、打健康端点，不能只 `import` 一下。

#### 上线一个月后的复盘：install 层的缓存依据（参考项目，2026-10）

上面的改法把源码挪到了 install 之后，层序已经正确。但 install 层的缓存依据是整份清单，不只是 lockfile。下面两件事让它重新退化：

1. 根 `package.json` 里有 `scripts`。团队每加一个 npm 脚本，install 层就作废。参考项目 9 月以来，根 `package.json` 被改了 55 次，其中 50 次只改了 scripts；同期 lockfile 只变了 7 次。10-02 至 10-16，api 镜像冷构建 89/182 次。
2. 按应用传的构建参数放在 install 前面（`ARG APP_FILTER` + `--filter ${APP_FILTER}`）。结果 api 和 worker 两个镜像各存一份 install 层。实测两份层的文件清单（各约 99,000 条）只有 9 个路径不同：各自的 2 个工作区链接和它们所在的目录，依赖本身完全相同，也就是同一份依赖存了两遍。BuildKit 缓存里 98% 是 install 层（10-16 实测总量 22.0 GB，api/worker 18.1 GB，admin 3.5 GB；总量随 GC 在 20 GiB 上下浮动）。

改法：

```dockerfile
# ① install 不带按应用的参数：所有 node 应用共用一份依赖层
RUN pnpm install --frozen-lockfile --filter @app/api... --filter @app/worker... --filter <root>
ARG APP_FILTER          # 需要的话放到 install 之后
# ② 缓存依据去掉 scripts：前置阶段把各 package.json 的 scripts 字段删掉再 COPY 进来做 install，
#    install 之后在源码层再 COPY 一次完整的 package.json
# ③ install 之前仍要带 pnpm-workspace.yaml 和 lockfile：pnpm 11 的 nodeLinker、allowBuilds 只从
#    pnpm-workspace.yaml 读，少了它装法和构建许可都会变
```

注意：`pnpm fetch` + `--offline` 解决不了这个问题。实测冷构建 65 秒里，`pnpm install` 整步（含下载）只占约 12–13 秒，大头是导出和解包 1.15 GB 的 node_modules 层（约 50 秒）。管用的办法只有两个：别让 install 层失效，别把它存两份。

收益：这项优化只影响速度和磁盘，不涉及正确性。参考项目 10-10 至 10-16 这一周，冷装共占约 85 分钟 runner 时间（install 约 25 分钟，导出与解包新的依赖层约 60 分钟），约占同期全部 job 时长的 3.2%。改完能省下其中大部分，lockfile 真变了的那几次仍要重装。改完还能让 BuildKit 的 Max Used 从 20 GiB 降下来，腾出 10 GB 以上磁盘。参考项目把这项并进了它的镜像瘦身卡（metta-app 09a-3，#271）。

**先改 Dockerfile，再降 Max Used。** 顺序反过来只会让构建更冷。

### 8.5 什么时候该加第二台机器

出现下面任一信号，就该算账评估加机器：

- 排队等待的 p90 超过单 run 时长
- 团队规模翻倍（用 8.1 的仿真验证，别猜）
- 想把重检查加进 PR 路径，但仿真显示会顶穿

**扩容要加第二台机器。** 在同机加第二个 runner（N=2）的方案已被实验证伪，出现了两种不同的失败模式：CPU 饥饿导致的随机失败（flake，同一份代码时红时绿），以及 OOM。

如果一定要在同机加第二个 runner，需要满足下面的前置条件（通常都不满足）：

- ① 修掉所有固定超时的测试；
- ② 第二个 runner 打独立 label，只接秒级、无 DB、无 docker build 的活；
- ③ 独立的 `_work` 与端口；
- ④ 必须复测。

### 8.6 日常巡检

日常巡检用下面四条命令；另有三项工作每月做一次。

```bash
bash scripts/verify.sh                    # 全面自检（有 job 在跑时部分项会 SKIP，空闲时再跑拿完整结果）
tail -20 /var/log/ci-health.log           # 采点趋势：可用空间、job 连续失败、runner 内存峰值
docker system df                          # 磁盘构成
systemctl list-timers | grep ci-          # 清理与监控 timer 还活着吗
```

#### 每月一次

找一个没有 job 在跑的时候做，即 `pgrep -x Runner.Worker` 输出为空。

1. 重启机器。
   - 原因：needrestart 已经豁免了 runner（4.2 节），安全更新装上了，但 runner 还在用旧库；内核更新更是必须重启才生效。参考机上线 5 周没重启过，期间来过 3 个新内核（自动只保留最新一个）和一次 libc6，全都没生效。
   - 做法：先 `systemctl stop <runner 服务>` 再重启，免得刚好接到一个 job。`live-restore` 与 `Restart=always` 会让一切自己恢复。
   - 确认：恢复后跑 `verify.sh`。
   - 旧内核不用手动删。Ubuntu 会把重启前在用的那个内核保留作回退，`apt autoremove` 这时不会删它，等下次装新内核时才会标记为可删除。参考机 2026-10-16 重启后就是这样。
2. 退役旧镜像。workflow 换了 pin 之后，旧版本不会被自动删除（钩子只删悬空的和打了 CI 标签的）：
   ```bash
   docker images --digests          # 对照 workflow 里实际引用的 image@sha256，删掉不再引用的
   docker image rm <旧镜像>          # 不带 -f：还有容器在用的话 Docker 会拒绝
   ```
   注意：别用 `docker image prune -a --filter until=...` 代劳。until 按镜像的创建时间算，一个两年前构建、今天还在用的 pin 会被删掉。
3. 看一眼 Docker 以外的增长，例如 `du -sh /root/.vscode-server /root/.cursor-server /home/*/.cache`。VS Code 远程服务端可以只留正在用的那一份：用 `ls ~/.vscode-server/cli/servers/` 列出所有版本，进程在用的那个之外都能删。

---

## 09 踩坑记录

本章记录部署和运行中踩过的坑，分三部分：

- A. 环境的坑：换一台机器还会遇到。
- B. 我们自己判断错的地方：方法论层面的问题，换个环境还会以别的形式出现，比 A 更值得读。
- C. 有争议、未采纳的建议，以及不采纳的数据依据。

---

### A. 环境的坑

#### A1. `defaultKeepStorage` 会把 Min Free 保护丢掉

用 `defaultKeepStorage` 配 BuildKit GC，会让出厂的 Min Free Space 保护失效。

```json
{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"10GB"}}}
```

这个写法看起来对，实际上 `defaultKeepStorage` 只映射到 Reserved Space，出厂的 `Min Free Space` 保护就没了。

另一种写法也不行：把 `reservedSpace`/`maxUsedSpace`/`minFreeSpace` 直接写在 `gc` 顶层，会被静默忽略。daemon 不报错，直接回落到出厂值。

怎么做：**必须用 `policy` 数组。**

怎么确认：改完运行 `docker buildx inspect default | grep -A6 'rule#0'`，看这三项在不在。

#### A2. Docker 29 用 containerd 快照器，镜像不在 `/var/lib/docker`

Docker 29 的镜像数据在 `/var/lib/containerd`，只量 `/var/lib/docker` 的磁盘监控会严重低估占用。

```text
/var/lib/docker      115M
/var/lib/containerd  2.6G      ← 96% 的字节在这里
```

在这种形态下，所有基于 `du /var/lib/docker` 的磁盘监控都是假绿（监控显示正常，实际有问题），低估约 10 倍。

匿名卷仍在 `/var/lib/docker/volumes`，要单独量。

#### A3. `Restart=always` 必须配 `StartLimitIntervalSec=0`

只加 `Restart=always`、不加 `StartLimitIntervalSec=0`，服务反复失败后仍会停止重启，等于没写。

- systemd 默认 `StartLimitBurst=5` / `Interval=10s`。连续失败 5 次后，unit 被标为 `failed`，不再重试。
- runner 出厂的 unit 根本没有 `Restart=`（默认 `no`），进程一死就不会再起来。

#### A4. `--ephemeral` 与「不留常驻凭据」互斥

用 `--ephemeral` 的 runner 跑完 job 后要重新上线，机器上就必须有常驻的管理员凭据。

依据：

- `config.sh --help` 原文是 "let the service un-configure the runner"。
- `bin/RunnerService.js` 对 0 退出的处理是 "stop the service, no retry needed"。

也就是说，跑完一个 job 后 runner 会自己注销，并停掉服务。它已经没有注册信息了，`Restart=always` 也拉不回来。要让它回来，必须有常驻的管理员凭据。

结论：在小团队专机上，`--ephemeral` 引入的风险大于它带来的隔离。

#### A5. `needrestart` 的出厂名单里有 docker、没有 containerd

写配置前先查出厂名单，不要不查就把两条都写上：`grep -n 'docker\|containerd' /etc/needrestart/needrestart.conf`。

#### A6. GitHub `schedule` 的派发延迟是小时级

`schedule` 触发的实际开始时间可能比 cron 设定晚几个小时。18 次真实触发的实测：

| 指标 | 延迟 |
|---|---|
| 中位 | 97 分钟 |
| p90 | 267 分钟 |
| 最大 | 483 分钟 |

名义上「北京 05:47」触发，实际中位落在 07:24，最差到过 13:50。

这意味着：

1. 靠 cron 精确控制「几点跑」是做不到的。
2. 需要低延迟检出的检查别挂 schedule，挂 push 触发（实测从排队到开始 1 秒）。

#### A7. 常驻 runner 上缓存 pull 不扣 Docker Hub 配额

在常驻 runner 上，已缓存的镜像 pull 不消耗 Docker Hub 配额，稳态消耗约等于 0。

实测：3 次已缓存 `docker pull` + 2 次全 CACHED `docker build` + 1 次 `--pull=false`，计数一格未动（命中 "version checks do not count towards usage"）。

因此不用担心配额不够，要防的是让稳态的 0 变回冷拉的情况：

- 清盘脚本写得太狠；
- 浮动 tag 被上游重指向。

注意：dockerd 可能走 IPv6，用 `getent ahosts registry-1.docker.io` 看首选地址族。Docker Hub 按 IPv4 地址或 IPv6 /64 分别计数，但客户端不能选走哪一族。所以「有两份配额」是错觉，真正要盯的是它实际走的那一族。

#### A8. `sshd_config.d` 是「首次出现者胜」

`sshd_config.d` 里同一个配置项以最先出现的为准，所以加固文件名必须排在 cloud-init 写的 `50-cloud-init.conf` 之前。后者里面是 `PasswordAuthentication yes`。

做法：加固文件用 `00-` 前缀。

#### A9. 云 metadata 对容器和宿主进程都可达，要两条规则

拦截云 metadata 需要分别处理容器和宿主进程：

- 容器流量：`DOCKER-USER` 只管这一类。
- CI job 的 shell：它是宿主进程，得用 `OUTPUT` + `-m owner --uid-owner`。

#### A10. 别在本机探自己的公网 IP 来验证防火墙

在本机探测自己的公网 IP，只走本地路由栈，证明不了外部可达性。验证防火墙要用外部节点，例如 check-host.net 的多地探测。

#### A11. runner 调 job 钩子时强加 `-e`，钩子里任何一条命令非零就让 job 全红

runner 执行 job 钩子时会强加 `-e`，钩子里任何一条命令非零退出都会让 job 失败。2026-09-07 的事故就是这样造成的：连续 7 天、21 个 job、100% 失败。

##### 原因

runner 执行 job 钩子的真实命令是（Worker diag 原文）：

```text
Arguments: '-e /opt/actions-runner/hooks/ci-cleanup.sh'
```

`ci-cleanup.sh` 第 16 行写的是 `set -uo pipefail`，不含 `-e`，但这关不掉外部传进来的 `-e`。两者叠加后，脚本里任何一条命令非零退出，都会让整个脚本当场中止。末尾那句 `exit 0   # 清理失败绝不让 job 变红` 根本执行不到。

实际触发点是第 7 步：

```bash
ls -dt bin.* 2>/dev/null | grep -vx "$cb" | tail -n +2 | xargs -r rm -rf
```

机器上不存在 `bin.*` → `ls` 退出 2 → `grep` 无输入退出 1 → `pipefail` 把管道判为 1 → 中止。也就是说，「没有垃圾要清理」这个正常状态触发了全线故障。

##### 排查和修复时要注意的三点

1. GitHub 网页日志显示的命令不准。它打印 `shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}`，但那是 `ScriptHandler.PrepareExecution` 打出的装饰性 banner；钩子实际走的是 `GetScriptArgumentsFormat("sh")` = `-e {0}` 分支。**以 `_diag/Worker_*.log` 里的 `Arguments:` 为准。**
2. 两个钩子指向同一个文件时，故障面加倍。`JOB_COMPLETED` 带 `always()`，前面的步骤全跳过它也照样跑，单独就足以让 job 变红。只修 `JOB_STARTED` 等于没修。
3. 局部修补都不管用：
   - 只给出事的那两行加 `|| true`：仍然红，因为第 1 步 `docker ps | xargs` 也是管道。
   - 改成 `set +o pipefail`：仍然红，因为第 4 步是裸命令，`-e` 照样会中止脚本。

##### 修法

在 `set -uo pipefail` 之后补两行：

```bash
set +e                # 解除外部强加的 -e
trap 'exit 0' EXIT    # 兜底：连 set -u 触发的中止也吃掉
```

##### 通用规则

**写 job 钩子时，始终假设调用方会加 `-e`。** 钩子的契约是「非零 = 让 job 失败」，所以清理类钩子必须自己保证退出 0，不能依赖脚本末尾的 `exit 0`。

#### A12. `sed` 把占位符和「判断占位符有没有被替换」的守卫一起换掉了

这是 A11 那次事故中发现的第二个 bug，静默了同样久。`sed` 把守卫里的占位符也换掉了，守卫条件恒为假，孤儿进程清理从未执行。

```bash
# ci-cleanup.sh
APP_PORTS="__CI_APP_PORTS__"                              # 18 行
if [ ... ] && [ "$APP_PORTS" != "__CI_APP_PORTS__" ]; then # 30 行，守卫
```

```bash
# bootstrap.sh：逐行替换，两行都会被换到
sed -e "s#__CI_APP_PORTS__#${CI_APP_PORTS}#" ...
```

替换完，守卫变成 `[ "3100 3101" != "3100 3101" ]`，恒为假。结果是「杀掉上一次 run 遗留的宿主孤儿进程」这段逻辑永远不执行。而它要防的，正是这个文件自己的注释里写的那种假绿：e2e 跑在上一次 run 的代码上，221 条里 220 条通过。

修法：守卫不能拿被替换的值和替换目标比较。改成判断前缀，`sed` 换不到它：

```bash
if [ -n "${APP_PORTS// /}" ] && [ "${APP_PORTS#__CI_}" = "$APP_PORTS" ]; then
```

#### A13. 自动安全更新会在 job 中途重启 runner 服务

自动安全更新升级系统库后，needrestart 会重启用了旧库的服务，其中包括 runner 服务，正在跑的 job 会被打断。

2026-10-02 06:06，上线第 25 天：

```text
06:05:55  Starting apt-daily-upgrade.service
06:06:00  unattended-upgrade：libssl3t64 / openssl 3.0.13-0ubuntu3.15 → 3.16
06:06:05  Stopping actions.runner.…service      ← needrestart 判定它用了旧 libssl
```

当时正在跑的 job（`adal-fixtures (2)`）被当场打断。GitHub 上记为 Failed，下游的 adal-gate 跟着变红，只能重跑。这也是 `JOB_COMPLETED` 钩子跑不到的一个实例：runner 服务被停掉了。

原因：A5 只豁免了 containerd，runner 服务本身也在 needrestart 的自动重启范围里。而 job 中途最不能重启的就是它。

修法：`$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;`（bootstrap.sh 已加）。代价是 runner 会继续用旧库，所以要配「每月空闲时重启」（08 章 8.6）。

教训：豁免名单要按「job 依赖的常驻进程」逐个过，不能只看容器运行时。

#### A14. 匿名卷：`docker rm -f` 留卷、`--rm` 救不了、runner 删 service 容器也留卷

镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就会建一个匿名卷。不同的删法对卷的处理如下：

| 删法 | 卷 |
|---|---|
| `docker rm -f`（不带 `-v`） | 留下 |
| `docker run -d --rm` 起、`docker rm -f` 删 | 留下（实测） |
| `docker rm -fv` | 删掉 |
| runner 删 `services:` 容器（`docker rm --force <id>`） | 留下 |

补充说明：

- `--rm` 只在容器自己退出或 `docker stop` 时生效。
- runner 删 service 容器的那条命令，workflow 管不到。

参考项目里，每个用到数据库的 job 原来留下 3 个卷（postgres + redis + minio），约 70 MB，大头是 PGDATA。清理钩子的 `docker volume prune` 一直在兜底，一个月约 2200 个 job 后卷数仍是 0。但这是钩子的作用；换一台没装钩子的常驻 runner，卷数会一直涨。

从源头避免产生匿名卷：

- service 容器在 `options:` 里挂 `--tmpfs <VOLUME 路径>`。
- 步骤里起的容器也挂 tmpfs，删除时再用 `rm -fv`。只靠 `rm -fv` 不够：runner 进程被杀时清理步骤不跑。

注意：路径要用镜像实际声明的。postgres 18 是 `/var/lib/postgresql`，不是 `/var/lib/postgresql/data`。写错了不报错，卷照样漏，所以 job 里要有一步核对容器没挂卷。以非 root 运行的镜像（prometheus 是 nobody）挂 tmpfs 要加 `mode=1777`，否则写不进去、起不来。（05 章 ⑫）

参考项目 2026-10-16 在 workflow 侧改完（metta-app #269），之后 job 期间新建卷为 0。钩子里的 `docker volume prune` 留着兜底。

playbook 自己为什么漏了这一点：05 章 ① 的模板写的就是 `docker rm -f`，参考项目沿用了这个模板。

---

### B. 我们自己判断错的地方

这部分是方法论层面的问题，换个环境还会以别的形式出现。

#### B1. 把「恒为 0 的计数器」当成了证据

当时采了 1855 个 `steal=0` 的样本，据此报告「无 CPU 争抢」。

这些样本全是同义反复。宿主根本没暴露 `KVM_FEATURE_STEAL_TIME`，那一列结构性恒为 0。

当时加了一条时延交叉验证，方向是对的，但没有走完最后一步去查 CPUID。

教训：拿到「全是 0」的观测时，先证明这个仪器在这台机器上能读出非 0，再去解释这个 0。

#### B2. GiB / GB 单位混用，还据此质疑了别人的数字

报告里写了「7751 MB（非 8 GB）」「74.8 GiB（非 80 GB）」，认为同事的数字不准。

实际上 7751 MiB = 8.13 GB，裸盘是 81.92 GB。厂商标称没错，换算错的是这份报告。

教训：

- `free -m` / `df -BM` 的「MB」其实是 MiB。跨口径比较前先统一单位。
- 指出别人数字有误之前，先确认自己的换算。

#### B3. 探针没跑完就下结论

采样脚本还在跑的时候（207/400 样本），就统计并写进了报告，结论是「全部 100% 成功」。

跑满后发现 `api.github.com` 有 6 次 504，密集落在 3 分钟窗口内，严格口径成功率是 98.50%。

教训：异步采集的作业，统计前先确认它已经结束（比对预期样本数）。

#### B4. 用被压制过的历史预测未来需求

算峰值到达率时，剔除了「额度耗尽期」那 205 个未分配到 runner 的 run，理由是它们「没真跑」。

但这些 run 代表真实需求。剔掉之后峰值从 20 变成 8，低估了 2.5 倍。

教训：区分「被服务量」和「需求量」。用被服务量预测容量，结果必然偏乐观。

#### B5. 用错模型：M/M/1 不建模 cancel-in-progress

按 `ρ=λS` 算出「排队 10.7 分钟」，而用真实事件做的仿真给出的结果完全不同。

公式假设每个到达都要完整服务一遍。而这个仓库里，同分支的新 push 会取消旧 run，新 run 替换旧 run，负载不会叠加。

教训：套排队公式前，先确认系统的取消/合并语义与模型假设一致。有真实时间戳就直接仿真。

#### B6. 语料假象：拿「那个东西还不存在」的日子做对照

仿真得出「把某检查挂到合并后 workflow 零排队成本」，依据是四天的等待分布逐格相同。

但其中三天那个 workflow 还没上线，事件数是 0。给不存在的 job 加活，当然看不出变化。重建事件流后，最忙那天的真实代价是 15.5 → 22.3 分钟。

教训：做对照实验时，先确认被比较的东西在那个时间窗里存在。

#### B7. 建议了一个成本超出免费额度的方案

当时直接采用了「每 13 分钟查一次排队队列」的哨兵建议，没有算成本。

按每 job 向上取整计费，这是 3323 计费分钟/月，比整个免费额度还多。

教训：任何「定时轮询」的建议，先乘一遍频率算出成本再说。

#### B8. 建议了一个会自相矛盾的开关（`--ephemeral`）

当时按通行做法建议开 `--ephemeral`，同时又建议「用完撤销 PAT」。读了 runner 源码才发现两者互斥（见 A4）。

教训：涉及「自动重新注册」的机制，先去读它到底靠什么重新注册。

#### B9. 监控脚本量错了目录

监控写完后才发现，它量的是 `/var/lib/docker`（见 A2）。

这个 bug 是 verify.sh 自己抓出来的。这说明写一个会失败的自检是有价值的：它检查的是你以为已经配好了的东西。

#### B10. 三道检测同时失明：全程只测了「存在」，没测过「能用」

verify.sh 抓到了 B9，却完全没发现 A11，而 A11 让 CI 瘫了 7 天。所以 B9 的结论要打个折扣。

事故期间这台机器的全部信号：

| 信号 | 读数 | 为什么是假的 |
|---|---|---|
| `systemctl is-active` | `active` | 服务确实活着，只是接一个 job 红一个 |
| `systemctl --failed` | 0 个 | 同上 |
| `ci-health.sh` × 170 次/7 天 | 全部 `runner=active` | 只采存活，不采产出 |
| `verify.sh` | 24 PASS / 0 FAIL | 三条钩子检查全是结构性的 |
| GitHub 上的 `main` | passing | 09-07 之后没人 push，那个绿从没被重新检验 |

verify.sh 当时问的三个问题是：

```bash
[ -x "$RUNNER_HOME/hooks/ci-cleanup.sh" ]              # 文件在不在、可不可执行
grep -c '^ACTIONS_RUNNER_HOOK_JOB_' "$RUNNER_HOME/.env" # 变量挂没挂
systemctl is-active ci-cleanup.timer                    # timer 起没起
```

三条都 PASS，结果也都对：文件确实在，变量确实挂了，timer 确实在跑。但没有一条检查过真正要紧的问题：它到底能不能正常退出。

`bootstrap.sh` 也有同样的问题：它把钩子装好、挂好、起好 timer，然后一次都没执行过。多花 0.2 秒执行一次就能发现。

教训（这条比 A11 本身更重要）：

> **结构检查 ≠ 执行检查。** 「装上了」和「真能用」之间隔着一次真实调用。凡是有「非零退出会产生后果」契约的东西，比如钩子、健康探针、`ExecStartPre`，自检必须用和调用方完全相同的方式执行它一次，不能只检查它存在。

由此推出一条监控选型的原则：

> 存活指标（liveness）永远不能替代产出指标（outcome）。`is-active` 在这 7 天里每次返回的都是正确答案，问题在于检查问的问题本身不对。

现在 ci-health.sh 加了 `jobs=streak=N`（最近连续失败次数），在这次故障的第 3 天就会报 CRIT。补这一条的成本是 15 行 shell。

另外，MSN-0035 恰好在故障开始那天收尾，结论是「已完成 / 关键假设 12 成立 / 24 PASS 0 FAIL」。验收通过不等于系统可用，当时只测了前者。

#### B11. 告警阈值没对齐设计稳态，也没有送达渠道

`ci-health.sh` 原来的磁盘告警阈值在系统正常状态下就会响，而且告警没有送到任何人。

原阈值是写死的：可用 < 40 GB 报 WARN，< 20000 MB 报 CRIT。

而 BuildKit GC 设的是 Max Used 20 GiB、Min Free 20 GiB：缓存长到 20 GiB 就停。参考机上这时可用空间稳定在约 23 GiB，这就是设计稳态。

结果：

- WARN 从 10-02 起开始出现，10-10 起每小时都响，一个月 309 次。
- CRIT 阈值只比 Min Free（20480 MiB）低 480 MiB，可用空间稍被挤占就会触发。
- 这些告警只写本机 journal，没有接收方。06 章说的心跳告警也从没部署。
- 唯一一次由定时任务产生的「job 连续失败」CRIT（10-08）同样没有送达任何人，而且它本身是误报：它统计的是全仓库的 run，把 GitHub 托管的 PR 标题检查失败也算了进来。日志里另外两次 CRIT 是 09-14 修 A11 时手工测试产生的。

教训：

> 阈值要从系统自己的设计平衡点推出来，不要凭感觉定「多少算少」。一个在正常状态下就会响的告警，会让所有人习惯忽略它，包括它真正该响的那一次。
>
> 告警的定义包括它送到谁手里。只写进本机日志的告警，等于没有告警。

#### B12. 把管理员 token 落在了 CI 机上（2026-09-14 修 A11 时引入）

给 `ci-health.sh` 加 job 产出采样时，把注册 runner 用的那个 PAT 写进了 `/etc/ci-health.env`，理由是「文件 0600、只有 root 能读」。这是一个 classic token，权限包括 `admin:org`、`delete_repo`、`workflow`。

为什么有问题：

- 0600 在 CI 机上不构成边界。runner 在 docker 组里（≈ root），任何 CI job，包括 `pnpm install` 时某个依赖的 postinstall 脚本，都可以 `docker run -v /etc:/h …` 读到它。
- 同一个 token 还嵌在机器上两个 git 检出的 remote URL 和一个排查脚本里（检出已在 10-16 的清理中删除）。
- 它有过期日，过期后采样会静默退化。

修法：

- bootstrap 不再把 `GH_TOKEN` 写进任何文件。
- 采样改用单独的 `CI_HEALTH_GH_TOKEN`（fine-grained，只授权这一个仓库，`Actions: read`）。
- 采样失败（401/403）时告警，不再静默跳过。

已部署的机器要做三件事：

1. 撤销旧 token。
2. 换上只读 token。
3. 删掉 `/etc/ci-health.env` 里的 `GH_TOKEN` 行。

教训：

> **CI 机上没有「只有 root 能读」这回事。** 落在这台机器磁盘上的任何东西，都要按「CI job 读得到」来设计。给监控用的凭据，按它真正需要的最小权限单独申请，不要顺手复用手边权限最大的那个。

#### B13. 把一次性回收量当成持续效果

原稿测了一次 `docker buildx prune --filter until=24h`，回收 5896 MB，于是在三处文档里把它写成清理「主力」。那是攒了几天缓存之后一次性清掉的量。

上线后看小时数据，情况如下：

- 它删的是 24 小时没被用到的缓存，常常是整层几 GB 的依赖层（lockfile 一换，或者安静了一晚上）。删完之后，下一次构建就是冷的。
- 这些空间在需要时 GC 本来就会回收。它确实在删东西，但删的时机不对：空间还够的时候就提前删，结果是冷构建。
- 真正卡住缓存上限的是 daemon.json 的 GC。
- 上线第一个月里每个 job 都在回收的是 `volume prune`（当时 workflow 还没挂 tmpfs，每个起 service/minio 的 job 约 70 MB），旧版表格却把它排在最后。

教训：

> 评估清理措施，要看稳态下它删的是什么、删了要付出什么代价，不能看攒了一阵之后清一次的总量。后者只说明它第一次跑的时候有多少东西可删，说明不了它平时是在帮忙还是在添乱。

#### B14. 自检脚本自称只读，却会打断正在跑的 job（2026-09-14 引入）

修 A11 时，按 B10 的教训给 `verify.sh` 加了「真的执行一次钩子」这条检查，但没改脚本头上「只读，不改任何东西」那句说明。

钩子会删 CI 容器、杀 e2e 端口，而 08 章把 `verify.sh` 列为日常巡检。有 job 在跑时执行一次 verify.sh，那个 job 就会被打断。每日 timer 也有同样的问题。

修复过程中，测试本身又出了两个问题：

- 用 `pgrep -f Runner.Worker` 判断「有没有 job」，结果匹配到了测试命令自己的命令行，空闲时也判成忙。改为 `pgrep -x`。
- 测试副本放在 `/tmp`，并 `chown` 给了 runner。Ubuntu 默认 `fs.protected_regular=2`，root 也不能覆盖写粘滞目录里别的用户的文件。于是之后每次重新生成都静默失败，测的一直是最早那个旧版本，有一轮「通过」是假的。

教训：

> 给一个「只读」工具加主动探测，要么加守卫，要么改掉它的名字和说明。名字、说明和实际行为不一致，就是陷阱。
>
> 测试通过时，先确认它测到的是新代码（比如 grep 一下被测文件里有没有刚加的那行），尤其是测试结果和预期一致的时候。

#### B15. 部署脚本幂等，但参数不落盘

`bootstrap.sh` 设计为幂等、可以重跑，但 `CI_LABEL`、`CI_APP_PORTS`、基线这些参数只在命令行上传一次，哪里都没存。参考机的实际值和默认值全都不同。

如果哪天直接重跑 `bootstrap.sh`，会出现以下情况，而且都不报错：

- 清理钩子换成默认标签，按标签清理全部落空；
- 孤儿端口清理被关掉；
- 争抢告警归零。

修法：参数落盘到 `/etc/ci-runner.env`，重跑时作为默认值读回；`verify.sh` 核对钩子里的标签与落盘值一致。

教训：

> 「可以重跑」的前提是「重跑时知道上次是怎么跑的」。幂等只保证操作可以重复，参数要另外落盘保存。

---

### C. 有争议、未采纳的建议

下面这些建议听起来都有道理，不采纳的理由来自数据。

| 建议 | 处理 | 主要依据 |
|---|---|---|
| 把 4 个 job 合并成 1 个 | 不采纳 | 排队改善与修 Dockerfile 层序 + 去 cache 等效 |
| `docker image prune` 是清理主力 | 不采纳 | 实测回收 0 MB |
| metadata 泄露 root 口令 = 阻塞项 | 降级为「高」 | 与 `/etc/shadow` 的 hash 不匹配 |
| 零下载的 `docker build` 也扣 Docker Hub 配额 | 记录在案，不采纳 | 没能复现 |

各条的详细说明：

- 把 4 个 job 合并成 1 个：三个独立方案都这么建议，论证也对（N=1 上 job 只排队不并行）。但仿真显示，它带来的排队改善与「修 Dockerfile 层序 + 去 cache」等效（11.7 vs 11.2 分钟），而后者不动一行文档，也不破坏回退时的并行。在提速之上再合并，只多省 2.2–2.6 分钟，不值 10 处文档改动。
- `docker image prune` 是清理主力：实测回收 0 MB。Docker 29 重打同名 tag 不留悬空镜像。原文接着说「主力是 `buildx prune`」，这半句也错了，见 B13：workflow 挂 tmpfs 之前，持续负载下一直在回收的是 `volume prune`；缓存上限靠 GC。
- metadata 泄露 root 口令 = 阻塞项：机制属实，但把口令与 `/etc/shadow` 的 hash 逐位比对后不匹配，是陈旧凭据，因此降级为「高」。判定「凭据泄露」之前，先验证那个凭据还有效。
- 零下载的 `docker build` 也扣 Docker Hub 配额：试着复现，没能复现（6 次操作计数一格未动）。记录在案，但不采纳。

---

## 附：脚本清单

| 脚本 | 作用 |
|---|---|
| `scripts/preflight.sh` | 候选机自检，输出 GO / NO-GO。只读 |
| `scripts/bootstrap.sh` | 装机、注册、加固，可以重复跑。`--harden-ssh` 才改 SSH，`--skip-runner` 跳过注册 |
| `scripts/verify.sh` | 装完或重启后自检，输出 PASS / FAIL 表。会试跑一次清理钩子，有 job 在跑时这一项自动跳过 |
| `scripts/ci-cleanup.sh` | 清理钩子，由 bootstrap 装到 runner 的 `hooks/` 目录 |
| `scripts/ci-health.sh` | 每小时健康采点，由 bootstrap 装到 `/usr/local/bin/` |
| `scripts/analysis/` | 调研期的测量工具：连通性采样、排队仿真、单步资源画像 |

## 附：脚本验证到什么程度

| 场景 | 怎么验证的 | 结果 |
|---|---|---|
| `bootstrap.sh` 在已配置的机器上重跑 | 完整重跑（2026-09） | 通过，退出码 0，12 项关键状态逐字节相同 |
| `bootstrap.sh` 从零安装工具链 | 干净的 `ubuntu:24.04` 容器 | 通过，docker、node、gh、psmisc 都能从零装上 |
| `bootstrap.sh` 加固段（需要 systemd） | 容器里测不了 | 只在已有机器上验证过效果，第一次在新机器上装请盯着输出 |
| `bootstrap.sh` 2026-10 新增的段落 | 参数落盘与读回、阈值推导、配置文件原地更新等逐段单独测试；线上按它的生成结果逐文件部署并逐字节比对 | 通过 |
| 在全新机器上注册 runner | 需要真实 token 和真实仓库 | 未验证，现有验证走的都是「已注册，跳过」分支 |
| `preflight.sh` | 本机实跑 | 13 PASS，2 WARN |
| `verify.sh` | 本机实跑（2026-10-16 重启后） | 34 PASS，0 FAIL |

## 附：手册没覆盖、需要你自己做的两件事

1. 配云防火墙。只能在云厂商控制台配。Docker 自己加的 DNAT 规则会绕过宿主机的 ufw，能挡住它的只有这一层。
2. 撤销注册用的 PAT。注册 runner 用的 registration token 是一次性的，但用来换取它的那个 PAT 不是，用完要撤销。
