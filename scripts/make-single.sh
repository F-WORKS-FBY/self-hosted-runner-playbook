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
# 自建 GitHub Actions CI runner —— 部署手册（单文件版）

> 本文由 `playbook/` 下的分章文件自动拼装（`bash scripts/make-single.sh` 重新生成）。
> **要改内容请改分章文件**，别改这一份，否则两版会漂移。
>
> 一套通用做法：怎么判一台机器够不够、怎么装、怎么改 workflow、怎么接线、怎么验、怎么运维。
> 所有数字都来自一次真实落地（一台 4 核 / 7.5 GiB 机器 + 一个 pnpm monorepo）；
> 凡标「参考项目」处是举例，不是要求。

---

## 15 分钟快速开始

```bash
# 1. 判这台机够不够（只读）
CI_HOST_PORTS="5433 6379 9000" bash scripts/preflight.sh --with-load

# 2. 装机 + 注册 + 加固（幂等）
GH_REPO=owner/repo GH_TOKEN=<一次性PAT> \
RUNNER_LABELS=self-hosted,linux,x64,ci \
CI_APP_PORTS="3100 3101" CI_LABEL=com.myorg.ci=1 \
CI_FIXEDWORK_BASELINE=<上一步给的 p50> \
bash scripts/bootstrap.sh

# 3. 自检
GH_REPO=owner/repo GH_TOKEN=<token> bash scripts/verify.sh

# 4. ★ 改 workflow —— 没有脚本，必须人读一遍第 05 章
#    改完之前**不要**打开开关，否则第 2 个 PR 就会红

# 5. 接线
gh variable set CI_RUNNER --repo owner/repo --body '["self-hosted","linux","x64","ci"]'

# 6. 连开**两个**测试 PR，再手动触发一次定时 workflow
```

**第 4 步是唯一不能跳的人工步骤。** 前三步是机器配置；第 4 步是把仓库里那些
「只在一次性 VM 上成立」的写法找出来改掉——那才是失败真正会发生的地方。

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
  sed -e '/^\*\*上一章\*\*/d' -e '/^\*\*下一章\*\*/d' -e '/^---$/{x;/./d;x}' "$f" \
    | awk 'BEGIN{blank=0} {if($0==""){blank++} else {blank=0}; if(blank<3) print}'
  echo
  echo "---"
  echo
done

cat <<'TAIL'
## 附：脚本清单

| 脚本 | 干什么 |
|---|---|
| `scripts/preflight.sh` | 候选机自检 → GO/NO-GO。只读 |
| `scripts/bootstrap.sh` | 装机 + 注册 + 加固。`--harden-ssh` 才动 SSH，`--skip-runner` 跳过注册。**幂等** |
| `scripts/verify.sh` | 装完 / 重启后自检，输出 PASS/FAIL 表。基本只读：会试跑一次清理钩子，有 job 在跑时自动跳过 |
| `scripts/ci-cleanup.sh` | 清理钩子（bootstrap 装到 runner 的 hooks/） |
| `scripts/ci-health.sh` | 每小时健康采点（bootstrap 装到 /usr/local/bin/） |
| `scripts/analysis/` | 调研期测量工具：连通性采样、**排队仿真**、单步资源画像 |

## 附：脚本被测到什么程度

| 路径 | 验证方式 | 状态 |
|---|---|---|
| `bootstrap.sh` 幂等重跑 | 在已配置完成的机器上完整重跑 | ✅ 退出码 0，12 项关键状态逐字节相同 |
| `bootstrap.sh` 从零安装（工具链段） | 干净 `ubuntu:24.04` 容器 | ✅ docker / node / gh / psmisc 全部从零装成 |
| `bootstrap.sh` 加固段（需 systemd） | 容器里测不了 | ⚠️ 仅在已有机器上验证过效果，首次全新安装请盯输出 |
| runner 全新注册路径 | 需真 token 与真仓库 | ⚠️ 未自动化验证（本次走的是「已注册，跳过」分支） |
| `preflight.sh` / `verify.sh` | 本机实跑 | ✅ 13 PASS+2 WARN / 24 PASS+0 FAIL |

## 附：手册没做、必须你自己做的两件事

1. **云防火墙**：只有云厂商控制台能配。它是唯一挡得住「Docker 自建 DNAT 绕过宿主 ufw」的那一层。
2. **撤销注册用的 PAT**：registration token 是一次性的，但你换它用的那个 PAT 不是。
TAIL
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "已生成 $OUT（$LINES 行，由 ${#CHAPTERS[@]} 章拼装）"
