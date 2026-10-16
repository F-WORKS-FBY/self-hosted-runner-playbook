#!/usr/bin/env bash
# ci-cleanup.sh —— CI 产物清理。由 bootstrap.sh 安装到 <RUNNER_HOME>/hooks/。
#
# 挂三处，缺一不可：
#   ACTIONS_RUNNER_HOOK_JOB_STARTED     ← 主力：对「上一个 job 被 cancel-in-progress 取消」免疫
#   ACTIONS_RUNNER_HOOK_JOB_COMPLETED   ← 顺手
#   ci-cleanup.timer（每日）             ← 兜底：上面两个在 runner 进程被杀时都不执行
#
# 上线一个月（2026-09-07 → 10-16，约 2200 个 job）后各步的实际作用：
#   docker volume prune  →  每个起了 service/minio 的 job 约 70 MB；参考项目 workflow 侧改完（metta-app #269，10-16）后
#                           job 不再建匿名卷，这一步只剩兜底，见第 6 步
#   docker image  prune  →  悬空镜像（同一个 tag 被拉到新版本后旧版本变成 <none>:<none>）；
#                           用 digest 钉住的旧 pin **不是**悬空镜像，清不掉，要人工退役（08 章 8.6）
#   BuildKit 缓存        →  **不归这里管**。上限由 daemon.json 的 GC 策略保证（bootstrap.sh 第 4 步）。
#                           这里原来有一条 `buildx prune --filter until=24h`：它删的是 24 小时没被用到的缓存，
#                           实际上常常是整层几 GB 的依赖层（换了 lockfile、或者安静了一晚上），删完下一次构建就是冷的。
#                           这些空间 GC 在需要时本来就会回收，提前删只换来更多冷构建。已删。
#
# ⚠️ 绝不裸 `docker system prune`、绝不用不带 label 的 `-a` —— 那会连基础镜像一起删，
#    把「稳态 Docker Hub 消耗 ≈0」变回每次冷拉。
set -uo pipefail
# ⚠️ 下面两行是 2026-09-07 事故的修复，删任何一行都会让「每个 job 全红」复发。
#
# runner 调 job 钩子时**强加 `-e`**（Worker diag 原文：`Arguments: '-e <本脚本>'`；
# 注意 GitHub 网页日志打印的 `bash --noprofile --norc -e -o pipefail {0}` 是装饰性
# banner，与钩子的真实调用不符）。`-e` 叠上本脚本上面那行自己设的 `pipefail` 之后，
# 下面任何一条命令非零退出都会**当场中止全篇**，走不到末尾的 `exit 0`。
#
# 实际引爆点是第 7 步：机器上不存在 `bin.*` 时 `ls` 退出 2、`grep` 无输入退出 1，
# pipefail 把管道判为 1 → 脚本中止 → 钩子非零 → job 判失败。
# 且 JOB_STARTED 与 JOB_COMPLETED 指向同一个文件，后者带 always()，
# **只修其中一个钩子，job 依然 100% 全红**。
set +e                # 解除外部强加的 -e
trap 'exit 0' EXIT    # 兜底：连 set -u 触发的中止也吃掉，让末尾那句承诺无条件成立

# ⚠️ 会撞上**别的**正在跑的 job 时，什么都不做。
#
# 下面第 1–3 步会删掉带 CI 标的容器、minio 容器，并杀掉 e2e 端口上的进程 ——
# 对「上一个 job 的残留」这是清理，对「正在跑的 job」这是谋杀。
#
# 怎么判断是不是 runner 自己调的（runner 2.337.0 源码核实）：钩子的 bash 由 Runner.Worker 直接
# vfork+execve 出来（ProcessInvoker.cs，中间没有 shell/node），所以父进程名就是 Runner.Worker；
# 另外 runner 给钩子注入了 GITHUB_ACTIONS=true 和 GITHUB_RUN_ID，作为将来 runner 改进程结构时的兜底。
# 每日 timer（systemd）、verify.sh（sudo 会清环境）、手工执行这三条路径两样都没有。
#   · runner 自己调的：本机只有它自己这一个 job 时放行（一台机器上装了两个 runner 时，
#     另一个 runner 的 job 也算「别的 job」）；
#   · 其他路径：本机没有任何 job 时才放行。
# 用 `pgrep -x`（按进程名精确匹配）而不是 `-f`：-f 匹配整条命令行，有人在跑
# `grep Runner.Worker` 或编辑器里开着含这个词的文件时会误判成「有 job」。
# 副作用：在 workflow 的某一步里显式调用本脚本，会清掉**当前 job 自己**的 CI 容器——那是调用者的选择。
n=$(pgrep -cx Runner.Worker 2>/dev/null); n=${n:-0}
if [ "$(ps -o comm= -p "$PPID" 2>/dev/null)" = "Runner.Worker" ] || { [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${GITHUB_RUN_ID:-}" ]; }; then
  [ "$n" -le 1 ] || { echo "ci-cleanup: 本机有 $n 个 job 在跑（多个 runner？），跳过"; exit 0; }
else
  [ "$n" -eq 0 ] || { echo "ci-cleanup: 有 job 正在运行，跳过（只有 runner 自己的钩子调用才会在 job 边界清理）"; exit 0; }
fi
# 正常路径也打一行：出现在每个 job 的「Set up runner / Complete runner」日志里，
# 哪天 runner 升级后守卫误判、每次都在跳过，对照这一行一眼就能看出来。
echo "ci-cleanup: 清理上一个 job 的残留"

L="${CI_LABEL:-__CI_LABEL__}"            # 由 bootstrap.sh 替换；必须与 workflow 给容器打的 --label 完全一致
APP_PORTS="__CI_APP_PORTS__"             # 由 bootstrap.sh 替换；e2e 等在宿主上监听的端口

# 1) 打了 CI 标的容器。带 -v：runner 进程被杀、workflow 的清理步骤没跑时，容器的匿名卷随容器一起删，不依赖第 6 步的 volume prune
docker ps -aq --filter "label=$L" 2>/dev/null | xargs -r docker rm -fv >/dev/null 2>&1

# 2) 漏网的服务容器（历史上用写死 --name 且零清理的那些）
docker ps -aq --filter "name=^minio" 2>/dev/null | xargs -r docker rm -fv >/dev/null 2>&1

# 3) 上一次 run 遗留的宿主孤儿进程。
#    不清的话，下一次 e2e 自己的 spawn 会 EADDRINUSE 死掉（只在 stderr 留一行、不失败），
#    而就绪探测会连上孤儿 → 整套 e2e 跑在**上一次 run 的代码**上。
#    实测过这个假绿：221 条里 220 条通过，唯一那条红叉还指向业务代码而非真实病因。
# ⚠️ 守卫写法有讲究：不能拿 $APP_PORTS 和占位符字面量比。bootstrap.sh 的 sed 是逐行替换，
#    18 行和这一行的占位符会被**一起**换掉，条件就退化成 [ "3100 3101" != "3100 3101" ]
#    ——恒假，整个第 3 步静默失效（2026-09-07 与 -e 事故一并发现）。
#    改为判「是否仍以 __CI_ 开头」，sed 换不到这个前缀，守卫才真正生效。
if [ -n "${APP_PORTS// /}" ] && [ "${APP_PORTS#__CI_}" = "$APP_PORTS" ]; then
  for p in $APP_PORTS; do fuser -k "${p}/tcp" >/dev/null 2>&1 || true; done
fi

# 4) 镜像。两条，作用不同：
#    · 悬空镜像（<none>:<none>）：同一个 tag（如 redis:7-alpine）被拉到新版本后，旧版本就变成这种。无条件安全。
#      用 digest 钉住的旧 pin（repo@sha256:…）不算悬空，这里清不掉，要人工退役（08 章 8.6）。
#    · 打了 CI 标的镜像：只有 workflow 的 `docker build` 带上 `--label $CI_LABEL` 才匹配得到。
#      没打标时这条匹配 0 个 —— 2026-10 实测 18 个镜像无一带标，不是脚本坏了，是 workflow 没打。
#    ⚠️ 不要换成 `--filter until=...` 加 -a：until 按镜像**创建**时间算，不是最后使用时间，
#       一个两年前构建、今天还在用的 pin 会被当场删掉。
docker image prune -f >/dev/null 2>&1
docker image prune -af --filter "label=$L" --filter "until=6h" >/dev/null 2>&1

# 5) （原 BuildKit 缓存清理已删，见文件头。）

# 6) 匿名卷 —— workflow 没挂 tmpfs 时，每个起了 service 容器或 minio 的 job 都会产生。service 容器的卷只有这一步回收。
#    来源：service 容器（postgres、redis）由 runner 用 `docker rm --force` 删除，**不带 -v**；
#    workflow 里 `docker run -d` 起、`docker rm -f` 删的容器同理。镜像声明了 VOLUME 就会留下匿名卷，
#    每个这样的 job 约 70 MB（主要是 PGDATA）。workflow 侧在 VOLUME 路径挂 `--tmpfs`、删容器用 `rm -fv`，
#    就从源头不产生（参考项目 10-16 改完，之后 job 期间新建卷为 0）。这一步留着兜底。见 05 章 ⑫ 与 09 章 A14。
#    无标签过滤，**只在这台机专用于 CI 时安全**。若这台机还跑别的东西，给它的卷打标并改成 --filter "label!=keep"。
docker volume prune -f >/dev/null 2>&1

# 7) runner 自更新残留。官方 update.sh 把旧版 mv 成 bin.<ver>/externals.<ver>，
#    脚本本身不删（listener 内部可能会删，本机无法证实）。保留最新 2 份，是无害的保险。
RH="${RUNNER_HOME:-/opt/actions-runner}"
if cd "$RH" 2>/dev/null; then
  cb=$(readlink -f bin 2>/dev/null | xargs -r basename 2>/dev/null || echo __none__)
  ce=$(readlink -f externals 2>/dev/null | xargs -r basename 2>/dev/null || echo __none__)
  ls -dt bin.*       2>/dev/null | grep -vx "$cb" | tail -n +2 | xargs -r rm -rf
  ls -dt externals.* 2>/dev/null | grep -vx "$ce" | tail -n +2 | xargs -r rm -rf
  find _diag -name '*.log' -mtime +14 -delete 2>/dev/null || true
fi

exit 0   # 清理失败绝不让 job 变红
