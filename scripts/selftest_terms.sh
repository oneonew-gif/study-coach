#!/usr/bin/env bash
# 术语纪律检查器 · 自检
#
# 为什么要有它：一个对什么都放行的检查器等于没有检查器；一个对什么都报警的检查器
# 也会被使用者学会无视。所以这里两头都要验：
#   · 该报的必须报（同义替换、拼写漂移）
#   · 不该报的必须不报（干净文档不能有噪音）
#   · 数据不够时必须说「无从校验」，不能假装通过
#
# 样本全是中性的（DEMO101 之类的假课号），不含任何真实课程/学校信息。
#
# 用法：  bash scripts/selftest_terms.sh
# 退出码：0 = 检查器工作正常；1 = 检查器有故障

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$HERE/check_terms.py"
# 公共运行时（Python 真跑验证 + UTF-8 + Windows 路径），与被测脚本同一份
. "$HERE/_common.sh"
[ -n "$PY" ] || { echo "错误：没找到 Python 3（试过 python3 / python / py -3）"; exit 1; }
[ -f "$CHECKER" ] || { echo "错误：找不到 $CHECKER"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_lib() {
  mkdir -p "$1/quiz"
  cat > "$1/quiz/terms.json" <<'JSON'
{
  "source": "selftest",
  "extractedAt": "2026-01-01",
  "terms": {
    "DEMO101": [
      { "en": "thick description", "zh": "厚描", "avoid": ["dense description"] },
      { "en": "adolescent-limited", "zh": "青春期限定型" },
      { "en": "reflexivity", "zh": "反身性" }
    ]
  }
}
JSON
}

LIB="$TMP/lib"
mk_lib "$LIB"

# 干净文档：用的全是原词
cat > "$TMP/clean.md" <<'MD'
# Demo
The study relies on thick description of adolescent-limited offending,
and the author reflects on reflexivity throughout.
MD

# 同义替换：命中 avoid 表（硬证据 → 必须报错）
cat > "$TMP/avoid.md" <<'MD'
# Demo
This paper offers a dense description of the setting.
MD

# 拼写漂移：写法近似但不等（应报「疑似」，但不得判错）
cat > "$TMP/drift.md" <<'MD'
# Demo
The sample consists of adolescence-limited offenders only.
MD

pass=0; fail=0
ok()   { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

run() { $PY "$CHECKER" --library "$LIB" "$@" 2>&1; }

echo "术语纪律检查器 · 自检"
echo

# ① 干净文档必须无错误、无疑似
out="$(run "$TMP/clean.md")"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "疑似"; then
  ok "干净文档：无错误、无噪音"
else
  bad "干净文档被误报（退出码 ${rc}）"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# ② avoid 命中必须报错并拦下（退出码 1）
out="$(run "$TMP/avoid.md")"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "dense description"; then
  ok "同义替换被拦下（dense description → thick description）"
else
  bad "同义替换没被拦住（退出码 ${rc}）—— 这条红线就白写了"
fi

# ③ 近似拼写必须报「疑似」，且不得判错（退出码 0）
out="$(run "$TMP/drift.md")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "疑似"; then
  ok "拼写漂移报为「疑似」，且不拦交付"
else
  bad "拼写漂移没被报出来，或错误地拦了交付（退出码 ${rc}）"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# ④ 术语表为空时必须说「无从校验」，不许假装通过（退出码 3）
mkdir -p "$TMP/empty/quiz"
printf '{"terms": {}}\n' > "$TMP/empty/quiz/terms.json"
out="$($PY "$CHECKER" --library "$TMP/empty" "$TMP/clean.md" 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then
  ok "空术语表 → 明确报「无从校验」（退出码 3）"
else
  bad "空术语表给了退出码 $rc —— 空的检查器不该看起来像通过"
fi

# ⑤ lint 必须抓出格式病（重复条目、avoid 撞原词）
mkdir -p "$TMP/dirty/quiz"
cat > "$TMP/dirty/quiz/terms.json" <<'JSON'
{
  "terms": {
    "DEMO101": [
      { "en": "anomie", "zh": "失范", "avoid": ["reflexivity"] },
      { "en": "anomie", "zh": "失范（重复）" },
      { "en": "reflexivity", "zh": "反身性" },
      { "en": "", "zh": "缺 en" }
    ]
  }
}
JSON
out="$($PY "$CHECKER" --library "$TMP/dirty" --lint 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q "重复条目" \
   && printf '%s' "$out" | grep -q "同时是" \
   && printf '%s' "$out" | grep -q "缺 \`en\`"; then
  ok "lint 抓出重复 / avoid 撞原词 / 缺字段"
else
  bad "lint 漏了格式病（退出码 ${rc}）"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

echo
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] && echo "✅ 检查器工作正常" || echo "❌ 检查器有故障，别信它的结论"

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
