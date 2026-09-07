# 自建 GitHub Actions CI runner —— 部署手册

一套**通用**的做法：怎么判一台机器够不够、怎么装、怎么改 workflow、怎么接线、怎么验、怎么运维。
所有数字都来自一次真实落地（一台 Hetzner 4c/7.5G 机器 + 一个 pnpm monorepo），
凡引用实测处都标了「参考项目」——那是例子，不是要求。

> **这份手册解决的问题**：换服务器时不必重新调研一遍。跑两个脚本 + 对一遍验收表就能到位。

---

## 15 分钟快速开始

```bash
# 1. 判这台机够不够（只读，不装任何东西）
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load
#    → 输出 GO / NO-GO。NO-GO 就别往下走。

# 2. 装机 + 注册 + 加固（幂等，重复跑安全）
GH_REPO=owner/repo GH_TOKEN=<一次性PAT> \
RUNNER_LABELS=self-hosted,linux,x64,ci \
CI_APP_PORTS="3100 3101" CI_LABEL=com.myorg.ci=1 \
CI_FIXEDWORK_BASELINE=<上一步给的 p50> \
bash scripts/bootstrap.sh

# 3. 自检
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh

# 4. ★ 改 workflow —— 这一步没有脚本，必须人读一遍第 05 章
#    在改完之前**不要**打开开关，否则第 2 个 PR 就会红

# 5. 接线
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'

# 6. 连开**两个**测试 PR（一个不够 —— 第二个才验容器名冲突），再手动触发一次定时 workflow
```

**第 4 步是唯一不能跳的人工步骤。** 前三步是机器配置，第 4 步是把仓库里那些
「只在一次性 VM 上成立」的写法找出来改掉——那是失败真正会发生的地方。

---

## 目录

| 章 | 内容 | 什么时候读 |
|---|---|---|
| [01 决策](01-决策.md) | 自建到底值不值；什么时候**不该**做 | 立项前 |
| [02 选机与验收](02-选机与验收.md) | 怎么判一台机器够不够；四条连通性阈值；**steal 可能测不了** | 买机器前 |
| [03 装机与注册](03-装机与注册.md) | 工具链、runner 用户、注册；**为什么不要 `--ephemeral`** | 装机时 |
| [04 加固](04-加固.md) | Docker / systemd / 清理 / metadata / SSH / 云防火墙 | 装机时 |
| **[05 workflow 改造](05-workflow改造.md)** | ★ **十一条会坏掉的托管假设**，每条给自查命令与改法 | **必读，且要逐条过** |
| [06 接线与回退](06-接线与回退.md) | 开关的正确形状与失败形态；哨兵怎么配才付得起 | 接线时 |
| [07 验证](07-验证.md) | 机器侧自检 + 必须用真实 PR 验的四件事 + 重启演练 | 接线后 |
| [08 运维与容量](08-运维与容量.md) | 清理 / 监控 / **用仿真而不是公式算排队** / 何时加第二台机器 | 长期 |
| [09 踩坑记录](09-踩坑记录.md) | 环境的坑 + **我们自己判断错的地方** | 出问题时；也建议先读一遍 |

**单文件版**：[`自建CI-runner部署手册-单文件版.md`](自建CI-runner部署手册-单文件版.md)
—— 由上面各章自动拼装（`bash scripts/make-single.sh` 重新生成），便于整篇粘贴到知识库。
**改内容请改分章文件，别改单文件版**，否则两版会漂移。

---

## 脚本

| 脚本 | 干什么 | 幂等 |
|---|---|---|
| `scripts/preflight.sh` | 候选机自检 → GO/NO-GO。只读 | — |
| `scripts/bootstrap.sh` | 装机 + 注册 + 加固。`--harden-ssh` 才动 SSH，`--skip-runner` 跳过注册 | ✅ |
| `scripts/verify.sh` | 装完 / 重启后自检，输出 PASS/FAIL 表。只读 | — |
| `scripts/ci-cleanup.sh` | 清理钩子（由 bootstrap 安装到 runner 的 hooks/） | ✅ |
| `scripts/ci-health.sh` | 每小时健康采点（由 bootstrap 安装到 /usr/local/bin/） | ✅ |
| `scripts/make-single.sh` | 由分章生成单文件版 | ✅ |
| `scripts/analysis/` | 调研期的测量工具（连通性采样、排队仿真、单步资源画像） | — |

### 这些脚本被测到什么程度

| 路径 | 验证方式 | 状态 |
|---|---|---|
| `bootstrap.sh` 幂等重跑 | 在一台**已配置完成**的机器上完整重跑 | ✅ 退出码 0，12 项关键状态逐字节相同（仅注释文本被标准化） |
| `bootstrap.sh` 从零安装 1–3 步 | 干净 `ubuntu:24.04` 容器 | ✅ docker / node / gh / psmisc 全部从零装成，`daemon.json` 生成正确 |
| `bootstrap.sh` 第 4–8 步 | 需要 systemd，容器里测不了 | ⚠️ **仅在已有机器上验证过效果**，首次在全新机器上跑请盯着输出 |
| runner 注册段 | 需要真 token 与真仓库 | ⚠️ 本次是在已注册的机器上跑的（走了「已注册，跳过」分支）；**全新注册路径未自动化验证** |
| `preflight.sh` | 本机实跑 | ✅ 13 PASS / 2 WARN，各项与已知实测值吻合 |
| `verify.sh` | 本机实跑 | ✅ 24 PASS / 0 FAIL（并因此抓出了两个自己的 bug） |
| `ci-cleanup.sh` / `ci-health.sh` | 以 runner 用户实跑 | ✅ |

---

## 这份手册的边界

**它是什么**：一次真实落地之后整理出的「怎么做」——按执行顺序排列，配可直接跑的脚本。
所有数字都是实测的，不是从文档抄的。

**它不是什么**：不是那次落地的**论证过程**。「为什么 N=1 够用」「为什么不合并 job」
这类结论背后的仿真数据与实测台账留在了内部的核验报告里，没有随手册发布。
手册里凡是引用结论处都直接给了数字与测法，一般不需要回溯原始台账。

**凡标「参考项目」处都是举例**——那是一个 4 人小队的 pnpm monorepo 跑在
4 核 / 7.5 GiB 单机上的实测值。你的数字会不同，但**测法**是通用的。

---

## 手册里没有、但你必须自己做的两件事

1. **云防火墙**（04 章 4.7）：只有云厂商控制台能配。它是唯一挡得住
   「Docker 自建 DNAT 绕过宿主 ufw」的那一层。
2. **撤销注册用的 PAT**（03 章 3.4）：registration token 是一次性的，但你换它用的那个 PAT 不是。
