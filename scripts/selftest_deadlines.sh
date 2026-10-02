#!/usr/bin/env bash
# deadlines.sh · 自检（注入式）
#
# deadlines.sh 的核心承诺：
#   ① 分层正确 —— 逾期/24h/3天/更远各归各位，排序按截止时间
#   ② 已提交、无截止日期的不进看板，且在尾部如实报数
#   ③ 读取失败可见 —— WARN + 看板头部警示，绝不冒充「没有 deadline」
#   ④ brief 模式只吐临期项，--within 语义正确
#   ⑤ Canvas 挂了明确报错，不给假绿灯
#   ⑥ ics 导出 —— 读取失败拒绝生成；CRLF/UID 稳定/VALARM×2；过滤口径正确
#
# 注入方式：把真 deadlines.sh 拷进临时目录，旁边放一个假 canvas.sh
#   喂已知数据 —— 这样自检跟你本机有没有配 token 无关。
#
# 用法：  bash scripts/selftest_deadlines.sh
# 退出码：0 = 全过；1 = 有失败

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "Deadline 情报站 · 自检"
echo

BIN="$(mktemp -d)"
LIB="$(mktemp -d)"
trap 'rm -rf "$BIN" "$LIB"' EXIT

cp "$HERE/_common.sh" "$HERE/deadlines.sh" "$BIN/"
chmod +x "$BIN/deadlines.sh"

# ---- 假 canvas.sh：3 门课，作业日期相对“现在”生成，永远新鲜 ----
cat > "$BIN/canvas.sh" <<'FAKE'
#!/bin/bash
PY="${SC_PY_REAL:-python3}"
case "${1:-}" in
  courses)
    $PY -c "import json; print(json.dumps([
      {'id':1,'course_code':'DEMO101','name':'假课一'},
      {'id':2,'course_code':'DEMO102','name':'假课二'},
      {'id':3,'course_code':'DEMO103','name':'坏课'}]))" ;;
  assignments)
    case "$2" in
      1) $PY -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([
  {'id':11,'name':'Essay 1','due_at':d(10),'points_possible':20,'html_url':'http://x/11','submission':{'workflow_state':'unsubmitted'}},
  {'id':12,'name':'Quiz 1','due_at':d(-48),'points_possible':10,'html_url':'http://x/12','submission':{'workflow_state':'unsubmitted'}},
  {'id':13,'name':'Reading submitted','due_at':d(120),'submission':{'workflow_state':'submitted'}},
  {'id':14,'name':'No-due task','due_at':None,'submission':{}}]))" ;;
      2) $PY -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([
  {'id':21,'name':'Lab report','due_at':d(50),'points_possible':15,'html_url':'http://x/21','submission':{'workflow_state':'unsubmitted'}},
  {'id':22,'name':'Far future','due_at':d(960),'points_possible':30,'submission':{'workflow_state':'unsubmitted'}},
  {'id':23,'name':'In 30 days','due_at':d(720),'submission':{'workflow_state':'unsubmitted'}}]))" ;;
      3) echo "fake boom" >&2; exit 1 ;;
    esac ;;
  *) echo "fake canvas: unknown command $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/canvas.sh"

# ---------------------------------------------------------------- ① board
OUT="$(bash "$BIN/deadlines.sh" board --lib "$LIB" 2>&1)"; RC=$?
BOARD="$LIB/DEADLINES.md"

if [ "$RC" -eq 0 ] && [ -f "$BOARD" ]; then
  ok "board 正常退出并生成 DEADLINES.md"
else
  bad "board 退出码 ${RC} 或没生成看板"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

for want in '已逾期未交（1）' '24 小时内（1）' '3 天内（1）' '21 天内（0）' '更远（21 天以外）（2）'; do
  if grep -q "$want" "$BOARD"; then
    ok "分层正确：$want"
  else
    bad "看板缺分层或计数不对：$want"
  fi
done

# 逾期条目要带「已逾期 N 天」
if grep -q "已逾期 [0-9]* 天" "$BOARD"; then
  ok "逾期条目带逾期天数"
else
  bad "逾期条目没有逾期天数标注"
fi

# ---------------------------------------------------------------- ② 排除项
if grep -q "Reading submitted" "$BOARD"; then
  bad "已提交的作业混进了看板"
else
  ok "已提交的作业不进看板"
fi
if grep -q "No-due task" "$BOARD"; then
  bad "无截止日期的作业混进了看板"
else
  ok "无截止日期的作业不进看板"
fi
if grep -q "1 项无截止日期未列入" "$BOARD" && grep -q "另有 1 项已提交" "$BOARD"; then
  ok "排除项在头部如实报数"
else
  bad "头部没报排除项数量"
fi

# ---------------------------------------------------------------- ③ 失败可见
if grep -q "1 门课的作业读取失败" "$BOARD" && printf '%s' "$OUT" | grep -q "WARN.*DEMO103"; then
  ok "读取失败进 WARN 和看板头部（不冒充数据齐全）"
else
  bad "读取失败被吞了 —— 假绿灯复活"
fi

# 排序：逾期条目出现在 24h 条目之前
if [ "$(grep -n 'Quiz 1' "$BOARD" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Essay 1' "$BOARD" | head -1 | cut -d: -f1)" ]; then
  ok "条目按截止时间排序（逾期在前）"
else
  bad "排序不对"
fi

# ---------------------------------------------------------------- ④ brief
B_OUT="$(bash "$BIN/deadlines.sh" brief --lib "$LIB" 2>/dev/null)"
if printf '%s' "$B_OUT" | grep -q "Quiz 1" && printf '%s' "$B_OUT" | grep -q "Essay 1" \
   && printf '%s' "$B_OUT" | grep -q "Lab report" \
   && ! printf '%s' "$B_OUT" | grep -q "Far future" \
   && ! printf '%s' "$B_OUT" | grep -q "In 30 days"; then
  ok "brief 默认 3 天内含逾期，不含远期"
else
  bad "brief 选取范围不对"
  printf '%s\n' "$B_OUT" | sed 's/^/       /'
fi

B0="$(bash "$BIN/deadlines.sh" brief --lib "$LIB" --within 0 2>/dev/null)"
if printf '%s' "$B0" | grep -q "Quiz 1" && ! printf '%s' "$B0" | grep -q "Essay 1"; then
  ok "--within 0 只报逾期"
else
  bad "--within 0 语义不对"
fi

B30="$(bash "$BIN/deadlines.sh" brief --lib "$LIB" --within 30 2>/dev/null)"
if printf '%s' "$B30" | grep -q "In 30 days" && ! printf '%s' "$B30" | grep -q "Far future"; then
  ok "--within 30 边界正确（30 天内含，40 天外不含）"
else
  bad "--within 30 边界不对"
fi

if printf '%s' "$B_OUT" | grep -qE '^🔴|^[0-9]-|逾期'; then
  ok "brief 逾期条目带红色标识"
else
  bad "brief 逾期条目没有标识"
fi

# ---------------------------------------------------------------- ⑤ 降级与参数
LIB2="$(mktemp -d)"
cat > "$BIN/canvas_dead.sh" <<'FAKE2'
#!/bin/bash
echo "connection refused" >&2
exit 1
FAKE2
chmod +x "$BIN/canvas_dead.sh"
mv "$BIN/canvas.sh" "$BIN/canvas_good.sh"
cp "$BIN/canvas_dead.sh" "$BIN/canvas.sh"
OUT="$(bash "$BIN/deadlines.sh" board --lib "$LIB2" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "读不到"; then
  ok "Canvas 全挂时明确报错（退出码 ${RC}）"
else
  bad "Canvas 挂了还退出码 ${RC} —— 可能给了假绿灯"
fi
mv "$BIN/canvas_good.sh" "$BIN/canvas.sh"
rm -f "$BIN/canvas_dead.sh"

OUT="$(bash "$BIN/deadlines.sh" brief --lib "$LIB" --within abc 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "非负整数"; then
  ok "--within 非数字明确报错"
else
  bad "--within abc 竟然退出码 ${RC}"
fi

# ---------------------------------------------------------------- ⑥ ics 导出
# 段 A：默认注入含坏课 DEMO103 —— ics 必须拒绝生成（半空的 .ics 比没有更害人）
rm -f "$LIB/deadline.ics"
OUT="$(bash "$BIN/deadlines.sh" ics --lib "$LIB" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "拒绝生成" && [ ! -f "$LIB/deadline.ics" ]; then
  ok "读取失败时 ics 拒绝生成（红线生效）"
else
  bad "读取失败还生成了 ics（RC=${RC}）—— 假绿灯"
fi

# 段 B：全好 canvas（无坏课），多带一条逾期超 30 天的旧账测 --include-late
cat > "$BIN/canvas.sh" <<'FAKE3'
#!/bin/bash
PY="${SC_PY_REAL:-python3}"
case "${1:-}" in
  courses)
    $PY -c "import json; print(json.dumps([
      {'id':1,'course_code':'DEMO101','name':'假课一'},
      {'id':2,'course_code':'DEMO102','name':'假课二'}]))" ;;
  assignments)
    case "$2" in
      1) $PY -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([
  {'id':11,'name':'Essay 1','due_at':d(10),'points_possible':20,'html_url':'http://x/11','submission':{'workflow_state':'unsubmitted'}},
  {'id':12,'name':'Quiz 1','due_at':d(-48),'points_possible':10,'html_url':'http://x/12','submission':{'workflow_state':'unsubmitted'}},
  {'id':13,'name':'Reading submitted','due_at':d(120),'submission':{'workflow_state':'submitted'}},
  {'id':14,'name':'No-due task','due_at':None,'submission':{}}]))" ;;
      2) $PY -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = lambda h: (now + datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([
  {'id':21,'name':'Lab report','due_at':d(50),'points_possible':15,'html_url':'http://x/21','submission':{'workflow_state':'unsubmitted'}},
  {'id':22,'name':'Far future','due_at':d(960),'points_possible':30,'submission':{'workflow_state':'unsubmitted'}},
  {'id':23,'name':'In 30 days','due_at':d(720),'submission':{'workflow_state':'unsubmitted'}},
  {'id':24,'name':'Old Late','due_at':d(-800),'submission':{'workflow_state':'unsubmitted'}}]))" ;;
      *) echo "fake canvas: unknown command $2" >&2; exit 1 ;;
    esac ;;
  *) echo "fake canvas: unknown command $1" >&2; exit 1 ;;
esac
FAKE3
chmod +x "$BIN/canvas.sh"

ICS="$LIB/deadline.ics"
OUT="$(bash "$BIN/deadlines.sh" ics --lib "$LIB" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$ICS" ]; then
  ok "全好数据时 ics 正常生成"
else
  bad "全好数据 ics 却失败（RC=${RC}）：$OUT"
fi

NV="$(grep -c 'BEGIN:VEVENT' "$ICS" || true)"
if [ "$NV" -eq 5 ]; then
  ok "默认导出 5 条（4 条正常 + 逾期 2 天；逾期 30 天外旧账不导）"
else
  bad "VEVENT 数不对：${NV}（预期 5）"
fi
if [ "$(grep -c 'UID:canvas-' "$ICS")" -eq "$NV" ] && [ "$(sort -u "$ICS" | grep -c 'UID:canvas-')" -eq "$NV" ]; then
  ok "UID 每事件一个且唯一"
else
  bad "UID 缺失或重复"
fi
if [ "$(grep -c 'BEGIN:VALARM' "$ICS")" -eq $((NV * 2)) ]; then
  ok "每事件双层提醒（VALARM ×2）"
else
  bad "VALARM 数量不对"
fi
if grep -q $'\r' "$ICS" && [ "$(grep -c $'\r$' "$ICS")" -eq "$(wc -l < "$ICS" | tr -d ' ')" ]; then
  ok "全文件 CRLF 换行"
else
  bad "换行不是 CRLF —— 日历 App 可能拒收"
fi
if grep -q 'Quiz 1' "$ICS" && ! grep -q 'Old Late' "$ICS" \
   && ! grep -q 'Reading submitted' "$ICS" && ! grep -q 'No-due task' "$ICS"; then
  ok "口径正确：逾期 2 天在、旧账/已提交/无 due 不在"
else
  bad "ics 过滤口径不对"
fi
if grep -q 'http://x/11' "$ICS" && grep -q 'VERSION:2.0' "$ICS" && grep -q 'DTSTAMP:' "$ICS"; then
  ok "链接、版本、DTSTAMP 齐全"
else
  bad "必备字段缺失"
fi

# UID 可复现：连跑两次 UID 集合一致（假 canvas 的 due_at 按当前时间生成，
#   DTSTART 本来会漂几秒 —— UID 稳定才是「重跑覆盖不重复导入」的保证）
cp "$ICS" "$LIB/.ics1"
bash "$BIN/deadlines.sh" ics --lib "$LIB" >/dev/null 2>&1
if diff <(grep '^UID:' "$LIB/.ics1") <(grep '^UID:' "$ICS") >/dev/null; then
  ok "重跑覆盖且 UID 稳定（不重复导入）"
else
  bad "重跑 UID 集合变了 —— UID 不稳定"
fi

OUT="$(bash "$BIN/deadlines.sh" ics --lib "$LIB" --within 30 2>&1)"
if printf '%s' "$OUT" | grep -q "已导出 3 条" && grep -q 'In 30 days' "$ICS" \
   && ! grep -q 'Far future' "$ICS" && ! grep -q 'Quiz 1' "$ICS"; then
  ok "--within 30：未来 30 天内（含逾期 0 条），40 天外与逾期不导"
else
  bad "--within 30 过滤不对：$OUT"
fi

bash "$BIN/deadlines.sh" ics --lib "$LIB" --include-late >/dev/null 2>&1
if grep -q 'Old Late' "$ICS"; then
  ok "--include-late 放开旧账"
else
  bad "--include-late 没放开旧账"
fi

OUT="$(bash "$BIN/deadlines.sh" board --lib "$LIB" --include-late 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "只对 ics"; then
  ok "--include-late 误用于 board 明确报错"
else
  bad "--include-late 用在 board 竟然 RC=${RC}"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "结果：${pass} 通过 / ${fail} 失败"
[ "${fail}" -eq 0 ] && echo "✅ Deadline 情报站行为正确" || echo "❌ 有行为偏离承诺"
exit $([ "${fail}" -eq 0 ] && echo 0 || echo 1)
