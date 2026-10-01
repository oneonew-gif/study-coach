#!/usr/bin/env bash
# AI 横幅检查器 · 自检
#
# 为什么要有它：检查器如果对什么都放行，就等于没有检查器。
# 这个脚本用**中性样本**（不含任何课程/学校信息）跑 6 个用例，
# 正向 3 个必须通过、反向 3 个必须失败。任何一个行为不对就说明检查器坏了。
#
# 用法：  bash scripts/selftest_ai_banner.sh
# 退出码：0 = 检查器工作正常；1 = 检查器有故障

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$HERE/check_ai_banner.py"
# Python 解析：python3 → python → py -3（Windows 兼容，W2）
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
  PY=python
elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
  PY="py -3"
fi

[ -n $PY ] || { echo "错误：没找到 Python 3（试过 python3 / python / py -3）"; exit 1; }
[ -f "$CHECKER" ] || { echo "错误：找不到 $CHECKER"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BAN='> ⚠️ **本课禁止 AI 代写**
>
> 课程：`DEMO101 示例课`｜政策依据：`outline 第 1 页`
>
> 以下内容**由 AI 生成**。该课明确规定不得使用生成式 AI，**直接提交可能触发 AI 检测**（后果示例）。
>
> **仅供理解与参考，是否使用由使用者自行判断并承担后果。**'

PARTIAL='> ⚠️ **本课规定不可 AI 代写**
>
> 课程：`DEMO102 示例课`｜政策依据：`outline 第 2 页`
>
> 以下内容**由 AI 生成**。该课允许 AI 辅助构思，但**明确规定不可代写**；直接提交可能触发检测（后果示例）。
>
> **仅供理解与参考，是否使用由使用者自行判断并承担后果。**'

UNCONFIRMED='> ⚠️ **本课 AI 政策未确认 —— 按最严处理**
>
> 课程：`DEMO103 示例课`｜政策依据：`未确认`
>
> 以下内容**由 AI 生成**。该课是否允许使用生成式 AI**尚未确认**。
>
> **使用前请先向老师确认。是否使用由使用者自行判断并承担后果。**'

printf '%s\n\n---\n\n正文。\n' "$BAN"          > "$TMP/ok-ban.md"
printf '%s\n\n---\n\n正文。\n' "$PARTIAL"      > "$TMP/ok-partial.md"
printf '%s\n\n---\n\n正文。\n' "$UNCONFIRMED"  > "$TMP/ok-unconfirmed.md"

# 反例一：完全没有横幅
printf '# 标题\n\n正文，没横幅。\n' > "$TMP/bad-none.md"
# 反例二：横幅在标题之后
printf '# 标题\n\n%s\n' "$BAN" > "$TMP/bad-late.md"
# 反例三：横幅被 <details> 折叠
printf '<details>\n<summary>展开</summary>\n\n%s\n\n</details>\n' "$BAN" > "$TMP/bad-folded.md"

pass=0; fail=0
expect() { # 期望(ok|bad) 期望类型 文件
  if $PY "$CHECKER" --expect "$2" "$3" >/dev/null 2>&1; then got=ok; else got=bad; fi
  if [ "$got" = "$1" ]; then
    printf '  ✅ %-22s 预期 %-3s 实际 %-3s\n' "$(basename "$3")" "$1" "$got"; pass=$((pass+1))
  else
    printf '  ❌ %-22s 预期 %-3s 实际 %-3s  ← 检查器行为不对\n' "$(basename "$3")" "$1" "$got"; fail=$((fail+1))
  fi
}

echo "AI 横幅检查器 · 自检"
echo
echo "正向（应通过）"
expect ok  ban         "$TMP/ok-ban.md"
expect ok  partial     "$TMP/ok-partial.md"
expect ok  unconfirmed "$TMP/ok-unconfirmed.md"
echo
echo "反向（应失败）"
expect bad ban         "$TMP/bad-none.md"
expect bad ban         "$TMP/bad-late.md"
expect bad ban         "$TMP/bad-folded.md"
echo
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] && echo "✅ 检查器工作正常" || echo "❌ 检查器有故障，别信它的结论"

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
