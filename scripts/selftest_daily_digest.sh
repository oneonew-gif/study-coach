#!/usr/bin/env bash
# daily_digest.sh · 自检（注入式）
#
# 每日播报的承诺：
#   ① Deadline 板块真接上了 deadlines.sh brief（不是摆设）
#   ② 复习笔记欠账判定跟 PROGRESS 走 —— 中文数字讲次（二十/二十一）不许再算错
#   ③ 齐的时候明说「无欠账」，不许编任务凑数
#   ④ PROGRESS 缺失时如实声明，不硬判
#
# 用法：  bash scripts/selftest_daily_digest.sh
# 退出码：0 = 全过；1 = 有失败

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "每日待办播报 · 自检"
echo

BIN="$(mktemp -d)"
LIB="$(mktemp -d)"
LIB2="$(mktemp -d)"
trap 'rm -rf "$BIN" "$LIB" "$LIB2"' EXIT

cp "$HERE/daily_digest.sh" "$HERE/deadlines.sh" "$HERE/vocab.sh" "$BIN/"
chmod +x "$BIN/daily_digest.sh" "$BIN/deadlines.sh"

cat > "$BIN/canvas.sh" <<'FAKE'
#!/bin/bash
PY="$(command -v python3 || command -v python)"
case "${1:-}" in
  courses) "$PY" -c "import json; print(json.dumps([{'id':1,'course_code':'DEMO101','name':'假课一'}]))" ;;
  assignments) "$PY" -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([{'id':11,'name':'Essay 1','due_at':d(10),'points_possible':20,'submission':{'workflow_state':'unsubmitted'}}]))" ;;
  *) echo "fake canvas: unknown $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/canvas.sh"

make_courses_md() {
  local dir="$1" body="$2"
  printf '# 课程索引\n\n<!-- PROGRESS v1 %s -->\n' "$body" > "$dir/COURSES.md"
}

# ---------------------------------------------------------------- ① 三板块集成
# PROGRESS：DEMO101 上到 3（笔记有 1、2 讲 → 缺 3）；DEMO102 上到 1（无笔记 → 缺 1）
make_courses_md "$LIB" '{"term":"2026-27A","currentWeek":4,"asOf":"2026-09-24","confirmed":false,"courses":[{"code":"DEMO101","taughtUpTo":3},{"code":"DEMO102","taughtUpTo":1}]}'
mkdir -p "$LIB/notes"
printf 'x' > "$LIB/notes/DEMO101_第1讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO101_第2讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO102_Week2课前预习包.md"

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "daily_digest 正常退出"
else
  bad "退出码 ${RC}"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi

if printf '%s' "$OUT" | grep -q '【Deadline 临期' && printf '%s' "$OUT" | grep -q 'Essay 1'; then
  ok "Deadline 板块真接上了 deadlines.sh brief（有真实条目）"
else
  bad "Deadline 板块没接上或没有条目"
fi

if printf '%s' "$OUT" | grep -q 'DEMO101：已上到第 3 讲，缺复习笔记 → 第 3 讲' \
   && printf '%s' "$OUT" | grep -q 'DEMO102：已上到第 1 讲，缺复习笔记 → 第 1 讲'; then
  ok "复习笔记欠账判定正确（1、2 讲有笔记只报缺 3；DEMO102 报缺 1）"
else
  bad "复习笔记欠账判定不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

if printf '%s' "$OUT" | grep -q '已上到第 3 讲' && ! printf '%s' "$OUT" | grep -q '缺复习笔记 → 第 1 讲.*DEMO101\|DEMO101.*缺复习笔记 → 第 1 讲'; then
  ok "没把已有笔记的讲次报成缺口"
else
  bad "把已有笔记的讲次也报成缺口了"
fi

if printf '%s' "$OUT" | grep -q '【预习缺口（提前 1 讲）】' \
   && printf '%s' "$OUT" | grep -q 'DEMO101：缺课前预习包 → 第 4 讲'; then
  ok "预习缺口按 taughtUpTo+1 判定（默认提前量 1 讲）"
else
  bad "预习缺口判定不对"
fi

if printf '%s' "$OUT" | grep -q 'confirmed: false'; then
  ok "进度未核对时如实声明"
else
  bad "confirmed: false 没有提示"
fi

if printf '%s' "$OUT" | grep -q '今日有人味儿的提醒'; then
  ok "末尾带背单词引导行（vocab.sh hint）"
else
  bad "背单词引导行丢了"
fi

# ---------------------------------------------------------------- ② 中文数字讲次
# DEMO103 上到第 21 讲（二十、二十一），笔记只有「第二十讲」→ 只该报缺 21。
# 早先 cn 解析把「二十」算成 12，缺口判定会整串错 —— 这条就是它的回归哨。
make_courses_md "$LIB" '{"term":"2026-27A","currentWeek":8,"asOf":"2026-09-24","confirmed":true,"courses":[{"code":"DEMO103","taughtUpTo":21}]}'
rm -f "$LIB/notes"/*.md
for i in $(seq 1 19); do printf 'x' > "$LIB/notes/DEMO103_第${i}讲复习笔记.md"; done
printf 'x' > "$LIB/notes/DEMO103_第二十讲复习笔记.md"

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" 2>&1)"
if printf '%s' "$OUT" | grep -q 'DEMO103：已上到第 21 讲，缺复习笔记 → 第 21 讲'; then
  ok "中文数字讲次正确（第二十讲=20 被认出，只缺第 21 讲）"
else
  bad "中文数字讲次解析回归 —— 二十/二十一又算错了"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi
if printf '%s' "$OUT" | grep -q '缺复习笔记 → 第 20 讲\|缺复习笔记 → 第 12 讲'; then
  bad "把已有笔记的讲次（第二十讲）报成缺口了"
else
  ok "第二十讲笔记被正确识别为已存在"
fi

# ---------------------------------------------------------------- ③ 齐 → 明说无欠账
make_courses_md "$LIB" '{"term":"2026-27A","currentWeek":4,"asOf":"2026-09-24","confirmed":true,"courses":[{"code":"DEMO101","taughtUpTo":2}]}'
rm -f "$LIB/notes"/*.md
printf 'x' > "$LIB/notes/DEMO101_第1讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO101_第2讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO101_第3讲课前预习包.md"

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q '复习笔记齐' && printf '%s' "$OUT" | grep -q '预习包已就绪' \
   && printf '%s' "$OUT" | grep -q '今日无学习债'; then
  ok "全齐时明说「今日无学习债」（不编任务凑数）"
else
  bad "全齐时输出不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ④ PROGRESS 缺失
make_courses_md "$LIB2" '# 课程索引（无 PROGRESS 块）'
OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB2" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'PROGRESS 块未设置'; then
  ok "PROGRESS 缺失时如实声明、不硬判"
else
  bad "PROGRESS 缺失时没有如实说明"
fi

# ---------------------------------------------------------------- ⑤ 预习提前量 --preview-ahead
# taughtUpTo=3，第 4 讲预习包已备好：
#   提前量 1 → 就绪；提前量 2 → 只缺第 5 讲；提前量 3 → 缺第 5、6 讲
make_courses_md "$LIB" '{"term":"2026-27A","currentWeek":4,"asOf":"2026-09-25","confirmed":true,"courses":[{"code":"DEMO101","taughtUpTo":3}]}'
rm -f "$LIB/notes"/*.md
printf 'x' > "$LIB/notes/DEMO101_第4讲课前预习包.md"

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'DEMO101：往后 1 讲（第 4 讲）预习包已就绪'; then
  ok "提前量默认 1：下一讲已备好就明说就绪"
else
  bad "提前量默认 1 时输出不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" --preview-ahead 2 2>/dev/null)"
if printf '%s' "$OUT" | grep -q '【预习缺口（提前 2 讲）】' \
   && printf '%s' "$OUT" | grep -q 'DEMO101：缺课前预习包 → 第 5 讲' \
   && ! printf '%s' "$OUT" | grep -q '→ 第 4 讲'; then
  ok "提前量 2：第 4 讲已备好不被误报，只报缺第 5 讲"
else
  bad "提前量 2 判定不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

OUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" --preview-ahead 3 2>/dev/null)"
if printf '%s' "$OUT" | grep -q '缺课前预习包 → 第 5, 6 讲'; then
  ok "提前量 3：一次报全缺的讲次（第 5、6 讲）"
else
  bad "提前量 3 判定不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑥ 降级与用法
OUT="$(bash "$BIN/daily_digest.sh" --preview-ahead 0 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "取值 1–10"; then
  ok "预习提前量非法值（0）明确报错"
else
  bad "预习提前量非法值没拦住（退出码 ${RC}）"
fi

OUT="$(bash "$BIN/daily_digest.sh" --lib /nonexistent_dir_xyz 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "资料库不存在"; then
  ok "库不存在时明确报错"
else
  bad "库不存在时退出码 ${RC} —— 可能给了假绿灯"
fi

OUT="$(bash "$BIN/daily_digest.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "用法"; then
  ok "无参数时打印用法（退出码 0）"
else
  bad "无参数调用行为不对（退出码 ${RC}）"
fi

echo
echo "结果：${pass} 通过 / ${fail} 失败"
[ "${fail}" -eq 0 ] && echo "✅ 每日播报行为正确" || echo "❌ 有行为偏离承诺"
exit $([ "${fail}" -eq 0 ] && echo 0 || echo 1)
