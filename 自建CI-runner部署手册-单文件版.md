# 自建 GitHub Actions CI runner 部署手册（单文件版）

> 这份文件由仓库里的分章文件自动拼成，用 `bash scripts/make-single.sh` 重新生成。
> 要改内容请改分章文件，不要改这一份，否则两个版本会对不上。
>
> 手册讲一套通用做法：怎么选机器、按规格怎么定参数、怎么装、怎么改 workflow、怎么接线、怎么验证、怎么运维。脚本面向 x86_64 的 Ubuntu（测过 24.04）。做法不绑定厂商，云主机和裸金属都适用。换厂商时要核对的事（CPU 型号是否固定、登录方式、metadata 地址、防火墙在哪配、计费粒度等）见 02 章 2.9。
> 里面的实测数字来自参考项目：一个 pnpm monorepo 的 CI，跑在 Hetzner Cloud 一台 4 核、约 7.6 GiB 内存的共享 vCPU 云主机上。准备加第二台时又在同一家试过几台候选机（02 章 2.7）。没有特别说明时，数字指第一台。
> 写着「参考项目」的地方是举例，不是要求。你的机器该跑几个实例、参数怎么取，按 10 章的公式算。

---

## 快速开始

```bash
# 1. 验机（只读）。端口填你项目 CI 占用的宿主端口（02 章开头）
CI_HOST_PORTS="<CI 会占用的宿主端口，空格分隔>" bash scripts/preflight.sh --with-load
REF=<现有 runner 的单核分数> bash scripts/machine-check.sh     # 第一台没有参考机，不给 REF

# 2. 装机和加固，先不注册，不需要 token。参数存到 /etc/ci-runner.env，下次重跑不用再传
#    新机器先跑这一步，再建开发用户等其他普通用户：它按 RUNNER_UID（默认 1000）建 runner 用户（03 章 3.3）
#    RUNNER_NAME 每台机器不同；标签所有机器相同
#    RUNNER_MEM_MAX、RUNNER_OOM_ADJ、BUILDKIT_* 不传就用默认值 6G、800、10GB/20GB/20GB，
#    这是参考项目 8 GB 内存、75 GB 盘、不在上面开发时的取值。别的规格按 10 章 10.3、10.4 算好后显式传
GH_REPO=owner/repo \
RUNNER_NAME=<每台不同，比如 ci-1> \
RUNNER_LABELS=self-hosted,linux,x64,myproj-ci \
CI_LABEL=com.myorg.ci=1 \
CI_APP_PORTS="<CI 在宿主上监听的端口，空格分隔，没有就留空>" \
CI_FIXEDWORK_BASELINE=<第 1 步 preflight 给的 p50> \
bash scripts/bootstrap.sh --skip-runner
#    然后以 runner 用户回放最慢的 job，核对超时余量（02 章 2.7）

# 3. 注册。PAT 用 read -s 输入，不留在 shell 历史里；注册完去 GitHub 撤销
read -rsp 'PAT: ' GH_TOKEN; echo; export GH_TOKEN
bash scripts/bootstrap.sh
unset GH_TOKEN
#    可选：CI_HEALTH_GH_TOKEN（只读 token，监控「本机 job 是否连续失败」用）、
#    CI_ALERT_WEBHOOK 和 CI_ALERT_SECRET（告警推送到飞书群）。同样用 read -s 输入后 export，再跑这一步

# 4. 自检。GitHub 侧那一组要只读 token，最好在 CI 机以外查（07 章）
bash scripts/verify.sh

# 5. 改 workflow：没有脚本，必须有人读一遍第 05 章
#    改完之前不要打开开关，否则第 2 个 PR 就会失败

# 6. 接线
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","myproj-ci"]'

# 7. 连开两个测试 PR，再手动触发一次定时 workflow
```

第 5 步是唯一不能跳过的人工步骤。前四步配置的是机器；第 5 步要找出仓库里那些只在一次性 VM 上才成立的写法并改掉，CI 出问题大多出在这里。

加第二台及以后的机器：第 1 到 4 步照做，第 5、6 步不用再做，步骤和验收清单见 08 章 8.7 和 07 章 7.5。

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
- [10 按机器规格定参数](#10-按机器规格定参数)

---

## 01 决策：要不要自建

这一章帮你判断要不要自建 runner。结论先说：自建 runner 通常不是省钱方案。如果你的动机是省钱，先把本章的账算完再决定。

### 1.1 先把「省多少」算清楚

先用真实数据算出每月的计费分钟，再看自建能省下多少。GitHub Actions 的计费模型有两处容易算错：

1. 每个 job 单独向上取整到整分钟，再求和，而不按 workflow 墙钟计。一个 6 秒的 job 和一个 59 秒的 job 都记 1 分钟。job 越多、越短，取整损耗的占比越高。
2. 自托管 runner 不消耗 included minutes（套餐内含的免费额度）。所以搬走哪些 workflow，就直接省下这些 workflow 的分钟数。

第 2 条截至 2026-10 仍然成立，但要留意它可能会变。GitHub 在 2025-12-16 宣布，从 2026-03-01 起对私有仓库的自托管 runner 收每分钟 $0.002 的平台费，并计入套餐额度；随后宣布推迟，说要重新评估，没有给新日期。动手前查一下 GitHub 当前的计费文档。这项一旦生效，1.1 的账和 1.2 的理由都要重算。

- [GitHub Changelog：Actions 定价调整，顶部有推迟说明](https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/)
- [github/roadmap #1197：自托管 runner 收费，已以 not planned 关闭](https://github.com/github/roadmap/issues/1197)
- [GitHub 文档：Actions runner 计费（托管 runner 的单价）](https://docs.github.com/en/billing/reference/actions-runner-pricing)

计算方法：

- 用真实数据算，不要按配置估。脚本见 `scripts/analysis/`。
- 从 `/actions/runs/{id}/jobs` 取 `started_at`/`completed_at`，自己算时长。
- 不要用 `/timing` 端点。它在当前计费平台下返回全 0。

```text
月计费分钟 = Σ(每个 workflow 的月 run 数 × 该 workflow 每 run 的计费分钟)
每 run 计费分钟 = Σ(每个 job 的 ceil(秒数/60))     # 注意是每 job 各自取整
```

> 参考项目：按现配置外推为 2280 计费分钟/月，免费额度 2000，超出 280 分钟。按 Linux 2 核 $0.006/分钟计，费用为 $1.68/月。参考项目用的厂商（Hetzner Cloud）上，这一档的机器月租 €7–14，换了厂商按它的报价重算。只算钱的话，自建是亏的。

### 1.2 为什么仍然值得做

自建的主要收益是：CI 不会因为免费额度在团队最忙的那天突然用完而跑不起来。

免费额度 2000 分钟看起来不少，换算一下：按每 run 10 计费分钟算，只够约 200 个 PR-run（一个 PR 触发的一次完整 CI 运行）。一个 4 人小队在冲刺周很容易一天跑掉 30–35 个 PR。

> 参考项目：额度于 2026-08-21 10:27 UTC 耗尽，直到 09-01 才重置。这 10.5 天里，GitHub 仍然接受触发，但不分配 runner，job 在 1–6 秒内失败。结果是 85 个已合并的 PR 里，52 个（61%）从来没有跑过一次真实的 CI。

自建要解决的就是这个问题。相比之下，每月 $1.68 的超额费用可以忽略。

### 1.3 什么时候不该自建

遇到下面任一情形，不建议自建：

| 情形 | 原因 |
|---|---|
| 公开仓库 | fork PR 会在你的机器上执行任意代码，而 `docker` 组约等于宿主 root。GitHub 官方明确不建议。 |
| 机器还跑着别的东西（包括日常开发） | CI 会独占宿主端口、写满磁盘、触发 OOM。开发工具也算，见表下说明。 |
| 没人愿意长期维护 | 它需要清理、监控、告警、版本升级。托管 runner 不需要管这些。 |
| 额度还很宽裕 | 先做免费优化（合并 job、砍重复触发、路径门控）。通常能砍掉 50%，而且零风险。 |
| 团队分布在多时区、峰值连续 | runner 实例少（比如只有一台机器、一个实例，N=1）时排队会累积。先算清楚（见 08 章 8.1 的仿真方法）。 |

关于共享机器：如果 CI 和业务共用一个 dockerd，一次 ENOSPC（磁盘写满）除了让 CI 变红，业务也会一起写不进去。要自建就用专机。

开发工具同理。机器能不能兼开发，要把开发工具的内存算进 10 章 10.2 的公式，算下来每台还能跑至少 1 个 job 才行，配置按 04 章 4.8。参考项目单个 job 整机峰值约 6 GiB，在一台 8 GB 的 CI 机上开着 VS Code Remote 和 AI 助手开发了两天，出了 11 次全局 OOM，被杀的大多是 CI 的进程。

### 1.4 决策清单

下面五项全部为「是」，才继续往下做：

1. 仓库是私有的，或你能接受 fork PR 的代码执行风险。
2. 有专用的机器：不跑业务、不跑别人的数据；按 10 章算下来内存不够兼开发的，也不做日常开发。要几台、每台多大，见 10 章。
3. 已经做完免费优化，额度仍然吃紧。
4. 有人负责它的运维（清理、监控、升级）。
5. 接受「runner 实例有限时 job 会排队」。先用 08 章 8.1 的方法算一遍你的峰值，再决定要几台机器、每台跑几个实例（10 章）。

---

## 02 选机与验收

本章说明怎么判断一台候选机能不能用作 CI runner。拿到机器、装任何东西之前，先跑两个只读脚本：

```bash
CI_HOST_PORTS="<CI 会占用的宿主端口，空格分隔>" bash scripts/preflight.sh --with-load
REF=<现有 runner 的单核分数> bash scripts/machine-check.sh
```

`CI_HOST_PORTS` 填这台机器上 CI 会占用的所有宿主端口：`services:` 映射到宿主的端口，加上 03 章的 `CI_APP_PORTS`。参考项目填的是 `5433 6379 9000 3100 3101`。不填时 preflight 跳过端口检查，并记一条提醒。

`preflight.sh` 查硬件下限、端口、时间同步、网络和 CPU 争抢，最后打印 GO / NO-GO。它判断不了单核速度，因为它的 sha256 基线只能和同一台机器自己比（2.5）。单核速度用 `machine-check.sh` 和现有 runner 比，再按 2.7 核对每个 job 的超时余量。第一台机器没有参考机，`REF` 留空，按 2.7 的第 4 步回放。

两个脚本里的硬件下限（4 核、7000 MiB 内存、40 GiB 可用盘）是按参考项目定的默认值。你的项目按 10 章算出要多少，用 `MIN_CORES`、`MIN_MEM_MIB`、`MIN_DISK_GIB`（machine-check 里叫 `MIN_DISK_GB`）传进去。其中 40 GiB 只是脚本的最低门槛，不代表够用。跑 docker build 的 CI，盘按 10 章 10.4 算，参考项目要约 75 GB 的盘。

下面逐项解释查什么、为什么这样查。阈值可以按你的项目调整，测法不能改。换了云厂商、或者用裸金属时，先对一遍 2.9。

### 2.1 CPU 与内存：按单 job 实测峰值来定

CPU 和内存的配置要以单个 job 的实测峰值为依据，不要靠估算。

唯一可靠的做法：在候选机上把你的 CI 完整跑一遍，测每一步的峰值内存和 CPU 核秒。内存要分两个口径量：

- 进程树的峰值：job 各步骤自己拉起的进程，上线后它们都在 runner 服务的 cgroup 里。用 `scripts/analysis/step.sh` 测，它把每一步放进单独的 cgroup 里跑、按 cgroup 统计内存，比 `/usr/bin/time` 准（`/usr/bin/time` 遇到多进程时只取单个进程的最大值，会低估）。`services:` 容器、`docker run` 起的容器和 `docker build` 的 RUN 步骤都由 dockerd 管，不在这个 cgroup 里，所以这个数不含它们。它用来定 `RUNNER_MEM_MAX`（03 章 3.1）。
- 整机的峰值。CI 完整跑一遍的同时，用 `scripts/analysis/sysmon.sh` 记可用内存（MemAvailable，5 秒一采），用空闲时的可用内存减去全程最低值。它包含容器、tmpfs 和 docker build，用来定机器要多大内存、一台跑几个实例。10 章把它记作 J。量的时候机器上不要开开发工具，否则它们的占用会混进来。

step.sh 的 CPU 核秒读的是整机，容器也算在内。

参考项目各 job 的进程树峰值（step.sh 读数，不含容器）：

| job | 峰值 RSS |
|---|---|
| typecheck | 3663 MB |
| lint | 1731 MB |
| test | 1596 MB |
| Metro | 1271 MB |
| e2e | 623 MB |

typecheck 的 3663 MB 是全场最高。CPU 方面，test 3.73 核、typecheck 3.31 核、Metro 3.34 核，单个 job 就几乎用满 4 核。这些数是在 4 核机器上量的。测试框架和打包工具的 worker 数默认跟着核数走，换到核更多的机器上，同一个 job 可能用更多的核和内存，所以要在目标机器上重新量（10 章 10.1）。

进程树的数加起来只能粗估整机。参考项目早先按「进程树 3.7 GB + 服务容器 0.6 GB + 系统 0.5 GB」估出单 job 约 4.8 GiB，漏掉了 docker build。后来按整机量：2026-09-14 完整跑一遍 ci.yml（含两次 docker build），7.57 GiB 的机器上可用内存最低只剩 1339 MB，也就是 CI 加系统最多占了约 6.3 GiB，减去系统的约 0.5 GiB，单 job 约 5.8 GiB。10 章取 J = 6 GiB 就是从这里来的。当时机器上是否开着开发工具已经确认不了，所以这个值偏保守。按这个数，7.57 GiB 的机器只能同时跑 1 个 job。

一台机器能不能同时跑 2 个 job（同机 2 个 runner 实例，10 章记作 k=2），算过之后还要用实验确认。参考项目在第一台 4 核 7.57 GiB 的机器上注册了两个 runner，让两个 job 并发跑了两次，结果如下：

| 第几次 | 报错 | 原因 |
|---|---|---|
| 1 | `Error: Test timed out in 5000ms` | CPU 饥饿 |
| 2 | `Out of memory: Killed process (node) ... Exit status 137` | 内核 OOM 杀掉了 tsc |

- 第 1 次：CPU 饥饿导致一条固定超时的测试失败。同一条测试在三次单 job 运行里全部通过。
- 第 2 次：内核 OOM 杀掉了 tsc，触发 OOM 的是另一个 job 的 redis 容器。

两次并发出现了两种不同的失败，说明在这台机器上同机跑两个实例会带来不确定的红叉，同一份代码时红时绿。这种失败会让团队习惯「重跑一次就好了」，CI 的可信度会跟着下降。

注意：第 1 次失败与内存无关。所以在这台 4 核机器上，加内存也跑不了两个实例，CPU 会先成为瓶颈。核数和内存都更多的机器，资源上能跑几个按 10 章 10.2 算。现有脚本和参考项目的 workflow 每台机器只支持一个实例，要跑多个，先满足 10 章 10.6 的前提。眼下要提高并发，加机器最省事，参考项目扩容也是再加一台同规格的 4 核 8 GB，每台一个实例。

### 2.2 swap：不是否决项，但决定了两项配置

swap 为 0 不影响这台机能否选用，但会决定两项必须做的配置。

`swap = 0` 时，内存超限的结果是 OOM kill，而不会变慢。这里不要求加 swap，CI 场景下快速失败通常好过换页颠簸。需要做的是：

- 必须设 `MemoryMax`，否则一个失控的 job 会拖垮整机。它只管 runner 的进程树，CI 起的容器不在里面，容器的内存要在 workflow 里用 `--memory` 限（04 章 4.3）。
- 必须设 `OOMScoreAdjust`，否则内核按内存占用挑要杀的进程，可能杀掉你的 SSH 会话、监控脚本或别的服务。sshd 主进程会把自己调到 −1000，不会被杀，从它派生出的登录会话没有这层保护。这个值让 CI 先于普通进程被杀。机器上还开着开发工具时，先被杀的也会是 CI，要让开发工具先死，按 04 章 4.8 配。

这两项 bootstrap 都会设。

### 2.3 端口：被占用时 CI 可能连错库

CI 要用的宿主端口被别的程序占着时，有两种结果：

- `services:` 映射到宿主的端口被占，按 Docker 的默认配置，服务容器起不来，job 直接失败。这种容易发现。
- CI 在宿主上直接起的进程（03 章的 `CI_APP_PORTS`，比如 e2e 拉起的 API）端口被占，测试可能连到占着端口的那个程序上，照常通过，数据却是错的。参考项目实测过这种假绿，见 05 章 ⑨。

做法：装机前确认端口空闲。preflight 的 `CI_HOST_PORTS` 把这两类端口都填上，或者用 `ss -ltn` 对照你项目的端口清单检查。

同一台机器上跑多个 runner 实例时，各实例会抢同一组宿主端口。这是参考项目每台只跑一个实例的原因之一，见 10 章 10.6。

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

依赖源按你的包管理器换：Python 是 `pypi.org` 和 `files.pythonhosted.org`，Go 是 `proxy.golang.org`，Maven 是 `repo.maven.apache.org`。preflight 默认测 npm，别的源用 `CI_EXTRA_ENDPOINTS` 加进去，比如 `CI_EXTRA_ENDPOINTS="https://pypi.org/simple/ https://files.pythonhosted.org/"`。

官方 allowlist 里还有 `*.actions.githubusercontent.com`（pipelines/vstoken/results-receiver）、`codeload.github.com`、`objects.githubusercontent.com`。它们通常和上面几个走同一路径。一次成功的真实 runner run 比任何 curl 探针都更能证明它们是通的。

统计口径上有两个坑：

① IP 协议族。探针如果写死 `curl -4`，在双栈机器上可能测错了栈：DNS 对 Docker、npm 这类地址常优先返回 IPv6，生产实际走的那条栈根本没测到。`preflight.sh` 的连通性测试不指定协议族，和生产流量一样由系统选，每行末尾标出实际走的是 IPv4 还是 IPv6。双栈机器上，有 IPv6 地址的端点一般走 IPv6，只有 IPv4 地址的端点走 IPv4（写这份手册时 `github.com`、`api.github.com`、`ghcr.io` 都只有 IPv4 地址）。只有 Docker Hub 配额那一项分别测了两个协议族。要让两个协议族都单独过阈值，用 `scripts/analysis/netprobe.sh` 和 `netprobe6.sh` 分别跑。

② 5xx 的计法。成功率要把 5xx 计为失败。宽口径（收到任何 HTTP 响应都算成功）会把对端故障也算成通过。参考项目实测：满载轮 400 个样本里，`api.github.com` 有 6 次 504，集中在 3 分钟窗口内。宽口径报 100%，严格口径是 98.50%，刚过 98% 的线。

另外，400 个样本里的 6 个事件在数学上不会体现在 p95 上。所以 PASS 只说明链路质量达标，偶发失败仍然可能出现。

### 2.5 CPU 争抢：先确认仪器能不能用

这一节说明为什么在很多云主机上不能用 steal 时间判断 CPU 争抢，以及改用什么方法。这是本章最容易被跳过、也最容易搞错的一项。

很多云的宿主不向 guest 暴露 `KVM_FEATURE_STEAL_TIME`（CPUID `0x40000001` 的 bit5）。这时 `/proc/stat` 的 steal 列结构上恒为 0：内核根本拿不到这项数据，这个 0 不是测出来的。任何基于 `%st` 的监控在这种机器上都是永久的假绿。假绿指检查本该报警或失败，却显示正常；这里就是指标一直正常，实际什么也没测到。

这一位只在 hypervisor 签名（CPUID `0x40000000` 返回的字符串）是 `KVMKVMKVM` 时才是这个含义。别的虚拟化（Xen、Hyper-V 等）的同一位另有含义，裸金属上读到的是无关的数据。preflight 会先看是不是裸金属、再核对这个签名，不是 KVM 的只报「判断不了」，这时争抢按下面的定长任务测。裸金属没有邻居抢核，定长任务的基线照样要测，ci-health 要用它。

先跑 `systemd-detect-virt --vm`。输出 none 是裸金属；输出别的值，再用下面的命令看签名。

检查方法如下：

```bash
# preflight.sh 会自动查这一位。手工查：
python3 -c "
import os,struct
fd=os.open('/dev/cpu/0/cpuid',os.O_RDONLY)   # 需要先 modprobe cpuid
_,b,c,d=struct.unpack('<IIII',os.pread(fd,16,0x40000000))
eax=struct.unpack('<IIII',os.pread(fd,16,0x40000001))[0]
print('签名', struct.pack('<III',b,c,d), hex(eax), 'STEAL_TIME bit5 =', (eax>>5)&1)"
```

签名是 `b'KVMKVMKVM\x00\x00\x00'` 时，bit5 才有意义。

参考项目（Hetzner Cloud）测得 `eax=0x0100005b`，bit5 = 0，steal 不可观测。第一轮测试曾把「steal 全程 0.00%」当作「无争抢」的证据。由于 steal 列恒为 0，那 1855 个样本得出 0.00% 是必然的，什么也证明不了。

替代方法是测定长任务的墙钟时间。同样的活干 N 遍，如果被邻居抢核，就会变慢。参考项目在一台机器上连跑 30 遍的结果：

```text
n=30  p50=0.51s  max=0.52s  max/p50=1.02   ⇒ 无实质争抢
判读：max/p50 < 1.15；样本多时再看 CV < 5%
```

preflight 只跑 8 遍，只看 max/p50。

注意：必须用定量负载，也就是固定工作量。不要用 `openssl speed -seconds N`：它是定时的，墙钟恒等于 N，测了等于没测。`preflight.sh` 用的是固定次数的 sha256。

这个数只能和同一台机器自己比，不能拿来比较两台机器的快慢。有 SHA 指令扩展（`/proc/cpuinfo` 里的 `sha_ni`）的 CPU 算 sha256 快得多，和跑 JS、Python 的快慢对不上，两个方向都可能测偏。参考项目里，没有 `sha_ni` 的 Intel Skylake 和有 `sha_ni` 的 AMD EPYC 比，sha256 慢约 5 倍，实际单核只慢约 2 倍；两台同为 EPYC 的机器，sha256 只差约 4%，Python 循环却差 15–25%。跨机比较单核用 2.7 的方法。

把这个 p50 记下来，作为这台机器自己的基线（03 章的 `CI_FIXEDWORK_BASELINE`）。装机后由 `ci-health.sh` 每小时采点，超过基线 1.4 倍就是争抢信号。有多台 runner 时，每台用自己测的基线，不要抄别的机器的。

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

- 上线前测得 13.7 GB / 74.8 GiB = 18%。这只是第一周的水位，不是稳态。
- 实际 10-12～10-16 稳定在约 47–49 GB / 65–68%。缓存长到 Max Used（20 GiB）后停住，可用空间约 23 GiB，不再下降。详见 08 章 8.2。

BuildKit 自己有 GC 兜底，缓存不会无限增长，盘一般不会被缓存写满。要关心的是下面两件事：

① 盘给小了，GC 为了守住 Min Free 会反复驱逐缓存，构建就从温缓存退回冷构建。参考项目一次冷构建比温构建多约 65 秒。

② 匿名卷不在 BuildKit 管辖范围内，Docker 以外的东西更没有任何机制管理。这两部分没有上界，要靠清理钩子和定期运维（08 章 8.6）。

GC 的三个参数（Reserved、Max Used、Min Free）按盘的大小取，公式和各档的值见 10 章 10.4。参考项目 75 GB 的盘用 10 / 20 / 20 GB。

上面的公式和脚本里的磁盘检查，都按 Docker 数据（`/var/lib/containerd`、`/var/lib/docker`）和根分区在同一个文件系统上来写。分开放的，见 2.9 的「磁盘」一行。

### 2.7 单核速度和超时余量

核数和内存达标，不代表这台机器够快。不同厂商、不同规格族、不同代际的 CPU，单核速度差得很多。共享 vCPU 的规格，同一个套餐每次开出来的 CPU 型号还可能不同；型号相同，也可能因为宿主负载或频率不同而慢一截。所以每台新机器都要实测，换厂商要核对的事见 2.9。

最先受影响的是单核受限的 job：被限成 1 个 CPU 的测试容器、单线程的类型检查和 lint，还有测试里写死的超时（2.1 里的 `Test timed out in 5000ms`）。这类 job 不会因为核多而变快，单核慢多少，耗时就涨多少，最后撞上 `timeout-minutes`。preflight 查不出这个问题。

> 参考项目（Hetzner Cloud 的共享 vCPU 规格，CPU 型号由分到的宿主机决定）：找第二台机器时，同一个套餐先开到两台 Intel Skylake 的机器，`machine-check.sh` 的单核分数是 4.2–4.7。现有 runner（AMD EPYC-Rome）在跑 CI 时测的分数约 2.5，比值 1.7–1.9，两台都判为不合格。这个 REF 是忙时量的，偏大，实际差距只会更大。后来开到一台同为 EPYC-Rome 的 8 核机器，把真实的单核算法测试在上面跑了一遍，仍比现有 runner 慢 23%。最后用上的那台也是 EPYC-Rome（4 核），分数 2.91，比值 1.16，回放算法测试慢 13–18%。

做法分四步。

1. 拿参考分数。在现有的、跑得好好的 runner 上跑一次 `machine-check.sh`，记下它打印的「单核分数」。分数是耗时，越大越慢。最好挑它空闲的时候量（03 章 3.0）。只能在它跑 CI 时量的，加 `PAR=0` 跳过全核满载那一项，免得和 CI 抢核。这时测出的分数偏大，候选机的比值跟着偏小，判得偏松。比值接近 1.2 的候选机，要按第 4 步回放后再定。

   ```bash
   PAR=0 bash scripts/machine-check.sh                  # 在现有 runner 上；它空闲时不用加 PAR=0
   REF=<上面的单核分数> bash scripts/machine-check.sh    # 在候选机上
   ```

2. 测候选机。拿到机器先跑。候选机分数 ÷ REF 不超过 1.2 判合格，不超过 1.4 判有保留，再大判不合格。脚本还会打印 CPU 型号、有没有 SHA 指令扩展，以及全核同时满载时单核掉速多少。掉速超过 1.3 倍，可能有邻居在抢 CPU，隔一会儿再测；一直这样，也可能是这个规格的 vCPU 是超线程，两个 vCPU 共用一个物理核（2.9）。

   两台机器要用同一个 Python 大版本，否则分数没法比。同一个发行版版本自带的 python3 是一样的。不要拿 preflight 的 sha256 基线比两台机器（2.5）。

   项目以 JS 为主时，可以再用 node 跑一个同类循环当旁证，两台机器的 Node 大版本也要一致：

   ```bash
   for i in 1 2 3; do node -e "let t=Date.now(),s=0;for(let i=0;i<5e8;i++)s+=i%7;console.log((Date.now()-t)/1000)"; done
   ```

   不合格怎么办看计费方式。按小时或按秒计费的云上，直接删掉重开，最多花一两个小时的钱。按月计费的云和裸金属，开错一台就是一个月的钱，下单前先按 2.9 查清这个规格的 CPU 型号是否固定。能选固定 CPU 代际或独享 vCPU 的规格就选，拿到后照样用 machine-check 确认。

   按小时计费时，这一步可以自动化：用厂商的 API 或 CLI 写一个循环，依次是开机、等 cloud-init 跑完、跑 machine-check、不合格就删。要守三条：只删自己开的机器（建机时打标签，删之前按标签核对）；中断时先删掉正在测的那台；设次数上限。

   > 参考项目（Hetzner Cloud）：用的是 `scripts/hetzner-pick.py`，只适用于 Hetzner Cloud。它用 API 开机，用运行者自己的 SSH 钥匙登进去跑 `machine-check.sh`，合格就停；不合格就删掉，随机等几分钟、优先换个机房再开。用法见 README 的「脚本」一节。

3. 核对超时余量。记 R = 候选机耗时 ÷ 参考机耗时，先用第 2 步的分数比，有了第 4 步的回放结果就换成回放的比值。对每个跑在自建机上的 job 核对：

   ```text
   最长实测耗时 × R ≤ timeout-minutes × 2/3
   ```

   `timeout-minutes` 没写的默认 360 分钟。不满足时，先调大这个 job 的超时或者优化它，再不行就换一台机器。测试里写死的超时（比如 Jest 默认的 5000 ms）也按同样的比例核对。一台机器上跑 k 个实例时（10 章），左边再乘争核系数 M = max(1, k × C ÷ 核数)，C 是单 job 用核；每台一个实例时 M = 1。

   最长实测耗时从 GitHub 取。下面这段列出最近 100 个成功的 run 里，每个自建 job 的最长耗时。`self-hosted` 可以换成你 `runs-on` 里的项目标签：

   ```bash
   REPO=owner/repo
   gh run list --repo "$REPO" --limit 100 --status success --json databaseId -q '.[].databaseId' |
   while read -r id; do
     gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" -q '.jobs[]
       | select(.conclusion == "success" and .completed_at != null and any(.labels[]; . == "self-hosted"))
       | [.name, ((.completed_at|fromdate) - (.started_at|fromdate))] | @tsv'
   done | sort -t$'\t' -k2,2nr | awk -F'\t' '!seen[$1]++ {printf "%-40s 最长 %d 秒\n", $1, $2}'
   grep -rn "timeout-minutes" .github/workflows/
   ```

4. 回放最慢的 job。这是最可靠的证据。先用 `bootstrap.sh --skip-runner` 装好工具链和加固，不注册（03 章 3.0）。再以 runner 用户把最慢的那个 job 的命令原样跑一遍：检出代码、装依赖、按 workflow 里的命令跑。跑两遍，拿第二遍的耗时和现有机器上同一个 job 的耗时比，用这个比值当 R 再核一遍第 3 步。通过了再注册。第一台机器没有参考机，就和这个 job 在托管 runner 上的耗时比。

### 2.8 最低要求汇总（起点，按项目调）

下表汇总各项的最低要求。它只是起点，具体的数按 10 章的公式算。表里的 k 是一台机器上的 runner 实例数，现有脚本下 k = 1。

| 项 | 建议下限 | 依据 |
|---|---|---|
| CPU 核数 | k × 单 job 用核 C（在目标机器上量，向上取整）；有人在这台机器上开发，再加 2 | 参考项目单 job 约 3.7 核，C 取 4，每台一个实例要 4 核。公式见 10 章 10.2 |
| 单核速度 | `machine-check.sh` 的分数不超过参考机的 1.2 倍合格；1.2–1.4 倍要逐个核对超时余量，或者回放最慢的 job；超过 1.4 倍换一台 | 见 2.7 |
| 内存 | 系统占用 S + k × 单 job 整机峰值 J + 开发工具 D + 余量 max(1 GiB, 总内存的 10%) | 参考项目 J 取 6 GiB、S 约 0.5 GiB，7.57 GiB 的机器刚好跑 1 个，不能兼开发。公式见 10 章 10.2 |
| 磁盘 | 按 2.6 的稳态公式估算，稳态可用要高于 GC 的 Min Free | 参考项目 74.8 GiB 的盘稳态可用约 23 GiB，高于 Min Free 20 GiB。BuildKit 三个值按盘大小取，见 10 章 10.4 |
| 端口 | CI 要用的宿主端口全部空闲 | 见 2.3 |
| swap | 无所谓，但影响配置 | 见 2.2 |
| 网络 | 四条阈值全过 | 见 2.4 |

各种规格的机器该跑几个实例、参数怎么取，见 10 章 10.5 的推荐表。

### 2.9 换云厂商时要核对的事

前面各节的测法不挑厂商，云主机和裸金属都适用。换厂商、或者第一次用裸金属时，按下表对一遍：建机前查厂商文档，拿到机器后在机器上查。厂商的做法会变，以它当前的文档为准。

| 核对什么 | 各家差在哪 | 怎么查 |
|---|---|---|
| CPU 型号和 vCPU | 共享 vCPU 的规格可能每次分到不同型号的宿主机，有的规格族固定 CPU 代际。有的厂商一个 vCPU 是一个超线程 | 看厂商文档里这个规格是否标明 CPU 型号或代际、vCPU 怎么算。拿到机器看 `lscpu`，每台都跑 machine-check（2.7） |
| 性能会不会变 | 突发性能规格积分用完会限速，machine-check 只跑一分钟测不出来。维护、迁移、关机再开可能换宿主机 | 避开突发性能规格。上线后看 ci-health 的定长任务（08 章 8.3）；`lscpu` 型号变了按 10 章 10.7 重测 |
| 架构和发行版 | 有更便宜的 ARM 规格；镜像不只有 Ubuntu | `uname -m`。脚本只支持 x86_64，按 Ubuntu 写，别的发行版见 03 章开头 |
| 登录 | 有的建机时选公钥、直接以 root 登录；有的只建一个默认用户，常占着 uid 1000。root 能不能用口令登录，看镜像里的 `PermitRootLogin`。SSH 断了要靠控制台、串口或 IPMI 这类带外入口 | 建机时填 SSH 公钥。`sshd -T` 看实际生效的值。见 03 章 3.0、3.3，04 章 4.6 |
| metadata 服务 | 地址不同，裸金属多数没有。实例绑了云身份时会发临时凭据 | IPv4 地址传给 `METADATA_IP`；IPv6 的地址不要传给它，按 04 章 4.5 用 ip6tables 手工加。runner 机器不绑云身份 |
| 入方向防火墙 | 云防火墙、安全组等，叫法和位置不同。有的新机器默认不挂规则，裸金属多数没有这一层 | 看实际生效的规则，从别的机器探端口（09 章 A10）。没有时按 04 章 4.7「没有云防火墙时」做 |
| 网络 | 公网 IPv4 可能单独收费或者没有。写这份手册时 GitHub 只有 IPv4 地址，只有 IPv6 的机器连不上，除非厂商提供 NAT64/DNS64。共享出口 IP 时 Docker Hub 配额和别人共用。有的地区访问 GitHub、Docker Hub 不稳定 | `ip -4 addr`；preflight 第 4、5 项（2.4）。配额不够见 09 章 A7，连不稳就换地区或配代理 |
| 磁盘 | 本地 NVMe 和网络盘快慢差很多，默认系统盘可能只有几十 GB | `lsblk -d -o NAME,SIZE,ROTA`。快慢靠 2.7 第 4 步回放，容量按 10 章 10.4 算。另挂数据盘见表下 |
| 内存和 swap | MemTotal 比标称少多少各家不同，厂商代理也占内存。云镜像多数不带 swap，安装盘装的常带 swap 文件或分区 | MemTotal 代进 10 章 10.1 的公式；`swapon --show`（10 章 10.3） |
| 计费粒度 | 按小时或按秒计费，开错一台最多花一两个小时的钱。按月计费和裸金属开错就是一个月的钱，可能还有安装费和最短租期 | 按月计费的，下单前确认 CPU 型号固定（本表第一行）。按小时计费的可以自动开、测、删，见 2.7 第 2 步 |

另挂数据盘放 Docker 时，preflight、machine-check、verify、ci-health 的磁盘检查量的仍是根分区，要改成 Docker 数据（`/var/lib/containerd`、`/var/lib/docker`）所在的路径，10 章 10.4 的盘总量也按那块盘算。不想改脚本，就在建机时把系统盘选够大，不另挂盘。

---

## 03 装机与注册

本章用 `scripts/bootstrap.sh` 完成装机和 runner 注册，后面各节逐项说明脚本每一步为什么这样做。新机器建议分两次跑：第一次不注册，确认机器够快之后再注册，见 3.0。

脚本的适用范围是 x86_64 的 Ubuntu（测过 24.04，真机测试都在参考项目所用的 Hetzner Cloud 上），一台机器一个 runner 实例。在别的架构上它一开始就退出。Debian 没有实测过：bootstrap 里 Docker 的 apt 源写死了 `linux/ubuntu`（第 2 步，两处），Debian 上换成 `linux/debian`。不用 apt 的发行版要自己改装包那几步。换厂商要核对的事见 02 章 2.9。现在要提高并发就加机器（08 章 8.7）；一台机器跑多个实例要先满足 10 章 10.6 的前提。

```bash
read -rsp 'PAT: ' GH_TOKEN; echo; export GH_TOKEN
GH_REPO=owner/repo \
RUNNER_NAME=<每台不同，比如 ci-1> \
RUNNER_LABELS=self-hosted,linux,x64,myproj-ci \
CI_LABEL=com.myorg.ci=1 \
CI_APP_PORTS="3100 3101" \
CI_FIXEDWORK_BASELINE=<这台机器上 preflight 给的 p50> \
bash scripts/bootstrap.sh
unset GH_TOKEN
```

第一行用 `read -s` 输入一次性 PAT，这样它不会留在 shell 历史里（3.4）。注册完去 GitHub 撤销这个 PAT。标签、端口和 `CI_LABEL` 是参考项目的取值，要换成你自己的，各项怎么定见 3.1。没写出来的参数用默认值。`PNPM_VERSION` 可选，留空就交给 workflow 里的 action 处理。

`bootstrap.sh` 是幂等的：重复运行不会破坏已有配置，只补齐缺少的部分。参数会落盘到 `/etc/ci-runner.env`，重跑时没显式传的从那里读回。已在一台配置完成的机器上重跑验证过：12 项关键状态逐字节相同，只有注释文本被标准化。2026-10-19 在全新的 Ubuntu 24.04 上从零安装时跑出过几处问题（09 章 A15–A17），修复后当天和 10-25 两次在全新机器上用 `--skip-runner` 跑通，退出码 0。10-25 第二台 runner 也是在全新机器上用修复后的脚本注册的，之后 `verify.sh` 33 PASS、0 FAIL。之后新加的等 apt 锁、检查架构和 uid、注册前查同名这几处只在沙箱里单独测过，还没在真机上整体跑过。

在已经接 job 的机器上重跑之前，先等它空闲，用 `systemctl stop` 停掉 runner 服务再跑，脚本最后会重新启动它。原因是脚本只在开头查一次有没有 job，跑的几分钟里接到的 job 会被最后那次重启打断；改了 BuildKit 参数还会重启 docker。具体步骤见 08 章 8.7。

### 3.0 装机前

拿到一台新机器，按下面的顺序做。

1. 确认登录方式，用密钥登录。各厂商注入 SSH 公钥、开放 root 登录的做法不同。有的建机时选公钥，直接以 root 登录。有的只建一个默认用户（比如 AWS 的 Ubuntu 镜像是 `ubuntu`），root 不能直接 SSH，要登录后 `sudo -i`。Ubuntu、Debian 的 sshd 默认 `PermitRootLogin prohibit-password`。镜像保留这个默认值时，root 用口令登录会被拒，厂商发了 root 口令、登录时也提示输口令也一样（09 章 A21）。有的厂商会把它改成 yes。实际生效的值看 `sshd -T | grep permitrootlogin`。不管哪种，建机时都填上 SSH 公钥。忘了填的，用厂商的带外入口登进去补公钥：云上多是控制台的网页终端或串口控制台，裸金属是 IPMI 或救援系统。脚本都要以 root 跑，用默认用户登录的先 `sudo -i`。默认用户常占着 uid 1000，处理办法见 3.3。
2. 测单核速度。`scripts/machine-check.sh` 只依赖 python3，一分钟左右打印硬件信息和单核分数。先在现有的 runner 上跑一次，拿到它的分数，最好挑它空闲的时候跑；它正在跑 CI 时加 `PAR=0`，跳过全核满载那一项。再在新机器上用 `REF=<现有 runner 的分数>` 跑，脚本会判合格、有保留或不合格。不合格就换一台：按小时计费的云上删掉重开即可；按月计费或裸金属，先看 02 章 2.9。第一台没有参考机，只记下分数，以后加机器时拿它当 REF。怎么判读、超时余量怎么核对，见 02 章 2.7。端口、网络、争抢这些检查用 `preflight.sh`（02 章）。
3. 等 apt 锁。新机器刚开机时，cloud-init 和自动升级常占着 dpkg 锁，这时 apt-get 会直接失败。bootstrap 会先等 cloud-init 跑完（机器上没有 cloud-init 就不等），之后每次 apt-get 遇到锁最多等 10 分钟（`APT_LOCK_WAIT` 可调，设成 0 表示不等）。在它之前要手工装东西的，先跑 `cloud-init status --wait`，apt-get 加 `-o DPkg::Lock::Timeout=600`。注意这个选项只管 install，`apt-get update` 遇到锁仍然直接失败，要自己重试。
4. 先建 runner 用户，固定 uid。bootstrap 第一次运行时按 `RUNNER_UID`（默认 1000）建 runner 用户，所以要在建开发用户等其他普通用户之前跑它。原因和处理办法见 3.3。
5. 分两次跑 bootstrap。第一次带上全部参数、不给 token，加 `--skip-runner`：装工具链、做加固、建 runner 用户，不注册。然后以 runner 用户把最慢的那个 job 回放一遍，和现有机器的耗时比（02 章 2.7）。通过了，再输入 PAT 重跑一次完成注册。第二次的参数从 `/etc/ci-runner.env` 读回，不用再传。

   ```bash
   # 第一次：不注册，不需要 token
   GH_REPO=owner/repo RUNNER_NAME=... RUNNER_LABELS=... CI_LABEL=... CI_APP_PORTS=... \
   CI_FIXEDWORK_BASELINE=... bash scripts/bootstrap.sh --skip-runner

   # 回放最慢的 job，比耗时（02 章 2.7）

   # 第二次：注册并启动 runner
   read -rsp 'PAT: ' GH_TOKEN; echo; export GH_TOKEN
   bash scripts/bootstrap.sh
   unset GH_TOKEN
   ```

   这样单核慢的机器在接到真实的 job 之前就能发现。

### 3.1 参数怎么定

第三列是参考项目的取值，只是示例。内存、OOM 优先级、BuildKit 这几项按机器规格怎么取，见 10 章的公式和推荐表。

| 变量 | 怎么定 | 参考项目取值 |
|---|---|---|
| `RUNNER_NAME` | 每台机器唯一。注册时带 `--replace`，同名会顶掉另一台的注册。脚本注册前会查 GitHub 上有没有同名的，有就停下（3.4）。默认取主机名，云上主机名可能重复，有多台机器时显式传 | `ci-<主机名>`（默认） |
| `RUNNER_LABELS` | 至少一个项目专属标签，不要只用 `self-hosted`。多台机器用同一套 | `self-hosted,linux,x64,myproj-ci` |
| `RUNNER_UID` | 所有 runner 机器一致，见 3.3。只在新建 runner 用户时用 | `1000`（默认） |
| `RUNNER_MEM_MAX` | 不低于 runner 进程树实测峰值的 1.3 倍，不高于 10 章 10.3 的上限。进程树峰值用 `step.sh`（02 章 2.1）或 runner 单元 `memory.stat` 里的 anon 加 shmem 量，不含容器。`systemctl show -p MemoryPeak` 含页缓存，不能直接拿来乘。这个值只跟 job 有关，换大机器不用调大 | `6G`（进程树峰值约 3.7 GB） |
| `RUNNER_OOM_ADJ` | runner 被内核 OOM 挑中的优先级。机器只跑 CI 用默认值。还开着开发工具、要它们先被杀时，取满足 (1000 − 本值) / 1000 × 总内存 > `RUNNER_MEM_MAX` 的值。原理见 04 章 4.3，各内存档的取值见 10 章 10.3 | `800`（只跑 CI）；约 7.6 GiB 的机器兼开发时 `200` |
| `CI_APP_PORTS` | CI 在宿主上监听的端口，不填容器端口 | `3100 3101`（e2e 拉起的 API） |
| `CI_LABEL` | 与 workflow 里 `docker run --label` 的值逐字一致 | `com.myorg.ci=1` |
| `CI_PER_RUN_IMAGE_LABEL` | 每次运行用唯一 tag 建、之后不再用的镜像带的标签键。镜像同时带着 CI 标签时，钩子每次都删，不等 6 小时（05 章 ⑫）。没有这类镜像就留空 | 留空；有这类镜像时如 `com.myorg.run` |
| `CI_TMP_GLOBS` | 工具自己建在 `/tmp` 下的临时目录名，空格分隔的模式，钩子删属于 runner 用户的（05 章 ③）。不能含 `/`，不能以 `*` 或 `.` 开头。工具改用 `$RUNNER_TEMP` 后就不用配 | 留空；有这类目录时如 `myproj-scratch-*` |
| `CI_FIXEDWORK_BASELINE` | 这台机器上 `preflight.sh --with-load` 给出的 p50。每台各测各的，不能抄别的机器，也不能拿来比两台机器的快慢（02 章 2.5） | `0.51`（第一台） |
| `BUILDKIT_RESERVED` / `BUILDKIT_MAX_USED` / `BUILDKIT_MIN_FREE` | 按盘大小定，不用出厂默认值，公式见 10 章 10.4。已部署的机器上改了 `BUILDKIT_MIN_FREE`，磁盘告警阈值不会跟着重算，做法也见 10.4 | 75 GB 盘：`10GB` / `20GB` / `20GB`；150 GB 盘：`10GB` / `40GB` / `30GB` |
| `METADATA_IP` | 云 metadata 服务的地址，bootstrap 拦住 CI 访问它。多数云用默认值，阿里云、腾讯云等不同，见 04 章 4.5。裸金属一般没有 metadata 服务，留默认值即可。旧版脚本没有把它落盘，这样的机器第一次用新版重跑时要显式传一次 | `169.254.169.254`（默认） |

注意：`CI_LABEL` 必须和 workflow 里 `docker run --label` 的值逐字一致。清理钩子（`scripts/ci-cleanup.sh`，见 04 章 4.4）靠这个标签认领容器。

参数落盘在 `/etc/ci-runner.env`，里面有 `RUNNER_NAME` 和这台机器自己测的基线。不要把它拷到别的机器，新机器照本章重新定参数（3.6）。

### 3.2 工具链：workflow 用到的命令都要自己装

托管 runner 预装了约 100 个工具，自建 runner 上默认没有。缺工具是装机时最容易被低估的问题。安装前先查清 workflow 用到了哪些命令：

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

解压时要加 `--no-same-owner`。官方包里的文件属主是 uid 1001，root 解压时默认照搬属主，机器上恰好是 uid 1001 的用户就能改掉 root 和 CI 都会执行的 node（09 章 A16）。脚本已经这样做了。Node 大版本没变时脚本不会重新解压，所以它每次运行都会检查 `/opt/node`，有不归 root 的文件就把属主收回 root。旧版脚本装的机器，重跑 bootstrap 就能修好，也可以手工执行 `chown -R root:root /opt/node`。检查命令是 `find /opt/node ! -user 0 | head`，没有输出就对了。

### 3.3 runner 用户：`docker` 组 ≈ 免密宿主 root

runner 用户必须加入 `docker` 组，而 `docker` 组等价于免密的宿主 root。

- 必须加入的原因：`services:` 容器、`docker build`、`docker run` 都需要 docker 权限。
- 等价于 root 的原因：`docker run -v /:/host` 就能读写整个文件系统。

除非改用 rootless dockerd（那是另一套工程），否则这一点没法绕开。需要清楚它意味着什么：

**任何能让 CI 执行代码的人，都能拿到这台机器的 root。**

- 在私有仓里，这指所有有 push 权限的协作者，可以接受。
- 它也包括被投毒的第三方 action。05 章 ⑪ 的供应链措施防的就是这种情况，有实际必要。

开发用的账号另建，不要加进 `docker` 组，见 04 章 4.8。

#### runner 用户的 uid：每台机器一致

所有 runner 机器上，runner 用户用同一个 uid，参考项目用 1000。

原因在工作区。常驻机器上工作区跨 job 复用，下一个 job 的 checkout 要先清掉上一次留下的文件。CI 容器往挂进去的工作区写文件时，文件属主是容器里进程的 uid。很多镜像里的普通用户是 uid 1000，比如 node 官方镜像自带的 `node` 用户（这个镜像默认以 root 运行，要在 workflow 里用 `--user` 切过去）。runner 也是 1000 时，这些文件归它，下一次 checkout 删得掉。runner 换成别的 uid，checkout 清理工作区时会报 `EACCES`，job 在第一步就失败（09 章 A19）。以 root 运行的容器写下的文件属于 uid 0，runner 是哪个 uid 都删不掉，处理办法见 05 章 ⑬。

做法：

- bootstrap 新建 runner 用户时用 `RUNNER_UID` 指定 uid，默认 1000。这个 uid 已经被别的用户占了，脚本报错退出，不会让 `useradd` 悄悄换一个。
- 所以拿到新机器先跑 bootstrap（3.0），再建开发用户等其他普通用户。
- 有的云镜像自带一个 uid 1000 的默认用户，比如 AWS 上的 `ubuntu`，而且它常常是唯一能 SSH 登录的账号。这种机器有两种做法：所有 runner 机器统一用另一个 uid（`RUNNER_UID=`），并按 05 章 ⑬ 让容器以 runner 的 uid 写文件；或者先给 root 或另一个账号配好公钥、确认能登录，再用那个账号把默认用户改到别的 uid。默认用户还登录着的时候改不了它的 uid。preflight 第 1 项会提示 uid 1000 被谁占着。
- runner 用户已经存在时，bootstrap 不改它的 uid，只在和 `RUNNER_UID` 不一致时打印一行提示。已部署的机器重跑不受影响。

### 3.4 注册：用一次性 token，不留常驻凭据

注册时用一次性 PAT 换取 registration token，不在机器上留常驻凭据。

```bash
# registration token 有效期 1 小时，只能用来注册 runner。
# PAT 经标准输入交给 curl（-H @-），不进命令行参数。printf 是 bash 内建命令，不单独起进程。
REG=$(printf 'Authorization: Bearer %s\n' "$GH_TOKEN" \
  | curl -fsS -X POST -H @- \
      "https://api.github.com/repos/$GH_REPO/actions/runners/registration-token" | jq -r .token)
sudo -u runner ./config.sh --unattended --url "https://github.com/$GH_REPO" \
  --token "$REG" --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work --replace
```

PAT 的处理：

- `GH_TOKEN` 只在注册时用，做两件事：查 runner 的最新版本号，换取 registration token。脚本不会把它写进任何文件。
- 建议用 fine-grained PAT，只授予目标仓库的 `Administration: read&write` 权限，注册完立刻撤销。
- 不要把 `GH_TOKEN=...` 写在交互式命令行上，它会留在 `~/.bash_history`。CI job 以 runner 用户运行，runner 在 `docker` 组里，读得到机器上的任何文件（3.3）。用 `read -rs GH_TOKEN` 输入后 `export`。
- 也不要把 PAT 放进命令行参数。命令行参数本机所有用户都看得到（`ps`、`/proc/<pid>/cmdline`），所以脚本里的两处 curl 都从标准输入读 token。
- 从另一台机器远程装的，经标准输入把 token 写进新机器上一个 0600 的临时文件，`source` 之后马上删掉，再跑 bootstrap。一定要在 runner 启动之前删，runner 一启动就可能接 job。
- registration token 会短暂出现在 `config.sh` 的命令行参数里。它只能用来注册 runner，1 小时后失效，而且注册时 runner 还没启动、机器上没有 job。注册时机器上不要有别人登录。

`--replace` 会顶掉同名的已有注册，不报错。名字撞上另一台在用的机器时，那台从此接不到 job，而按名字查 GitHub 上的状态还是 online（在线的是新机器），很难发现（09 章 A18）。所以 `RUNNER_NAME` 每台必须不同，多台机器的其他注意事项见 08 章 8.7。

为此 bootstrap 在调 `config.sh` 之前，会用同一个 PAT 查一次仓库里的 runner 列表。查到同名的注册（不管在线还是离线）就报错退出，不注册。这时分两种情况：

- 那是另一台还在用的机器：换一个名字，用 `RUNNER_NAME=<新名字>` 重跑。
- 那条注册确实已经作废，比如这台机器重装之前留下的，或者对应的机器已经撤掉：先在仓库的 Settings → Actions → Runners 里删掉它再重跑，或者重跑时加 `FORCE_REPLACE=1`，让 `--replace` 顶掉它。

手工注册时没有这层检查，先按 08 章 8.7 的命令列一遍已有的 runner。

启动顺序：注册之后脚本只把服务装好，不启动。等 04 章的 systemd 加固、清理钩子和 metadata 拦截都就位，最后才启动一次（09 章 A17）。原因有两个：

1. runner 一上线就会去接排队的 job。先启动再加固，紧接着的重启会把这个 job 打断。
2. runner 只在启动时读 `.env` 里的钩子。启动早了，那一轮接到的 job 没有清理钩子。

手工注册也按这个顺序。

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

一次没被发现的注销，会造成最长 24 小时全员 CI 停摆。原因有两点：

- GitHub 对排队 job 的自动取消时限是 24 小时。
- 回退开关救不了已经排队的 job。

如果需要每个 job 都有干净的环境，用 `ACTIONS_RUNNER_HOOK_JOB_STARTED` 钩子实现，代价是 0（见 04 章 4.4）。

### 3.6 目录布局

装机完成后，相关文件的位置如下：

```text
/opt/actions-runner/          runner 本体
├── .env                      两个钩子的挂载点（JOB_STARTED / JOB_COMPLETED），runner 只在启动时读
├── .runner .credentials*     注册信息（别备份、别进快照，原因见下）
├── hooks/ci-cleanup.sh       清理脚本
└── _work/                    工作区，跨 job 复用（这正是自建比托管快的原因）
    ├── <repo>/<repo>/        checkout 落点
    ├── _temp/                $RUNNER_TEMP，每个 job 新建并清理
    └── _tool/                setup-node 等的工具缓存（约 200 MB，跨 job 复用）
/opt/node/                    Node 运行时
/usr/local/bin/ci-health.sh   健康采点
/etc/cron.d/ci-health         每小时跑一次 ci-health.sh，基线和磁盘阈值也写在这里
/etc/ci-runner.env            本机的部署参数（无密钥，0644），重跑 bootstrap 时读回。不要拷到别的机器
/etc/ci-health.env            监控用的只读 token 和告警地址（0600）
```

注意：`.runner` 和 `.credentials*` 是注册信息，不要备份，也不要放进快照。`.credentials` 和 `.credentials_rsaparams` 里是这台 runner 的身份凭据（含 RSA 私钥）：拿到这两个文件的人可以冒充这台 runner 去领 job，而 job 能读到仓库的 secrets；把快照恢复到另一台机器上，还会出现两台机器用同一个身份抢 job 的情况。

`/etc/ci-runner.env` 也不要跟着快照或拷贝走。它存着 `RUNNER_NAME`，用快照克隆或拷文件做出第二台时，新机器会带着同一个名字去注册。bootstrap 查到同名会停下（3.4），但加了 `FORCE_REPLACE=1` 或者手工注册时，第一台的注册就被顶掉了。新机器照 3.0 从头装，参数重新定。

---

## 04 加固

`bootstrap.sh` 已经完成了这一章的大部分操作。本章逐条说明每项配置的理由，其中有几条和直觉相反。

文中的具体数值，比如 `MemoryMax=6G`、BuildKit 的 10GB / 20GB / 20GB，都是参考项目的取值，来自它的第一台 runner：4 核、约 7.6 GiB 内存、75 GB 盘。你的机器按 10 章的公式和推荐表定。

### 4.1 Docker 守护进程

daemon.json 里要有这两项。下面 GC 的三个数是参考项目 75 GB 盘的取值，别的盘大小见 10 章 10.4：

```json
{
  "builder": { "gc": { "enabled": true, "policy": [
    { "all": true, "reservedSpace": "10GB", "maxUsedSpace": "20GB", "minFreeSpace": "20GB" }
  ] } },
  "live-restore": true
}
```

#### BuildKit GC 上限

出厂默认值按盘大小的比例算，对 CI 机来说太松。参考项目 75 GB 的盘上，出厂的 Max Used 是 55.88 GiB，Min Free 是 13.97 GiB，大约是盘的四分之三和五分之一。

写法上踩过两个坑：

- `"defaultKeepStorage": "10GB"` 只映射到 Reserved Space，会丢掉 `Min Free` 保护。
- 在顶层直接写 `reservedSpace`/`maxUsedSpace`/`minFreeSpace` 会被静默忽略。daemon 不报错，回落到出厂值。

所以要用 `policy` 数组，三个参数写全。

改完后确认三项都在：

```bash
docker buildx inspect default | grep -A6 'rule#0'
```

三个值按盘大小怎么取，见 10 章 10.4。两个参考点：75 GB 的盘取 10GB / 20GB / 20GB，150 GB 的盘取 10GB / 40GB / 30GB。

磁盘告警阈值跟着 Min Free 走。bootstrap 按 Min Free + 1 GiB 算出 `CI_DISK_WARN_MB`，写进 `/etc/ci-runner.env`。这个值落盘以后，重跑 bootstrap 会读回旧值，不会按新的 Min Free 重算。所以在已部署的机器上改 `BUILDKIT_MIN_FREE` 时，要么同时显式传新的 `CI_DISK_WARN_MB`，要么先把 env 文件里那一行删掉。

#### `live-restore: true`

不开的话，dockerd 一旦重启（比如由 unattended-upgrades 触发），当前 job 的 `services` 容器会当场全部被杀掉。这时报错会指向业务代码，排查方向会完全错。

#### 在已部署的机器上改参数

本章各项参数（BuildKit 三个值、`RUNNER_OOM_ADJ`、`RUNNER_MEM_MAX` 等）在已部署的机器上要改，做法是重跑 bootstrap。重跑之前先等机器空闲，用 `systemctl stop` 停掉 runner 服务。bootstrap 只在开头查一次有没有 job，跑的几分钟里接到的 job 会被末尾的重启打断；daemon.json 有变化时，它还会重启 docker。脚本最后会重新启动 runner。有多台机器时一次只动一台，步骤见 08 章 8.7。

### 4.2 别让自动升级打断 job

本节要防的是：自动升级在 job 中途重启 containerd 或 runner 服务，把 job 打断。

本节按 Ubuntu 写。Ubuntu 的 `unattended-upgrades` 默认每日运行。`needrestart` 的 APT 钩子默认 `-m u`，即自动重启受影响的服务。needrestart 是 Ubuntu 服务器版默认装的；Debian 有这个包，但默认不装。没装 needrestart 的系统可以跳过这一节，bootstrap 发现没有 `/etc/needrestart` 目录也会跳过。别的发行版的自动更新机制不一样，原则相同：不要让它在 job 中途重启 containerd、docker 和 runner。

出厂配置已经豁免了 `docker`：`/etc/needrestart/needrestart.conf` 的 `override_rc` 里有 `qr(^docker) => 0`。但 `containerd` 不在名单里，而 Docker 29 的镜像与容器都由 containerd 承载。所以要补上 containerd 一条，再加上 runner 服务自身：

```perl
# /etc/needrestart/conf.d/90-ci-containerd.conf
$nrconf{override_rc}->{qr(^containerd)} = 0;
# runner 服务本身
$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;
```

docker 已经在出厂名单里，不用重复写。不同版本的出厂名单可能不一样，写之前先查一下：

```bash
grep -n override_rc -A12 /etc/needrestart/needrestart.conf
```

#### runner 服务本身也要豁免

参考项目出过一次事：

- 2026-10-02 06:06，一次 libssl 自动安全更新让 needrestart 在 job 中途重启了 runner 服务。
- 那个 job 当场被打断，GitHub 上记为 Failed，只能重跑。经过见 09 章 A13。

豁免的代价是 runner 会一直用旧库，直到下次重启。所以要配一条运维纪律：每月找一个没有 job 的时间重启一次机器（见 08 章 8.6）。有多台机器时一台一台来（08 章 8.7）。

`unattended-upgrades` 默认 `Automatic-Reboot "false"`，不会自己重启机器，这一项不用改。

### 4.3 runner 的 systemd 加固

出厂 unit 的 `[Service]` 段只有 `ExecStart` / `User` / `WorkingDirectory` / `KillMode` / `KillSignal` 这几项。也就是说 `Restart` 默认是 `no`，listener 一旦退出就再也不会起来。GitHub 侧的 `online` 状态有分钟级延迟，你不会立刻发现。

在 unit 里加上这些：

```ini
[Unit]
After=docker.service docker.socket
Wants=docker.service
# 缺这行等于白写，见下
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
# 默认 800，由 bootstrap 的 RUNNER_OOM_ADJ 设，取值见下
OOMScoreAdjust=800
MemoryAccounting=yes
# 参考项目的值，取值见 10 章 10.3
MemoryMax=6G
```

注意：systemd 的 unit 文件不支持行尾注释，`#` 只有放在行首才算注释。写在值后面会被当成值的一部分，这一行解析失败，systemd 在日志里记一条警告后直接忽略它。bootstrap 生成的 override 没有这个问题，手工照抄时要注意。

四条各自的理由：

- `After=docker`：出厂 unit 不写这个依赖。实测 runner 就绪只比 dockerd 晚 1.3 秒，而且两者完全无序。重启后 runner 可能先接到 job，docker 才起来。
- `StartLimitIntervalSec=0`：systemd 默认 `StartLimitBurst=5` / `Interval=10s`。不关掉的话，`Restart=always` 在连续失败 5 次后会被标成 `failed` 并停止重试。只写 `Restart=always` 是不够的，这是最容易漏的一行。
- `OOMScoreAdjust`：swap=0 的机器上，内存不够时进程会被 OOM kill，不会只是变慢。内核不知道哪些进程是 CI 这样的「客人」。这一行让 CI 比系统服务先被杀。取值见下面「OOM 优先级怎么定」。
- `MemoryMax`：一个失控的 job 只杀死自己。它按 runner 进程树的实测峰值定，只跟 job 有关，换大内存的机器不用调大，取值见 10 章 10.3。

注意：`MemoryMax` 只管 runner 的进程树。CI 起的容器由 containerd-shim 托管，cgroup 在 `system.slice/docker-<容器ID>.scope` 下，不在 runner 的 cgroup 里。docker build 的 RUN 步骤由 dockerd 执行，也不算在里面。所以：

- 整机内存够不够，不能拿 `MemoryMax` 或 runner 进程树的峰值推。要在跑满一整轮 CI 时记下整机可用内存的最低值，最重的几个 job 都要跑到。用 `scripts/analysis/sysmon.sh` 记，它每 5 秒记一行，量法见 10 章 10.1。
- 要管住容器，给容器加 `--memory`。也可以建一个带 `MemoryMax` 的 slice，用 `--cgroup-parent` 把容器放进去。Ubuntu 24.04 上 Docker 用 systemd cgroup 驱动，这里只能写 slice 名，比如 `ci.slice`。后一种做法参考项目没有实测。

#### OOM 优先级怎么定

内核给每个进程打一个分：内存占用 + adj × 总内存 ÷ 1000，分最高的先被杀。这里的总内存是内存加 swap，adj 的范围是 −1000 到 1000。

机器只跑 CI 时，用默认值 800。CI 进程比系统服务（adj 是 0）先被杀。sshd 的监听进程会自己把自己设成 −1000，不会被选中。

CI 起的容器不归 runner 的 unit 管。docker 默认给容器里的进程 0，启动时用 `--oom-score-adj` 单独设过的除外（services 写在 `options` 里）。所以只跑 CI 时，容器和系统服务一起按内存大小排。参考机的内核日志里两种情况都有：全局 OOM 杀过容器里 adj 为 0 的 node 进程；也有 adj 为 300 的容器在自己的 `--memory` 上限内被杀，那些容器是启动时单独设过的。想让容器也排在系统服务前面，就给它们加 `--oom-score-adj`。哪些容器设了、设的多少，以你的 workflow 和测试代码为准。

机器上还有开发工具时（VS Code 远程服务端、Claude Code、Codex 等），又要它们比 CI 先被杀，先按 4.8 把开发会话设成 1000，再调低 runner 的值。只靠 1000 对 800 不够：两者差 200，只抵 0.2 × 总内存，8 GB 的机器上约 1.5 GiB，一个大的 CI 进程照样排在开发工具前面。runner 的值要满足：

```text
(1000 − RUNNER_OOM_ADJ) ÷ 1000 × 总内存 > RUNNER_MEM_MAX
也就是 RUNNER_OOM_ADJ < 1000 × (1 − RUNNER_MEM_MAX ÷ 总内存)，再往下取整到百
```

单个 CI 进程最多涨到 `RUNNER_MEM_MAX`，再大就先撞上 runner 自己的上限。所以只要满足这个式子，开发工具哪怕只占一点内存，分也比任何一个 CI 进程高。容器的 adj 默认是 0，一定排在开发工具后面。启动时单独设过 adj 的容器，把式子里的 RUNNER_OOM_ADJ 换成它的 adj、RUNNER_MEM_MAX 换成它的 `--memory` 上限，满足了也排在开发工具后面。

例子：`RUNNER_MEM_MAX=6G`、总内存约 7.6 GiB 时，上限约 210，取 200。别的内存档的取值见 10 章 10.3。

这个式子只决定先杀谁，不解决内存不够。CI 加开发工具放不下时，调了 adj 也只是每次 OOM 改成先杀开发工具。内存够不够，按 10 章 10.2 把开发工具的占用算进去。

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

#### 钩子怎么装才算数

runner 只在启动时读 `<RUNNER_HOME>/.env`。`.env` 里这两行挂载点新加了或改了，要重启 runner 服务才生效。只改钩子脚本的内容不用重启，runner 每个 job 都会重新读一遍脚本再执行。

所以 bootstrap 注册之后只装服务、不启动。systemd 加固、钩子、metadata 拦截都就位后，在最后统一启动一次。先启动的话，新 runner 一上线就会去接排队的 job，后面的重启会把它打断，而且那一轮跑的 job 没有清理钩子（09 章 A17）。手工装的时候也按这个顺序。

更新钩子时，先写到 `ci-cleanup.sh.new`，以 runner 的身份按 `bash -e` 试跑一次（runner 调钩子时会加 `-e`，见 09 章 A11），跑通了再替换正式文件。`.env` 指向的是正式路径，直接覆盖的话，试跑失败时坏钩子已经生效，每个 job 都会红（09 章 B10）。手工做的话是这样：

```bash
H=/opt/actions-runner/hooks/ci-cleanup.sh       # 按你的 RUNNER_HOME 改
# 新内容先写到 $H.new（占位符要替换好），然后：
chown runner:runner "$H.new"; chmod 0755 "$H.new"
sudo -u runner bash -e "$H.new" && mv -f "$H.new" "$H"
```

试跑要在没有 job 的时候做。有 job 在跑时，脚本开头的守卫会让它直接退出，试跑等于没跑。先停 runner 服务再动手（4.1 末尾）就不会遇到这种情况。

#### 为什么 `JOB_STARTED` 是主力

它在下一个 job 开始前运行，不管上一个 job 是怎么结束的。

常见的说法是「`JOB_COMPLETED` 在 job 被 `cancel-in-progress` 取消时根本不执行」。参考项目的数据不支持这个说法：`_diag` 日志由清理钩子只保留最近 14 天（脚本第 7 步），这 14 天里 38 个被取消的 job 都执行了两个钩子（runner 2.337.0）。

`JOB_COMPLETED` 真正跑不到的是两种少见情况：

- job 在初始化阶段就被取消；
- runner 服务被停掉。

所以 `JOB_STARTED` 仍是更可靠的那个。

#### 为什么还要 timer

runner 进程被杀时，两个钩子都不执行。

#### 脚本里各条命令的实际作用

脚本里的关键命令，以及参考项目上线一个月（约 2200 个 job）后的实际作用：

| 命令 | 作用 | 状态 |
|---|---|---|
| `docker volume prune` | 回收匿名卷；workflow 没挂 tmpfs 时，每个起 service/minio 的 job 约 70 MB | 保留（兜底） |
| `docker image prune`（悬空）+ 按 CI 标签的 `-a`（只删 6 小时前建的） | 同一个 tag 拉到新版本后留下的旧版本 | 保留 |
| `docker buildx prune --filter until=24h` | 删掉的多是下次还要用的缓存，见下 | 已删 |
| `fuser -k <app_ports>/tcp` | 上一次 run 的宿主孤儿进程 | 保留 |
| 按 `CI_PER_RUN_IMAGE_LABEL` 删镜像（不看创建时间） | 每次运行各建一份的镜像，job 被取消时程序自己删不掉 | 2026-10-26 新增，按项目配置 |
| 删 `/tmp` 下匹配 `CI_TMP_GLOBS`、属于 runner 的条目 | 工具自己建在 `/tmp` 下的临时目录，job 被取消时留下 | 2026-10-26 新增，按项目配置 |

各条说明：

- `docker volume prune`：回收匿名卷。runner 删 service 容器时用的是不带 `-v` 的 `rm --force`，会留下匿名卷（主要是 PGDATA）。workflow 没挂 tmpfs 时，每个 job 都靠这一步回收；挂了之后就不再产生这些卷（05 章 ⑫），这一步只作兜底。
- 带 CI 标签的容器：脚本删的时候带 `-v`，runner 被杀后留下的容器连卷一起删。钩子认领容器只看 CI 标签，workflow 里自己用 `docker run` 起的容器都要带 `--label <CI_LABEL>`，不带的就清不到。services 容器平时由 runner 自己删，想让钩子在 runner 被杀后也能兜底，就在 services 的 `options` 里加上同样的 `--label`。
- `docker image prune`：用 digest 钉住的旧 pin 不算悬空，清不掉，要人工退役（08 章 8.6）。按 CI 标签的那条，要 workflow 的 `docker build` 打了标签才匹配得到，否则匹配 0 个。
- `docker buildx prune --filter until=24h`：已从脚本删除。它一次回收过 5896 MB，但那是攒了几天的量，不是持续效果（09 章 B13）。它删的是 24 小时没被用到的缓存，实际常常是整层几 GB 的依赖层（换了 lockfile，或者安静了一晚上），删完下一次构建就是冷的。这些空间在需要时 GC 本来就会回收。缓存上限靠 4.1 节 daemon.json 里的 GC 策略控制。
- `fuser -k <app_ports>/tcp`：清掉上一次 run 留在宿主上的孤儿进程，见 05 章 ⑨。这种情况属于「假绿」：测试实际跑在上一次 run 留下的孤儿进程上，本该失败的检查却显示通过。
- 最后两条接的是程序自己没删掉的东西。job 被取消时钩子照常执行，但步骤里程序的 finally、`trap` 不执行（05 章 ⑥、09 章 A22），它建的镜像和 `/tmp` 目录就留了下来。两个参数默认为空，等于不清；按项目填，取值见 03 章 3.1。删镜像那条只删同时带 CI 标签的，机器上还有别人用 docker 时的前提见 05 章 ⑫ 末尾。删 `/tmp` 那条只动 `/tmp` 下一层、属于当前用户（runner）的条目，同机开发用户的同名目录不受影响。根治还是让工具把临时目录放进 `$RUNNER_TEMP`（05 章 ③）。

#### 钩子不能撞上正在跑的 job

一台机器只跑一个 runner 时，runner 自己调用钩子，本机只有这一个 job，没有问题。但每日 timer、`verify.sh`、手工执行都可能正好撞上一个在跑的 job，这时钩子会删掉它的容器、杀掉它的 e2e 进程。

防护做法：

- 脚本开头有一道守卫。runner 自己调用时（父进程是 `Runner.Worker`），本机只有这一个 job 才往下走。从其他路径调用时，本机没有任何 job 才往下走。条件不满足就直接退出。
- 判断有没有 job 要用 `pgrep -x Runner.Worker`（按进程名精确匹配），别用 `-f`。`-f` 匹配整条命令行，有人正在执行 `grep Runner.Worker` 时就会误判。
- timer 的 unit 要写 `User=runner`。钩子文件归 runner 所有、runner 可写，不应以 root 执行它。

这个钩子按一台机器一个 runner 写。同一台机器装了多个实例时，守卫发现本机有别的 job 就整段跳过，不会误删别人的东西，但清理多数时候不跑。要在一台机器上跑多个实例，钩子得先改成只清本 job 的资源，前提和改法见 10 章 10.6。

> 注意：绝不裸跑 `docker system prune`，也绝不用不带 label 的 `-a`。这样会连基础镜像一起删掉，让「稳态 Docker Hub 消耗 ≈0」变回每次冷拉。

### 4.5 挡住 CI 读云 metadata

本节用两条 iptables 规则，阻止 CI 读取云 metadata 服务。

云 metadata 服务对 CI job 和容器都是可达的。里面常有 SSH 公钥、网络配置和 cloud-init 的配置数据，有的厂商还放了初始 root 口令；实例绑了云身份时，还会发这个身份的临时凭据（见本节末尾）。多数云的地址是 `169.254.169.254`，包括 AWS、GCP、Azure、Hetzner、DigitalOcean、华为云。也有例外：阿里云是 `100.100.100.200`，腾讯云是 `169.254.0.23`。用之前查一下你那家云的文档。裸金属一般没有 metadata 服务，规则加了也无害。bootstrap 用 `METADATA_IP` 参数指定地址，默认 `169.254.169.254`。传过一次就会落盘到 `/etc/ci-runner.env`，重跑时不用再传。旧版 bootstrap 不落盘这一项，这样的机器第一次用新版重跑时要显式传一次。

两条规则一条管容器，一条管宿主进程：

```bash
M=169.254.169.254        # 按你那家云改
iptables -I DOCKER-USER -d "$M" -j DROP
iptables -I OUTPUT -d "$M" -m owner --uid-owner "$(id -u runner)" \
         -j REJECT --reject-with icmp-port-unreachable
netfilter-persistent save
```

两条都要。`DOCKER-USER` 只管容器流量，而 CI job 的 shell 是宿主进程，`DOCKER-USER` 管不到它。

有的厂商给 metadata 加了自己的保护，比如要先取 token、限制跳数。这类保护挡不住宿主上的 CI 进程，两条规则照样要加。

root 仍然可以读 metadata（cloud-init 要用）。这两条只管 IPv4。你那家云如果还开了 IPv6 的 metadata 地址，要用 `ip6tables` 照样加一遍。

metadata 里有什么因厂商而异，按厂商文档以 root 在本机读一遍再判断。有两种情况要分清：

- 实例绑定了云账号的角色或服务账号：metadata 会发这个身份的临时凭据，CI job 拿到就能用它调云 API，这就是正在发生的泄露。runner 机器不要绑任何云身份。有的厂商默认会给新机器挂一个，建机时看清楚。
- 里面有口令：先和 `/etc/shadow` 里的 hash 比对再定级。口令在建机后改过的，泄露的是陈旧凭据。没比对就定级，容易把陈旧凭据当成正在发生的泄露，定得过重。

> 参考项目（Hetzner Cloud）的情况：metadata 的 `vendor_data` 里确实有 cloud-init 写入的 root 口令，在容器内能取出来。但与 `/etc/shadow` 的 hash 逐位比对后不匹配：口令在 cloud-init 之后已被改过，泄露的是陈旧凭据。实例也没有绑云身份。所以在参考项目里，这条规则属于纵深防御。

### 4.6 SSH：唯一可能把你锁在门外的动作

SSH 加固是本章唯一可能把你锁在门外的操作。`bootstrap.sh` 默认不做这一条，要加 `--harden-ssh` 才执行。

下面的命令按 Ubuntu、Debian 写，SSH 服务名是 `ssh`。别的发行版多叫 `sshd`，命令里相应地换掉。

#### 动手前：查登录方式

动手前必须先查一件事：这台机上的人现在是怎么登录的。

```bash
journalctl -u ssh --since "-30d" --no-pager | grep -oE "Accepted (publickey|password)" | sort | uniq -c
stat -c '%n %y' /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null   # 公钥是什么时候装的
```

把两者按时间线对一下：

- 口令登录全部发生在公钥装上之前：说明那些人已经切到公钥，可以关。
- 公钥装上之后仍有口令登录：说明有人还在用口令，不能关，先让他们配公钥。

> 参考项目：8 次口令登录全在 `09-06 14:18–14:54`，而 `authorized_keys` 写于 `14:54:52`（他登进来就是为了装公钥）。此后 11 次登录全是 publickey，零口令。结论：可以关。

还要确认 SSH 断了以后有别的路进机器，也就是厂商的带外入口：云上多是控制台网页终端或串口控制台，裸金属是 IPMI 或救援系统。有的带外入口（VNC 式的网页控制台、串口控制台、IPMI）登录的是本地终端，要用口令，只配了公钥、没设口令的账号进不去。需要时先用 `passwd` 给 root 设一个本地口令，SSH 关掉口令认证后，它只在本地终端有用。走 SSH 的网页终端在 sshd 配错时也进不去，不算带外入口。动手前先确认这条路走得通。

#### 写配置

```text
# /etc/ssh/sshd_config.d/00-hardening.conf
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
```

注意：文件名要以 `00-` 开头。`sshd_config.d` 里同一项以首次出现的为准，这个文件要排在其他文件之前，比如 cloud-init 写的 `50-cloud-init.conf`。这个文件有没有、里面写什么看厂商，参考项目的机器上是 `PasswordAuthentication yes`，以 `sshd -T` 的输出为准。前提是主配置 `/etc/ssh/sshd_config` 的 `Include` 行在最前面，Ubuntu 和 Debian 的默认配置是这样。

#### 生效与验证

按顺序执行，最后一步通过才算完成：

1. `sshd -t`
2. `systemctl reload ssh`（reload 不踢现有连接）
3. `sshd -T | grep -E '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication)'` 确认
4. **另开一个终端验证能登入**

第 4 步的验证命令：

```bash
ssh -o PasswordAuthentication=no -p <SSH 端口> <登录用户>@<IP>   # 强制不用口令，能进说明公钥这条路通
```

登录用户是 root，或者厂商建的默认用户（03 章 3.0）。`--harden-ssh` 只检查 root 的 `authorized_keys`。用默认用户登录的，先确认那个用户的 `~/.ssh/authorized_keys` 里有你的公钥；root 没有公钥时脚本会拒绝执行，按上面「写配置」手工做。

进不去的话，在当前还活着的会话里回滚：

```bash
rm -f /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh
```

#### 可选的安全网

如果担心改完之后、验证之前会话就断了，可以挂一个安全网：`scripts/ssh-guard.sh` 每 3 分钟查一次，只在一条 SSH 会话都不剩时才回滚。

- 你正常连着时，它不会动配置；
- 你被踢下线又进不来时，它会自动回滚。

它数的是 sshd 实际监听端口上的已建立连接。端口从 `sshd -T` 和 sshd 正在监听的端口读，SSH 不在 22 端口也能用。在控制台网页终端、串口控制台或 IPMI 这类带外入口里操作时，它数不到 SSH 会话，3 分钟内就会回滚，所以加固要在 SSH 会话里做。

安全网要在加固之前装好。`bootstrap.sh --harden-ssh` 写完配置马上 reload，中间不停顿。

```bash
install -m 0755 scripts/ssh-guard.sh /usr/local/bin/ssh-guard.sh
touch /root/.ssh-hardening-unconfirmed          # 「还没确认」的标记
systemd-run --unit=ssh-guard --on-active=3min --on-unit-active=3min /usr/local/bin/ssh-guard.sh
# 然后再加固：bootstrap.sh --harden-ssh，或者按上面手工写 00-hardening.conf
# 另开终端确认能登入之后：
rm /root/.ssh-hardening-unconfirmed
systemctl stop ssh-guard.timer
```

`systemd-run` 建的是临时 timer，机器重启后就没了，不用另外清理。回滚之后脚本会自己停掉 `ssh-guard.timer`。自己写 timer unit 的话，`OnUnitActiveSec=` 要和 `OnActiveSec=` 一起写。只写前者时，对应的服务一次都没跑过，timer 没有起算点，可能一次都不触发。

### 4.7 入方向防火墙：挡得住 Docker 端口的那一层

入方向的防火墙要配在机器外面。各厂商叫法不同，有的叫云防火墙，有的叫安全组、网络安全组或 VPC 防火墙规则，下文统称云防火墙。它在控制台或厂商的 API、CLI 里配，bootstrap 管不到。有的厂商新机器默认不挂任何防火墙，所有端口对公网开着，建好机器先看一眼实际生效的规则。

不能只靠宿主 ufw 的原因：Docker 会自己往 iptables 写 DNAT 规则，从结构上绕过 ufw。对容器端口来说，「在防火墙封了 3000」多半不生效。云防火墙在机器外面，Docker 改不了它。

它挡的是容器端口绑回环也盖不住的部分，也就是 CI 里在宿主上监听的进程，比如 e2e 直接 `spawn` 起来的应用服务器。这类进程不是容器，没有 `-p` 可以绑。

配置：入方向只放行 SSH 端口（默认 22，建议限来源 IP），出方向全放。IPv4 和 IPv6 都要覆盖，有的厂商两者分开配。

对 CI 的影响为零。runner 是出站长轮询去 GitHub 领活，不需要任何入站端口。但要注意：以后想在这台机上跑任何对外服务，得回去加规则。

#### 没有云防火墙时

裸金属，或者厂商不提供云防火墙时，分两部分处理：

- 宿主进程监听的端口，用 ufw 或 nftables 挡。宿主进程不走 Docker 的链，主机防火墙对它有效。先放行 SSH 端口再启用防火墙，否则可能断线，之后也登不进来。
- 容器端口，靠 05 章 ② 的 `127.0.0.1` 绑定。再在 `DOCKER-USER` 链里丢掉从公网网卡进来、目标是容器的新连接，作为第二道防线：

```bash
iptables -I DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP   # eth0 换成你的公网网卡
netfilter-persistent save
```

公网网卡名各厂商不同（eth0、ens3、enp1s0 等），用 `ip route show default` 看 `dev` 后面的名字。有的云在机器外面做公网地址转换，机器里只看到内网地址，公网流量也从这块网卡进来，规则照样有效。这条规则只管 IPv4，在 daemon.json 里给 Docker 开了 IPv6 的，用 `ip6tables` 照样加一条。

这条规则和 4.5 的规则一起持久化。参考项目没有在没有云防火墙的机器上实测过，加完之后从别的机器测一下端口，不要在本机探自己的公网 IP（09 章 A10）。

### 4.8 机器上还要开发时

最好不要在 CI 机上开发。能不能兼开发要按下面第 1 步算，取决于你的 job 和开发工具各占多少内存，没有一个通用的内存档。参考项目在一台 4 核、约 7.6 GiB、没有 swap 的 CI 机上开着 VS Code Remote、Claude Code、Codex 开发了两天，出了 11 次全局 OOM，被杀的大多是 CI 的进程（09 章 B17）。原因有两层。一是内存账里没算开发工具，一个 VS Code 远程服务端就占约 4 GB。二是优先级排反了：runner 是 800，开发会话是 0，内核每次先挑的都是 CI。开发搬到别的机器之后，没有再出现。

一定要在 CI 机上开发时，下面几步都要做。

1. 先算内存。把开发工具的占用 D 算进 10 章 10.2 的公式，算出来每台至少还能跑 1 个实例才行。参考项目一个人开发时 D 按 4–5 GiB 算，8 GB 的机器不够。

2. 开发用单独的非 root 用户，不加进 docker 组。docker 组约等于 root。开发如果要用 Docker，它的容器和匿名卷会被清理钩子当成 CI 的残留删掉（不带过滤的 `docker volume prune`），这种情况就不该和 CI 共用一台机器。

3. 让开发会话比 CI 先被杀。给 `ssh.service` 和 `user@.service` 各加一个 drop-in：

   ```ini
   # /etc/systemd/system/ssh.service.d/50-dev-tools-oom.conf
   # /etc/systemd/system/user@.service.d/50-dev-tools-oom.conf 内容相同
   [Service]
   OOMScoreAdjust=1000
   ```

   写完执行 `systemctl daemon-reload && systemctl restart ssh`。重启 ssh 不会断开已有的连接，但已有的会话还是旧值，要重新登录。

   sshd 的监听进程启动时会把自己调到 −1000，不会被杀。它为每个登录派生出的会话会恢复成 unit 上的 1000，会话里起的 VS Code 服务端、Claude Code、Codex 都继承这个值。`user@.service` 管的是 systemd 用户实例里起的进程，第 5 步的 `systemd-run --user` 就在这里。

   这个设置对所有 SSH 登录都生效，包括 root 的运维会话。内存紧张时，你登进来排查用的 shell 也会先被杀，这时用厂商的带外入口（控制台网页终端、串口控制台，裸金属用 IPMI）。用 `systemctl` 启动的服务不受影响，它们由 systemd 直接拉起，不继承会话的值。

   确认：

   ```bash
   cat /proc/self/oom_score_adj                   # 在新登录的会话里执行，应为 1000
   cat /proc/$(pgrep -o -x sshd)/oom_score_adj    # sshd 监听进程，应为 -1000
   ```

4. 调低 runner 的 OOM 优先级。按 4.3「OOM 优先级怎么定」的公式算，各内存档的取值见 10 章 10.3，约 7.6 GiB 的机器取 200。改法是带上新的 `RUNNER_OOM_ADJ` 重跑 bootstrap，重跑之前先停 runner 服务（4.1 末尾）。新值会写进 `/etc/ci-runner.env`，以后重跑不用再传。

5. 吃内存的命令行工具可以单独限住。先对开发用户执行 `loginctl enable-linger <开发用户>`，再确认 systemd 用户实例拿到了内存控制器：

   ```bash
   # 以开发用户执行，输出里要有 memory
   cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
   ```

   Ubuntu 24.04 默认就有。有了以后这样起：

   ```bash
   systemd-run --user --scope --quiet --collect -p MemoryMax=1G -p MemorySwapMax=0 -p CPUQuota=200% -- codex
   ```

   上限不要超过全量 CI 期间整机可用内存的最低值减 0.3 GiB。参考项目 7.6 GiB 的机器上最低可用约 1.3 GiB，所以取 1G；按它的 job 推算，16 GiB 的机器上可以给到 2G。你的机器用自己量到的最低值来算。`CPUQuota=200%` 对应 10 章 10.2 里开发工具用核按 2 算。这条命令要在开发用户自己登录的 SSH 会话里执行。用 `su` 切过去的会话通常没有用户实例的环境变量，`systemd-run --user` 会报连不上 bus。

6. 开发工具的磁盘占用也要算进去。VS Code 远程服务端每次客户端升级会多留一份，要定期删，见 08 章 8.6 的每月巡检。

---

## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

本章列出 workflow 里依赖托管 runner 特性的写法，以及在自建常驻 runner 上该怎么改。本章和机器无关，对任何仓库都适用。

托管 runner 给每个 job 分配一台全新的一次性 VM：

- `/tmp` 是空的；
- 容器名没被用过；
- 端口没被占用；
- 磁盘是干净的；
- job 跑完，VM 就销毁。

几乎每个仓库的 workflow 里都积累了一批依赖这些性质的写法。它们在托管 runner 上不会出问题，所以也一直没有暴露出来。

本章用到的几个说法：

- N：全仓库自建 runner 实例的总数，所有机器加起来算，也就是同时最多能跑几个 job。N=1 时所有 job 串行排队。有两台机器、每台一个实例时 N=2，job 能并行了，但同一个 run 的两个 job 仍可能先后落在同一台机器上。
- k：一台机器上跑几个实例。现有脚本和占固定宿主端口的 workflow 都只支持每台 1 个，原因见 10 章 10.6。
- 假绿：检查本该失败，结果却显示通过。

参考项目最初只有一台机器、一个实例（N=1），本章的实测大多是在这个条件下做的。

下面 ①–⑬ 共十三条，每条按「怎么自查、失败是什么样、怎么改」组织。⑫ 是上线一个月后补的，⑬ 是准备加第二台机器时补的。建议把它们当作 checklist，对照你的 workflow 逐条检查。章末有一组汇总命令，改完后用来确认。

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

同一个 run 里的两个 job 用同一个写死的名字时更严重：

- 托管 runner 上，两个 job 在两台独立 VM 上，互不影响。
- N=1 的自建机上，两个 job 在同一台机器上串行。第一个 job 不清理，第二个 job 一定冲突。
- N≥2 时，两个 job 有时分到不同机器，有时落在同一台，冲突时有时无，更难查。

怎么改：

```yaml
env:
  # 名字要唯一到 run、attempt、job 三级：
  #   run_attempt 不能省，re-run 时 run_id 不变
  #   github.job 不能省，同一个 run 里的两个 job 只唯一到 run 级仍会撞名
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

- `--label` 的值必须和 bootstrap.sh 里的 `CI_LABEL` 完全一致。清理钩子第 1 步按这个 label 删除上一个 job 没删掉的容器。bootstrap 的默认值是 `com.ci.selfhosted=1`，上面的 `com.myorg.ci=1` 是示例，两边写成同一个就行。
- 删除容器用 `rm -fv`，不用 `rm -f`。镜像声明了 `VOLUME` 时（minio、postgres、redis、prometheus 都声明了），Docker 会建匿名卷，带 `-v` 才会连卷一起删。参考项目原来用 `rm -f`，每个起 minio 的 job 漏 1 个卷，见 ⑫。
- `docker run --rm` 解决不了漏卷。实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下。`--rm` 只在容器自己退出或被 `docker stop` 时生效。
- `rm -fv` 只在清理步骤真的跑了时有用。runner 进程被杀时 `if: always()` 也不执行，容器留给钩子删。更稳的是在镜像的 VOLUME 路径挂 tmpfs，一开始就不建卷，写法和注意事项见 ⑫。
- 清理钩子并非只按 label 过滤。它的第 6 步是一条不带过滤的 `docker volume prune`，用来兜底回收匿名卷。workflow 里写对了，就不必依赖它。service 容器的卷见 ⑫。

---

### ② 服务端口默认绑 `0.0.0.0`

`ports:` 只写 `宿主端口:容器端口` 时，端口绑在 `0.0.0.0` 上，服务会直接暴露到公网。

自查：

```bash
grep -rn "ports:" .github/workflows/ | grep -v "127.0.0.1"
```

失败是什么样：CI 不会失败，所以也不会提醒你。它只是把你的数据库开放到了公网上。

> 实测：`ports: ['5433:5432']` 加明文 `POSTGRES_PASSWORD`，check-host.net 的四个外部节点全部成功建立 TCP 连接，并收到 Postgres 的认证响应。当时宿主的 `ufw` 是 inactive，但这不影响结论：Docker 的 DNAT 本来就绕过 ufw。

怎么改：

```yaml
services:
  postgres:
    ports: ['127.0.0.1:5433:5432']    # runner 把三段式原样透传给 docker create（已实测）
```

确认：localhost 可以连上，从公网连接返回 `Connection refused`。

上面的 `5433` 是固定的宿主端口。每台机器只跑一个 runner 实例时没有问题，机器再多也一样，每台各有一套端口。一台机器跑多个实例时，两个 job 会抢同一个宿主端口，后起的 service 起不来。到那一步有两种改法：

- 让 Docker 随机分配宿主端口：写成 `ports: ['127.0.0.1::5432']`，job 里用 `${{ job.services.postgres.ports['5432'] }}` 读出实际端口。runner 能不能正确处理这种写法，参考项目没有实测，先在测试分支上验证。
- job 跑在 `container:` 里，用服务名直连（`postgres:5432`），不发布宿主端口。

测试在宿主上起的进程（⑨ 里的 API）也一样，每个实例要用不同的端口。不占固定宿主端口是一台机器跑多个实例的前提之一，其余几条见 10 章 10.6。

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

上面的 grep 只能查到 workflow 里写死的路径。还有一类更隐蔽：工具代码自己建临时目录，用的是语言默认的 `os.tmpdir()`、`mkdtemp`、`mktemp`、`tempfile`，落点都是 `/tmp`。这类目录平时由程序结束时自己删，job 被取消时删不掉（见 ⑥），在常驻机器上会一直留着。Ubuntu 24.04 默认的 tmpfiles 规则只删 `/tmp` 里 30 天没动过的东西。参考项目有个测试工具，每次在 `/tmp` 下打一份约 1 GB 的源码包，一周被取消 9 次，就攒下 9 份。

自查（目录换成你的工具和脚本所在的位置）：

```bash
grep -rnE 'tmpdir\(\)|mkdtemp|mktemp|tempfile|TemporaryDirectory' tools/ scripts/
```

怎么改：临时目录的上一级换成 `$RUNNER_TEMP`，没有这个变量时（本地运行）再用系统默认，比如 Node 里写成 `mkdtempSync(join(process.env.RUNNER_TEMP || tmpdir(), 'x-'))`。runner 在每个 job 结束时清空这个目录，被取消的 job 也一样（Worker 日志里是 `Cleaning runner temp folder`），下一个 job 开始前还会再清一次。

不要图省事在步骤上设 `TMPDIR=$RUNNER_TEMP`。那样工具链放在 `/tmp` 里的编译缓存也会每个 job 被清一次，构建会变慢。

工具一时改不了的，用清理钩子兜底：bootstrap 传 `CI_TMP_GLOBS="<目录名模式>"`，钩子每次在 job 前后删掉 `/tmp` 下一层、属于 runner 用户、名字匹配的条目（04 章 4.4）。

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
- 命令后面有 `|| fallback`：静默降级。表现为路径门控退化成全跑、定时任务每次都跑、某个检出被跳过。门禁看起来还在跑，实际已经失效。

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
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # 错误写法，不成立
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

#### 程序里的清理也一样不执行

写在程序里的清理更容易漏：try/finally、`trap ... EXIT`、程序自己装的 SIGTERM 处理，在 job 被取消时同样不执行。原因在 runner 取消步骤的方式，下面是 Worker 日志原文（runner 2.338.0）：

```
Sending SIGINT to process 624280.
Process did not honor SIGINT signal within 7.5 seconds.
Sending SIGTERM to process 624280.
Process did not honor SIGTERM signal within 2.5 seconds.
Kill entire process tree since both cancel and terminate signal has been ignored by the target process.
```

624280 是 runner 为这一步起的 bash（`bash -e <步骤脚本>`）。信号只发给这个 bash，bash 不会把信号转给它正在等的子进程，真正干活的程序收不到。10 秒后整棵进程树被 SIGKILL，程序里的清理代码没有机会运行。就算信号送到了，10 秒也常常不够：要先停容器，再删几 GB 的文件。

所以 job 里产生的东西，要交给不依赖程序自己退出的机制去清：

- 临时文件放进 `$RUNNER_TEMP`（③），job 被取消后 runner 也会清。
- 容器和 `docker build` 出来的镜像打 CI 标签（⑫ 末尾），由清理钩子在下一个 job 开始前删。
- 每次运行用唯一 tag 建的镜像，另打一个专用标签，并配上 `CI_PER_RUN_IMAGE_LABEL`（同在 ⑫ 末尾）。

参考项目踩过这个坑：一个测试工具在 finally 里删它建的镜像和 `/tmp` 目录，一周被取消 9 次，留下 9 份，每份约 3 GB 镜像加 1 GB 目录，根分区一度只剩 5.5 GB（09 章 A22）。

---

### ⑦ `timeout-minutes` 的含义变了

在自建 runner 上，`timeout-minutes` 决定了一个卡死的 job 最多能占住一个实例多久。N=1 时，这就是全组 CI 最多停多久，所以要对照实测时长重新检查。

| 环境 | `timeout-minutes` 的含义 | job 跑飞的后果 |
|---|---|---|
| 托管 runner | 这个 job 最多烧多少钱 | 只烧掉自己那台一次性 VM |
| 自建 runner，共 N 个实例 | 一个实例最多被占住多久，N=1 时就是全组 CI 停摆的上界 | 少一个可用实例，排队变长；N=1 时后面所有 PR 一起等 |

自查：

```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> 参考项目：现值是实测时长的 8–150 倍（lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。一次 ci run 最坏占用 15+15+30+30 = 90 分钟。按「实测 p95 × 4」重设后是 29 分钟。

实测时长要记下是在哪台机器上量的。换到单核更慢的机器，同样的 `timeout-minutes` 余量会缩水，单核受限的 job（限了 1 个 CPU 的测试容器、单线程的类型检查）最先超时。加机器或换机器之前，按 02 章 2.7 核对：最长实测耗时 × R ≤ timeout-minutes × 2/3，R 是新机器和参考机的耗时比。

注意：`timeout-minutes` 从 job 开始执行才计时，排队时间不算。机器宕机导致排队 24 小时这种情况它管不了，要靠哨兵（06 章 6.4）。

---

### ⑧ job 级并行的假设

要不要为 N=1 合并 job，先量再决定：合并 job 在自建机上的收益比在托管上小得多。

- 托管 runner 上，多个 job 并行是免费的（各自一台 VM）。
- N=1 上，它们串行排队，每多一个 job 就多付一次脚手架。
- N≥2 时，同一个 run 的 job 又能分到几个实例上并行，合并的收益比 N=1 时更小。

不要急着合并 job。先量两个数，即托管和自建机上各自的每 job 脚手架时间：

```text
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```

> 参考项目：托管上脚手架约 52 秒/job（合并 4→1 省 156 秒）；自建机上只有约 16 秒/job（合并只省 48 秒），因为常驻机器上依赖早就在盘上了。收益缩水 3 倍，而代价（文档同步、required check 粒度、回退时降级）一点没少。

判断方法：用真实事件时间戳做排队仿真（08 章 8.1），比较「合并 job」和其他提速手段的实际收益。现有的仿真脚本只模拟一个 runner，也就是 N=1 的情况。

参考项目的结论：合并 job 与「修 Dockerfile 层序 + 去 cache」效果相当（最忙那天 11.7 vs 11.2 分钟），而后者不用改任何文档，所以先做后者。

---

### ⑨ 孤儿进程导致的假绿

测试依赖的后台进程如果是上一次 run 遗留的孤儿进程，测试会跑在旧代码上，CI 却可能显示通过。

自查：workflow 或测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？如果就绪判据只是 `curl <url>`，不校验应答的是不是自己刚起的那个进程，就是命中。

失败是什么样：

```text
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在孤儿进程上
```

> 实测：用一个孤儿进程占住端口后跑 e2e，221 条里 220 条通过，唯一失败的那条还指向认证代码，而不是真实原因。换一个对状态不敏感的孤儿进程，结果就是全绿。

也就是说，整套 e2e 跑在上一次 run 的代码上，CI 却是绿的。

孤儿进程的来源：

- `teardown` 只有一行 `proc.kill()`，而 job 被取消时它不执行。
- runner 自己的兜底没有接住。job 结束时，runner 会杀掉环境变量里带本 job `RUNNER_TRACKING_ID` 的进程，日志里显示为 `Cleaning up orphan processes`。有几种情况它认不出来：测试代码 spawn 子进程时传了一份新的 env，没继承这个变量；workflow 把这个变量设成了空串；runner 进程本身被杀了。参考项目当时的孤儿属于哪一种，没有核对过。
- runner 服务的 `KillMode=process` 只决定停服务时杀不杀子进程，和 job 结束没有关系。

怎么改：分三层，至少做前两层。

第一层（代码注释中的 ①）：起进程之前，先确认端口没被占用。

```ts
// ① 起之前先确认端口没被占。用裸 TCP 连接，不依赖对方回什么
async function assertPortFree(port: number) {
  const busy = await new Promise<boolean>((res) => {
    const s = connect({ port, host: '127.0.0.1' });
    const done = (v: boolean) => { s.destroy(); res(v); };
    s.setTimeout(2000);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error',   () => done(false));
  });
  if (busy) throw new Error(`端口 ${port} 已被占用，多半是上一次 run 的孤儿进程，先清掉再跑。`);
}
```

第二层（代码注释中的 ②）：在 runner 的 `JOB_STARTED` 钩子里清掉孤儿进程。

```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
# 3100、3101 是参考项目 e2e 的端口，换成你的 CI_APP_PORTS（03 章 3.1）
fuser -k 3100/tcp 3101/tcp 2>/dev/null || true
```

第三层：用入方向防火墙挡住这些宿主端口（04 章 4.7）。它们不是容器，`-p 127.0.0.1` 管不到。

---

### ⑩ 宿主进程绑 `0.0.0.0`

② 只管容器。测试直接 spawn 起来的应用进程是宿主进程，没有 `-p` 可以绑，需要另外处理。

自查：`grep -rn "0\.0\.0\.0\|listen(" <你的应用入口>`

怎么改：

- 优先靠入方向防火墙（04 章 4.7）。宿主进程不走 Docker 的链，所以云防火墙（安全组）和主机防火墙（ufw、nftables）对它都有效。
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
grep -rn 'docker rm -f ' .github/workflows/ <CI 用的脚本目录> | grep -v -- '-fv'   # 应为空
```

机制：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；删容器时不带 `-v`，卷就留下。卷有两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | runner 自己，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，挂 tmpfs，删除时用 `rm -fv`（见 ①） |

参考项目里，每个用到数据库的 job 原来漏 3 个卷（postgres、redis、minio，约 70 MB，大头是 PGDATA），跑监控冒烟的 job 还会给 prometheus 漏 1 个。那台机器上卷数始终是 0，是因为清理钩子的 `docker volume prune` 在每个 job 前后都在回收，workflow 本身并没有写对。换一台没装钩子的常驻 runner，卷数就会一直涨。

参考项目 2026-10-16 按下面的写法改完：postgres、redis、minio、prometheus 都挂 tmpfs，起这些容器的 job 都在起完后核对没挂卷。合并前在 runner 上记了约 15 分钟 `docker events`，期间跑了几个起这些容器的 job，容器照常建了又删，没有新建卷。

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
- tmpfs 占内存（参考项目约 50–120 MB/job）。它记在容器的 cgroup 上，不在 runner 的 MemoryMax 里；但在没有 swap 的机器上它占的是真内存，所以 `size=` 必须写，量单 job 整机峰值 J 时也要把它算进去（10 章 10.1）。
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

每次运行都用唯一 tag 建的镜像（tag 里带 run ID 或随机串，用完就删的那种），还要再打一个专用标签，比如 `--label com.myproj.run=<本次的名字>`，并在 bootstrap 里传 `CI_PER_RUN_IMAGE_LABEL=com.myproj.run`（只写键）。钩子对 CI 标签的镜像只删 6 小时前建的，而这类镜像以后不会再用，没必要等。job 正常结束时程序自己会删；被取消时删不了（⑥），只能靠钩子。不配这个参数，每取消一次就要多占 6 个小时以上的空间，参考项目一个这样的镜像独占约 3 GB。

钩子只删同时带 CI 标签和这个专用标签的镜像。机器上还有别人用 docker、又会在本地跑同一个工具时，让工具只在 CI 里（`GITHUB_ACTIONS=true`）打 CI 标签，本地建的镜像就不会被钩子删掉。

参考项目还在 job 末尾的 `if: always()` 清理里加了一条 `docker image prune -f --filter "label=$CI_LABEL"`（不带 `-a`，只删悬空的，带 tag 的当前版本留着），防的是固定 tag 重建后旧版本变成悬空镜像。这是经典镜像存储的行为；Docker 29 + containerd 快照器上带 `-t` 重建，旧版本直接被删、不留悬空镜像（02 章 2.6 实测，10-16 复测相同），所以在这类机器上这一条只是保险。

---

### ⑬ 容器写进工作区的文件，runner 删不掉（准备加第二台机器时补）

常驻机器上工作区跨 job 复用，下一个 job 的 checkout 要先删掉上一次留下的文件。CI 容器往挂进去的工作区写文件时，文件属主是容器里进程的 uid。这个 uid 和 runner 用户对不上，runner 就删不掉这些文件。托管 runner 每个 job 都是新 VM，碰不到这个问题。

自查：

```bash
# 在每台 runner 上跑。runner 和 /opt/actions-runner 按你的 RUNNER_USER、RUNNER_HOME 换
id -u runner                                              # 各台机器应该相同
find /opt/actions-runner/_work -not -user runner | head   # 应为空
```

失败是什么样：`actions/checkout` 清理工作区时报 `EACCES: permission denied`，job 在第一步就失败，和代码改动无关（09 章 A19）。

文件归谁，看容器以哪个用户运行：

- node 官方镜像默认以 root 运行，只是自带一个 uid 1000 的 `node` 用户，要用 `--user node` 才会切过去。很多镜像里的普通用户也是 uid 1000。
- 以 root 运行的容器写下的文件属于 uid 0，runner 是哪个 uid 都删不掉。
- job 用 `container:` 跑时，步骤在容器里以镜像的默认用户执行，常常是 root，写进工作区的文件也归 root。

怎么改：

- 所有 runner 机器上 runner 用户的 uid 保持一致，参考项目用 1000。bootstrap 按 `RUNNER_UID` 建用户；装机顺序，以及云镜像自带 uid 1000 用户时怎么处理，见 03 章 3.3。
- 自己 `docker run` 又挂了工作区的容器，用 runner 的身份运行：`docker run --user "$(id -u):$(id -g)" -v "$GITHUB_WORKSPACE:/w" ...`。这样文件直接归 runner，不依赖镜像里有没有 uid 1000 的用户。
- 必须以 root 运行的容器，在 `if: always()` 的清理步骤里把属主改回来：`docker run --rm -v "$GITHUB_WORKSPACE:/w" <同一个镜像> chown -R "$(id -u):$(id -g)" /w`。runner 进程被杀时这一步也不会执行，下一个 job 会在 checkout 失败，这时要登上机器用 root 删掉那些文件。

---

### 改造完的自查

改完后跑下面这组命令确认，每行末尾的注释是期望结果。

```bash
grep -rn -- '--name '        .github/workflows/ | grep -v 'run_id'      # 应为空
grep -rn 'ports:'            .github/workflows/ | grep -v '127.0.0.1'  # 应为空
grep -rn '/tmp/'             .github/workflows/                        # 应为空或已确认无害
grep -rnE 'tmpdir\(\)|mkdtemp|mktemp' tools/ scripts/                 # CI 里跑的临时目录应改用 $RUNNER_TEMP（③）
grep -rc 'if: always()'      .github/workflows/*.yml                   # 清理步骤应该有
grep -rn 'docker rm -f '     .github/workflows/ | grep -v -- '-fv'      # 应为空（⑫）
grep -rn -- '--tmpfs'        .github/workflows/                        # 每个声明了 VOLUME 的镜像都应有一条（⑫）
grep -rn '容器没有挂卷'       .github/workflows/                        # 起了这些容器的 job 都应有这一步（⑫）
grep -rnE '127\.0\.0\.1:[0-9]+:' .github/workflows/                    # 一台机器跑多个实例时应为空（②）
find /opt/actions-runner/_work -not -user runner | head                # 在每台 runner 上跑，应为空（⑬）
find /tmp -maxdepth 1 -user runner -mtime +1 | head                    # 在每台 runner 上跑，应为空或只有工具缓存（③⑥）
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
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","myproj-ci"]'
# 关
gh variable delete CI_RUNNER --repo owner/repo
```

变量里的标签要和 runner 注册时的 `RUNNER_LABELS` 对上（03 章 3.1）。变量里的每个标签 runner 都得有，job 才会派给它。上面的 `myproj-ci` 要换成你的项目标签。bootstrap 注册完会按本机的 `RUNNER_LABELS` 打印这条命令，可以直接用。有多台机器时，各台的标签要完全一致。缺了一个标签的那台领不到这些 job，也不会报错，只是一直闲着。

### 6.2 变量值必须是合法 JSON

`CI_RUNNER` 的值会被 `fromJSON` 解析，写成裸字符串会出错。错误示例：

```bash
gh variable set CI_RUNNER --body 'ubuntu-latest'      # 错误：裸字符串
```

这种错误很难排查。现象和「回退没生效」不同，具体是：

- 整个 workflow 解析失败，产生 0 个 job。
- run 直接变红。
- 页面上没有任何 job 可以点开查看。

正确写法：

- 多个标签写成数组：`'["self-hosted","linux","x64","myproj-ci"]'`
- 单个值要带引号：`'"ubuntu-latest"'`

### 6.3 开关救不了已经排队的 job

删掉变量只影响新 run。已经处于 `queued` 状态的 job 不会改去托管，会继续排队到 runner 恢复，所以切回时要手动取消再重跑。

实测过程：

1. 停掉 runner，让 job 进入 `queued`。
2. 删掉变量。
3. 在 t+20/40/60/80/100/120 秒检查，那个 job 一直是 `queued`，没有任何变化。
4. runner 恢复后，这个 job 才被执行。

GitHub 对排队 job 的自动取消时间是 24 小时。如果机器半夜宕机（有多台时是全部宕机），全组的 PR 会一直卡到有人醒来处理。

`timeout-minutes` 帮不上忙，它从 job 开始执行时才计时，排队时间不算。

切回托管时按下面的步骤操作：

```bash
gh variable delete CI_RUNNER --repo owner/repo                       # 1. 新 run 立刻走托管
gh run list --repo owner/repo --status queued -L 200 --json databaseId -q '.[].databaseId' \
  | xargs -r -I{} gh run cancel {} --repo owner/repo                 # 2. 取消卡住的排队 run
# 3. 在各 PR 上 Re-run，或推一个空 commit
```

第 2 步的 `gh run list` 要带 `--repo`。不带时它查的是当前目录所在的仓库，在别的目录里执行就会查错或者报错。`-L 200` 是因为它默认只列 20 条，排队多时取消不全。

只查 `queued` 会漏掉一种 run：里面已经有 job 开跑或跑完，剩下的 job 还在等 runner。按 GitHub 的状态定义，这种 run 的状态是 `in_progress`，不是 `queued`。比如所有机器在一个 run 跑到一半时挂掉，剩下的 job 就是这样。这类 run 要在页面上手动取消，或者用 `gh run list --repo owner/repo --status in_progress` 列出来逐个看。参考项目没有实际碰到过这种情况。

### 6.4 哨兵：机器挂了要有人知道

自建 runner 下线时必须有告警。这里的「哨兵」指定期检查 runner 是否正常、发现异常就发出提醒的机制。

原因：只有一台自建机器时，它就是单点，6.3 说明了它挂掉的代价最长是 24 小时。有两台以上机器时，一台下线不会让 CI 停，但容量少了，排队会变长，也要有人知道。所以下面两层的分工是：① 机器侧心跳每台各报各的，发现的是哪一台挂了；② 排队哨兵发现的是所有机器都挂了，或者剩下的机器忙不过来。

注意：在托管上跑高频定时哨兵，费用承受不了。

一个流传很广的方案是「配一个跑在托管上的哨兵，每 13 分钟查一次排队队列」。它的费用问题如下：

- 托管按每个 job 向上取整计费，这样每月要 3323 计费分钟。
- 这已经超过 GitHub Free 私有仓库每月的免费额度（2000 分钟）。
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
# 只有 runner 服务在跑时才上报。机器活着、runner 停了，心跳也会断
ExecStart=/bin/bash -c 'systemctl is-active --quiet <runner-unit> && curl -fsS -m 10 --retry 3 https://hc-ping.com/<UUID> >/dev/null'
```

再给它配一个 5 分钟的 timer。这一层能发现以下情况：

- 机器宕机
- 网络断开
- runner 进程退出

装好后先手工执行一次 `ExecStart` 里的命令，确认心跳服务收到了。有的地区的机房访问某些心跳服务不稳定，连不上就换一家或者配代理（02 章 2.9）。

有多台机器时，每台在心跳服务上单独建一个检查，用各自的 UUID，检查名带上主机名或 `RUNNER_NAME`，告警时能看出是哪一台。几台共用一个检查的话，只要还有一台在报，别的机器挂了也发现不了。撤掉一台机器时，要同时删掉它的检查，不然它会一直告警，步骤见 08 章 8.7。

心跳只看 runner 服务是不是 active。服务 active 只说明进程还在，这台机器能不能领到 job、跑得对不对，心跳看不出来。这些要看 verify.sh 的 GitHub 侧检查（07 章）、ci-health 的产出告警（服务 active 但本机的 job 连续失败），以及每台机器最近有没有领到过 job（08 章 8.7）。

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
    [ "$stuck" -gt 0 ] && echo "::warning::有 $stuck 个 run 排队超过 15 分钟，自建 runner 可能全部下线或全部占满"
    exit 0    # 哨兵只提醒，不让宿主 workflow 变红
```

这个 step 用 `github.token` 调 API，需要 `actions: read` 权限，最稳的是在这个 job 的 `permissions:` 里显式写上。两种情况下拿不到这项权限：workflow 顶层写了 `permissions:` 但没列它；仓库或组织把 GITHUB_TOKEN 的默认权限设成了受限。在 job 上写 `permissions:` 时，没列出的权限都会变成 none，这个 job 原来用到的权限要一起列上。私有仓库里缺这项权限时，`gh api` 返回 403，被 `2>/dev/null` 吞掉，哨兵永远不响。

有多台机器时，这个哨兵响了，说明所有机器都挂了，或者都忙了 15 分钟以上。只挂一台时它不会响，要靠 ① 的心跳。

局限：

- 只有在有人开 PR 时才会运行，没有 PR 的时段覆盖不到。这段时间靠 ① 主层。
- 和 6.3 的取消命令一样，它只查 `queued` 的 run，看不到状态是 `in_progress`、里面还有 job 在排队的 run。要查全，就把 `in_progress` 的 run 也列出来，逐个查它的 jobs 里有没有排队太久的。这个写法参考项目没有实测过。

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
# 1. 确认各台 runner 都在线、空闲，标签一致
gh api repos/OWNER/REPO/actions/runners --jq '.runners[]|{name,status,busy,labels:[.labels[].name]}'

# 2. 合入改好的 workflow（此时变量未设，行为与合并前逐字相同，先确认这一步不改变任何东西）

# 3. 打开开关
gh variable set CI_RUNNER --repo OWNER/REPO --body '["self-hosted","linux","x64","myproj-ci"]'

# 4. 开一个空改动的测试 PR，确认各 check 都出现、都落到你的 runner、都绿
#    再开第二个 PR，容器名冲突的修复要在第二个 PR 上才能验证
```

---

## 07 验证

本章说明装完之后怎么确认 runner 真的可用：先跑机器侧自检脚本，再用真实 PR 验证，然后做破坏性验证和重启演练。加第二台及以后的机器时，再对一遍 7.5 的清单。

机器侧的全部检查用一条命令跑完：

```bash
bash scripts/verify.sh
```

重启之后也只需要跑这一条。它会逐项核对开机恢复路径是否真的自愈。

脚本从 `/etc/ci-runner.env` 读回 bootstrap 落盘的参数，比如 `RUNNER_HOME`、`RUNNER_USER`、`RUNNER_UID`、`RUNNER_OOM_ADJ`、`METADATA_IP`、磁盘阈值和 `GH_REPO`，读法和 bootstrap 相同。所以用了非默认参数的机器不用再传一遍。环境变量里显式给的值优先。

旧版 bootstrap 不落盘 `METADATA_IP`。这样的机器在用新版 bootstrap 重跑之前，如果云 metadata 地址不是默认的 `169.254.169.254`（比如阿里云、腾讯云，见 04 章 4.5），跑 verify 时要显式传，比如 `METADATA_IP=<你那家云的地址> bash scripts/verify.sh`，否则网络加固那几项会报假 FAIL。

最后一组「GitHub 侧」查本机的 runner 在 GitHub 上是不是 online，需要一个 token。列 runner 的接口要求目标仓库的 `Administration: read` 权限，所以单独建一个 fine-grained token，只授权这个仓库，只给这一项读权限。不要拿注册用的读写 token。

这一项最好在 CI 机以外查，比如在笔记本上，这样 token 不用上 CI 机，做法见 7.1 末尾。一定要在 CI 机上查时，token 用 `read -s` 输入，不要写在命令行上，否则会留在 shell 历史里：

```bash
read -rsp 'token: ' GH_TOKEN; echo; export GH_TOKEN
bash scripts/verify.sh
unset GH_TOKEN
```

脚本把 token 经标准输入交给 curl，不放进命令行参数（09 章 B19）。不给 token 时这一组是 SKIP。

> 注意：`verify.sh` 不是纯只读的。
>
> 「钩子实跑」这一项会真的执行一次清理钩子：删带 CI 标签的容器，杀 `CI_APP_PORTS` 端口上的进程，删没有容器在用的匿名卷。有 job 在跑时执行，会打断那个 job。
>
> 因此脚本会先检查有没有 `Runner.Worker` 进程。如果有，就把「钩子实跑」和「无残留容器」两项标为 SKIP。这时等空闲后再跑一次，拿到完整结果。
>
> 背景：这个脚本原来自称「只读」，08 章又把它列为日常巡检。两者叠在一起会打断 job，2026-10-16 才发现（09 章 B14）。

SKIP 有两种。一种是上面说的机器在忙，跳过了会打断 job 的检查。另一种是提醒，不算失败，比如口令登录还开着、没配告警推送、有待重启的更新、根分区低于 WARN 线。通过与否只看 FAIL 的个数。

用 `--skip-runner` 装、还没注册的机器，「找不到 runner 服务单元」会是 FAIL，给了 token 的话 GitHub 侧也是 FAIL。注册之后再跑一次。

### 7.1 `verify.sh` 查什么

`verify.sh` 按下表分组检查。

| 分组 | 检查项 | 不通过意味着 |
|---|---|---|
| 服务与开机自启 | docker / containerd / runner 三个 unit `active + enabled` | 重启后回不来 |
| runner 加固 | `Restart=always`、`StartLimitIntervalSec=0`、`MemoryMax`、`OOMScoreAdjust` 等于 `RUNNER_OOM_ADJ`（没写按 800）且大于 0、`After=docker`；runner 用户的 uid 等于 `RUNNER_UID`（默认 1000） | 前几项见 04 章 4.3。uid 不一致只提示（SKIP），原因见 03 章 3.3 |
| Docker | `live-restore=true`；BuildKit GC 有 Max Used 与 Min Free 两项 | 见表下说明 |
| 清理与监控 | 共 11 项，见表下说明 | 见表下说明 |
| 部署参数与系统更新 | `/etc/ci-runner.env` 存在；里面的 CI 标签和钩子一致（配了 `CI_PER_RUN_IMAGE_LABEL`、`CI_TMP_GLOBS` 的，这两项也要一致）；里面的 `RUNNER_NAME` 和本机注册名一致；needrestart 豁免 runner；有没有待重启的更新 | 见表下说明 |
| 网络加固 | DOCKER-USER + OUTPUT 两条 metadata 规则；已持久化；实拨容器验证 | 少一条就有一条路通 |
| SSH | 口令登录是否关闭 | 开着时只提示（SKIP），关不关见 04 章 4.6 |
| 干净度 | 无残留容器（有 job 时 SKIP）；匿名卷没有累积；根分区可用空间；runner 用户在 `/tmp` 下的占用 | 清理没生效，或者有清理管不到的东西在吃盘 |
| GitHub 侧 | 按本机 `.runner` 里的注册 ID 找到自己那一条，状态为 online | 查不到：没注册，或者网络问题。同名那条的 ID 不是本机的：本机的注册被另一台用同名 `--replace` 顶掉了（09 章 A18） |

Docker 组：如果 BuildKit GC 只有 Reserved，说明你用了 `defaultKeepStorage`，Min Free 保护就丢了（09 章 A1）。

干净度组：根分区那一项和 ci-health 用同一套阈值，都从 `/etc/ci-runner.env` 读。低于 `CI_DISK_CRIT_MB`（默认 10 GiB）是 FAIL；低于 `CI_DISK_WARN_MB`（BuildKit 的 Min Free 加 1 GiB）只提示。这样盘大小不同的机器不会误报，两个值怎么取见 10 章 10.4。匿名卷的上限默认 6 个，是按参考项目定的：三个服务容器，workflow 没给它们挂 tmpfs 时，每个 job 会短暂留下约 3 个匿名卷。别的项目取每个 job 的服务容器数乘 2，跑 verify 时用 `CI_MAX_VOLUMES=<上限> bash scripts/verify.sh` 传入。runner 用户在 `/tmp` 下的文件合计超过 2048 MiB 时只提示（SKIP），多半是被取消的 job 留下的临时目录（05 章 ③⑥）。`/tmp` 里也有工具自己的编译缓存，缓存本来就大的项目用 `CI_MAX_TMP_MB=<上限>` 调高。

`verify.sh` 只检查本机第一个 `actions.runner.*` 服务。一台机器装了多个实例时，脚本会打一行提示，其余实例查不到，前提见 10 章 10.6。

清理与监控组的 11 个检查项，按脚本里的顺序：

1. 清理钩子文件就位
2. 钩子按 `bash -e` 实跑一次能退出 0（有 job 时 SKIP）
3. 钩子带运行中 job 的守卫
4. 占位符已替换
5. 两个钩子都挂（`JOB_STARTED` 和 `JOB_COMPLETED`）
6. `ci-cleanup.timer` active
7. 健康监控已装（脚本和 `/etc/cron.d` 条目都在）
8. 监控量的是 `/var/lib/containerd`
9. 磁盘告警阈值与 GC 对齐
10. 告警推送已配（没配是 SKIP，不算 FAIL）
11. 每日清理以 runner 身份运行

这一组不通过的后果：

| 不通过的项 | 后果 |
|---|---|
| 钩子在 `-e` 下非零退出 | 每个 job 全红（原因见下文） |
| 钩子没有 job 守卫 | timer 撞上 job 时会删它的容器 |
| 只挂了一个钩子 | job 在初始化阶段被取消、或者 runner 服务被停掉时，残留没人清 |
| 阈值没与 GC 对齐 | 每小时误报 |
| 没配告警推送 | 告警没有接收方 |
| 每日清理以 root 运行 | root 执行一个 runner 可写的脚本，runner 能借此拿到 root |

部署参数与系统更新组不通过的后果：

- 参数没落盘：下次重新部署时会静默改回默认值。
- `RUNNER_NAME` 和注册名对不上：这个文件多半是从别的机器拷来的，里面的基线和 BuildKit 上限也是那台的。照 03 章重新定参数，这个文件不要跨机器拷（03 章 3.6）。
- needrestart 没豁免 runner：安全更新会在 job 中途重启 runner。

#### 为什么要实跑一次钩子

参考机在 2026-09-07 到 09-14 连续 7 天、21 个 job 全部失败，而这张表当时报的是 24 PASS / 0 FAIL。

原因是当时的三条钩子检查都是结构性的：

- 查文件可执行
- 查 `.env` 挂了两个变量
- 查 timer active

三条都 PASS，结论也都没错，但没有一条执行过那个钩子。

runner 调用钩子时会强加 `-e`，钩子非零退出就会把 job 判为失败（详见 09 章 A11）。钩子「装上了」和「真能用」之间差一次真实调用，当时的检查只验证了前者。

这条规则适用于所有自检：凡是非零退出会产生后果的东西，自检必须用和调用方完全相同的方式执行它一次。只检查它存在，等于没检查。

#### 在 CI 机以外查 GitHub 侧

在装了 `gh` 的笔记本或运维机上列出仓库的所有 runner：

```bash
gh api repos/OWNER/REPO/actions/runners \
  --jq '.runners[] | "\(.id) \(.name) \(.status) busy=\(.busy) \([.labels[].name] | join(","))"'
```

再在每台 runner 上看它自己的注册 ID：

```bash
sudo grep -o '"agentId": *[0-9]*' /opt/actions-runner/.runner    # RUNNER_HOME 不是默认值的换成你的
```

每台机器的 agentId 都要出现在列表里，对应那一条的名字是这台的名字，状态是 online。名字对得上而 ID 对不上，说明这台的注册被另一台用同名顶掉了（09 章 A18）。

### 7.2 机器侧之外：必须用真实 PR 验的四件事

下面四件事 `verify.sh` 验不了，只能开 PR 验证。

#### ① 第一个测试 PR：check 落到自建机且全绿

```bash
gh api repos/OWNER/REPO/actions/runs/<id>/jobs --jq '.jobs[]|"\(.name) \(.conclusion) \(.runner_name)"'
```

输出里的 `runner_name` 应该是你的 runner 名，而不是 `GitHub Actions ####`。

仓库里已经有别的自建机器时，新机器要单独确认两件事：上面的输出里出现了新机器的名字；每种重 job（构建、类型检查、带数据库的测试、e2e）都在它上面至少绿过一次。GitHub 把 job 派给空闲的那台，新机器不一定马上轮到。想让 job 尽快落到新机器上，可以等老机器空闲（`pgrep -x Runner.Worker` 没有输出）时停掉它的 runner 服务几分钟，验完再启动。

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

- 变量未设时开 PR，应落在 `ubuntu-latest`
- 变量设了再开 PR，应落在你的 runner

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

参考项目实测 30 秒内恢复。修改前（`Restart=no`）runner 会一直停着，不会再起来。

#### 公网暴露

在 CI 跑着服务容器时验证，或者手动起一个绑法相同的容器再验证。

```bash
# 用外部节点探。在本机探自己的公网 IP 只走本地路由栈，证明不了外部可达性（09 章 A10）
# 端口换成你的服务容器映射到宿主的端口，参考项目是 Postgres 的 5433
curl -s -H "Accept: application/json" "https://check-host.net/check-tcp?host=<你的IP>:<端口>&max_nodes=4"
```

参考项目的实测结果：

- 修复前：四个外部节点全部成功连上，并收到 Postgres 认证响应。
- 修复后：全部 `Connection refused`。

#### 孤儿进程假绿

适用于测试里有「起进程 + 轮询健康端点」模式的项目。

```bash
# 先用一个进程占住端口，再跑测试。期望：当场失败并指名道姓，而不是跑出一堆绿
```

参考项目的实测结果：

- 修复前：220/221 通过，测到的其实是孤儿进程。
- 修复后：退出码 1，并给出明确报错。

#### OOM 顺序（机器上还跑着开发工具时做）

目的是确认内存不够时内核先杀开发工具，不杀 CI。配置步骤见 04 章 4.8。最好在一个重 job（类型检查、打包）跑到一半时执行：

```bash
# 按 oom_score 从高到低列前 15 个进程：分数、adj、常驻内存（MB）、用户、进程名
for d in /proc/[0-9]*; do
  s=$(cat "$d/oom_score" 2>/dev/null) || continue
  printf '%6s %6s %7s  %-10s %s\n' "$s" "$(cat "$d/oom_score_adj")" \
    "$(awk '/^VmRSS/{print int($2/1024)}' "$d/status")" "$(stat -c %U "$d")" "$(cat "$d/comm")"
done 2>/dev/null | sort -rn | head -15
```

分数越高越先被杀。开发会话里起的进程（VS Code 远程服务端的 node、Claude Code、Codex 等）adj 应为 1000，分数要排在 runner 用户名下最大的 node、tsc 进程前面。顺序反了，先查开发会话的 adj 是不是 1000（04 章 4.8 第 3 步），再按 04 章 4.3 的公式调低 `RUNNER_OOM_ADJ`。

#### 开机恢复

见 7.4。

### 7.4 重启演练

重启演练验证机器重启后能不能自己回来。这是本章唯一需要承担一次中断的验证，但它验的是最要紧的东西。

容易忽略的一点：docker 和 runner 通常是机器开机之后才装的，所以在你主动重启一次之前，「开机自启」这条路径从来没有被执行过。三个 unit 都 `enabled` 只能证明配置对，证明不了启动顺序对，也证明不了 iptables 规则已经持久化。

```bash
# 重启前：记基线
systemctl is-enabled docker containerd <runner-unit>
M=$(sed -n 's/^METADATA_IP=//p' /etc/ci-runner.env)    # 本机落盘的 metadata 地址
sudo iptables -S | grep -cF -- "${M:-169.254.169.254}"  # metadata 规则条数，正常是 2，重启后应不变
systemctl list-timers --no-pager | grep ci-

# 等机器空闲（下面这条没有输出）再停 runner，免得重启时正好在跑 job
pgrep -x Runner.Worker
sudo systemctl stop <runner-unit>
sudo reboot

# 回来之后：一条命令（GitHub 侧那一组要 token，见本章开头）
bash scripts/verify.sh
```

有多台机器时一次只重启一台。等它回来、`verify.sh` 通过、GitHub 上显示 online，再重启下一台，这样任何时候都有机器在接 job（08 章 8.7）。

`reboot` 是机器内部的重启，一般不换宿主机。在控制台关机再开，或者厂商做了迁移，有的云会换到别的宿主机。这之后看一眼 `lscpu` 的型号，变了按 10 章 10.7 重测。

注意：如果你的终端或 CI 助手就跑在这台机器上，重启会把它一起断掉，所以重启放在最后一步。

### 7.5 加一台机器时的验收清单

操作步骤见 08 章 8.7，这里只列要核对的结果。

注册之前（`bootstrap.sh --skip-runner` 跑完之后）：

- `machine-check.sh` 带上现有 runner 的 REF 判为合格。判为有保留的，按 02 章 2.7 逐个 job 核过超时余量。
- 最慢的 job 以 runner 用户回放过，算出的 R 代进 02 章 2.7 的式子，所有跑在自建机上的 job 都满足。
- runner 用户的 uid 和其他 runner 机器相同，在各台上执行 `id runner` 比一下（03 章 3.3）。
- `/etc/ci-runner.env` 是在这台机器上跑 bootstrap 生成的，不是从别的机器拷来的。里面的 `RUNNER_NAME` 和已有的机器都不同，`CI_FIXEDWORK_BASELINE` 是这台自己用 preflight 测的。

注册之后：

- `verify.sh` 没有 FAIL，GitHub 侧那一项按注册 ID 找到了本机。
- GitHub 上几台都在，名字各不相同，标签相同。老机器那一条的 ID 没变，说明新机器没有用同名把它顶掉（09 章 A18）。在 CI 机以外查的命令见 7.1 末尾。
- 7.2 ① 的查询里出现了新机器的名字，每种重 job 都在新机器上至少绿过一次。
- 新机器的 ci-health 只统计自己的 job。执行 `grep -o 'jobs=[^ ]*' /var/log/ci-health.log | tail -3`，应是 `streak=` 开头。`skip` 是没配只读 token；`skip:no-runner` 是 ci-health 在注册之前装的，注册时没有重跑 bootstrap；`error:no-runner-name` 是读不到本机的 `.runner`。
- 告警推送的标题里带主机名，几台推到同一个群也分得清。
- 新机器在心跳服务上有自己的检查项（06 章 6.4）。

---

## 08 运维与容量

本章讲上线之后的长期工作：怎么估算排队和容量、磁盘和 CPU 怎么监控、构建缓存怎么优化、什么时候该扩容、日常和每月的巡检步骤，以及有多台机器时怎么加、怎么撤、怎么更新。一台机器该跑几个实例、参数按规格怎么取，见 10 章。

本章的 N 指整个仓库的 runner 实例总数，k 指一台机器上的实例数。现有脚本每台机器只装一个实例，所以眼下 N 就是机器台数。

### 8.1 容量：用仿真，别套公式

估算排队时间和 runner 数量，要拿真实事件做仿真，不要套排队公式。

最常见的错误是套 `ρ = λ × S`（到达率 × 服务时长），再按 M/M/1 模型算排队。在有 `cancel-in-progress` 的仓库里，这个模型不成立，原因如下：

- 同分支的新 push 会取消旧 run，排队中的和正在跑的都会被取消。
- 所以到达的 run 变多，不等于要做的工作变多。新 run 有很大一部分是在替换旧 run。

做法：拿真实事件的时间戳做仿真，脚本是 `scripts/analysis/queue_sim.py`。在仓库根目录运行：

```python
import sys; sys.path.insert(0, 'scripts/analysis')
from queue_sim import ts, simulate
# runs 是 /repos/{owner}/{repo}/actions/runs 返回的 workflow_runs 列表
events = [(ts(r['created_at']), r['name'], r['head_branch']) for r in runs]
svc    = {'ci': 305, 'main-post-merge': 276, 'pr-meta': 12}   # 参考项目各 workflow 的实测时长（秒），换成你的
r = simulate(events, svc)
```

这个脚本有两处限制，用之前要知道：

- 它只模拟一个 runner。要比较 N=1 和 N=2，先把 `simulate()` 改成多个 runner 同时从队列取活。
- workflow 的名字和 concurrency 规则是按参考项目写死的（`ci`、`pr-meta`、`main-post-merge`、`nightly`）。事件里出现别的 workflow 名会直接报 KeyError。用到你的仓库，先按你的 workflow 改 `CANCEL_RUNNING` 和 `group()`。

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

- 全仓库要几个 runner 实例，也就是 N 该是几（先把脚本改成能模拟多个 runner）
- 要不要合并 job（比较它与别的提速手段的实际收益）
- 能不能把某个检查加到 PR 路径上
- 团队人数翻倍时会怎样
- 需求回弹（CI 恢复后大家推得更勤）会不会顶穿（超出现有 runner 的容量）

参考项目的仿真结果如下，都是一个 runner 的结果。数据取历史最忙的一天，单位是分钟。

| 场景 | 中位 | p90 | 最长 |
|---|---|---|---|
| 现状（2 人） | 1.8 | 9.7 | 15.5 |
| 需求回弹 1.9× | 1.8 | 10.1 | 22.7 |
| 团队 4 人 | 4.6 | 18.4 | 37.1 |
| 团队 8 人 | 17.0 | 81.5 | 122.8 |

结论：

- 只有一个 runner 时，天花板约在 4 人。
- 到 8 人时要加 runner。参考项目的第一台是 4 核、约 7.6 GiB，在它上面同机跑两个实例的实验失败了，所以参考项目扩容是加机器，每台一个实例（8.5）。更大的机器一台能跑几个，见 10 章 10.2 和 10.6。

### 8.2 磁盘：各类占用分别由谁清理

磁盘占用来自 Docker 内的三个来源（BuildKit 缓存、匿名卷、镜像），再加上 Docker 以外的文件。它们各自由不同的机制清理，一个机制不会替其他来源兜底。BuildKit 缓存有 GC 兜底，不会无限增长；真正没有上界的是匿名卷和 Docker 以外的文件。

| 来源 | 由谁清理 | 不清理的后果 |
|---|---|---|
| BuildKit build cache | `daemon.json` 的 GC 策略 | 长到上限后由 GC 驱逐 |
| 匿名卷（services 容器的数据） | 只有 `docker volume prune` | workflow 没挂 tmpfs 时无上界，约 70 MB/job |
| 镜像 | 悬空的由钩子清；换掉的旧 pin 要人工退役；每次运行各建一份的，配了 `CI_PER_RUN_IMAGE_LABEL` 由钩子清 | 慢慢累积，参考项目一个月约 2 GB；每次运行各建一份的镜像，每取消一次留一份，参考项目约 3 GB 一份 |
| Docker 以外 | 无；`/tmp` 下的临时目录配了 `CI_TMP_GLOBS` 由钩子清 | 参考项目一个月涨了约 6 GiB；被取消的 job 留在 `/tmp` 的目录，参考项目约 1 GB 一份 |

表格补充说明：

- BuildKit 的 GC 策略有三个参数：Reserved / Max Used / Min Free。缓存会一直增长，直到长到 Max Used，或者把可用空间压到 Min Free，然后 GC 开始驱逐。
- `docker volume prune` 由清理钩子在每个 job 前后各执行一次。service 容器留下的匿名卷只有它会清，BuildKit 的 GC 不管卷；workflow 给这些容器挂上 tmpfs 后就不再产生（05 章 ⑫）。
- 换掉的旧 pin 不会被自动清理，退役步骤见 8.6。
- Docker 以外的增长包括 IDE 远程服务端、旧检出、包管理器缓存等。约 6 GiB 这个数，是 `ci-health` 采样里「可用 + containerd」之和的减少量。
- 被取消的 job 留下的东西：程序在 finally 里删的镜像和 `/tmp` 目录，job 被取消时都删不掉（05 章 ⑥）。这类增长跟着取消次数走，PR 推得越勤越快，不是匀速的。

所以「不清理就会盘满」这个判断通常不对。要盯的是匿名卷、被取消的 job 留下的东西和 Docker 以外的增长。

containerd 涨了，不一定是 BuildKit 缓存。缓存有 GC 上限，镜像不归 GC 管。参考项目第一台 2026-10-26 报 CRIT（根分区只剩 5.5 GB），之前 3 小时里可用空间少了 12.8 GB：containerd 涨了 8.9 GB，全是被取消的 job 留下的镜像；其余 3.9 GB 是 `/tmp` 里的目录（09 章 A22、B20）。ci-health 的磁盘告警会列出 containerd、`/tmp` 和其余部分各占多少，按下面的顺序查：

1. `docker images`：有没有一串名字只差一段随机串的镜像。有的话按 05 章 ⑫ 末尾配 `CI_PER_RUN_IMAGE_LABEL`。
2. `du -sh /tmp/* | sort -h | tail`：有没有同一个前缀的一串大目录。有的话按 05 章 ③ 处理。
3. 最后再看 Docker 以外的其他目录（8.6 第 3 条）。

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

缓存工作集由构建频率与层序决定（见 8.4）。它填满 Max Used 之后就不再增长，可用空间会停在一个稳定值上。这是设计行为，不该触发告警。

Min Free 是另一条线。只有在盘更小、或者 Docker 以外的增长把可用空间挤到 Min Free 附近时，GC 才会为了保底而驱逐缓存。这种情况才值得告警。

#### 监控要点

监控脚本是 `scripts/ci-health.sh`。要点如下：

- 量 `/var/lib/containerd`，不要量 `/var/lib/docker`。Docker 29 默认用 containerd 快照器，实测 containerd 占 2.6 G，docker 目录只有 115 M。量错目录会低估约 10 倍，监控就成了假绿（指标显示正常，实际没量到真实占用）。
- 匿名卷在 `/var/lib/docker/volumes`，要单独量。
- 可用空间（`root_avail`）量的是根分区，也就是 `df /`。Docker 数据放在另一块盘上时，告警看的就不是 Docker 所在的那块盘，按 02 章 2.9 表下的说明改。
- 磁盘阈值从 Min Free 推算。原版写死的两个阈值都有问题：
  - WARN < 40 GB：在设计稳态下每小时都会触发，一个月响了 309 次，没有送达任何人。
  - CRIT < 20000 MB：只比 Min Free（20480 MiB）低 480 MiB。
  - 现在的阈值：WARN = Min Free + 1 GiB，对应可用空间被挤到 Min Free 附近、GC 开始为保底驱逐缓存的时刻；CRIT = 10 GiB。
  - bootstrap 会从 `BUILDKIT_MIN_FREE` 自动算出阈值，写进 `/etc/cron.d/ci-health`，同时落盘到 `/etc/ci-runner.env`。以后改了 `BUILDKIT_MIN_FREE`，这个阈值不会跟着重算，做法见 10 章 10.4。
- 告警要送到人。只写本机 journal 等于没有告警。在 `/etc/ci-health.env` 里配置 `CI_ALERT_WEBHOOK` 后，告警集合一有变化就推送，持续存在的告警每 24 小时提醒一次。消息标题带主机名，几台机器推到同一个群也分得清。脚本目前只实现了飞书自定义机器人的消息格式和签名，换成 Slack、钉钉、企业微信，要改 `ci-health.sh` 里的 `notify()`。
- 失败连续计数只看落在本机上的 job，按本机的 runner 名匹配。按整个 run 的结论统计会有两种误报：GitHub 托管的检查（PR 标题之类）失败会被算进来；多台机器共用一套标签时，同一个 run 的 job 会分到几台机器上，别的机器上的 job 红了，这台也会报连续失败。读不到本机的 runner 名时，这一项报采样失败，不会退回去统计全仓库；用 `--skip-runner` 装、还没注册的机器上，这一项跳过。被取消的 run 整个不算：新推送顶掉旧 run 时，写了 `if: always()` 的汇总 job 会因为前面的 job 被取消而判失败，不跳过的话 PR 推得勤时很快就凑满 3 次（09 章 B11）。
- 除了水位，也要看增量。日增超过预期两倍时，检查是不是哪个构建的层序坏了。

> 注意：开发工具（VS Code 远程服务端、Claude Code、Codex 等）在 CI 机上同时占磁盘和内存。磁盘方面，VS Code 远程服务端每次客户端升级就多留一份，参考机上一份约 650 MB，一个月攒了 5 份，要在每月巡检时删（8.6）。内存方面后果更重，参考项目在 8 GB 的 CI 机上开发了两天，出了 11 次全局 OOM。最好不在 CI 机上开发；一定要开发，按 04 章 4.8 配置。

### 8.3 CPU 争抢监控

CPU 争抢要常态化采点监控，上线前查一次不够。

1. 先确认 steal 指标能不能用（见 02 章 2.5）。preflight 第 6 项会先核对虚拟化类型，只在 KVM 上判断 steal 能不能用，别的虚拟化和裸金属按「不能用」处理。
2. 不能用的话，就采集定长任务的墙钟时间，超过基线 1.4 倍时报警。`ci-health.sh` 已经按这个方式实现。

注意：共享 vCPU 的邻居会变。今天不拥挤，只能说明此刻不拥挤。按 CPU 积分限速的突发性能规格，积分用完后也表现为定长任务变慢，这类规格选型时就该避开（02 章 2.9）。

基线只在同一台机器上有意义，不能拿来比较两台机器。`ci-health.sh` 和 `preflight.sh` 用的 sha256 定长任务，速度主要看 CPU 有没有 SHA 指令扩展。参考项目的 Intel Skylake 候选机没有这条扩展，现有的 AMD EPYC 有，sha256 显示 Intel 那台慢约 5 倍，实际单核只慢约 2 倍。反过来也会错：另一台同为 EPYC 的候选机，sha256 和现有 runner 只差约 4%，Python 循环却慢 15–25%。所以每台用自己的 preflight 结果当基线；换机、换规格，或者 `lscpu` 显示的 CPU 型号变了，都要重测。要比较两台机器的单核速度，用 02 章 2.7 的方法。

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

收益：这项优化只影响速度和磁盘，不涉及正确性。参考项目 10-10 至 10-16 这一周，冷装共占约 85 分钟 runner 时间（install 约 25 分钟，导出与解包新的依赖层约 60 分钟），约占同期全部 job 时长的 3.2%。改完能省下其中大部分，lockfile 真变了的那几次仍要重装。改完还能让 BuildKit 的 Max Used 从 20 GiB 降下来，腾出 10 GB 以上磁盘。

顺序是先改 Dockerfile，再降 Max Used。反过来的话，缓存工作集还没变小就先缩了上限，构建只会更冷。

### 8.5 什么时候该扩容

出现下面任一信号，就该算账评估扩容：

- 排队等待的 p90 超过单个 run 的时长
- 团队规模翻倍（用 8.1 的仿真验证，别猜）
- 想把重检查加进 PR 路径，但仿真显示会顶穿

扩容有两条路：加机器，每台跑一个实例；或者在一台大机器上跑多个实例。全仓库要几个实例（N）用 8.1 的仿真估，一台机器放几个（k）按 10 章 10.2 算。

现在先加机器。现有脚本支持多台机器共用一套标签，workflow 和开关变量都不用改，一台挂了其他台照常接 job。步骤见 8.7。

参考项目在第一台（4 核、约 7.6 GiB）上试过同机跑两个实例，两次出了两种不同的失败：CPU 不够导致的随机超时，以及 OOM（02 章 2.1）。这个结论只对那台机器成立。核数和内存更多的机器，资源上能跑几个，按 10 章 10.2 算。

资源够了也不能马上在一台机器上跑多个实例。参考项目的 workflow 给服务容器发布了固定的宿主端口，清理钩子也是按一台机器一个 job 写的，两个实例同时跑会抢端口。钩子现在发现本机有别的 job 就整段跳过，不会误删，但清理基本不再执行；去掉这道守卫，又会删掉对方的容器、杀掉对方的进程。要等 workflow 不再发布固定宿主端口、钩子只清自己这个 job 的资源、脚本能按实例分别安装之后，才能换一台大机器跑 k 个实例。完整的前提和扩容路线见 10 章 10.6。

还有一个折中做法：第二个实例打独立的标签，只接秒级、不用数据库、不跑 docker build 的轻 job。它省的只是 CPU 和内存，端口、钩子和按实例安装这几条照样要先满足。

参考项目现在选的是两台 4 核 8 GB 的机器，每台一个实例。等 workflow 和钩子按 10.6 改完，再考虑换成一台大机器跑多个实例。

### 8.6 日常巡检

日常巡检用下面四条命令；另有几项工作每月做一次。有多台机器时每台各做一遍。

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
   - 做法：先 `systemctl stop <runner 服务>` 再重启，免得刚好接到一个 job。`live-restore` 与 `Restart=always` 会让一切自己恢复。有多台机器时一次只重启一台，这台回来、`verify.sh` 通过、GitHub 上显示 online 之后再动下一台（8.7）。
   - 确认：恢复后跑 `verify.sh`，再看一眼 `lscpu` 的 CPU 型号。有的云上关机再开或者被厂商迁移后会换宿主机，型号变了按 10 章 10.7 重测。
   - 旧内核不用手动删。Ubuntu 会把重启前在用的那个内核保留作回退，`apt autoremove` 这时不会删它，等下次装新内核时才会标记为可删除。参考机 2026-10-16 重启后就是这样。
2. 退役旧镜像。workflow 换了 pin 之后，旧版本不会被自动删除（钩子只删悬空的和打了 CI 标签的）：
   ```bash
   docker images --digests          # 对照 workflow 里实际引用的 image@sha256，删掉不再引用的
   docker image rm <旧镜像>          # 不带 -f：还有容器在用的话 Docker 会拒绝
   ```
   注意：别用 `docker image prune -a --filter until=...` 代劳。until 按镜像的创建时间算，一个两年前构建、今天还在用的 pin 会被删掉。
3. 看一眼 Docker 以外的增长，例如 `du -sh /root/.vscode-server /home/*/.vscode-server /root/.cursor-server /home/*/.cache`，再看 `du -sh /tmp/* | sort -h | tail` 里有没有被取消的 job 留下的目录（8.2）。VS Code 远程服务端可以只留正在用的那一份：用 `ls ~/.vscode-server/cli/servers/` 列出所有版本，进程在用的那个之外都能删。
4. 核对参数。`/etc/ci-runner.env` 里的参数和按 10 章公式算出来的值是否还一致。workflow 加了重 job、机器上开始或不再有人开发、换了盘，都要按 10 章 10.7 重新量一遍。

### 8.7 多台机器

几台机器注册同一套标签时，GitHub 会把排队的 job 派给空闲的那台，workflow 和 `CI_RUNNER` 变量都不用改。每台机器各装各的，参数按各自的规格定。现有脚本每台只装一个实例，一台机器跑多个实例的前提见 10 章 10.6。

#### 哪些必须不同，哪些必须相同

- `RUNNER_NAME` 每台不同。注册时带 `--replace`，名字和已有的 runner 重复时，会直接顶掉那台的注册，不报错，那台从此接不到 job（09 章 A18）。默认值是 `ci-<主机名>`，云上新机器的主机名可能和老机器重复，有多台时显式传。
- `/etc/ci-runner.env` 不要从一台拷到另一台，里面有 `RUNNER_NAME` 和那台机器自己测的基线。也不要拿一台已经注册过的机器做快照来克隆新机器，`RUNNER_HOME` 下的 `.runner` 和 `.credentials` 会一起带过去，两台用的是同一个注册。
- `RUNNER_LABELS` 每台完全相同。`CI_LABEL`、`CI_APP_PORTS` 跟着 workflow 走，每台也相同。
- runner 用户的 uid 每台相同（03 章 3.3）。
- 和机器有关的参数每台单独定。`CI_FIXEDWORK_BASELINE` 用这台自己跑 `preflight.sh --with-load` 得到的 p50，不能抄别的机器，也不能拿来比两台的快慢（8.3）。`RUNNER_MEM_MAX`、`RUNNER_OOM_ADJ`、BuildKit 三个值按这台的内存和盘定（10 章）。

监控也按台看。每台的 ci-health 只统计落在本机的 job，告警标题带主机名。verify.sh 的 GitHub 侧检查按本机 `.runner` 里的注册 ID 找自己那一条。心跳每台单独建一个检查（06 章 6.4）。06 章的排队哨兵在多台时，只有全部下线或全部忙满才会响，单台下线要靠这台自己的心跳发现。

#### 加一台机器

1. 选机。规格按 10 章定。拿到机器后按 03 章 3.0 用 `machine-check.sh` 测单核速度，拿现有 runner 的分数当 `REF`，不合格就换一台（按月计费的先看 02 章 2.9）。
2. 第一次跑 bootstrap 加 `--skip-runner`，带上这台自己的 `RUNNER_NAME` 和其余参数，只装机、不注册。
3. 以 runner 用户回放最慢的 job，按 02 章 2.7 核对超时余量。
4. 确认老机器上的脚本是当前版本。早期版本的 ci-health 按整个 run 统计连续失败，几台共用标签时会互相报警；早期的 verify.sh 只按名字查 GitHub 侧状态，本机注册被同名顶掉时查不出来。老机器先按下面「更新已部署的机器」更新。
5. 输入 PAT 重跑 bootstrap 完成注册，参数从 `/etc/ci-runner.env` 读回。然后跑 `verify.sh`。
6. 配告警：`/etc/ci-health.env` 里的只读 token 和推送地址（8.2），心跳服务上给这台单独建一个检查（06 章 6.4）。
7. 在 GitHub 上核对。几台都在线、名字各不相同、标签相同；老机器 `.runner` 里的 agentId 还在列表里，说明它没有被顶掉。再看新机器领到了 job，每种重 job（构建、类型检查、带数据库的测试、e2e）都在它上面绿过一次。注册前后要验的完整清单见 07 章 7.5。

在 CI 机以外查 runner 列表，token 要有目标仓库的 Administration 读权限：

```bash
gh api repos/OWNER/REPO/actions/runners \
  --jq '.runners[] | "\(.id) \(.name) \(.status) busy=\(.busy) \([.labels[].name] | join(","))"'
```

`status` 有分钟级的延迟，刚停掉的 runner 可能还显示 online（06 章 6.4）。

看最近 30 个 run 里每台各领了多少 job，用 Actions 读权限就够：

```bash
REPO=owner/repo
gh run list --repo "$REPO" -L 30 --json databaseId -q '.[].databaseId' |
while read -r id; do
  gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
    -q '.jobs[] | select((.runner_name // "") != "") | .runner_name'
done | sort | uniq -c
```

名字以 `GitHub Actions` 开头的是托管 runner。某台机器在线却长时间一个 job 都没领到，先查它的标签和别的机器是否一致。

#### 重启和升级：一次只动一台

等这台空闲（`pgrep -x Runner.Worker` 没有输出），`systemctl stop` 它的 runner 服务，再重启或升级。等它回来、`verify.sh` 通过、GitHub 上显示 online，再动下一台。动手前先确认别的机器在线，不然这段时间没有机器接 job。

#### 更新已部署的机器

手册仓库里的脚本更新以后，机器上已经装好的副本不会跟着变。整体更新就重跑 bootstrap：

```bash
pgrep -x Runner.Worker                         # 没有输出再往下
systemctl stop <runner 服务>
git -C <手册仓库目录> pull
bash <手册仓库目录>/scripts/bootstrap.sh         # 参数从 /etc/ci-runner.env 读回；已注册的机器不需要 token
bash <手册仓库目录>/scripts/verify.sh
```

一定要先停 runner 服务。bootstrap 只在开头查一次有没有 job，跑的几分钟里接到的 job 会被它末尾的重启打断；daemon.json 有变化时，它还会重启 docker。脚本最后会重新启动 runner。

也可以只换一个文件。清理钩子按 04 章 4.4 的做法换：先写到 `.new`，试跑通过再替换，同样先停 runner 服务。`ci-health.sh` 不影响正在跑的 job，替换占位符后直接覆盖：

```bash
sed "s#__RUNNER_SVC__#<runner 服务>#" scripts/ci-health.sh > /usr/local/bin/ci-health.sh
```

#### 撤掉一台机器

1. 如果这是最后一台自建机器，先按 06 章把 job 切回托管。
2. 等它空闲，执行 `systemctl disable --now <runner 服务>`。job 会落到剩下的机器上，标签和变量都不用改。
3. 删掉 `/etc/cron.d/ci-health`。不删的话，ci-health 每小时都会记一条「runner 服务不是 active」，配了推送的还会每 24 小时提醒一次。
4. 停掉心跳 timer（`systemctl disable --now ci-heartbeat.timer`），再到心跳服务上删掉这台的检查，否则心跳服务会一直告警。
5. 处理 GitHub 上的注册。撤掉的机器在列表里显示 offline，离线超过 14 天的注册 GitHub 会自动删掉。想马上删，在仓库的 Settings → Actions → Runners 里删，或者执行 `gh api -X DELETE repos/OWNER/REPO/actions/runners/<id>`（要 Administration 写权限）。

14 天这条规则对临时关机的机器同样适用。一台机器停机超过 14 天，它的注册会被 GitHub 删掉，开回来之后 runner 连不上，要清掉本地的注册信息重新注册。参考项目没有遇到过这种情况，具体做法以 GitHub 的文档为准。

---

## 09 踩坑记录

本章记录部署和运行中踩过的坑，分三部分：

- A. 环境的坑：换一台机器还会遇到。A15–A21 是装新机器、准备加第二台机器时遇到的，A22 是两台都上线以后发现的。
- B. 判断方法上的错误：换个环境还会以别的形式出现，比 A 更值得读。
- C. 有争议、未采纳的建议，以及不采纳的数据依据。

文中的日期和数字都来自参考项目。参考项目的机器开在 Hetzner Cloud 上，和厂商有关的几条（A8、A19、A20、A21）注明了换厂商时怎么看，各厂商的差别汇总在 02 章 2.9。

---

### A. 环境的坑

#### A1. `defaultKeepStorage` 会把 Min Free 保护丢掉

用 `defaultKeepStorage` 配 BuildKit GC，会让出厂的 Min Free Space 保护失效。

```json
{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"10GB"}}}
```

这个写法看起来对，实际上 `defaultKeepStorage` 只映射到 Reserved Space，出厂的 `Min Free Space` 保护就没了。

另一种写法也不行：把 `reservedSpace`/`maxUsedSpace`/`minFreeSpace` 直接写在 `gc` 顶层，会被静默忽略。daemon 不报错，直接回落到出厂值。

怎么做：必须用 `policy` 数组。

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

`sshd_config.d` 里同一个配置项以最先出现的为准，所以加固文件名必须排在 cloud-init 写的 `50-cloud-init.conf` 之前。参考项目的机器上，后者里面是 `PasswordAuthentication yes`。这个文件有没有、里面写什么看厂商，以 `sshd -T` 的输出为准。

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

`ci-cleanup.sh` 开头写的是 `set -uo pipefail`，不含 `-e`，但这关不掉外部传进来的 `-e`。两者叠加后，脚本里任何一条命令非零退出，都会让整个脚本当场中止。末尾那句 `exit 0   # 清理失败绝不让 job 变红` 根本执行不到。

实际触发点是第 7 步：

```bash
ls -dt bin.* 2>/dev/null | grep -vx "$cb" | tail -n +2 | xargs -r rm -rf
```

机器上不存在 `bin.*` → `ls` 退出 2 → `grep` 无输入退出 1 → `pipefail` 把管道判为 1 → 中止。也就是说，「没有垃圾要清理」这个正常状态触发了全线故障。

##### 排查和修复时要注意的三点

1. GitHub 网页日志显示的命令不准。它打印 `shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}`，但那是 `ScriptHandler.PrepareExecution` 打出的装饰性 banner；钩子实际走的是 `GetScriptArgumentsFormat("sh")` = `-e {0}` 分支。以 `_diag/Worker_*.log` 里的 `Arguments:` 为准。
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

写 job 钩子时，始终假设调用方会加 `-e`。钩子的契约是「非零 = 让 job 失败」，所以清理类钩子必须自己保证退出 0，不能依赖脚本末尾的 `exit 0`。

#### A12. `sed` 把占位符和「判断占位符有没有被替换」的守卫一起换掉了

这是 A11 那次事故中发现的第二个 bug，静默了同样久。`sed` 把守卫里的占位符也换掉了，守卫条件恒为假，孤儿进程清理从未执行。

```bash
# ci-cleanup.sh
APP_PORTS="__CI_APP_PORTS__"                              # 赋值行
if [ ... ] && [ "$APP_PORTS" != "__CI_APP_PORTS__" ]; then # 守卫行（旧写法）
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

当时正在跑的一个测试 job 被当场打断。GitHub 上记为 Failed，下游的汇总检查跟着变红，只能重跑。这也是 `JOB_COMPLETED` 钩子跑不到的一个实例：runner 服务被停掉了。

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

参考项目 2026-10-16 在 workflow 侧改完，之后 job 期间新建卷为 0。钩子里的 `docker volume prune` 留着兜底。

手册为什么漏了这一点：05 章 ① 原来的模板写的就是 `docker rm -f`，参考项目沿用了这个模板。

#### A15. 全新的 Ubuntu 24.04 上，`dpkg -l` 对没装的包也返回 0

旧版 bootstrap 用 `dpkg -l iptables-persistent` 判断要不要安装这个包。全新的 24.04 上，dpkg 里已经有这个包名的记录，状态是 `un`（未安装），`dpkg -l` 照样返回 0。于是脚本跳过安装，下一行的 `netfilter-persistent save` 找不到命令，bootstrap 在第 8 步退出，metadata 拦截规则没有持久化。

这个问题在已经装好的机器上重跑发现不了，只有全新机器会踩到。参考项目是 2026-10-19 在一台全新机器上装机时遇到的。

修法：用 `dpkg-query -W -f='${Status}' <包名> | grep -q 'install ok installed'` 判断，bootstrap 已经这样改了。

规律：`dpkg -l` 的退出码只说明 dpkg 认得这个名字，不说明它装上了。

#### A16. Node 官方 tarball 解压后归 uid 1001

Node 官方 tarball 里的文件属主是 uid 1001，root 用 tar 解压时默认保留属主，于是 `/opt/node` 归 uid 1001。机器上谁恰好是 1001，谁就能改掉 CI 和 root 都会执行的 node。参考项目装新机器时，机器上的开发用户恰好就是 1001。

修法：解压时加 `--no-same-owner`，bootstrap 已经这样改了。检查：`find /opt/node ! -user root | wc -l` 应为 0。

#### A17. runner 一启动就会接排队的 job，而 `.env` 只在启动时读

旧版 bootstrap 在第 5 步注册完就启动 runner，第 6 步加固时再重启一次，钩子到第 7 步才写进 `.env`。这带来两个问题：

- 新注册的 runner 一上线就去接排队中的 job，紧接着的重启把它打断。
- runner 只在启动时读 `.env`，重启之前接到的 job 没有清理钩子。

修法：第 5 步只装服务不启动，等加固、钩子、metadata 规则都就位后，在第 8 步末尾启动一次（04 章 4.4）。

规律：runner 服务的第一次启动要放在所有配置之后。它启动的那一刻，就可能在跑真实的 job。

#### A18. 两台机器用了同一个 `RUNNER_NAME`，后注册的会顶掉先注册的

bootstrap 注册时带 `--replace`，方便在同一台机器上重新注册。名字和仓库里已有的 runner 相同时，GitHub 会用新机器替换掉那条注册，不报错，老机器从此接不到 job。这时按名字查 GitHub 上的状态还是 online，因为在线的是新机器，很难发现。

最容易出事的做法是把 `/etc/ci-runner.env` 从老机器拷到新机器，里面的 `RUNNER_NAME` 也跟着过去了。用已注册机器的快照克隆新机器也一样，注册信息会一起带过去。另一种情况是云上新机器的主机名和老机器相同，默认的 `ci-<主机名>` 就撞了。

做法：每台机器显式传不同的 `RUNNER_NAME`，`/etc/ci-runner.env` 不跨机器拷贝（08 章 8.7）。核对时比 ID：本机 `.runner` 里的 agentId，要和 GitHub 上同名那条的 id 一致。verify.sh 现在就是这样查的。

#### A19. runner 用户的 uid 要和容器写文件的身份对上

常驻机器上工作区跨 job 复用，下一个 job 的 checkout 要先清掉上一次留下的文件。CI 容器往挂进去的工作区写文件时，文件属主是容器里进程的 uid。很多镜像里的普通用户是 uid 1000，比如 node 官方镜像自带的 `node` 用户（这个镜像默认以 root 运行，要在 workflow 里用 `--user` 切过去）。runner 也是 1000 时，这些文件归它，下一次 checkout 删得掉。runner 是别的 uid 时，清理会报 `EACCES`，job 在 checkout 这一步就失败。

参考项目第一台的 runner 恰好是 1000，因为它是机器上第一个普通用户（参考项目所用厂商的镜像只有 root，没有自带普通用户）。如果先建了开发用户，runner 就会拿到 1001。

做法：装机时先建 runner 用户，uid 固定为 1000（bootstrap 的 `RUNNER_UID`，默认 1000，被占用时报错退出），再建其他普通用户，多台机器保持一致（03 章 3.3）。有的云镜像自带 uid 1000 的用户，比如 AWS Ubuntu 镜像里的 `ubuntu`。它常常是唯一能 SSH 登录的账号，不能直接删，处理办法见 03 章 3.3。

#### A20. 同一个套餐开出来的 CPU 型号可能不一样（参考项目：Hetzner Cloud 共享 vCPU）

参考项目用的 Hetzner Cloud 共享 vCPU 机型，CPU 型号由分到的宿主机决定，下单时选不了。别的厂商有的规格族固定 CPU 代际，有的能指定最低 CPU 平台，看厂商文档；不管哪种，拿到机器都要实测。参考项目找第二台机器时，同一个套餐先后开到两台 Intel Skylake，`machine-check.sh` 的单核分数是 4.2–4.7（分数是耗时，越大越慢），现有 runner（AMD EPYC-Rome）在跑 CI 时测的约 2.5，比值 1.7–1.9。后来开到一台同为 EPYC-Rome 的 8 核机器，型号和现有 runner 一样，真实的单核算法测试仍慢 23%。

单核慢主要影响被限制在单核上跑的 job（比如测试容器只给 1 个 CPU）、单线程的类型检查和 lint，以及带固定超时的测试。核数多也补不回来。

做法：拿到机器先用 `machine-check.sh` 和现有 runner 比（03 章 3.0），不合格就换一台，按月计费时怎么办见 02 章 2.7 和 2.9。合格的也要回放最慢的 job、核对超时余量，再注册（02 章 2.7）。

#### A21. 新机器 root 用口令 SSH 登不上，口令是对的

Ubuntu、Debian 的 sshd 默认是 `PermitRootLogin prohibit-password`（OpenSSH 7.0 起的上游默认值）。镜像保留这个默认值时，root 只能用公钥登录。有的厂商建机时如果没选公钥，会生成一个 root 口令发给你，登录时也提示可以输口令，这时 root 用口令登录照样被拒。也有厂商会把 `PermitRootLogin` 改成 yes，root 用口令能登上去。实际生效的值看 `sshd -T | grep permitrootlogin`。cloud-init 写进去的 `PasswordAuthentication yes`（有的厂商会写）只打开了口令认证，root 能不能用口令登录由 `PermitRootLogin` 单独决定。参考项目在 Hetzner Cloud 上遇到过。另一些厂商根本不给 root 口令，只建一个默认用户、注入你的公钥。

做法：建机器时就填上 SSH 公钥。忘了填的，用厂商的带外入口（控制台网页终端、串口控制台，裸金属用 IPMI 或救援系统）登录，把公钥写进要登录的那个用户的 `~/.ssh/authorized_keys`（03 章 3.0）。

#### A22. job 被取消时，程序里的清理不执行

参考项目有个算法测试工具，每次运行在 `/tmp` 下打一份约 1 GB 的源码包，再建一个唯一 tag 的镜像（独占约 3 GB），两样都在 finally 里删。workflow 开了 `cancel-in-progress`，同一个 PR 再推一次，正在跑的 job 就被取消。

runner 取消一个步骤时，只给这一步的 bash 发 SIGINT，等 7.5 秒再发 SIGTERM，再等 2.5 秒就杀掉整棵进程树（Worker 日志原文见 05 章 ⑥）。bash 不会把信号转给它正在等的子进程，工具收不到信号，finally 没有机会执行。清理钩子在取消后照常执行（04 章 4.4），但当时它不认识这两样东西：镜像带 CI 标签，要等 6 小时才删；`/tmp` 它根本不管，而 Ubuntu 24.04 默认的 tmpfiles 规则（`D /tmp 1777 root root 30d`）要 30 天没动过才删。

参考项目第一台 14 天的 Worker 日志里，这个 job 成功 200 次、失败 4 次、被取消 9 次。`/tmp` 里正好有 9 份残留，创建时间都落在对应那次被取消的 job 的起止时间内。失败的 4 次都在 30 秒内结束，还没跑到建目录那一步。2026-10-26 一天被取消 4 次，根分区可用空间从 18.4 GB 掉到 5.5 GB，告警到了 CRIT。

修法：

- 工具把临时目录放进 `$RUNNER_TEMP`（05 章 ③）。被取消的 job 结束时，runner 也会清空它。
- 每次运行各建一份的镜像另打专用标签，配上 `CI_PER_RUN_IMAGE_LABEL`，钩子在下一个 job 开始前就删，不等 6 小时（05 章 ⑫）。
- 工具一时改不了的，配 `CI_TMP_GLOBS`，由钩子删 `/tmp` 下的残留（04 章 4.4）。
- 别指望在程序里多捕获几个信号来补救：信号送不到；送到了也只有 10 秒。

排查时用 Worker 日志对账：`_diag/Worker_*.log` 里 `"jobDisplayName"` 后面是 job 名，`Job result after all job steps finish:` 后面是结局，再拿残留文件的创建时间去对。

---

### B. 判断方法上的错误

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

> 结构检查不等于执行检查。「装上了」和「真能用」之间隔着一次真实调用。凡是有「非零退出会产生后果」契约的东西，比如钩子、健康探针、`ExecStartPre`，自检必须用和调用方完全相同的方式执行它一次，不能只检查它存在。

由此推出一条监控选型的原则：

> 存活指标（liveness）永远不能替代产出指标（outcome）。`is-active` 在这 7 天里每次返回的都是正确答案，问题在于检查问的问题本身不对。

现在 ci-health.sh 加了 `jobs=streak=N`（最近连续失败次数），在这次故障的第 3 天就会报 CRIT。补这一条的成本是 15 行 shell。

另外，那次部署的验收恰好在故障开始那天收尾，结论是「已完成，24 PASS 0 FAIL」。验收通过不等于系统可用，当时只测了前者。

门禁放在哪一步也有讲究。2026-10 之前的 bootstrap 先把新钩子覆盖到正式路径，再试跑。`.env` 指向的就是正式路径，runner 每个 job 都现读现跑，所以在已部署的机器上，试跑失败时坏钩子已经生效，「拒绝接线」没有起作用。现在先渲染到 `ci-cleanup.sh.new`，试跑通过后再替换（04 章 4.4）。

#### B11. 告警阈值没对齐设计稳态，也没有送达渠道

`ci-health.sh` 原来的磁盘告警阈值在系统正常状态下就会响，而且告警没有送到任何人。

原阈值是写死的：可用 < 40 GB 报 WARN，< 20000 MB 报 CRIT。

而 BuildKit GC 设的是 Max Used 20 GiB、Min Free 20 GiB：缓存长到 20 GiB 就停。参考机上这时可用空间稳定在约 23 GiB，这就是设计稳态。

结果：

- WARN 从 10-02 起开始出现，10-10 起每小时都响，一个月 309 次。
- CRIT 阈值只比 Min Free（20480 MiB）低 480 MiB，可用空间稍被挤占就会触发。
- 这些告警只写本机 journal，没有接收方。06 章说的心跳告警也从没部署。
- 唯一一次由定时任务产生的「job 连续失败」CRIT（10-08）同样没有送达任何人，而且它本身是误报：它统计的是全仓库的 run，把 GitHub 托管的 PR 标题检查失败也算了进来。日志里另外两次 CRIT 是 09-14 修 A11 时手工测试产生的。
- 改成只统计用到本机的 run 之后，准备加第二台机器时又发现一个问题：几台机器共用标签，同一个 run 的 job 会分到几台上，按 run 的结论算，别的机器上的 job 红了，这台也会报连续失败。现在只看落在本机的 job，按 runner 名匹配。
- 改成按 job 统计后的第一天（2026-10-25），第二台上线时手工试跑 ci-health，第一台报了 CRIT「连续 3 次失败」。查下来那 3 次失败都是 `adal-gate` 这类写了 `if: always()` 的汇总 job：PR 推了新提交，旧 run 被取消，它照样跑，因为分片被取消而判失败。按 run 统计时这些 run 的结论是 cancelled，不算失败；按 job 统计就算进来了。现在被取消的 run 整个跳过。

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

> CI 机上没有「只有 root 能读」这回事。落在这台机器磁盘上的任何东西，都要按「CI job 读得到」来设计。给监控用的凭据，按它真正需要的最小权限单独申请，不要顺手复用手边权限最大的那个。

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

#### B16. 拿 sha256 定长任务比较两台机器的快慢

preflight.sh 原来说它的 sha256 定长任务「跨机可比」，找第二台机器时就拿它比较候选机和现有 runner。读数把差距说大了：Intel Skylake 的候选机没有 SHA 指令扩展，现有的 AMD EPYC 有，sha256 显示 Intel 那台慢约 5 倍，实际单核只慢约 2 倍。

反过来也会错。另一台同为 EPYC 的候选机，sha256 的 p50 是 0.53 秒，现有 runner 是 0.51 秒，只差约 4%，而 Python 循环慢 15–25%，真实的单核算法测试慢 23%。也就是说，sha256 换了机器之后，两个方向都会测偏。

这个测法用来看同一台机器有没有被邻居抢核，仍然有效，因为同一台机器的指令集不会变。跨机器比单核速度，现在用 `machine-check.sh` 的分数，最可靠的是在候选机上回放最慢的 job（02 章 2.7）。

教训：

> 基准测试要像真实负载。两台机器的读数差得很多或者差得很少时，先弄清差异从哪里来，再下结论。

#### B17. 在 CI 机上开发，内核先杀了 CI

参考项目有两天在 CI 机（4 核、约 7.6 GiB、无 swap）上开着 VS Code 远程、Claude Code 和 Codex 开发，出了 11 次全局 OOM。被杀的大多是 CI 的 lint、typecheck，job 以 exit 137 失败。

原因有两层：

- 内存账没算开发工具。VS Code 远程服务端常驻约 4 GB，断线重连后新旧两套扩展进程还会并存一阵。08 章原来写的「2–3 GB」偏低。
- OOM 优先级排反了。runner 设成 800，本意是让 CI 比系统服务先被杀，而 SSH 会话里起来的开发工具是默认的 0。内核按「内存占用 + oom_score_adj × 总内存 ÷ 1000」挑进程，800 在这台机器上相当于给 CI 多算了约 6 GiB，于是 CI 排在了开发工具前面。

开发搬到别的机器之后，没有再出现。

教训：

> 给一个服务调 OOM 优先级时，要把机器上所有大进程放在一起排一遍，不能只和系统服务比。

配置方法见 04 章 4.8，各内存档的取值见 10 章 10.3。

#### B18. 把一台小机器上的实验写成了通用结论

参考项目在第一台 4 核、约 7.6 GiB 的机器上试过同机跑两个 runner 实例，两次分别出了 CPU 不够导致的随机超时和 OOM（02 章 2.1）。手册据此写了「同机加第二个 runner 已被实验证伪」，读起来像是任何机器都不行。

这次实验的条件是：4 核、约 7.6 GiB、workflow 发布固定的宿主端口、清理钩子按一台机器一个 job 写。换成核数和内存更多的机器，端口和清理按 job 隔开之后，结论不一定还成立。现在的写法是：资源上能跑几个按 10 章 10.2 算，要真的跑多个，先满足 10.6 的前提；在那之前扩容就加机器。

教训：

> 实验结论要连同它的条件一起写。

#### B19. 自检脚本把 token 放进了命令行参数

verify.sh 查 GitHub 侧状态时，原来用的是 `curl -H "Authorization: Bearer $GH_TOKEN"`，bootstrap 查 runner 版本和换注册 token 时也是这样。命令行参数对本机所有用户可见（`ps`、`/proc/<pid>/cmdline`），runner 用户和正在跑的 CI job 都看得到。文档里的示例还把 `GH_TOKEN=<token>` 写在命令前面，token 会留在 shell 历史里。列 runner 要求仓库的 Administration 读权限，大家顺手用的往往是注册用的读写 token，泄露的代价更大。

修法：

- token 经标准输入交给 curl（`printf ... | curl -H @-`），不出现在参数里，两个脚本都已经这样改了。
- 示例改成用 `read -s` 输入 token。
- GitHub 侧的在线状态最好在 CI 机以外用 `gh api` 查（07 章 7.1）。
- 从别的机器远程装机、token 经临时文件传进去的，读进环境变量后立刻删掉这个文件，而且要在 runner 启动之前删。runner 一启动就可能在跑 job（A17）。

教训：

> 在 CI 机上，密钥不能进命令行参数和 shell 历史。必须落盘的，用完马上删。能不上 CI 机的就不上。

#### B20. 告警文案替人下了结论

ci-health 原来的磁盘告警写的是「GC 腾不出空间了，是 Docker 以外的东西在吃盘」。这句话背后的假设是 Docker 里的东西都有人管：缓存有 GC，镜像和卷有钩子。参考项目 2026-10-26 那次 CRIT 查下来，可用空间少掉的部分七成在 containerd 里，是被取消的 job 留下的镜像，GC 管不到，钩子要 6 小时后才删（A22）。照着告警去翻 Docker 以外的目录，只能找到三成。

修法：告警只给数据。现在的文案列出 containerd、`/tmp` 和其余部分各占多少，再附排查顺序（08 章 8.2）；采样行多记一个 `tmp=`，事后能对出是哪一部分在涨。

教训：

> 告警文案里写的原因，是写告警那天的假设，不是这一次的事实。告警里只写测到的数，结论留给查的人。

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

- 把 4 个 job 合并成 1 个：三个独立方案都这么建议，论证也对（只有一个 runner 时，job 只排队不并行）。但仿真显示，它带来的排队改善与「修 Dockerfile 层序 + 去 cache」等效（11.7 vs 11.2 分钟），而后者不动一行文档，也不破坏回退时的并行。在提速之上再合并，只多省 2.2–2.6 分钟，不值 10 处文档改动。
- `docker image prune` 是清理主力：实测回收 0 MB。Docker 29 重打同名 tag 不留悬空镜像。原文接着说「主力是 `buildx prune`」，这半句也错了，见 B13：workflow 挂 tmpfs 之前，持续负载下一直在回收的是 `volume prune`；缓存上限靠 GC。
- metadata 泄露 root 口令 = 阻塞项：机制属实，但把口令与 `/etc/shadow` 的 hash 逐位比对后不匹配，是陈旧凭据，因此降级为「高」。判定「凭据泄露」之前，先验证那个凭据还有效。这个降级只对参考项目所用厂商的 metadata 成立。metadata 里有什么因厂商而异，实例绑了云账号的角色或服务账号时，metadata 发的是能直接调云 API 的临时凭据，不能这样降级（04 章 4.5）。
- 零下载的 `docker build` 也扣 Docker Hub 配额：试着复现，没能复现（6 次操作计数一格未动）。记录在案，但不采纳。

---

## 10 按机器规格定参数

本章回答两个问题：一台机器跑几个 runner 实例；装机时和规格有关的几个参数（`RUNNER_MEM_MAX`、`RUNNER_OOM_ADJ`、BuildKit 的三个值、磁盘告警阈值）按这台机器的核数、内存和盘怎么取。

做法是先在机器上量几个数，再套公式。文中的推荐值按参考项目的 job 算，你的 job 不一样，结果也会不一样，量法和公式是通用的，不挑云厂商，裸金属也一样。

本章用两个记号：

- N：全仓库的 runner 实例总数，所有机器加起来算，也就是同时最多能跑几个 job。要几个用 08 章 8.1 的仿真按排队估。
- k：一台机器上的实例数。本章的公式算的是 k。

每台机器各自套公式，参数存在各自的 `/etc/ci-runner.env` 里。不要在机器之间拷这个文件（03 章 3.6）。

> 注意：现有脚本和参考项目的 workflow 每台机器只支持一个实例。公式算出 k 大于 1，只说明这台机器的资源够；要真的跑多个，先满足 10.6 的前提。在那之前，提高并发就加机器（08 章 8.7）。

### 10.1 先量哪些数

| 记号 | 是什么 | 怎么量 | 参考项目 |
|---|---|---|---|
| T | 总内存，系统里看到的 MemTotal，比厂商标的数小一点。差多少各厂商不同（有的标 GB，有的标 GiB，内核还会预留一部分），一律用自己机器的 MemTotal | `grep MemTotal /proc/meminfo` | 约 7.6 GiB（标 8 GB） |
| S | 系统自己占的内存：没有 job、没有开发会话时，T 减去可用内存。镜像里预装的厂商监控、安全代理也算在这里 | 空闲时执行 `free -m`，T 减去 available 那一列 | 约 0.5 GiB（估算） |
| J | 一个 job 的整机峰值：最重的 job 让整机可用内存少了多少，含它起的容器、tmpfs 和 docker build | sysmon.sh，见下文 | 取 6 GiB |
| C | 一个 job 用几个核：最重的 job 运行时平均忙几个核，向上取整 | step.sh 或 sysmon.sh，见下文 | 约 3.7 核，取 4 |
| P | runner 进程树的峰值，不含容器，用来定 `RUNNER_MEM_MAX` | step.sh，或者读 memory.stat，见下文 | 约 3.7 GB |
| Q | 和进程树峰值同时存在的容器占用，主要是 services 容器 | 读 memory.stat，见下文 | 约 0.6 GiB（估算） |
| D | 开发工具占的内存：VS Code 远程服务端、Claude Code、Codex 等。不在这台机器上开发就是 0 | 见下文 | 一个人开发按 4–5 GiB |

磁盘相关的几个数（缓存工作集、Docker 以外的增长、单 job 临时写盘）放在 10.4。单核速度不影响 k，但影响每个 job 的超时余量，见 02 章 2.7。

#### J：用 sysmon.sh 记整机可用内存

J 要按整机量。runner 单元的 `MemoryMax` 只管 runner 进程树。CI 起的容器挂在 `system.slice/docker-<id>.scope` 下，docker build 的 RUN 步骤由 dockerd 执行，都不在 runner 的 cgroup 里（04 章 4.3），只看 runner 的内存峰值会低估。

在已经装好、能接 job 的机器上（还没有任何自建机器时见代码块后面的说明）：

```bash
free -m          # 先在空闲时记下 available 那一列，记作 A0（MiB）
nohup bash scripts/analysis/sysmon.sh /var/tmp/sysmon.csv >/dev/null 2>&1 &
# 让完整的 CI 跑几轮，最重的几个 job 都要跑到，然后停掉采样：
pkill -f analysis/sysmon.sh
awk -F, 'NR>1{print $11}' /var/tmp/sysmon.csv | sort -n | head -1    # 全程最低可用（MiB），记作 A1
```

J = A0 − A1，S = T − A0。

- sysmon.sh 每 5 秒记一行，短暂的低点可能漏掉，算出的 J 会偏小一点。10.2 的余量要留足。
- 量的时候机器上不要开开发工具，否则它们的占用会混进 S 和 J。开发工具单独量。
- 多台机器共用一套标签时，job 会分到各台。sysmon 要多跑一阵，确认最重的 job 在这台机器上跑过（08 章 8.7 有按机器统计 job 的查询）。

还没有任何自建机器时，J 要先有一台机器才量得出来。先按 10.5 里接近的档位开一台候选机，跑 `bootstrap.sh --skip-runner`。按 02 章 2.7 第 4 步回放最重的 job 时同时开着 sysmon.sh，services 容器按 workflow 里的参数用 `docker run` 起好，docker build 也照跑，这样量出的就是 J。再用 10.2 核对这一档够不够，不够就换一档重开。

参考项目的 J 是这样来的：2026-09-14 在 7.57 GiB 的机器上完整跑了一遍 ci.yml（含两次 docker build），整机可用内存最低 1339 MB。按 S 约 0.5 GiB 算，最重的 job 约 5.8 GiB，取 6 GiB。当时机器上是否开着开发工具已经确认不了，所以这个值偏保守。早先按「进程树 + 服务容器 + 系统」加出来的 4.8 GiB 漏了 docker build（02 章 2.1）。

#### C：一个 job 用几个核

用 step.sh 跑最重的 job 的各个步骤（02 章 2.1），结果文件 `steps.psv` 的第 5 列是核秒除以墙钟，也就是这一步平均忙几个核。也可以从上面的 sysmon.csv 算：这个 job 运行期间，每行的 (100 − 第 5 列 − 第 6 列) × 核数 ÷ 100，就是那 5 秒里忙的核数。

C 要在目标机器上量。测试框架和打包工具的 worker 数默认跟着核数走，换到 8 核的机器上，同一个 job 可能用更多的核，内存也跟着涨。量之前先把 worker 数写死（比如 Jest 的 `--maxWorkers`），4 核和 8 核机器上量出的数才能比，按 C 分核也才靠得住。参考项目在 4 核机器上量的是单 job 3.3–3.7 核，基本用满了 4 个核。

#### P 和 Q：读 memory.stat

P 可以用 step.sh 的峰值（02 章 2.1），也可以在最重的 job 运行期间读 runner 单元的 memory.stat。

- step.sh 读的是 ci.slice 的 memory.current，里面含页缓存：这一步自己读写文件产生的，加上前几步留下、还没回收的。所以它比只算 anon 和 shmem 略大，拿来定 10.3 的下限偏保守。
- 要精确就读 memory.stat，只取 anon 和 shmem（含 tmpfs）两项，不算页缓存，页缓存在内存紧张时可以回收。
- `systemctl show -p MemoryPeak` 和 ci-health 记的 `mem_peak` 也含页缓存，而且 runner 服务启动以来前面各个 job 留下的页缓存都算在里面，偏得更多，不能直接拿来定 `RUNNER_MEM_MAX`。参考机上 MemoryPeak 读到 5.6 GB，step.sh 量的进程树峰值约 3.7 GB。

下面每 2 秒记一行：时间、runner 进程树（MiB）、全部 CI 容器合计（MiB）。在 tmux 或 screen 里跑，断线不受影响，最重的 job 跑完后按 Ctrl-C 停：

```bash
U=$(basename "$(ls /etc/systemd/system/actions.runner.*.service | head -1)")
G=/sys/fs/cgroup/system.slice
m(){ awk '$1=="anon"||$1=="shmem"{s+=$2} END{print int(s/1048576)}'; }
while sleep 2; do
  echo "$(date +%T) $(m < "$G/$U/memory.stat") $(cat "$G"/docker-*.scope/memory.stat 2>/dev/null | m)"
done >> /var/tmp/ci-mem.log
```

取数：`sort -k2,2n /var/tmp/ci-mem.log | tail -1` 是进程树最大的那一行，第 2 列就是 P。`sort -k3,3n /var/tmp/ci-mem.log | tail -1` 是容器最多的时候，Q 取它的第 3 列，偏保守。

#### D：开发工具占多少

不在 CI 机上开发，D 就是 0。一定要在上面开发时，先按人头估：

| 工具 | 每人按多少算 | 参考项目实测 |
|---|---|---|
| VS Code 远程（含扩展里的 TS 服务、Pylance、Claude 扩展） | 4 GiB | 约 3–4.3 GiB；断线重连后，新旧两套扩展进程会并存一阵 |
| 只在终端里用 Claude Code、Codex | 1–2 GiB | 没有单独量过 |
| 套了 `systemd-run` 内存上限的命令行工具 | 按它的上限算 | Codex 限 1G（04 章 4.8） |

再实测核对。开发用户的进程都在 `user-<uid>.slice` 下，开着平时用的工具、没有 job 的时候读几次，取最大值：

```bash
awk '$1=="anon"||$1=="shmem"{s+=$2} END{printf "%.1f GiB\n", s/2^30}' \
  /sys/fs/cgroup/user.slice/user-$(id -u <开发用户>).slice/memory.stat
```

参考项目一个人开发时 D 按 4–5 GiB 算：VS Code 远程 4 GiB，加上限 1G 的 Codex。

### 10.2 每台几个实例 k

```text
按内存：k_mem = 向下取整((T − S − D − 余量) ÷ J)     余量 = max(1 GiB, T × 10%)
按 CPU：k_cpu = 向下取整((核数 − 开发用核) ÷ C)      有人在这台机器上开发时开发用核按 2 算，没人开发时为 0
k = min(k_mem, k_cpu)
```

10.6 的前提都满足之前，每台按 1 个部署。k = 0 说明这台机器跑不了这套 CI 最重的 job，要么换机器，要么把开发工具搬走。

几点说明：

- 余量留给内核、页缓存的最低需要和 sysmon 漏掉的尖峰。没有 swap 的机器内存一超就是 OOM kill，这部分不能省。
- 开发用核按 2 算，对应 04 章 4.8 给 Codex 限的 `CPUQuota=200%`。
- 会把核用满的 job，同机跑多个实例之前要先给每个实例限定核数（容器的 `--cpus`、测试框架的 worker 数），再按限定后的条件重新量 C 和耗时。
- k 是一台机器的资源上限。全仓库要几个实例（N）是另一个问题，用 08 章 8.1 的仿真按排队算。

拿参考项目核对：4 核、约 7.6 GiB、不在上面开发时，k_mem = 向下取整((7.6 − 0.5 − 0 − 1) ÷ 6) = 1，k_cpu = 向下取整(4 ÷ 4) = 1。参考项目在这台机器上试过同机跑两个实例，两次分别撞上 CPU 不够和 OOM（02 章 2.1），和公式的结果一致。

### 10.3 RUNNER_MEM_MAX 与 RUNNER_OOM_ADJ

#### RUNNER_MEM_MAX

它是 runner 单元的 `MemoryMax`，防的是一个失控的 job 拖垮整机（04 章 4.3）。它只管 runner 进程树，不管容器。

```text
下限 = 1.3 × P                  低于下限，正常的 job 也会撞上自己的上限被杀
上限 = (T − S − D) ÷ k − Q      高于上限，失控的 job 还没撞上自己的上限，整机就先触发全局 OOM
```

下限向上取整到 G。下限高于上限说明内存不够，要减 k、把开发工具搬走，或者换大内存的机器。

这个值只跟 job 有关，大内存的机器上不用调大。参考项目取 6G：P 是 3663 MB，下限约 4.7 GiB；上限 = 7.6 − 0.5 − 0 − 0.6 = 6.5 GiB。10.5 表里能跑的各档，6G 都在范围内。

#### RUNNER_OOM_ADJ

机器只跑 CI 时用默认值 800。

机器上有开发工具、又要它们比 CI 先被杀时，先按 04 章 4.8 把开发会话设成 1000，再按 04 章 4.3 的式子调低 runner 的值：

```text
(1000 − RUNNER_OOM_ADJ) ÷ 1000 × T > RUNNER_MEM_MAX
也就是 RUNNER_OOM_ADJ < 1000 × (1 − RUNNER_MEM_MAX ÷ T)，再往下取整到百
```

有 swap 时，T 按内存加 swap 算。单个 CI 进程最多涨到它所在实例的 `RUNNER_MEM_MAX`，所以 k 大于 1 时这个式子照样成立。

`RUNNER_MEM_MAX=6G` 时各档的取值。表里「系统里看到的内存」是按参考项目所用厂商（Hetzner Cloud）的机器给的 MemTotal，别的厂商同一档可能差几百 MiB，用你自己机器的值代进式子：

| 机器 | 系统里看到的内存 | 式子给的上限 | 有开发工具时取 | 只跑 CI 时取 |
|---|---|---|---|---|
| 8 GB | 约 7.6 GiB | 约 210 | 200 | 800 |
| 16 GB | 约 15.2–15.6 GiB | 约 605–615 | 600 | 800 |
| 32 GB | 约 31 GiB | 约 806 | 800 | 800 |

比上限小的值也满足这个式子，比如参考项目在一台 16 GB 的候选机上试装时设的是 200。

这个式子只决定先杀谁。CI 加开发工具放不下时，调了它也只是每次 OOM 改成先杀开发工具，内存够不够要按 10.2 把 D 算进去。CI 起的容器不继承这个值，docker 默认给 0，见 04 章 4.3。

#### 开发工具的上限和 swap

开发工具里吃内存的命令行工具，按 04 章 4.8 用 `systemd-run` 套上限。上限不超过全量 CI 期间整机最低可用内存减 0.3 GiB。参考项目 8 GB 的机器上最低可用约 1.3 GiB，所以取 1G；按参考项目的 job 推算，16 GB 的机器可以给到 2G。你的机器用自己量到的最低可用内存来定。

CI 机建议不开 swap。内存一超直接 OOM kill，job 很快失败，比换页拖到超时好查（02 章 2.2）。有没有 swap 要先看一眼：云镜像多数默认不带；用发行版安装盘装的系统（裸金属常见）通常默认带 swap 分区或 swap 文件。用 `swapon --show` 查，不想要就 `swapoff -a`，再注释掉 /etc/fstab 里对应的那一行。

机器上有开发工具时，可以考虑加 2–4 GB swap，让开发工具闲着的内存换出去，同时给 runner 单元加 `MemorySwapMax=0`，让 CI 自己不用 swap。bootstrap 不写这一项，要手动加 drop-in。这个组合参考项目没有实测过，用之前先在空闲时验证。不管是自己加的还是系统默认带的，有 swap 时上面式子里的 T 都按内存加 swap 算。

### 10.4 BuildKit 与磁盘阈值

这几个数要上线一段时间才量得出来：

| 记号 | 是什么 | 怎么量 |
|---|---|---|
| W | 构建缓存工作集：BuildKit 缓存稳定下来的大小 | 上线一周后看 `docker system df` 的 Build Cache 行 |
| G | Docker 以外每月增长 | `ci-health.log` 里「可用 + containerd」之和每月减少多少（08 章 8.2） |
| F | 固定占用：系统与工具链、在用镜像、工作区，再加一个月的 G | 已用空间减去 Build Cache，再加 G |
| 单 job 临时写盘 | node_modules、构建产物、新镜像 | step.sh 输出的 `disk=`，或者 job 前后各看一次 `df` |

还没有数据时，W 按 20 GB、G 按每月 6 GiB 起步，F 按 25 GB 估（参考项目清理后约 19 GB，加一个月的增长）。这些是参考项目的值，当时机器上还有开发工具，CI 专用机通常小一些。一台跑 k 个实例时，工作区要按 k 份算（`du -sh <RUNNER_HOME>/_work` 看一份多大），镜像和 BuildKit 缓存是共用的。

```text
Min Free = 盘总量 × 20%，不低于 20 GB，不高于 40 GB
Max Used = min(2 × W, 盘总量 − F − Min Free − 10 GB)
Reserved = min(10 GB, Max Used ÷ 2)
检查：Max Used ≥ W；Min Free ≥ k × 单 job 临时写盘 + G
```

- Max Used 小于 W 时，GC 会反复驱逐还在用的缓存，构建退回冷构建（02 章 2.6）。这时要么换大盘，要么先按 08 章 8.4 修 Dockerfile 的层序，把 W 降下来。
- Max Used 取 W 的 2 倍，是给换 lockfile 前后的两套依赖层都留出位置。盘再大，也不用超过这个数。
- 公式里减去的 10 GB 是余量，让稳态可用空间停在 Min Free 之上，免得一上线就贴着告警线。
- 被取消的 job 留下的镜像和 `/tmp` 目录没算在 G 里。它跟着取消次数走，量 G 的时候如果它也在涨，G 会被高估；该做的是配清理钩子把它清掉（04 章 4.4、09 章 A22），不是把盘按它放大。

磁盘告警阈值：

```text
CI_DISK_WARN_MB = Min Free 换算成 MiB + 1024                    bootstrap 按 BUILDKIT_MIN_FREE 自动算
CI_DISK_CRIT_MB = max(10240, 2 × k × 单 job 临时写盘（MiB）)     默认 10240，要改就显式传
```

按盘大小查（W = 20 GB，F = 25 GB，k = 1）。表里的盘总量指 Docker 数据所在的那块盘。有的厂商默认系统盘只有几十 GB 甚至更小，建机时改大，或者另挂数据盘放 Docker。脚本按 Docker 数据在根分区上写，分开放的见 02 章 2.9 表下的说明。

| 盘总量 | Reserved | Max Used | Min Free | CI_DISK_WARN_MB | 说明 |
|---|---|---|---|---|---|
| 40 GB | 不适用 | 不适用 | 不适用 | 不适用 | 跑 docker build 的 CI 不推荐：F 加 Min Free 已经超过盘总量 |
| 75 GB | 10GB | 20GB | 20GB | 21504 | 参考项目第一台，也是 bootstrap 的默认值。这是下限：机器上留过开发工具时，一个多月后可用空间就会挤到 Min Free 附近，要靠每月巡检（08 章 8.6）清理 |
| 150 GB | 10GB | 40GB | 30GB | 31744 | 参考项目在一台 150 GB 盘的候选机上用的就是这组值 |
| 300 GB | 10GB | 40GB | 40GB | 41984 | 缓存上限由 W 决定，盘大了不用跟着调 |

`CI_DISK_CRIT_MB` 在这几档都是默认的 10240。

在已部署的机器上改 BuildKit 参数：先等机器空闲，`systemctl stop` 停掉 runner 服务，再带上新的 `BUILDKIT_*` 重跑 bootstrap。daemon.json 有变化时 bootstrap 会重启 docker，最后会重新启动 runner（04 章 4.1）。`CI_DISK_WARN_MB` 第一次算出来以后就落盘到 `/etc/ci-runner.env`，重跑时读回旧值，不会按新的 Min Free 重算。所以改 `BUILDKIT_MIN_FREE` 时，要么同时显式传新的 `CI_DISK_WARN_MB`，要么先把 env 文件里那一行删掉。

`CI_FIXEDWORK_BASELINE` 不按规格算。它是每台机器自己跑 `preflight.sh --with-load` 得到的 p50，各测各的，不能抄别的机器，也不能拿来比两台机器的快慢（02 章 2.5）。

### 10.5 推荐表

下表按参考项目的 job 算：J = 6 GiB，C = 4，S = 0.5 GiB，Q = 0.6 GiB，`RUNNER_MEM_MAX` 取 6G。有一个人在机器上开发时，D 按 5 GiB 算（VS Code 远程 4 GiB，加上限 1G 的 Codex），开发用核按 2。内存按系统里看到的 MemTotal 算，都不开 swap。

| 规格 | 有人在上面开发 | k_mem | k_cpu | 资源上的 k | 现在部署 | RUNNER_MEM_MAX | RUNNER_OOM_ADJ | 结论 |
|---|---|---|---|---|---|---|---|---|
| 2 核 / 4 GB（约 3.8 GiB） | 否 | 0 | 0 | 0 | 不适用 | 不适用 | 不适用 | 不推荐：放不下一个约 6 GiB 的 job |
| 4 核 / 8 GB（约 7.6 GiB） | 否 | 1 | 1 | 1 | 1 | 6G | 800 | 可用，参考项目用的就是这一档。完整跑一遍 CI 时整机最低只剩约 1.3 GiB，没有余地再放别的 |
| 4 核 / 8 GB | 是 | 0 | 0 | 0 | 不适用 | 6G | 200 | 不推荐：参考项目在这一档上开发了两天，出了 11 次全局 OOM（09 章 B17） |
| 8 核 / 16 GB（约 15.2–15.6 GiB） | 否 | 2 | 2 | 2 | 1 | 6G | 800 | 资源上够跑 2 个。现有脚本和参考项目的 workflow 每台只支持 1 个，满足 10.6 的前提后才能跑 2 个 |
| 8 核 / 16 GB | 是 | 1 | 1 | 1 | 1 | 6G | 600 | 要在 CI 机上开发时，这是最小的规格 |
| 16 核 / 32 GB（约 31 GiB） | 否 | 4 | 4 | 4 | 1 | 6G | 800 | 资源富余。不满足 10.6 的前提时只能跑 1 个，多出来的资源只能让 job 里多线程的步骤快一点 |
| 16 核 / 32 GB | 是 | 3 | 3 | 3 | 1 | 6G | 800 | 同上 |

表下说明：

- 「资源上的 k」大于 1 只说明资源够。「现在部署」是现有脚本能做到的数。
- 表里只列了 CPU 和内存 1:2 的规格，括号里的 GiB 也是按 Hetzner Cloud 的机器给的 MemTotal。别的配比（比如 1:4）和别的厂商，按 10.2 用自己机器的数重算。
- 「核」指系统里看到的 vCPU 数（`nproc`）。有的厂商一个 vCPU 是一个超线程，同样标 4 核，物理核可能只有一半，C 要在这台机器上重量（02 章 2.9）。
- 开发工具里的命令行工具，按参考项目的 job，8 GB 的机器上限取 1G，16 GB 及以上可以给到 2G。你的机器按 10.3 用自己量到的最低可用内存定。
- 盘按 10.4 的表另外查。
- job 轻的项目（单 job 整机峰值不超过 2 GiB、用核不超过 2、不跑 docker build）按同样的公式重算：2 核 / 4 GB 能跑 1 个，4 核 / 8 GB 资源上够跑 2 个。

#### 参考项目的选择

参考项目定下的做法是两台 4 核 8 GB 的机器，每台一个实例。第一台在跑，第二台按同样的规格再买。考虑的是三点：

1. 单核速度。核多帮不了单核受限的 job（02 章 2.7）。参考项目开到的一台 8 核 16 GB 候选机，把真实的单核算法测试跑了一遍，比现有 runner 慢 23%。不管买哪种规格，单核都要先和现有机器比过。
2. 每台只能跑一个实例时，一台 8 核 16 GB 同时也只跑一个 job，排队不会比一台 4 核 8 GB 短。两台 4 核 8 GB 的核数和内存加起来和它一样，却能同时跑两个 job，排队更短。
3. 一台出问题，另一台照样接 job。

以后要换成一台大机器跑多个实例，按 10.6 的路线走。

### 10.6 一台多实例的前提（扩容路线）

现有脚本和参考项目的 workflow 都按每台机器一个实例写。一台机器上跑不了多个实例，原因有两个：

- 参考项目的 workflow 给 services 容器和步骤里 `docker run` 起的容器发布了固定的宿主端口（127.0.0.1 上的 5433、6379、9000），e2e 在宿主上起的进程也用固定端口（3100、3101）。两个实例同时跑，后起的那个会撞端口（02 章 2.3）。
- 清理钩子按一台机器一个 job 写。它删全部带 CI 标签的容器、对 `CI_APP_PORTS` 执行 `fuser -k`、执行不带过滤的 `docker volume prune`，这些都是整机范围的。为了不误伤别的 job，它发现本机有不止一个 job 在跑时就整段跳过（04 章 4.4）。所以多实例下它不会误删，但清理基本不跑。去掉这道守卫又不改清理范围，才会删掉另一个 job 的容器、杀掉它的进程。

#### 前提

同机跑 k 个实例之前，下面每一条都要满足：

1. workflow 不占固定的宿主端口。做法有两种：job 跑在容器里，services 不发布端口，按服务名访问；或者发布到随机端口，比如 `ports: ['127.0.0.1::5432']`，再从 `${{ job.services.postgres.ports['5432'] }}` 读实际端口。随机端口的写法参考项目没有实测过。e2e 在宿主上起的进程也要按实例分开端口，或者在运行时挑空闲端口（05 章 ②、⑨）。
2. 清理钩子只动自己这个 job 的东西。容器按实例或按 job 打标签，只删自己的；端口按实例分；卷按标签清，或者 workflow 挂 tmpfs 不产生卷（05 章 ⑫）。
3. 每个实例有自己的 `RUNNER_HOME`、`RUNNER_NAME`、systemd 单元和 `MemoryMax`，脚本能按实例分别安装、检查和监控（见下表）。
4. 按 10.2 算出的 k 不小于要跑的实例数。会把核用满的 job，先给每个实例限定核数。盘按 k 份工作区重算（10.4）。
5. 测试里没有写死的短超时（比如 Jest 默认的 5000 ms），或者已经按 k 个实例并发时的耗时放宽。参考项目同机跑两个实例时的第 1 次失败就是这种（02 章 2.1）。每个 job 都按 02 章 2.7 乘上争核系数 M 核过超时余量。
6. 改完后让 k 个完整的 CI run 同时跑，至少三轮，没有随机红叉、没有 OOM。

脚本要改的地方如下。这里只列范围，没有实现，也没有验证过：

| 文件 | 现状 | 多实例要改成 |
|---|---|---|
| `bootstrap.sh` | `RUNNER_NAME`、`RUNNER_HOME` 各只有一个；服务单元取第一个；钩子、`ci-cleanup.service`、`ci-health.sh` 都按一个实例渲染；`/etc/ci-runner.env` 只存一套参数 | 按实例循环注册、装服务、写 override 和 `.env`；参数按实例存 |
| `ci-cleanup.sh` | 本机 job 数大于 1 就跳过；删全部带 CI 标签的容器；按端口 `fuser -k`；卷不带过滤 | 只删本实例或本 job 的容器；端口按实例分；卷按标签清 |
| `ci-health.sh` | 只有一个服务名、一个 runner 名 | 逐个实例采 `mem_peak` 和服务状态；连续失败按本机所有实例的名字统计 |
| `verify.sh` | 只查第一个服务单元，多于一个时打一行提示 | 逐个实例检查 |
| workflow | 端口固定 | 见前提第 1、2 条 |

#### 加机器还是同机多实例

两条路各有代价：

- 加机器：脚本和 workflow 都不用改，一台挂了其他台照常接 job。代价是每台要单独装、单独监控，构建缓存各存一份，新机器第一次构建是冷的。
- 同机多实例：镜像和 BuildKit 缓存共用。代价是要先改 workflow、清理钩子和脚本；一台机器挂了，上面的实例一起停。

#### 扩容路线

分三个阶段。每个阶段写了做法和什么时候考虑下一步，条件到了再动，不用提前做。

阶段一：每台机器一个实例。参考项目现在在这个阶段：第一台 4 核 8 GB 在跑，计划再加一台同规格的，每台一个实例。

- 做法：要更多并发就加一台机器。新机器的单核分数要和现有机器比过（03 章 3.0、02 章 2.7），步骤见 08 章 8.7。
- 什么时候考虑阶段二：机器多到每台单独装机、单独监控、构建缓存各存一份成了负担，或者想用一台大机器换下几台小机器。

阶段二：改 workflow、清理钩子和脚本，仍然每台一个实例。

- 做法：满足前提第 1、2、3 条。改完的 workflow 和钩子先在现有机器上跑一段时间，每台还是一个实例，行为和改之前应该一样。
- 什么时候考虑阶段三：现有机器上跑了一段时间没有新问题，前提第 4、5 条也满足。

阶段三：一台大机器跑 k 个实例。

- 做法：k 按 10.2 算。大机器的单核同样要先和现有机器比（02 章 2.7）。它可以和小机器混用，标签相同，GitHub 会把 job 派给空闲的实例。
- 上线条件：按前提第 6 条做完并发实验再接真实 job。上线后出现随机红叉或 OOM，就把 k 降回 1，查清原因再加。

### 10.7 上线后看哪些数、什么时候复核

上线后头两周，每天看一次下面这几项：

| 看什么 | 怎么看 | 正常 | 不正常时 |
|---|---|---|---|
| 全局 OOM | `journalctl -k --since -1d \| grep 'Out of memory: Killed'` | 0 次 | J 或 D 估小了，或者 k 定大了，按 10.1 重新量 |
| runner 撞上自己的上限 | runner 单元 cgroup 下 `memory.events` 里的 `max` 和 `oom_kill` | 都不涨 | `max` 在涨，说明进程树顶到了上限，在靠回收页缓存撑着；`oom_kill` 在涨，说明 job 被杀了，看 P 是不是变大了 |
| 容器撞上自己的上限 | 内核日志里 `oom_memcg=` 指向 `docker-<id>.scope` 的记录 | 没有 | 容器自己的 `--memory` 设小了。这归 workflow 管，和机器规格无关 |
| `mem_avail` | `ci-health.log`，每小时一个快照 | k 个 job 在跑时也不低于 10.2 的余量 max(1 GiB, T × 10%) | 快照只记整点那一刻，通常比真实的最低值高，所以快照里出现低值就要查 |
| `mem_peak` | `ci-health.log`，runner 进程树自上次启动以来的峰值 | 含页缓存，接近 `RUNNER_MEM_MAX` 不一定有问题 | 以 `memory.events` 的 `oom_kill` 为准 |
| `fixedwork` | `ci-health.log`，定长任务耗时 | 不超过基线的 1.4 倍 | 邻居在抢核，或者突发性能规格的 CPU 积分用完了（08 章 8.3）；k 大于 1 时也可能是自己的 job 占满了核，说明 k 定大了 |
| `root_avail`、`containerd`、`volumes` | `ci-health.log`（08 章 8.2） | `containerd` 涨到 Max Used 加镜像后停住；`volumes` 接近 0 | 见 08 章 8.2 |
| job 耗时 | 02 章 2.7 的 gh 查询 | 每个 job 都满足超时余量 | 先查 R 是不是变了 |

出现下面任一情况，就按 10.1 重新量一遍，再套公式：

- workflow 加了重的 job 或步骤（新的 docker build、e2e、更大的测试容器），或者 Node、TypeScript、测试框架升了大版本；
- 测试框架或打包工具的 worker 数改了；
- 机器上开始有人开发，或者不再有人开发；
- 换盘、扩盘，或者按 08 章 8.4 修完 Dockerfile 后 W 变了；
- 重启或迁移后，`lscpu` 显示的 CPU 型号变了（有的云上关机再开或厂商迁移会换宿主机）。这时 preflight 基线和单核分数也要重测（08 章 8.3）；
- 排队等待的 p90 超过了单个 run 的时长（08 章 8.5）。

每月巡检（08 章 8.6）时顺便核对一次：`/etc/ci-runner.env` 里的参数，和按本章公式算出来的值是否还一致。

---

## 附：脚本清单

| 脚本 | 作用 |
|---|---|
| `scripts/machine-check.sh` | 新机器一分钟测硬件和单核速度，和现有 runner 比，判合格 / 有保留 / 不合格。只读，只要 python3 |
| `scripts/hetzner-pick.py` | 只适用于 Hetzner Cloud：自动开机、跑 machine-check，不合格就删掉，随机等几分钟再开，直到开到合格的。只删自己开的机器。别的厂商照 02 章 2.7 第 2 步的三条规则自己写 |
| `scripts/preflight.sh` | 候选机自检：硬件下限、端口、时间同步、网络、CPU 争抢，输出 GO / NO-GO。只读 |
| `scripts/bootstrap.sh` | 装机、注册、加固，可以重复跑。`--harden-ssh` 才改 SSH，`--skip-runner` 跳过注册 |
| `scripts/verify.sh` | 装完或重启后自检，输出 PASS / FAIL 表。会试跑一次清理钩子，有 job 在跑时这一项自动跳过 |
| `scripts/ci-cleanup.sh` | 清理钩子，由 bootstrap 装到 runner 的 `hooks/` 目录 |
| `scripts/ci-health.sh` | 每小时健康采点，由 bootstrap 装到 `/usr/local/bin/` |
| `scripts/ssh-guard.sh` | SSH 加固的安全网：一条 SSH 会话都不剩时才回滚配置（04 章 4.6） |
| `scripts/analysis/` | 调研期的测量工具：连通性采样、排队仿真、单步资源画像、整机内存采样 |

现在的脚本一台机器只装一个 runner 实例。同机多实例的前提见 10 章 10.6。

## 附：脚本验证到什么程度

| 场景 | 怎么验证的 | 结果 |
|---|---|---|
| `bootstrap.sh` 在已配置的机器上重跑 | 第一台完整重跑（2026-09） | 通过，退出码 0，12 项关键状态逐字节相同 |
| `bootstrap.sh` 从零安装工具链 | 干净的 `ubuntu:24.04` 容器 | 通过，docker、node、gh、psmisc 都能从零装上 |
| `bootstrap.sh --skip-runner` 从零安装 | 全新的 Ubuntu 24.04 云主机 | 2026-10-19 第一次跑出几处问题（09 章 A15–A17），已修；修复后 10-19 和 10-25 各跑通一次，退出码 0 |
| 全新机器上的注册和 `verify.sh` | 第二台 runner（全新 Ubuntu 24.04，2026-10-25） | 注册后立刻接到排队的 job；`verify.sh` 33 PASS，0 FAIL |
| `machine-check.sh` | 在现有 runner 和三台候选机上实跑 | 两台 Intel Skylake 是现有 runner 的 1.7–1.9 倍，判不合格；一台 AMD EPYC-Rome 1.16 倍，判合格 |
| `hetzner-pick.py` | 模拟的 Hetzner API 加一台真机（真实 SSH 和验机） | 合格停止、不合格删除、机房开不出来时换机房、随机等待、Ctrl-C / SIGTERM / SIGHUP 时清理，都按预期 |
| `preflight.sh` | 第一台实跑 | 13 PASS，2 WARN |
| `verify.sh` | 第一台实跑（2026-10-16 重启后） | 34 PASS，0 FAIL |
| `ci-cleanup.sh` / `ci-health.sh` | 以 runner 用户实跑 | 通过 |

上表的真机都在同一家厂商（参考项目用的 Hetzner Cloud）上，别的厂商没有实测过。实跑用的都是 2026-10-25 这一轮修订之前的脚本。这一轮的修改（等 apt 锁、检查架构、`RUNNER_UID`、token 经标准输入传给 curl、verify 和 ci-health 从 `/etc/ci-runner.env` 读回参数等）还没在机器上整体跑过。

## 附：手册没覆盖、需要你自己做的三件事

1. 配入方向的防火墙（04 章 4.7）。云上用厂商的云防火墙或安全组，在控制台或厂商的 API 里配，bootstrap 管不到。Docker 会自己写 DNAT 规则，绕过宿主机的 ufw，所以只开 ufw 不够。厂商没有云防火墙、或者用的是裸金属时，按 04 章 4.7「没有云防火墙时」做。
2. 撤销注册用的 PAT（03 章 3.4）。注册 runner 用的 registration token 是一次性的，但用来换取它的那个 PAT 不是，用完要撤销。
3. 配心跳告警（06 章 6.4 ①）。bootstrap 不装它。机器宕机或断网时 ci-health 也跟着停了，只有外部的心跳服务能发现。有几台机器就建几个检查。
