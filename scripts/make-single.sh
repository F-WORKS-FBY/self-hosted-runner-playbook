#!/usr/bin/env bash
# make-single.sh —— 由分章文件拼装出单文件版（飞书/知识库粘贴用）。
#
# 为什么要生成而不是手写：两版并存必然漂移。**改内容只改分章文件，然后跑这个。**
#
# 用法： bash scripts/make-single.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="自建CI-runner部署手册-单文件版.md"
CHAPTERS=(01-决策.md 02-选机与验收.md 03-装机与注册.md 04-加固.md 05-workflow改造.md
          06-接线与回退.md 07-验证.md 08-运维与容量.md 09-踩坑记录.md)

{
cat <<'HEAD'
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

HEAD

# 目录。锚点必须用 python 生成 —— `tr -d` 是按**字节**删的，会把中文标题的
# 多字节 UTF-8 字符切碎，产出乱码锚点甚至非法 UTF-8 文件（踩过）。
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
TAIL
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "已生成 $OUT（$LINES 行，由 ${#CHAPTERS[@]} 章拼装）"
