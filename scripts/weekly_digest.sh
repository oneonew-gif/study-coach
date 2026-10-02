#!/usr/bin/env bash
# weekly_digest.sh — 每周复盘（只读）
#
# 干什么：每周一条，管趋势。daily_digest.sh 管「今天欠什么」，本脚本管「这周整体怎么样」：
#   【本周产出】      notes/ 近 7 天新增的复习笔记 / 预习包（按文件修改时间统计）
#   【学习债趋势】    本次复习缺口 + 预习缺口 vs 上次快照（digest/weekly-stats.json）—— 涨了还是消了
#   【Deadline 未来一周】 deadlines.sh brief --within 7（临期 + 逾期）
#   【下周预告】      deadlines.sh brief --from 7 --within 7（第 7–14 天要交的，提前心里有数）
#   【一句总评】      只基于上面数字的规则式总结，不搞鸡汤
#
# 判定原则（与 daily_digest 同源）：
#   笔记跟着课程时间走 —— 缺口 = 讲次 ≤ taughtUpTo 且无笔记；
#   预习提前量同 daily_digest（PREVIEW_AHEAD / --preview-ahead，默认 1）。
#
# 存档：每次跑完写 <库根目录>/digest/weekly-<年-周>.md 报告 + 刷新 weekly-stats.json 快照。
#
# 用法：
#   weekly_digest.sh [--lib DIR] [--days N] [--preview-ahead N]
#     --days N            「本周产出」的统计窗口（天），默认 7
#     --preview-ahead N   预习提前量（讲），默认 1 —— 与 daily_digest 同一口径
#
# 排程（装的时候问使用者，不许替人定）：一条**周** rrule（星期几 + 几点由用户说），
#   提示词形状：「到点了，跑 scripts/weekly_digest.sh，把输出原样转述给使用者。」

set -euo pipefail

# ---- 公共运行时：Python 选择（真跑验证）+ UTF-8 + Windows 路径规范化，见 _common.sh ----
# 用法：$PY 调用时**不要加引号**（"py -3" 需要拆成两个词）
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
[ -n "$PY" ] || { printf 'ERROR: 没找到 Python 3 —— 试过 python3 / python / py -3。\n' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEADLINES="${HERE}/deadlines.sh"
WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

MODE="${1:-}"
case "$MODE" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

LIB="${CANVAS_LIB:-}"
DAYS="${WEEKLY_DAYS:-7}"
AHEAD="${PREVIEW_AHEAD:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --lib)           [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; shift 2 ;;
    --days)          [ $# -ge 2 ] || die "--days 后面要跟天数"; DAYS="$2"; shift 2 ;;
    --preview-ahead) [ $# -ge 2 ] || die "--preview-ahead 后面要跟讲数"; AHEAD="$2"; shift 2 ;;
    *) die "不认识的参数：$1" ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) die "--days 要是非负整数天数" ;; esac
case "$AHEAD" in ''|*[!0-9]*) die "--preview-ahead 要是正整数讲数" ;; esac
[ "$AHEAD" -ge 1 ] && [ "$AHEAD" -le 10 ] || die "--preview-ahead 取值 1–10 讲（再远就超出课程节奏了）"

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
LIB="$(sc_path "${LIB}")"
[ -n "${LIB}" ] || die "还没配置资料库路径。把 library 写进 ${CONFIG}，或用 --lib 指定。"
[ -d "${LIB}" ] || die "资料库不存在：${LIB}"

REPORT_DIR="${LIB}/digest"
mkdir -p "${REPORT_DIR}"
STAMP="$(date +%G-W%V)"
REPORT="${REPORT_DIR}/weekly-${STAMP}.md"
NOW_TS="$(date '+%Y-%m-%d %H:%M')"

{
  echo "# 周报复盘 · ${STAMP}"
  echo
  echo "> 生成时间：${NOW_TS} · 来源：本地资料库 + Canvas（只读）"
  echo

  # ---- ① 本周产出（近 N 天 notes/ 新增）----
  $PY - "$LIB" "$DAYS" <<'PY'
import os, sys, datetime, time

lib, days = sys.argv[1], int(sys.argv[2])
cutoff = time.time() - days * 86400
review, preview = [], []
notes_dir = os.path.join(lib, 'notes')
if os.path.isdir(notes_dir):
    for root, dirs, files in os.walk(notes_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fn in files:
            p = os.path.join(root, fn)
            try:
                mt = os.path.getmtime(p)
            except Exception:
                continue
            if mt < cutoff:
                continue
            rel = os.path.relpath(p, notes_dir)
            (preview if '预习' in rel else review).append((mt, rel))

print(f'【本周产出（近 {days} 天）】')
if not review and not preview:
    print(f'- 近 {days} 天 notes/ 没有新增笔记')
else:
    if review:
        print(f'- 复习笔记 {len(review)} 份：' + '；'.join(r for _, r in sorted(review, reverse=True)[:8])
              + ('…' if len(review) > 8 else ''))
    if preview:
        print(f'- 预习包 {len(preview)} 份：' + '；'.join(r for _, r in sorted(preview, reverse=True)[:8])
              + ('…' if len(preview) > 8 else ''))
print()
PY

  # ---- ② 学习债趋势（与 daily_digest 同源判定 + 快照对比）----
  $PY - "$LIB" "$AHEAD" <<'PY'
import json, os, re, sys, datetime

lib, ahead = sys.argv[1], int(sys.argv[2])
courses_md = os.path.join(lib, 'COURSES.md')
now = datetime.datetime.now().astimezone()
STATS = os.path.join(lib, 'digest', 'weekly-stats.json')

PROGRESS_RE = re.compile(r"<!--\s*PROGRESS\s*v1\s*(\{.*?\})\s*-->", re.S)

def read(p):
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        return ''

def cn_num_to_int(s):
    unit = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
            '六': 6, '七': 7, '八': 8, '九': 9}
    if not s:
        return None
    if s == '十':
        return 10
    if '十' in s:
        a, _, b = s.partition('十')
        tens = unit.get(a, 1) if a else 1
        ones = unit.get(b, 0) if b else 0
        return tens * 10 + ones
    return unit.get(s) if len(s) == 1 else None

def session_from_name(n):
    m = re.search(r'第([一二三四五六七八九十]+|\d+)讲', n)
    if not m:
        return None
    t = m.group(1)
    if t.isdigit():
        v = int(t)
    else:
        v = cn_num_to_int(t)
        if v is None:
            return None
    return str(v)

def sess_base(s):
    m = re.match(r'^(\d+)', str(s))
    return int(m.group(1)) if m else None

# --- 与 daily_digest 同源的缺口计算 ---
gaps_total, prev_gaps, prog_courses = 0, 0, {}
progress = None
if os.path.exists(courses_md):
    m = PROGRESS_RE.search(read(courses_md))
    if m:
        try:
            d = json.loads(m.group(1))
            progress = d if isinstance(d, dict) else None
        except Exception:
            progress = None

if progress:
    for c in progress.get('courses') or []:
        if isinstance(c, dict) and c.get('code'):
            prog_courses[str(c['code'])] = c

review, preview = {}, {}
notes_dir = os.path.join(lib, 'notes')
if os.path.isdir(notes_dir):
    for root, dirs, files in os.walk(notes_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fn in files:
            code = None
            for k in prog_courses:
                if fn.startswith(k):
                    code = k
                    break
            if not code:
                continue
            s = session_from_name(fn)
            if not s:
                continue
            rel = os.path.relpath(os.path.join(root, fn), notes_dir)
            if '预习' in rel:
                preview.setdefault(code, set()).add(s)
            else:
                review.setdefault(code, set()).add(s)

def sort_key(s):
    b = sess_base(s)
    return (b if b is not None else 999, s)

newest_miss = []   # (code, [missing]) 缺口最多的课程，供总评点名
if progress:
    for code in sorted(prog_courses):
        pc = prog_courses[code]
        limit = pc.get('taughtUpTo')
        if not isinstance(limit, int):
            continue
        noted = review.get(code, set())
        due = {str(i) for i in range(1, limit + 1)}
        miss = sorted({s for s in due
                       if s not in noted and (sess_base(s) is None or sess_base(s) not in noted)},
                      key=sort_key)
        gaps_total += len(miss)
        if miss:
            newest_miss.append((code, limit, miss))
        nxt_want = [limit + i for i in range(1, ahead + 1)]
        pset = preview.get(code, set())
        prev_gaps += sum(1 for n in nxt_want if not (str(n) in pset or n in pset))

# --- 与上次快照对比 ---
def arrow(cur, prev):
    d = cur - prev
    if d > 0:
        return f'（上次 {prev} → ↑{d}）'
    if d < 0:
        return f'（上次 {prev} → ↓{-d}）'
    return f'（上次 {prev} → 持平）'

print('【学习债趋势】')
if not progress:
    print('- （PROGRESS 块未设置 —— 无法判定学习债。先在 COURSES.md 填各课 taughtUpTo）')
    cur_review, cur_prev = None, None
else:
    cur_review, cur_prev = gaps_total, prev_gaps
    try:
        old = json.load(open(STATS, encoding='utf-8'))
        old_r = old.get('reviewGaps') if isinstance(old.get('reviewGaps'), int) else None
        old_p = old.get('previewGaps') if isinstance(old.get('previewGaps'), int) else None
    except Exception:
        old_r = old_p = None
    if old_r is None:
        print(f'- 复习缺口 {gaps_total} 讲 · 预习缺口 {prev_gaps} 门（上次没有快照 —— 从这周开始记趋势）')
    else:
        print(f'- 复习缺口 {gaps_total} 讲{arrow(gaps_total, old_r)}'
              f' · 预习缺口 {prev_gaps} 门{arrow(prev_gaps, old_p)}')
    if unconfirmed := (progress.get('confirmed') is not True):
        print('- ⚠️ 教学进度尚未与使用者核对（confirmed: false），以当前声明为准')

# --- 刷新快照（本轮结果留给下周对比） ---
try:
    os.makedirs(os.path.dirname(STATS), exist_ok=True)
    json.dump({'savedAt': now.strftime('%Y-%m-%d %H:%M'),
               'reviewGaps': cur_review, 'previewGaps': cur_prev},
              open(STATS, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
except Exception:
    pass

# 给总评用的中间结果落盘（bash 侧再取）
import json as _j
_j.dump({'gapsTotal': gaps_total or 0, 'previewGaps': prev_gaps or 0,
         'newestMiss': [[c, l, m[:3]] for c, l, m in newest_miss],
         'hasProgress': progress is not None},
        open(os.path.join(lib, 'digest', '.weekly-tmp.json'), 'w', encoding='utf-8'),
        ensure_ascii=False)
print()
PY

  # ---- ③ Deadline 未来一周 ----
  echo "【Deadline 未来一周（7 天内 + 已逾期）】"
  if ! bash "$DEADLINES" brief --lib "$LIB" --within 7 2>/dev/null; then
    echo "（Canvas 读不到 —— deadline 不可用；接好 token 后恢复）"
  fi
  echo

  # ---- ④ 下周预告（第 7–14 天）----
  echo "【下周预告（第 7–14 天要交的）】"
  if ! bash "$DEADLINES" brief --lib "$LIB" --from 7 --within 7 2>/dev/null; then
    echo "（Canvas 读不到 —— 下周预告不可用）"
  fi
  echo

  # ---- ⑤ 一句总评（只基于数字的规则式总结）----
  echo "【总评】"
  $PY - "$LIB" <<'PY'
import json, os, sys

lib = sys.argv[1]
tmp_p = os.path.join(lib, 'digest', '.weekly-tmp.json')
try:
    t = json.load(open(tmp_p, encoding='utf-8'))
except Exception:
    t = {}
finally:
    try:
        os.remove(tmp_p)
    except Exception:
        pass

lines = []
if not t.get('hasProgress'):
    lines.append('- 教学进度没设，欠账算不了 —— 先把 COURSES.md 的 PROGRESS 补上。')
else:
    g, p = t.get('gapsTotal', 0), t.get('previewGaps', 0)
    miss = t.get('newestMiss') or []
    if g == 0 and p == 0:
        lines.append('- 本周学习债清零：复习笔记和预习包都跟上了，节奏健康。')
    else:
        worst = max(miss, key=lambda x: len(x[2])) if miss else None
        if worst:
            lines.append(f"- 欠账集中在 {worst[0]}：缺复习笔记 {len(worst[2])} 讲（{', '.join(worst[2])}）—— 下周优先补这门。")
        if p > 0:
            lines.append(f'- 还有 {p} 个预习包没备齐，建议上课前一天做完。')

lines = [l for l in lines if l]
if not lines:
    lines = ['- 数据不足，无法给出有依据的总评（不编）。']
for l in lines:
    print(l)
PY

  # ---- 末尾：背单词引导行（进报告存档；可配置关闭，失败不挡周报）----
  VOCAB="${HERE}/vocab.sh"
  if [ -f "$VOCAB" ]; then
    echo
    bash "$VOCAB" hint --lib "$LIB" || true
  fi
} | tee "${REPORT}" >/dev/null

cat "${REPORT}"
echo
echo "（报告已存档：${REPORT}）"
