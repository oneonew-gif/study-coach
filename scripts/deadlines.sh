#!/usr/bin/env bash
# deadlines.sh — Deadline 情报站（只读）
#
# 干什么：把 Canvas 上所有在读课程的作业/测验截止日期拉下来，
#         按紧急度分层生成 <库根目录>/DEADLINES.md 看板；
#         另有 brief 模式，只吐临期条目——给定时提醒的自动化吃。
#
# 只读保证：本脚本**不直接发任何 HTTP 请求**，全部转发给同目录的 canvas.sh，
#          而 canvas.sh 只实现 GET。想破口必须同时改两个文件 —— 这是刻意的。
#
# 用法：
#   deadlines.sh board  [--lib DIR] [--within N]              生成 DEADLINES.md 看板 + 打印摘要
#   deadlines.sh brief  [--lib DIR] [--within N] [--from N]   只打印临期条目（默认 3 天内 + 已逾期）
#                                                             --from 7 = 只看第 7–14 天的（下周预告用，
#                                                             此时不含逾期项）；--from 只对 brief 生效
#   deadlines.sh ics    [--lib DIR] [--within N] [--include-late]  导出 .ics 日历文件
#                                                             默认导全部未交（逾期超 30 天的旧账不导，
#                                                             --include-late 放开）；--within N = 只导未来 N 天
#   deadlines.sh help
#
# 紧急度分层（board）：
#   🔴 已逾期未交 · 🟠 24 小时内 · 🟡 3 天内 · 🔵 7 天内 · ⚪ 21 天内 · 灰 更远
#   已提交的不进分层，只在尾部报个数；没有 due_at 的作业不进看板（无法判急）。
#
# 库路径来源：--lib 参数 > 环境变量 CANVAS_LIB > <WORKBUDDY_HOME>/study-coach.json 的 library
# 学期标识来源：环境变量 CANVAS_TERM > <WORKBUDDY_HOME>/study-coach.json 的 term（盖在看板头上）
# WORKBUDDY_HOME 默认为 ~/.workbuddy，可通过环境变量覆盖。
#
# 数据可信原则：某门课的作业读不到时**明示**「N 门课读取失败」，
#   看板头部带警示。绝不因为读不到就宣称「没有 deadline」。
# ics 红线：读取失败 / 解析失败时**拒绝生成**——半空的 .ics 比没有 .ics 更害人。
#   deadline.ics 是生成物：只许重新生成，不许手改；UID 稳定可复现，重跑覆盖不重复导入。

set -euo pipefail

# ---- Python 解析：python3 → python → py -3（Windows 兼容，W2）----
if [ -z "${PY:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
    PY=python
  elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    PY="py -3"
  fi
fi
[ -n "$PY" ] || { printf 'ERROR: 没找到 Python 3 —— 试过 python3 / python / py -3。\n' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANVAS="${HERE}/canvas.sh"
WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

MODE="${1:-}"; [ $# -gt 0 ] && shift
case "$MODE" in
  board|brief|ics) : ;;
  help|-h|--help) usage; exit 0 ;;
  *) die "用法: deadlines.sh board|brief|ics [--lib DIR] [--within N]（详见 deadlines.sh help）" ;;
esac

LIB="${CANVAS_LIB:-}"
WITHIN="${DEADLINE_WITHIN:-3}"
FROM="${DEADLINE_FROM:-0}"
INCLUDE_LATE=0
WITHIN_SET=0
case "${DEADLINE_WITHIN:-}" in '') : ;; *) WITHIN_SET=1 ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --lib)    [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; shift 2 ;;
    --within) [ $# -ge 2 ] || die "--within 后面要跟天数"; WITHIN="$2"; WITHIN_SET=1; shift 2 ;;
    --from)   [ $# -ge 2 ] || die "--from 后面要跟天数"; FROM="$2"; shift 2 ;;
    --include-late) INCLUDE_LATE=1; shift ;;
    *) die "不认识的参数：$1" ;;
  esac
done
case "$WITHIN" in ''|*[!0-9]*) die "--within 要是非负整数天数（收到：${WITHIN}）" ;; esac
case "$FROM" in ''|*[!0-9]*) die "--from 要是非负整数天数（收到：${FROM}）" ;; esac
if [ "$INCLUDE_LATE" = "1" ] && [ "$MODE" != "ics" ]; then
  die "--include-late 只对 ics 模式生效"
fi

# 库路径兜底：--lib > 环境变量 > 配置文件
if [ -z "${LIB}" ] && [ -f "${CONFIG}" ]; then
  LIB="$($PY - "${CONFIG}" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(str((d or {}).get('library') or '').strip())
PY
)"
fi
[ -n "${LIB}" ] || die "还没配置资料库路径。把 library 写进 ${CONFIG}，或用 --lib 指定。"
[ -d "${LIB}" ] || die "资料库不存在：${LIB}"

# 学期标识（只作看板落款，不参与逻辑）
TERM="${CANVAS_TERM:-}"
if [ -z "${TERM}" ] && [ -f "${CONFIG}" ]; then
  TERM="$($PY - "${CONFIG}" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(str((d or {}).get('term') or '').strip())
PY
)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- ① 在读课程 ----
if ! "$CANVAS" courses > "${TMP}/courses.json" 2>"${TMP}/courses.err"; then
  msg="$(head -c 200 "${TMP}/courses.err" 2>/dev/null | tr '\n' ' ' || true)"
  die "课程列表读不到 —— Canvas 接入有问题（${msg:-原因未知}）。跑 ${CANVAS} doctor 自查。"
fi

$PY - "${TMP}/courses.json" <<'PY' > "${TMP}/course_list.tsv"
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    d = []
if not isinstance(d, list):
    d = []
for c in d:
    if not isinstance(c, dict):
        continue
    cid = str(c.get('id') or '').strip()
    if not cid:
        continue
    code = (c.get('course_code') or c.get('sis_course_id') or '').strip()
    name = (c.get('name') or '').strip()
    # TSV 安全：把制表符/换行压成空格
    code = code.replace('\t', ' ').replace('\n', ' ')
    name = name.replace('\t', ' ').replace('\n', ' ')
    print(f"{cid}\t{code}\t{name}")
PY

N_COURSES="$(grep -c . "${TMP}/course_list.tsv" 2>/dev/null || true)"
if [ "${N_COURSES:-0}" -eq 0 ]; then
  die "Canvas 返回了 0 门在读课程（enrollment_state=active）。学期没开始？还是账号里真没有课？"
fi

# ---- ② 逐课拉作业（失败记录，不吞） ----
FAIL_N=0
while IFS=$'\t' read -r cid code cname; do
  [ -n "$cid" ] || continue
  if "$CANVAS" assignments "$cid" > "${TMP}/${cid}.assignments.json" 2>"${TMP}/${cid}.err"; then
    :
  else
    msg="$(head -c 160 "${TMP}/${cid}.err" 2>/dev/null | tr '\n' ' ' || true)"
    printf '[]\n' > "${TMP}/${cid}.assignments.json"
    printf '%s\t%s\n' "$cid" "$msg" >> "${TMP}/fetch_errors.tsv"
    FAIL_N=$((FAIL_N + 1))
    warn "课程 ${code:-$cid} 作业读取失败：${msg}"
  fi
done < "${TMP}/course_list.tsv"

# ---- ③ 汇总 → 看板 / brief ----
BOARD="${LIB}/DEADLINES.md"
$PY - "$MODE" "$WITHIN" "$FROM" "$BOARD" "$TERM" "${TMP}" "$WITHIN_SET" "$INCLUDE_LATE" <<'PY'
import json, os, sys, datetime, hashlib

mode, within, from_days, board_path, term, tmp, within_set, include_late = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6],
    sys.argv[7] == '1', sys.argv[8] == '1')
now = datetime.datetime.now().astimezone()

# 课程表
courses = {}
order = []
with open(os.path.join(tmp, 'course_list.tsv'), encoding='utf-8') as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 3:
            cid, code, name = parts[0], parts[1], parts[2]
            courses[cid] = (code, name)
            order.append(cid)

# 读取失败
errors = []
err_f = os.path.join(tmp, 'fetch_errors.tsv')
if os.path.exists(err_f):
    with open(err_f, encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('\t', 1)
            cid = parts[0] if parts else ''
            msg = parts[1] if len(parts) > 1 else '原因未知'
            code = courses.get(cid, ('?', ''))[0] or cid
            errors.append((code, msg))

# 收集作业
items, submitted_n, nodue_n, badjson_n = [], 0, 0, 0
for cid in order:
    p = os.path.join(tmp, f'{cid}.assignments.json')
    try:
        asg = json.load(open(p, encoding='utf-8'))
    except Exception:
        asg = []
        badjson_n += 1
    if not isinstance(asg, list):
        asg = []
    code, name = courses.get(cid, ('?', ''))
    for a in asg:
        if not isinstance(a, dict):
            continue
        sub = a.get('submission') if isinstance(a.get('submission'), dict) else {}
        state = (sub.get('workflow_state') or '').lower()
        if state == 'submitted':
            submitted_n += 1
            continue
        due = a.get('due_at')
        if not due:
            nodue_n += 1
            continue
        try:
            d = datetime.datetime.fromisoformat(str(due).replace('Z', '+00:00')).astimezone()
        except Exception:
            nodue_n += 1
            continue
        items.append({
            'id': str(a.get('id') or '').strip(),
            'code': code or (name[:12] if name else cid),
            'course': name,
            'name': a.get('name') or '(未命名作业)',
            'due': d,
            'points': a.get('points_possible'),
            'url': a.get('html_url') or '',
        })

items.sort(key=lambda x: x['due'])

def bucket(d):
    h = (d - now).total_seconds() / 3600.0
    if h < 0:      return 0, '🔴', '已逾期未交'
    if h <= 24:    return 1, '🟠', '24 小时内'
    if h <= 72:    return 2, '🟡', '3 天内'
    if h <= 168:   return 3, '🔵', '7 天内'
    if h <= 504:   return 4, '⚪', '21 天内'
    return 5, '灰', '更远'

def fmt_dt(d):
    return d.strftime('%m-%d %H:%M')

def fmt_item(it, is_board):
    late = ''
    if it['due'] < now:
        days = int((now - it['due']).total_seconds() // 86400)
        late = f'（已逾期 {days} 天）' if days >= 1 else '（今天到期已过点）'
    pts = f" · {it['points']:g} 分" if isinstance(it['points'], (int, float)) else ''
    link = f" · [打开]({it['url']})" if is_board and it['url'] else ''
    bullet = '- ' if is_board else ''
    return f"{bullet}**[{it['code']}] {it['name']}** — 截止 {fmt_dt(it['due'])}{late}{pts}{link}"

buckets = {i: [] for i in range(6)}
for it in items:
    b, _, _ = bucket(it['due'])
    buckets[b].append(it)

ts = now.strftime('%Y-%m-%d %H:%M')

if mode == 'brief':
    warn_lines = []
    if errors:
        warn_lines.append(f"⚠️ {len(errors)} 门课读取失败，本清单可能不全")
    # within 天内 + 全部逾期；within=0 只报逾期
    # from_days > 0（周报的下周预告）：只看第 from – from+within 天，逾期项不混进来
    def _keep(it):
        h2 = (it['due'] - now).total_seconds()
        if from_days > 0:
            return from_days * 86400 < h2 <= (from_days + within) * 86400
        return bucket(it['due'])[0] == 0 or h2 <= within * 86400
    urgent = [it for it in items if _keep(it)]
    out = []
    if urgent:
        for it in urgent:
            icon = bucket(it['due'])[1]
            out.append(f"{icon} {fmt_item(it, is_board=False)}")
    elif from_days > 0:
        out.append(f"第 {from_days}–{from_days + within} 天没有要交的作业。")
    else:
        out.append(f"未来 {within} 天没有临期作业。")
    for w in warn_lines:
        print(w)
    for l in out:
        print(l)
    sys.exit(0)

# ---- ics 模式：生成 deadline.ics（CRLF，UID 稳定，VALARM 双层）----
if mode == 'ics':
    # 红线：读取失败/解析失败 → 拒绝生成，半空的 .ics 比没有更害人
    if errors or badjson_n:
        parts = []
        if errors:
            parts.append(f"{len(errors)} 门课读取失败")
        if badjson_n:
            parts.append(f"{badjson_n} 门课解析失败")
        print(f"ERROR: {'、'.join(parts)}，导出的日历会缺作业 —— 拒绝生成。"
              f"先解决 Canvas 接入问题再重跑。", file=sys.stderr)
        sys.exit(1)
    if not items:
        print("ERROR: 没有可导出的未交作业（已提交的、无截止日期的不导）。", file=sys.stderr)
        sys.exit(1)

    horizon = 30 * 86400  # 逾期超 30 天的旧账默认不导
    def _keep_ics(it):
        h2 = (it['due'] - now).total_seconds()
        if h2 >= 0:
            return (not within_set) or h2 <= within * 86400
        if within_set:
            return False  # --within = 只导未来 N 天，逾期不混入
        return include_late or -h2 <= horizon
    export = [it for it in items if _keep_ics(it)]
    if not export:
        print("ERROR: 过滤后没有可导出的作业（试试放宽 --within 或加 --include-late）。", file=sys.stderr)
        sys.exit(1)

    def ics_utc(d):
        return d.astimezone(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')

    def esc(s):
        return (str(s).replace('\\', '\\\\').replace(';', '\\;')
                .replace(',', '\\,').replace('\n', '\\n'))

    def uid_of(it):
        if it['id']:
            return f"canvas-{it['id']}@study-coach"
        raw = f"{it['code']}|{it['name']}|{it['due'].isoformat()}"
        return "canvas-" + hashlib.md5(raw.encode('utf-8')).hexdigest()[:16] + "@study-coach"

    stamp = ics_utc(now)
    out = ['BEGIN:VCALENDAR', 'VERSION:2.0',
           'PRODID:-//study-coach//Deadline Export//CN', 'CALSCALE:GREGORIAN',
           'X-WR-CALNAME:Study-Coach Deadlines']
    for it in export:
        uid = uid_of(it)
        summary = f"[{it['code']}] {it['name']}"
        pts = f" · 分值 {it['points']:g}" if isinstance(it['points'], (int, float)) else ''
        desc = (f"来自 Canvas（只读导出）{pts}"
                + (f" · 作业页: {it['url']}" if it['url'] else ''))
        out += [
            'BEGIN:VEVENT',
            f'UID:{uid}',
            f'DTSTAMP:{stamp}',
            f'DTSTART:{ics_utc(it["due"])}',
            f'DTEND:{ics_utc(it["due"] + datetime.timedelta(hours=1))}',
            f'SUMMARY:{esc(summary)}',
            f'DESCRIPTION:{esc(desc)}',
            'BEGIN:VALARM', 'ACTION:DISPLAY',
            f'DESCRIPTION:{esc(summary)}（提前 1 天）', 'TRIGGER:-P1D',
            'END:VALARM',
            'BEGIN:VALARM', 'ACTION:DISPLAY',
            f'DESCRIPTION:{esc(summary)}（提前 1 小时）', 'TRIGGER:-PT1H',
            'END:VALARM',
            'END:VEVENT',
        ]
    out.append('END:VCALENDAR')

    ics_path = os.path.join(os.path.dirname(board_path), 'deadline.ics')
    with open(ics_path, 'w', encoding='utf-8', newline='') as f:
        f.write('\r\n'.join(out) + '\r\n')
    late_n = sum(1 for it in export if it['due'] < now)
    print(f'已导出 {len(export)} 条截止项 → {ics_path}'
          + (f'（含 {late_n} 条逾期）' if late_n else ''))
    print('导入方法：macOS 双击文件进日历 App；Google Calendar 设置 → 导入。')
    print('deadline.ics 是生成物：重新导出即可刷新，别手改。')
    sys.exit(0)

# ---- board 模式：写 DEADLINES.md ----
L = []
L.append('# Deadline 看板')
L.append('')
L.append(f'> 生成时间：{ts}' + (f' · 学期 {term}' if term else '') + ' · 来源：Canvas API（只读）')
L.append(f'> 共 {len(items)} 项未交截止项' + (f'（另有 {submitted_n} 项已提交）' if submitted_n else '')
         + (f'，{nodue_n} 项无截止日期未列入' if nodue_n else ''))
L.append('')
if errors:
    L.append(f'> ⚠️ **{len(errors)} 门课的作业读取失败**，下面的清单可能不全：'
             + '；'.join(f'{c}（{m[:60]}）' for c, m in errors))
    L.append('')
if badjson_n:
    L.append(f'> ⚠️ {badjson_n} 门课的作业数据解析失败，同样可能不全。')
    L.append('')

order_b = [
    (0, '## 🔴 已逾期未交'),
    (1, '## 🟠 24 小时内'),
    (2, '## 🟡 3 天内'),
    (3, '## 🔵 7 天内'),
    (4, '## ⚪ 21 天内'),
    (5, '## 更远（21 天以外）'),
]
for b, title in order_b:
    L.append(title + f'（{len(buckets[b])}）')
    L.append('')
    if buckets[b]:
        for it in buckets[b]:
            L.append(fmt_item(it, is_board=True))
    else:
        L.append('- （无）')
    L.append('')

L.append('---')
L.append('')
L.append('*由 `deadlines.sh board` 生成；重新生成即可刷新，别手改本文件——下次刷新会覆盖。*')
L.append('')

os.makedirs(os.path.dirname(board_path), exist_ok=True)
open(board_path, 'w', encoding='utf-8').write('\n'.join(L))

SUMMARY_LABELS = {0: '🔴 已逾期', 1: '🟠 24h 内', 2: '🟡 3 天内', 3: '🔵 7 天内',
                  4: '⚪ 21 天内', 5: '更远'}
print(f'看板已更新：{board_path}')
for b, _ in order_b:
    n = len(buckets[b])
    if n:
        print(f'  {SUMMARY_LABELS[b]} {n} 项')
print(f'合计 {len(items)} 项未交'
      + (f'，另有 {submitted_n} 项已提交' if submitted_n else '')
      + (f'，{nodue_n} 项无截止日期' if nodue_n else ''))
if errors:
    print(f'⚠️ {len(errors)} 门课读取失败，清单可能不全（详见看板头部）')
print('—— 想把这些 deadline 灌进系统日历？说「导出日历」就行 ——')
PY
