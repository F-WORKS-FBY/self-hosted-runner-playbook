#!/usr/bin/env bash
# make-single.sh：由分章文件拼装出单文件版（飞书/知识库粘贴用）。
#
# 为什么要生成而不是手写：两版并存必然漂移。改内容只改分章文件，然后跑这个。
# 下面 HEAD 里的快速开始是 README 那段命令的副本，改了 README 要同步改这里。
#
# 用法： bash scripts/make-single.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="自建CI-runner部署手册-单文件版.md"
CHAPTERS=(01-决策.md 02-选机与验收.md 03-装机与注册.md 04-加固.md 05-workflow改造.md
          06-接线与回退.md 07-验证.md 08-运维与容量.md 09-踩坑记录.md 10-按机器规格定参数.md)

# 新加的章没登记进上面的列表时直接报错，免得它被静默漏掉
for f in [0-9][0-9]-*.md; do
  case " ${CHAPTERS[*]} " in
    *" $f "*) ;;
    *) echo "分章文件 $f 没登记进 CHAPTERS" >&2; exit 1 ;;
  esac
done
for f in "${CHAPTERS[@]}"; do
  [ -f "$f" ] || { echo "CHAPTERS 里的 $f 不存在" >&2; exit 1; }
done

{
cat <<'HEAD'
# 自建 GitHub Actions CI runner 部署手册（单文件版）

> 这份文件由仓库里的分章文件自动拼成，用 `bash scripts/make-single.sh` 重新生成。
> 要改内容请改分章文件，不要改这一份，否则两个版本会对不上。
>
> 手册讲一套通用做法：怎么选机器、按规格怎么定参数、怎么装、怎么改 workflow、怎么接线、怎么验证、怎么运维。脚本面向 x86_64 的 Ubuntu（测过 24.04）。
> 里面的实测数字来自参考项目：一个 pnpm monorepo 的 CI，跑在一台 4 核、约 7.6 GiB 内存的机器上。没有特别说明时，数字指这一台。
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
RUNNER_NAME=ci-$(hostname -s) \
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

HEAD

# 目录。锚点必须用 python 生成：`tr -d` 按字节删，会把中文标题的多字节 UTF-8 字符切碎，
# 产出乱码锚点甚至非法 UTF-8 文件（踩过）。
echo "## 目录"
echo
python3 - "${CHAPTERS[@]}" <<'PY'
import io, re, sys
for f in sys.argv[1:]:
    t = io.open(f, encoding='utf-8').readline().lstrip('# ').strip()
    # GitHub 锚点规则：转小写、空格转 -、去掉标点（CJK 与字母数字保留）
    a = re.sub(r'[^\w一-鿿 -]', '', t.lower()).replace(' ', '-')
    print(f"- [{t}](#{a})")
PY
echo
echo "---"
echo

for f in "${CHAPTERS[@]}"; do
  # 去掉每章末尾的「上一章/下一章」导航（单文件里没意义）
  # 每章末尾自带一条 ---（原本在导航行上面），导航删掉后它会和下面统一加的那条连在一起，所以一并去掉末尾的分隔线和空行
  sed -e '/^\*\*上一章\*\*/d' -e '/^\*\*下一章\*\*/d' "$f" \
    | awk 'BEGIN{blank=0} {if($0==""){blank++} else {blank=0}; if(blank<3) l[++n]=$0}
           END{while(n>0 && (l[n]=="" || l[n]=="---")) n--; for(i=1;i<=n;i++) print l[i]}'
  echo
  echo "---"
  echo
done

cat <<'TAIL'
## 附：脚本清单

| 脚本 | 作用 |
|---|---|
| `scripts/machine-check.sh` | 新机器一分钟测硬件和单核速度，和现有 runner 比，判合格 / 有保留 / 不合格。只读，只要 python3 |
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
| 全新机器上的注册和 `verify.sh` | 需要真实 token 和真实仓库 | 修复后还没在全新机器上完整跑过，第一次注册时请盯着输出 |
| `machine-check.sh` | 在现有 runner 和两台 Intel Skylake 候选机上实跑 | 两台候选机耗时是现有 runner 的 1.7–1.9 倍，判为不合格 |
| `preflight.sh` | 第一台实跑 | 13 PASS，2 WARN |
| `verify.sh` | 第一台实跑（2026-10-16 重启后） | 34 PASS，0 FAIL |
| `ci-cleanup.sh` / `ci-health.sh` | 以 runner 用户实跑 | 通过 |

上表的实跑用的都是 2026-10-25 这一轮修订之前的脚本。这一轮的修改（等 apt 锁、检查架构、`RUNNER_UID`、token 经标准输入传给 curl、verify 和 ci-health 从 `/etc/ci-runner.env` 读回参数等）还没在机器上整体跑过。

## 附：手册没覆盖、需要你自己做的三件事

1. 配云防火墙。只能在云厂商控制台配。Docker 自己加的 DNAT 规则会绕过宿主机的 ufw，能挡住它的只有这一层。
2. 撤销注册用的 PAT。注册 runner 用的 registration token 是一次性的，但用来换取它的那个 PAT 不是，用完要撤销。
3. 配心跳告警（06 章 6.4 ①）。bootstrap 不装它。机器宕机或断网时 ci-health 也跟着停了，只有外部的心跳服务能发现。有几台机器就建几个检查。
TAIL
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "已生成 $OUT（$LINES 行，由 ${#CHAPTERS[@]} 章拼装）"
