#!/usr/bin/env bash
# weekly_digest.sh · 自检（注入式）
#
# 每周复盘的承诺：
#   ① 五个板块都真实产出（产出统计 / 趋势 / 未来一周 deadline / 下周预告 / 总评）
#   ② 学习债判定与 daily_digest 同源 —— 同一个库两边算出的数字必须一致
#   ③ 趋势对比真读快照：预置旧快照要看到 ↓，跑完快照要刷新成新值
#   ④ PROGRESS 缺失时如实声明，不硬判
#   ⑤ 报告与快照落盘 digest/，不许只在 stdout 说一声
#
# 用法：  bash scripts/selftest_weekly_digest.sh
# 退出码：0 = 全过；1 = 有失败

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "每周复盘 · 自检"
echo

BIN="$(mktemp -d)"
LIB="$(mktemp -d)"
LIB2="$(mktemp -d)"
trap 'rm -rf "$BIN" "$LIB" "$LIB2"' EXIT

cp "$HERE/weekly_digest.sh" "$HERE/daily_digest.sh" "$HERE/deadlines.sh" "$HERE/vocab.sh" "$BIN/"
chmod +x "$BIN/weekly_digest.sh" "$BIN/daily_digest.sh" "$BIN/deadlines.sh"

cat > "$BIN/canvas.sh" <<'FAKE'
#!/bin/bash
PY="$(command -v python3 || command -v python)"
case "${1:-}" in
  courses) "$PY" -c "import json; print(json.dumps([{'id':1,'course_code':'DEMO101','name':'假课一'},{'id':2,'course_code':'DEMO102','name':'假课二'}]))" ;;
  assignments) "$PY" -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([{'id':11,'name':'Essay 1','due_at':d(72),'points_possible':20,'submission':{'workflow_state':'unsubmitted'}},
                  {'id':12,'name':'Quiz 2','due_at':d(240),'points_possible':10,'submission':{'workflow_state':'unsubmitted'}}]))" ;;
  *) echo "fake canvas: unknown $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/canvas.sh"

make_courses_md() {
  local dir="$1" body="$2"
  printf '# 课程索引\n\n<!-- PROGRESS v1 %s -->\n' "$body" > "$dir/COURSES.md"
}

# ---------------------------------------------------------------- ① 五板块 + 产出统计 + 债务判定
# DEMO101 上到 3（笔记 1、2 → 缺 3；预习缺第 4 讲）；DEMO102 上到 1（无笔记 → 缺 1；预习缺第 2 讲）
make_courses_md "$LIB" '{"term":"2026-27A","currentWeek":4,"asOf":"2026-09-25","confirmed":true,"courses":[{"code":"DEMO101","taughtUpTo":3},{"code":"DEMO102","taughtUpTo":1}]}'
mkdir -p "$LIB/notes"
printf 'x' > "$LIB/notes/DEMO101_第1讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO101_第2讲复习笔记.md"
printf 'x' > "$LIB/notes/DEMO101_第4讲课前预习包.md"

OUT="$(bash "$BIN/weekly_digest.sh" --lib "$LIB" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "weekly_digest 正常退出"
else
  bad "退出码 ${RC}"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi

for sec in '【本周产出' '【学习债趋势】' '【Deadline 未来一周' '【下周预告' '【总评】' '今日有人味儿的提醒'; do
  if printf '%s' "$OUT" | grep -q "$sec"; then
    ok "板块齐全：${sec}…】"
  else
    bad "缺板块：${sec}…】"
  fi
done

if printf '%s' "$OUT" | grep -q '复习笔记 2 份' && printf '%s' "$OUT" | grep -q '预习包 1 份'; then
  ok "本周产出按 mtime 统计正确（复习 2 + 预习 1）"
else
  bad "本周产出统计不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

if printf '%s' "$OUT" | grep -q '复习缺口 2 讲' && printf '%s' "$OUT" | grep -q '预习缺口 1 门'; then
  ok "学习债判定正确（缺复习 2 讲 + 缺预习 1 门）"
else
  bad "学习债判定不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# 与 daily_digest 同源交叉核对：同一个库，缺口结论必须一致
DOUT="$(bash "$BIN/daily_digest.sh" --lib "$LIB" 2>/dev/null)"
if printf '%s' "$DOUT" | grep -q 'DEMO101：已上到第 3 讲，缺复习笔记 → 第 3 讲' \
   && printf '%s' "$OUT" | grep -q '复习缺口 2 讲'; then
  ok "与 daily_digest 同源（同一库两边结论吻合）"
else
  bad "与 daily_digest 判定不同源 —— 有一边算错了"
fi

# ---------------------------------------------------------------- ② 趋势：预置旧快照 → ↓，跑完刷新
printf '{"savedAt":"2026-09-18 09:00","reviewGaps":5,"previewGaps":3}\n' > "$LIB/digest/weekly-stats.json"
OUT="$(bash "$BIN/weekly_digest.sh" --lib "$LIB" 2>&1)"
if printf '%s' "$OUT" | grep -q '复习缺口 2 讲（上次 5 → ↓3）' \
   && printf '%s' "$OUT" | grep -q '预习缺口 1 门（上次 3 → ↓2）'; then
  ok "趋势对比真读快照（5→2 ↓、3→1 ↓）"
else
  bad "趋势对比没读快照或算错"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

STATS_N="$(python3 -c "import json;print(json.load(open('$LIB/digest/weekly-stats.json'))['reviewGaps'])" 2>/dev/null || echo ERR)"
if [ "$STATS_N" = "2" ]; then
  ok "跑完快照刷新为本次值（reviewGaps=2）"
else
  bad "快照没刷新（读到：${STATS_N}）"
fi

# ---------------------------------------------------------------- ③ deadline 两窗口分流
if printf '%s' "$OUT" | grep -q 'Essay 1' \
   && ! printf '%s' "$OUT" | sed -n '/【下周预告/,/【总评】/p' | grep -q 'Essay 1' \
   && printf '%s' "$OUT" | sed -n '/【下周预告/,/【总评】/p' | grep -q 'Quiz 2'; then
  ok "deadline 分流正确：3 天内的进未来一周、10 天后的只进下周预告"
else
  bad "deadline 两窗口分流不对"
  printf '%s\n' "$OUT" | sed -n '/【Deadline/,/【总评】/p' | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ④ 存档落盘
REPORT_N="$(ls "$LIB"/digest/weekly-*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$REPORT_N" -ge 1 ] && grep -q '【学习债趋势】' "$LIB"/digest/weekly-*.md; then
  ok "报告已存档 digest/weekly-*.md"
else
  bad "报告没存档"
fi

# ---------------------------------------------------------------- ⑤ PROGRESS 缺失
make_courses_md "$LIB2" '# 课程索引（无 PROGRESS 块）'
OUT="$(bash "$BIN/weekly_digest.sh" --lib "$LIB2" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'PROGRESS 块未设置' \
   && printf '%s' "$OUT" | grep -q '教学进度没设，欠账算不了'; then
  ok "PROGRESS 缺失时如实声明（趋势块 + 总评都不硬判）"
else
  bad "PROGRESS 缺失时没有如实说明"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑥ 降级与用法
OUT="$(bash "$BIN/weekly_digest.sh" --lib /nonexistent_dir_xyz 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "资料库不存在"; then
  ok "库不存在时明确报错"
else
  bad "库不存在时退出码 ${RC} —— 可能给了假绿灯"
fi

OUT="$(bash "$BIN/weekly_digest.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "用法"; then
  ok "无参数时打印用法（退出码 0）"
else
  bad "无参数调用行为不对（退出码 ${RC}）"
fi

OUT="$(bash "$BIN/weekly_digest.sh" --lib "$LIB" --preview-ahead 0 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "取值 1–10"; then
  ok "预习提前量非法值（0）明确报错"
else
  bad "预习提前量非法值没拦住（退出码 ${RC}）"
fi

echo
echo "结果：${pass} 通过 / ${fail} 失败"
[ "${fail}" -eq 0 ] && echo "✅ 每周复盘行为正确" || echo "❌ 有行为偏离承诺"
exit $([ "${fail}" -eq 0 ] && echo 0 || echo 1)
