#!/usr/bin/env bash
# 抽题器 · 自检
#
# 抽题器要保证三件事，少一件都会让「刷题」变成「练位置记忆」：
#   ① 选项真的被打乱了（否则答案位置偏移照样存在）
#   ② 种子可复现（同一个 seed 必须出同一套题，否则错题本对不上）
#   ③ 答案分布异常时要报出来（出题时人工没分散，工具得提醒）
#
# 用法：  bash scripts/selftest_draw_quiz.sh
# 退出码：0 = 抽题器工作正常；1 = 有故障

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIZ="$HERE/draw_quiz.js"
NODE="$(command -v node || true)"

[ -n "$NODE" ] || { echo "错误：找不到 node"; exit 1; }
[ -f "$QUIZ" ] || { echo "错误：找不到 $QUIZ"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 造一份小题库：4 题，**答案故意全在 B 位**，用来验「分布异常会不会被报出来」
cat > "$TMP/bank.json" <<'JSON'
{
  "questions": [
    { "id": 1, "course": "DEMO101", "question": "Q1 哪个是原词？",
      "options": ["ONE", "TWO", "THREE", "FOUR"], "answerIndex": 1,
      "explanation": "靠 TWO" },
    { "id": 2, "course": "DEMO101", "question": "Q2 哪个是原词？",
      "options": ["ALPHA", "BETA", "GAMMA", "DELTA"], "answerIndex": 1,
      "explanation": "靠 BETA" },
    { "id": 3, "course": "DEMO202", "question": "Q3 哪个是原词？",
      "options": ["RED", "GREEN", "BLUE", "YELLOW"], "answerIndex": 1,
      "explanation": "靠 GREEN" },
    { "id": 4, "course": "DEMO202", "question": "Q4 哪个是原词？",
      "options": ["NORTH", "SOUTH", "EAST", "WEST"], "answerIndex": 1,
      "explanation": "靠 SOUTH" }
  ]
}
JSON

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

run() { "$NODE" "$QUIZ" --bank "$TMP/bank.json" "$@" 2>&1; }

echo "抽题器 · 自检"
echo

# ① 同一 seed 必须复现同一套题
A="$(run --course DEMO101 --n 2 --seed 7)"; B="$(run --course DEMO101 --n 2 --seed 7)"
if [ "$A" = "$B" ] && [ -n "$A" ]; then
  ok "同 seed 可复现（同一套题，错题本才对得上）"
else
  bad "同 seed 出了不同的题 —— 可复现性坏了"
fi

# ② 选项真的被打乱了：同一道题换 seed，选项顺序要变
ORDERS=""
for s in 1 2 3 4 5 6; do
  ORD="$(run --course DEMO101 --n 1 --seed $s | grep -oE '^\- [A-Z]\. [A-Z]+' | tr '\n' '|')"
  ORDERS="${ORDERS}${ORD}
"
done
UNIQ="$(printf '%s' "$ORDERS" | sort -u | wc -l | tr -d ' ')"
if [ "$UNIQ" -gt 1 ]; then
  ok "跨 seed 选项顺序会变（打乱生效，${UNIQ} 种排列）"
else
  bad "不同 seed 的选项顺序完全一样 —— 打乱没生效"
fi

# ③ --check 必须报出「答案位置过于集中」
OUT="$(run --check)"
if printf '%s' "$OUT" | grep -q "B" && printf '%s' "$OUT" | grep -q "重排题库"; then
  ok "--check 报出了答案位置集中（全押 B 位被抓住）"
else
  bad "--check 没报出答案位置异常 —— 这个体检就是白做的"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ④ 不存在的课程代号必须明确报错，并列出可选项
OUT="$(run --course NOPE101 --n 1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "DEMO101"; then
  ok "课程代号不存在时明确报错并列出可选项"
else
  bad "课程代号不存在时没有明确报错（退出码 ${RC}）"
fi

# ⑤ 坏题（answerIndex 缺失/越界）必须被剔除，不能把 "undefined" 当答案打出来
#    （样本值用拼接构造，避免本文件自命中）
printf '%s\n' '{"questions":[{"id":9,"course":"DEMO101","question":"坏题","options":["X","Y"],"explanation":""}]}' \
  > "${TMP}/bad.json"
OUT="$("$NODE" "$QUIZ" --bank "${TMP}/bad.json" --course ALL --n 1 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "answerIndex"; then
  ok "全坏题库明确报错，不出卷"
else
  bad "全坏题库没报错（退出码 ${RC}）—— 答案栏会打出 undefined 假装成功"
fi
printf '%s\n' '{"questions":[{"id":1,"course":"DEMO101","question":"好题","options":["X","Y"],"answerIndex":0,"explanation":""},{"id":2,"course":"DEMO101","question":"坏题","options":["X","Y"],"explanation":""}]}' \
  > "${TMP}/mixed.json"
OUT="$("$NODE" "$QUIZ" --bank "${TMP}/mixed.json" --course ALL --n 5 2>&1)"; RC=$?
if [ "$RC" = "0" ] && ! printf '%s' "$OUT" | grep -q "undefined" && printf '%s' "$OUT" | grep -q "1 题"; then
  ok "好坏混合时剔除坏题继续出卷，答案栏无 undefined"
else
  bad "混合题库处理不对（退出码 ${RC}）"
  printf '%s\n' "$OUT" | head -5 | sed 's/^/       /'
fi

# ⑥ --n 非正整数必须报错，不能静默出 0 题空卷
OUT="$(run --course DEMO101 --n abc)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '\-\-n'; then
  ok "--n 非数字时明确报错"
else
  bad "--n 非数字没报错（退出码 ${RC}）—— 会静默出一份 0 题空卷"
fi
OUT="$(run --course DEMO101 --n 0)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "--n 0 时明确报错"
else
  bad "--n 0 没报错 —— 空卷也是卷"
fi

echo
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] && echo "✅ 抽题器工作正常" || echo "❌ 抽题器有故障，别用它出题"

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
