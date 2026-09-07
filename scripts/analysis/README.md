# analysis/ —— 调研期的测量工具

这些**不是部署需要的**，是当初做可行性核验时用来产生实测数字的。
换机器时通常用不到；但如果你要重新论证「这台机够不够」「要不要合并 job」「排队会不会爆」，
它们能省掉重新造轮子的时间。

| 脚本 | 干什么 | 什么时候用 |
|---|---|---|
| `netprobe.sh` / `netprobe6.sh` | 按端点采样 connect / TTFB，输出 CSV（v4 / v6 两版） | 要长时间、大样本的连通性数据时（`preflight.sh` 只做 12 样本的快检） |
| `netstats.py` | 宽口径统计（任何 HTTP 响应都算成功） | — |
| `netstats2.py` | **严格口径**（5xx 计为失败）+ 阵发故障定位 | 推荐用这个。宽口径会把 504 算成成功，看不见短时故障 |
| `queue_sim.py` | 单 runner 排队仿真：喂真实 run 时间戳 + 各 workflow 的 concurrency 语义 | **决定 N、决定要不要合并 job、决定能不能加检查时用这个，别套 ρ=λS** |
| `step.sh` | 单步跑并测 wall / peak RSS / CPU 核秒 / 磁盘增量（用 cgroup） | 量「单 job 峰值内存」时用——那是定 MemoryMax 与 N 的唯一依据 |
| `sysmon.sh` | 5 秒粒度采 CPU/内存/磁盘 | 跑压测时并行开着 |
| `stealtest.sh` | 满载 + steal 采样 | ⚠️ 先用 `preflight.sh` 确认这台机的 steal 可观测，否则它采到的全是 0 且毫无意义 |

## queue_sim.py 怎么用

```python
import sys; sys.path.insert(0, 'analysis')
from queue_sim import ts, simulate
# events: [(datetime, workflow_name, branch), ...]
# svc:    {workflow_name: 服务时长秒数}
r = simulate(events, svc)
# r['waits'] 是每个跑完的 job 的排队等待秒数（已排序）
```
事件流从 GitHub API 拿：`/repos/{owner}/{repo}/actions/runs?per_page=100`，
取 `created_at` / `name` / `head_branch`。

**两个必须注意的口径**（都是踩过的坑，见 `../09-踩坑记录.md`）：
1. **别剔除「额度耗尽期」的 run**——那些 run 代表真实需求，剔掉会低估到达率一倍以上。
2. **必须建模 `cancel-in-progress`**——它会取消**排队中和正在跑的**同组 run，
   忽略它会把排队时间高估几倍。`queue_sim.py` 已经按各 workflow 的真实 concurrency 语义实现了。
