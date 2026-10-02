#!/usr/bin/env bash
# daily_digest.sh — 每日待办播报（只读）
#
# 干什么：一条命令吐出「今天有什么没干完」，给每日提醒的自动化吃：
#   【Deadline 临期】  逾期未交 + N 天内要交的（来自 deadlines.sh brief）
#   【复习笔记欠账】  已上过（PROGRESS taughtUpTo 之内）、但还没有复习笔记的讲次
#   【预习缺口】      下一讲还没有课前预习包的课
#
# 判定原则（与 lib_doctor 同源）：
#   笔记跟着课程时间走 —— 缺口 = 讲次 ≤ taughtUpTo 且无笔记。
#   课件提前传 ≠ 课已上过；PROGRESS 没设或未核对时如实声明，不硬判。
#
# 用法：
#   daily_digest.sh [--lib DIR] [--deadline-within N] [--preview-ahead N]
#     --deadline-within N   Deadline 提醒窗口（天），默认 3
#     --preview-ahead N     预习提前量（讲），默认 1 —— 安装引导 ⑤½ 由使用者自己选
#
# 自动化提示词形状（建自动化时照抄这个语义）：
#   「到点了，跑 daily_digest.sh，把输出原样转述给使用者；
#     输出『今日无待办』时也如实说，一个字都不要编。」

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
WITHIN="${DEADLINE_WITHIN:-3}"
AHEAD="${PREVIEW_AHEAD:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --lib)             [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; shift 2 ;;
    --deadline-within) [ $# -ge 2 ] || die "--deadline-within 后面要跟天数"; WITHIN="$2"; shift 2 ;;
    --preview-ahead)   [ $# -ge 2 ] || die "--preview-ahead 后面要跟讲数"; AHEAD="$2"; shift 2 ;;
    *) die "不认识的参数：$1" ;;
  esac
done
case "$WITHIN" in ''|*[!0-9]*) die "--deadline-within 要是非负整数天数" ;; esac
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

echo "【Deadline 临期（${WITHIN} 天内 + 已逾期）】"
if ! bash "$DEADLINES" brief --lib "$LIB" --within "$WITHIN" 2>/dev/null; then
  echo "（Canvas 读不到 —— deadline 不可用；接好 token 后恢复）"
fi

# ---- 学习债：笔记缺口（判定与 lib_doctor 的 coverage 同源） ----
$PY - "$LIB" "$AHEAD" <<'PY'
import json, os, re, sys, datetime

lib, ahead = sys.argv[1], int(sys.argv[2])
courses_md = os.path.join(lib, 'COURSES.md')
now = datetime.datetime.now().astimezone()

PROGRESS_RE = re.compile(r"<!--\s*PROGRESS\s*v1\s*(\{.*?\})\s*-->", re.S)

def read(p):
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        return ''

def cn_num_to_int(s):
    """中文数字 → int（十位结构正确：二十=20、二十一=21、十二=12）。"""
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

print()
print('【复习笔记欠账】')

progress = None
if os.path.exists(courses_md):
    m = PROGRESS_RE.search(read(courses_md))
    if m:
        try:
            d = json.loads(m.group(1))
            progress = d if isinstance(d, dict) else None
        except Exception:
            progress = None

if not progress:
    print('- （PROGRESS 块未设置 —— 无法判定笔记欠账。先在 COURSES.md 填各课 taughtUpTo）')
    print()
    print(f'【预习缺口（提前 {ahead} 讲）】')
    print('- （同上，无法判定）')
    sys.exit(0)

prog_courses = {}
for c in progress.get('courses') or []:
    if isinstance(c, dict) and c.get('code'):
        prog_courses[str(c['code'])] = c

# 扫 notes/（递归）：按文件名归课、归讲次
review, preview = {}, {}
notes_dir = os.path.join(lib, 'notes')
if os.path.isdir(notes_dir):
    for root, dirs, files in os.walk(notes_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fn in files:
            rel = os.path.relpath(os.path.join(root, fn), notes_dir)
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
            if '预习' in rel:
                preview.setdefault(code, set()).add(s)
            else:
                review.setdefault(code, set()).add(s)

def sort_key(s):
    b = sess_base(s)
    return (b if b is not None else 999, s)

unconfirmed = progress.get('confirmed') is not True
gaps_total = 0
for code in sorted(prog_courses):
    pc = prog_courses[code]
    limit = pc.get('taughtUpTo')
    if not isinstance(limit, int):
        print(f'- {code}：未声明 taughtUpTo —— 不判定笔记欠账')
        continue
    noted = review.get(code, set())
    due = {str(i) for i in range(1, limit + 1)}
    miss = sorted({s for s in due
                   if s not in noted and (sess_base(s) is None or sess_base(s) not in noted)},
                  key=sort_key)
    if miss:
        gaps_total += len(miss)
        print(f'- {code}：已上到第 {limit} 讲，缺复习笔记 → 第 {", ".join(miss)} 讲'
              + ('（最新缺的优先补）' if miss else ''))
    else:
        print(f'- {code}：已上到第 {limit} 讲，复习笔记齐')
if gaps_total == 0:
    print('- 今日无复习笔记欠账 🎉')
if unconfirmed:
    print('- ⚠️ 教学进度尚未与使用者核对（confirmed: false），欠账清单以当前声明为准')

print()
print(f'【预习缺口（提前 {ahead} 讲）】')
prev_gaps = 0
for code in sorted(prog_courses):
    pc = prog_courses[code]
    limit = pc.get('taughtUpTo')
    if not isinstance(limit, int):
        continue
    want = [limit + i for i in range(1, ahead + 1)]
    pset = preview.get(code, set())
    missing = [n for n in want if not (str(n) in pset or n in pset)]
    span = f'第 {want[0]} 讲' if ahead == 1 else f'第 {want[0]}–{want[-1]} 讲'
    if not missing:
        print(f'- {code}：往后 {ahead} 讲（{span}）预习包已就绪')
    else:
        prev_gaps += len(missing)
        miss_label = f'第 {missing[0]} 讲' if len(missing) == 1 \
            else f'第 {", ".join(str(m) for m in missing)} 讲'
        print(f'- {code}：缺课前预习包 → {miss_label}（预习提前量 = {ahead} 讲，建议上课前一天做完）')
if prev_gaps == 0:
    print('- 预习包都齐 🎉')

print()
total = gaps_total + prev_gaps
print(f'—— 学习债合计：复习缺口 {gaps_total} 讲 + 预习缺口 {prev_gaps} 门 ——'
      if total else '—— 今日无学习债 ——')
PY

# ---- 末尾：背单词引导行（「今日有人味儿的提醒」，vocab.sh hint；可配置关闭，失败不挡播报）----
VOCAB="${HERE}/vocab.sh"
if [ -f "$VOCAB" ]; then
  echo
  bash "$VOCAB" hint --lib "$LIB" || true
fi
