#!/usr/bin/env bash
# make-single.sh：由分章文件拼装出单文件版（飞书/知识库粘贴用）。
#
# 为什么要生成而不是手写：两版并存必然漂移。改内容只改分章文件，然后跑这个。
# 快速开始的命令块和附录「脚本验证到什么程度」那张表直接从 README 取，改 README 就行。
# 附录的脚本清单和「需要你自己做的三件事」是另写的精简版，README 里对应的内容改了要同步改这里。
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

# 从 README 里取一段原文：$1 是所在小节的标题行（整行），$2 是 code 或 table，
# 分别取这一节里第一个 ```bash 代码块（连同围栏）和第一张表；note 取第一张表后面的第一段文字。到下一个标题还没找到就算取不到，直接报错。
from_readme() {
  local out
  out=$(awk -v h="$1" -v kind="$2" '
    $0 == h { s = 1; next }
    !s { next }
    kind == "code" {
      if (p) { print; if ($0 == "```") { done = 1; exit } next }
      if ($0 == "```bash") { p = 1; print; next }
    }
    kind == "table" {
      if (/^\|/) { p = 1; done = 1; print; next }
      if (p) exit
    }
    kind == "note" {
      if (/^\|/) { t = 1; next }
      if (t && $0 != "") { print; done = 1; exit }
    }
    /^#+ / { exit }
    END { exit done ? 0 : 1 }
  ' README.md) || { echo "README.md 里「$1」这一节下没取到 $2" >&2; exit 1; }
  printf '%s\n' "$out"
}
QUICKSTART=$(from_readme '## 快速开始' code)
TEST_TABLE=$(from_readme '### 这些脚本测到了什么程度' table)
TABLE_NOTE=$(from_readme '### 这些脚本测到了什么程度' note)

{
cat <<'HEAD'
# 自建 GitHub Actions CI runner 部署手册（单文件版）

> 这份文件由仓库里的分章文件自动拼成，用 `bash scripts/make-single.sh` 重新生成。
> 要改内容请改分章文件，不要改这一份，否则两个版本会对不上。
>
> 手册讲一套通用做法：怎么选机器、按规格怎么定参数、怎么装、怎么改 workflow、怎么接线、怎么验证、怎么运维。脚本面向 x86_64 的 Ubuntu（测过 24.04）。做法不绑定厂商，云主机和裸金属都适用。换厂商时要核对的事（CPU 型号是否固定、登录方式、metadata 地址、防火墙在哪配、计费粒度等）见 02 章 2.9。
> 里面的实测数字来自参考项目：一个 pnpm monorepo 的 CI，跑在 Hetzner Cloud 一台 4 核、约 7.6 GiB 内存的共享 vCPU 云主机上。准备加第二台时又在同一家试过几台候选机（02 章 2.7）。没有特别说明时，数字指第一台。
> 写着「参考项目」的地方是举例，不是要求。你的机器该跑几个实例、参数怎么取，按 10 章的公式算。

---

## 快速开始

HEAD
printf '%s\n' "$QUICKSTART"
cat <<'HEAD'

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
| `scripts/hetzner-pick.py` | 只适用于 Hetzner Cloud：自动开机、跑 machine-check，不合格就删掉，随机等几分钟再开，直到开到合格的。只删自己开的机器。别的厂商照 02 章 2.7 第 2 步的三条规则自己写 |
| `scripts/preflight.sh` | 候选机自检：硬件下限、端口、时间同步、网络、CPU 争抢，输出 GO / NO-GO。只读 |
| `scripts/bootstrap.sh` | 装机、注册、加固，可以重复跑。`--harden-ssh` 才改 SSH，`--skip-runner` 跳过注册 |
| `scripts/verify.sh` | 装完或重启后自检，输出 PASS / FAIL 表。会试跑一次清理钩子，有 job 在跑时这一项自动跳过 |
| `scripts/ci-cleanup.sh` | 清理钩子，由 bootstrap 装到 runner 的 `hooks/` 目录 |
| `scripts/ci-health.sh` | 每小时健康采点，由 bootstrap 装到 `/usr/local/bin/` |
| `scripts/add-light-runner.sh` | 在已装好的机器上再加一个只接小任务的轻实例：单独的用户、不进 docker 组、不挂清理钩子（10 章 10.6）。可以重复跑，已注册就不再注册 |
| `scripts/deploy-cleanup-hook.sh` | 只把清理钩子换成仓库里的新版，不重跑 bootstrap：确认现行那份没被手改，试跑通过才替换（08 章 8.7） |
| `scripts/deploy-ci-health.sh` | 只把 `ci-health.sh` 换成仓库里的新版，不重跑 bootstrap：确认现行那份没被手改，查语法、试跑、备份后替换（08 章 8.7） |
| `scripts/ssh-guard.sh` | SSH 加固的安全网：一条 SSH 会话都不剩时才回滚配置（04 章 4.6） |
| `scripts/tests/ci-health-notify.sh` | ci-health 推送卡片的用例：桩加本地假 webhook，不要 root、不联网 |
| `scripts/analysis/` | 调研期的测量工具：连通性采样、排队仿真、单步资源画像、整机内存采样 |

跑完整检查的 runner 实例一台机器只装一个，同机多个的前提见 10 章 10.6；只接小任务的轻实例可以另加，也在 10.6。

## 附：脚本验证到什么程度

TAIL
printf '%s\n' "$TEST_TABLE"
echo
printf '%s\n' "$TABLE_NOTE"
cat <<'TAIL'

## 附：手册没覆盖、需要你自己做的三件事

1. 配入方向的防火墙（04 章 4.7）。云上用厂商的云防火墙或安全组，在控制台或厂商的 API 里配，bootstrap 管不到。Docker 会自己写 DNAT 规则，绕过宿主机的 ufw，所以只开 ufw 不够。厂商没有云防火墙、或者用的是裸金属时，按 04 章 4.7「没有云防火墙时」做。
2. 撤销注册用的 PAT（03 章 3.4）。注册 runner 用的 registration token 是一次性的，但用来换取它的那个 PAT 不是，用完要撤销。
3. 配心跳告警（06 章 6.4 ①）。bootstrap 不装它。机器宕机或断网时 ci-health 也跟着停了，只有外部的心跳服务能发现。有几台机器就建几个检查。
TAIL
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "已生成 $OUT（$LINES 行，由 ${#CHAPTERS[@]} 章拼装）"
