#!/usr/bin/env bash
# ci-cleanup.sh —— CI 产物清理。由 bootstrap.sh 安装到 <RUNNER_HOME>/hooks/。
#
# 挂三处，缺一不可：
#   ACTIONS_RUNNER_HOOK_JOB_STARTED     ← 主力：对「上一个 job 被 cancel-in-progress 取消」免疫
#   ACTIONS_RUNNER_HOOK_JOB_COMPLETED   ← 顺手
#   ci-cleanup.timer（每日）             ← 兜底：上面两个在 runner 进程被杀时都不执行
#
# 各命令的实测回收量（Hetzner 4c/7.5G，Docker 29 + containerd 快照器）：
#   docker image  prune  →  0 MB      ← Docker 29 重打同名 tag 不留悬空镜像，这条基本是摆设
#   docker buildx prune  →  5896 MB   ← **主力**
#   docker volume prune  →  634 MB    ← services 容器的匿名 PGDATA/minio，约 70 MB/run
#
# ⚠️ 绝不裸 `docker system prune`、绝不用不带 label 的 `-a` —— 那会连基础镜像一起删，
#    把「稳态 Docker Hub 消耗 ≈0」变回每次冷拉。
set -uo pipefail
# ⚠️ 下面两行是 2026-09-07 事故的修复，删任何一行都会让「每个 job 全红」复发。
#
# runner 调 job 钩子时**强加 `-e`**（Worker diag 原文：`Arguments: '-e <本脚本>'`；
# 注意 GitHub 网页日志打印的 `bash --noprofile --norc -e -o pipefail {0}` 是装饰性
# banner，与钩子的真实调用不符）。`-e` 叠上本脚本第 16 行自己设的 `pipefail` 之后，
# 下面任何一条命令非零退出都会**当场中止全篇**，走不到末尾的 `exit 0`。
#
# 实际引爆点是第 7 步：机器上不存在 `bin.*` 时 `ls` 退出 2、`grep` 无输入退出 1，
# pipefail 把管道判为 1 → 脚本中止 → 钩子非零 → job 判失败。
# 且 JOB_STARTED 与 JOB_COMPLETED 指向同一个文件，后者带 always()，
# **只修其中一个钩子，job 依然 100% 全红**。
set +e                # 解除外部强加的 -e
trap 'exit 0' EXIT    # 兜底：连 set -u 触发的中止也吃掉，让末尾那句承诺无条件成立
L="${CI_LABEL:-__CI_LABEL__}"            # 由 bootstrap.sh 替换；必须与 workflow 给容器打的 --label 完全一致
APP_PORTS="__CI_APP_PORTS__"             # 由 bootstrap.sh 替换；e2e 等在宿主上监听的端口

# 1) 打了 CI 标的容器
docker ps -aq --filter "label=$L" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1

# 2) 漏网的服务容器（历史上用写死 --name 且零清理的那些）
docker ps -aq --filter "name=^minio" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1

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

# 4) 打了 CI 标的镜像（实测回收 0 MB，留作保险）
docker image prune -af --filter "label=$L" --filter "until=6h" >/dev/null 2>&1

# 5) BuildKit 缓存 —— 真正的回收主力。
#    Docker 29 已移除 --keep-storage，必须用 --filter until=
docker buildx prune -f --filter "until=24h" >/dev/null 2>&1

# 6) 匿名卷。无标签过滤，**只在这台机专用于 CI 时安全**。
#    若这台机还跑别的东西，给它的卷打标并改成 --filter "label!=keep"。
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
