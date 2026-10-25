# analysis/：调研期的测量工具

这些脚本不是部署需要的，是当初做可行性核验时用来产生实测数字的。换机器时通常用不到；要重新论证「这台机器够不够」「一台跑几个实例」「要不要合并 job」「排队会不会爆」时，可以省掉重新造轮子的时间。

下面的命令都在仓库根目录运行。几个采样脚本默认把结果写到 `./data/`，先 `mkdir -p data`，或者用 `CI_DATA_DIR` 指定别的目录。

| 脚本 | 干什么 | 什么时候用 |
|---|---|---|
| `netprobe.sh` / `netprobe6.sh` | 按端点采样 connect / TTFB，输出 CSV（v4 / v6 两版） | 要长时间、大样本的连通性数据时（`preflight.sh` 只做 12 样本的快检） |
| `netstats.py` | 宽口径统计（收到任何 HTTP 响应都算成功） | 一般不用，留着对照 |
| `netstats2.py` | 严格口径（5xx 计为失败），并定位阵发故障 | 推荐用这个。宽口径会把 504 算成成功，看不见短时故障 |
| `queue_sim.py` | 排队仿真：喂真实 run 的时间戳和各 workflow 的 concurrency 语义 | 要不要合并 job、能不能加检查时用这个，别套 ρ=λS。限制见下文 |
| `step.sh` | 把一条命令放进单独的 cgroup 里跑，记墙钟、内存峰值、CPU 核秒、磁盘增量 | 量 runner 进程树的峰值，用来定 `RUNNER_MEM_MAX`。不含容器，见下文 |
| `sysmon.sh` | 每 5 秒记一行 CPU、内存、磁盘 | 量单 job 的整机峰值 J（10 章 10.1）；跑压测时并行开着 |
| `stealtest.sh` | 全核满载，同时采 steal | 先用 `preflight.sh` 确认这台机器的 steal 能观测到，否则采到的全是 0，没有意义。需要先装 `stress-ng` |

## queue_sim.py 怎么用

```python
import sys; sys.path.insert(0, 'scripts/analysis')
from queue_sim import ts, simulate
# events: [(datetime, workflow_name, branch), ...]
# svc:    {workflow_name: 服务时长秒数}
r = simulate(events, svc)
# r['waits'] 是每个跑完的 run 的排队等待秒数（已排序）
```

事件流从 GitHub API 拿：`/repos/{owner}/{repo}/actions/runs?per_page=100`，取 `created_at`、`name`、`head_branch`。

两处限制：

- 它只模拟一个 runner。要比较全仓库 1 个和 2 个 runner 的差别，先把 `simulate()` 改成多个 runner 同时从队列取活。
- workflow 的名字和 concurrency 规则是按参考项目写死的（`ci`、`pr-meta`、`main-post-merge`、`nightly`），出现别的 workflow 名会报 KeyError。用到你的仓库，先按你的 workflow 改 `CANCEL_RUNNING` 和 `group()`。

两个必须注意的口径（都是踩过的坑，见 [08 章 8.1](../../08-运维与容量.md) 和 [09 章 B4、B5](../../09-踩坑记录.md)）：

1. 别剔除「额度耗尽期」的 run。那些 run 代表真实需求，剔掉会把到达率低估一倍以上。
2. 必须建模 `cancel-in-progress`。它会取消同组里排队中和正在跑的 run，忽略它会把排队时间高估几倍。

## 内存要分两个口径量

`step.sh` 读的是它自己那个 cgroup（`ci.slice`）的 `memory.current`，只含这条命令拉起的进程。`services:` 容器、`docker run` 起的容器和 `docker build` 的 RUN 步骤都由 dockerd 管，不在这个 cgroup 里。它的 CPU 核秒读的是整机的 `/proc/stat`，机器上别的负载也会算进去，所以量的时候机器上不要跑别的东西。要 root 运行。

```bash
mkdir -p data
CI_WORK_DIR=<检出好的项目目录> bash scripts/analysis/step.sh typecheck 'pnpm typecheck'   # 结果追加到 data/steps.psv
```

整机的峰值用 `sysmon.sh`。CI 完整跑一遍的同时让它记着，跑完用空闲时的可用内存减去全程最低值，就是单 job 的整机峰值 J，含容器、tmpfs 和 docker build。量的时候不要开开发工具。

```bash
mkdir -p data
bash scripts/analysis/sysmon.sh &          # 写 data/sysmon.csv，每 5 秒一行
# ……跑完整 CI……
kill %1
awk -F, 'NR>1 && (m=="" || $11<m) {m=$11} END {print "最低可用内存:", m, "MiB"}' data/sysmon.csv
```

第 11 列是 `mem_avail_mb`。5 秒一采会漏掉很短的尖峰，所以这个最低值偏乐观，按 10 章 10.2 留的余量就是为这类误差准备的。
