#!/usr/bin/env bash
# vocab.sh — 背词教练
#
# 干什么：背「这学期课程里的活词」。词源全部有出处、有审核，服务考试和英文写作
#         （与硬红线 ⑤「术语原词」共用 quiz/terms.json 基准）。
#
# 三原则：
#   ① 不编词 —— 词库里没有就是没有，绝不现场编一份词表
#   ② 先确认再入库 —— 自动来源（探测器/提词）先进 inbox 收词箱，用户点头才进正式词库
#   ③ 状态只写 <库>/vocab/ —— 本脚本是全引擎唯一有状态写入的脚本，写入区就这一个目录
#
# 记忆算法：莱特纳 5 盒 —— 答对进下一盒，答错回盒 1；draw 优先抽盒 1、2（越不熟越常见）。
#
# 用法：
#   vocab.sh draw   [--lib DIR] [--course X] [--book 册名] [--n N] [--lecture N | --recent N]
#                   --lecture 5 = 只抽第 5 讲的词；--recent 3 = 只抽最近 3 讲的词（讲次从词条
#                   lecture 字段或 source 里的「第N讲」解析）
#                   抽词（不给答案；每词带来源标签与 id，供 grade 用）
#   vocab.sh grade  [--lib DIR] --id N --hit|--miss     记对错（答对进盒、答错回盒 1）
#   vocab.sh stats  [--lib DIR]                          各盒词数、待背数、收词箱数
#   vocab.sh add    [--lib DIR] --term 词 [--def 释义] [--course 课] [--source 来源] [--book 册]
#   vocab.sh remove [--lib DIR] --id N | --term 词 [--book 册]     删词（打印删了什么，可追溯）
#   vocab.sh import [--lib DIR] --file 词表文件 [--book 册名]      词表：每行一词，或 term<TAB>释义
#   vocab.sh import [--lib DIR] --from-terms [--course 课]        从 quiz/terms.json 术语表导入
#   vocab.sh inbox  [--lib DIR] list|add|accept|dismiss ...       收词箱（自动来源的必经之路）
#   vocab.sh hint   [--lib DIR]                                   「今日有人味儿的提醒」一行
#
# 册：默认主册 = <库>/vocab/vocab.json（课程词）；--book 名字 存成 <库>/vocab/<册名>.json

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
WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

# --lib 允许放在命令前或命令后（命令前优先级最高）
LIB_PRE=""
while [ "${1:-}" = "--lib" ]; do
  [ $# -ge 2 ] || die "--lib 后面要跟目录"
  LIB_PRE="$2"; shift 2
done

CMD="${1:-}"
case "$CMD" in
  draw|grade|stats|add|remove|import|inbox|hint) shift ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) die "不认识的命令：${CMD}（详见 vocab.sh help）" ;;
esac

LIB="${LIB_PRE:-${CANVAS_LIB:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --lib)  [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; shift 2 ;;
    *) break ;;
  esac
done

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

# hint 在没库时也要能出（digest 兜底）；其他命令没库直接报错
if [ "$CMD" != "hint" ]; then
  [ -n "${LIB}" ] || die "还没配置资料库路径。把 library 写进 ${CONFIG}，或用 --lib 指定。"
  [ -d "${LIB}" ] || die "资料库不存在：${LIB}"
fi

VOCAB_DIR="${LIB:+${LIB}/vocab}"
MAIN_JSON="${VOCAB_DIR:+${VOCAB_DIR}/vocab.json}"

# ---------------------------------------------------------------- draw
if [ "$CMD" = "draw" ]; then
  BOOK="主册"; COURSE=""; N=10; LECTURE=0; RECENT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --book)   [ $# -ge 2 ] || die "--book 后面要跟册名"; BOOK="$2"; shift 2 ;;
      --course) [ $# -ge 2 ] || die "--course 后面要跟课程代码"; COURSE="$2"; shift 2 ;;
      --n)      [ $# -ge 2 ] || die "--n 后面要跟数量"; N="$2"; shift 2 ;;
      --lecture) [ $# -ge 2 ] || die "--lecture 后面要跟讲次"; LECTURE="$2"; shift 2 ;;
      --recent) [ $# -ge 2 ] || die "--recent 后面要跟讲数"; RECENT="$2"; shift 2 ;;
      *) die "draw 不认识的参数：$1" ;;
    esac
  done
  case "$N" in ''|*[!0-9]*) die "--n 要是正整数" ;; esac
  [ "$N" -ge 1 ] || die "--n 至少为 1"
  case "$LECTURE" in ''|*[!0-9]*) die "--lecture 要是正整数讲次" ;; esac
  case "$RECENT" in ''|*[!0-9]*) die "--recent 要是正整数" ;; esac
  if [ "$LECTURE" -gt 0 ] && [ "$RECENT" -gt 0 ]; then
    die "--lecture 和 --recent 二选一"
  fi
  F="$MAIN_JSON"; [ "$BOOK" != "主册" ] && F="${VOCAB_DIR}/${BOOK}.json"
  [ -f "$F" ] || die "词库是空的（${F} 不存在）—— 先收词：出笔记时说「收进背词」、说「加个生词」、或 vocab.sh import 导词表。我不会编词。"
  $PY - "$F" "$COURSE" "$N" "$LECTURE" "$RECENT" <<'PY'
import json, sys, datetime, re

f, course, n, lecture, recent = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                                 int(sys.argv[4]), int(sys.argv[5]))
try:
    d = json.load(open(f, encoding='utf-8'))
except Exception:
    d = {}
words = d.get('words') if isinstance(d, dict) else None
words = [w for w in (words or []) if isinstance(w, dict)]
if course:
    words = [w for w in words if w.get('course') == course]

# 讲次过滤：优先词条显式 lecture 字段，否则从 source 里解析「第N讲」（含中文数字）
CN = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10}
def lect_of(w):
    if isinstance(w.get('lecture'), int):
        return w['lecture']
    src = str(w.get('source') or '')
    m = re.search(r'第\s*(\d+)\s*讲', src)
    if m:
        return int(m.group(1))
    m = re.search(r'第\s*([一二三四五六七八九十]+)\s*讲', src)
    if m:
        s = m.group(1)
        if s == '十':
            return 10
        if '十' in s:
            a, _, b = s.partition('十')
            return (CN.get(a, 1) * 10) + (CN.get(b, 0) if b else 0)
        return CN.get(s, 0)
    return 0

if lecture > 0 or recent > 0:
    for w in words:
        w['_lec'] = lect_of(w)
    if lecture > 0:
        words = [w for w in words if w['_lec'] == lecture]
    else:  # recent：只留讲次最大的 recent 讲（无讲次的词算讲次 0，不算在内）
        lecs = sorted({w['_lec'] for w in words if w['_lec'] > 0}, reverse=True)[:recent]
        words = [w for w in words if w['_lec'] in lecs]
    for w in words:
        w.pop('_lec', None)

if not words:
    print('（这册/这门课还没有词可抽。）')
    sys.exit(0)

def key(w):
    lr = w.get('lastReviewed') or ''
    try:
        return (int(w.get('box') or 1), str(lr))
    except Exception:
        return (1, str(lr))

words.sort(key=key)
picked = words[:n]
now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
print(f'—— 今日该背（{len(picked)} 词 · 盒 1、2 优先）——')
for w in picked:
    src = w.get('source') or ''
    crs = w.get('course') or ''
    tag = ' · '.join(x for x in (crs, src) if x)
    box = w.get('box') or 1
    print(f"  [{w.get('id')}] {w.get('term')}  —— {tag or '（无来源记录）'} · 盒{box}")
print()
print('（先自己回忆意思，再对答案：grade --id 编号 --hit 或 --miss）')
PY
  exit 0
fi

# ---------------------------------------------------------------- grade
if [ "$CMD" = "grade" ]; then
  ID=""; VERDICT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)    [ $# -ge 2 ] || die "--id 后面要跟编号"; ID="$2"; shift 2 ;;
      --hit)   VERDICT="hit"; shift ;;
      --miss)  VERDICT="miss"; shift ;;
      *) die "grade 不认识的参数：$1" ;;
    esac
  done
  case "$ID" in ''|*[!0-9]*) die "grade 要 --id 数字编号" ;; esac
  [ -n "$VERDICT" ] || die "grade 要 --hit 或 --miss"
  [ -f "$MAIN_JSON" ] || die "词库是空的，没词可判。"
  $PY - "$MAIN_JSON" "$ID" "$VERDICT" <<'PY'
import json, sys, datetime, os

f, id_, verdict = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(f, encoding='utf-8'))
words = d.get('words') or []
w = next((x for x in words if x.get('id') == id_), None)
if not w:
    sys.exit(f"ERROR: 编号 {id_} 不在词库里。（词被删过？用 stats 或 draw 看现有词）")
if verdict == 'hit':
    w['box'] = min(5, int(w.get('box') or 1) + 1)
    w['streak'] = int(w.get('streak') or 0) + 1
    msg = f"答对 → {w['term']} 进盒 {w['box']}"
else:
    w['box'] = 1
    w['streak'] = 0
    msg = f"答错 → {w['term']} 回盒 1（明天再见到它）"
w['lastReviewed'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(msg)
PY
  exit 0
fi

# ---------------------------------------------------------------- stats
if [ "$CMD" = "stats" ]; then
  $PY - "${VOCAB_DIR}" <<'PY'
import json, os, sys

vd = sys.argv[1]
main = os.path.join(vd, 'vocab.json')
def load(f):
    try:
        d = json.load(open(f, encoding='utf-8'))
        return d.get('words') if isinstance(d, dict) else []
    except Exception:
        return []

words = load(main)
print('—— 背词总览 ——')
if not words:
    print('主册：0 词（词库还空着）')
else:
    boxes = {}
    for w in words:
        boxes[int(w.get('box') or 1)] = boxes.get(int(w.get('box') or 1), 0) + 1
    due = sum(boxes.get(i, 0) for i in (1, 2))
    print(f"主册：{len(words)} 词 · 盒1:{boxes.get(1,0)} 盒2:{boxes.get(2,0)} "
          f"盒3:{boxes.get(3,0)} 盒4:{boxes.get(4,0)} 盒5:{boxes.get(5,0)} · 今日优先待背 {due} 词")
inbox = load(os.path.join(vd, 'inbox.json'))
if inbox:
    print(f"收词箱：{len(inbox)} 个待确认（vocab.sh inbox list 看看）")
others = [f[:-5] for f in os.listdir(vd) if f.endswith('.json') and f not in ('vocab.json', 'inbox.json')] \
    if os.path.isdir(vd) else []
if others:
    extra = sum(len(load(os.path.join(vd, o + '.json'))) for o in others)
    print(f"自定义册：{', '.join(sorted(others))}（共 {extra} 词）")
PY
  exit 0
fi

# ---------------------------------------------------------------- add
if [ "$CMD" = "add" ]; then
  TERM=""; DEF=""; COURSE=""; SOURCE=""; BOOK="主册"
  while [ $# -gt 0 ]; do
    case "$1" in
      --term)   [ $# -ge 2 ] || die "--term 后面要跟词"; TERM="$2"; shift 2 ;;
      --def)    [ $# -ge 2 ] || die "--def 后面要跟释义"; DEF="$2"; shift 2 ;;
      --course) [ $# -ge 2 ] || die "--course 后面要跟课程代码"; COURSE="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || die "--source 后面要跟来源"; SOURCE="$2"; shift 2 ;;
      --book)   [ $# -ge 2 ] || die "--book 后面要跟册名"; BOOK="$2"; shift 2 ;;
      *) die "add 不认识的参数：$1" ;;
    esac
  done
  [ -n "$TERM" ] || die "add 要 --term 词（词义必须来自课程材料或你给的原文，我不编）"
  mkdir -p "$VOCAB_DIR"
  F="$MAIN_JSON"; [ "$BOOK" != "主册" ] && F="${VOCAB_DIR}/${BOOK}.json"
  $PY - "$F" "$TERM" "$DEF" "$COURSE" "$SOURCE" <<'PY'
import json, sys, datetime, os

f, term, dfn, course, source = sys.argv[1:6]
d = {}
if os.path.exists(f):
    try:
        d = json.load(open(f, encoding='utf-8'))
    except Exception:
        d = {}
words = d.get('words') or []
if any(w.get('term', '').lower() == term.lower() for w in words):
    print(f"（{term} 已经在册，不重复加。）")
    sys.exit(0)
nid = int(d.get('nextId') or 1)
w = {'id': nid, 'term': term, 'definition': dfn or '（待补充——只许填材料或原文里的意思）',
     'course': course or '', 'source': source or '手动添加',
     'box': 1, 'streak': 0, 'lastReviewed': None,
     'addedAt': datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}
words.append(w)
d['words'] = words
d['nextId'] = nid + 1
os.makedirs(os.path.dirname(f), exist_ok=True)
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"已加入：[{nid}] {term}" + (f" · {course}" if course else '') + f"（来源：{w['source']} · 盒1）")
PY
  exit 0
fi

# ---------------------------------------------------------------- remove
if [ "$CMD" = "remove" ]; then
  ID=""; TERM=""; BOOK="主册"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)    [ $# -ge 2 ] || die "--id 后面要跟编号"; ID="$2"; shift 2 ;;
      --term)  [ $# -ge 2 ] || die "--term 后面要跟词"; TERM="$2"; shift 2 ;;
      --book)  [ $# -ge 2 ] || die "--book 后面要跟册名"; BOOK="$2"; shift 2 ;;
      *) die "remove 不认识的参数：$1" ;;
    esac
  done
  [ -n "$ID" ] || [ -n "$TERM" ] || die "remove 要 --id 编号或 --term 词"
  F="$MAIN_JSON"; [ "$BOOK" != "主册" ] && F="${VOCAB_DIR}/${BOOK}.json"
  [ -f "$F" ] || die "这册还不存在：${F}"
  $PY - "$F" "$ID" "$TERM" <<'PY'
import json, sys

f, id_, term = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(f, encoding='utf-8'))
words = d.get('words') or []
def match(w):
    if id_:
        return w.get('id') == int(id_)
    return w.get('term', '').lower() == term.lower()
hit = next((w for w in words if match(w)), None)
if not hit:
    sys.exit('ERROR: 词库里没有这个词/编号。')
words.remove(hit)
d['words'] = words
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"已删除：[{hit.get('id')}] {hit.get('term')}（来源：{hit.get('source') or '未知'} · 曾在盒 {hit.get('box')}）")
PY
  exit 0
fi

# ---------------------------------------------------------------- import
if [ "$CMD" = "import" ]; then
  FILE=""; FROM_TERMS=0; BOOK=""; COURSE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)       [ $# -ge 2 ] || die "--file 后面要跟词表文件"; FILE="$2"; shift 2 ;;
      --from-terms) FROM_TERMS=1; shift ;;
      --book)       [ $# -ge 2 ] || die "--book 后面要跟册名"; BOOK="$2"; shift 2 ;;
      --course)     [ $# -ge 2 ] || die "--course 后面要跟课程代码"; COURSE="$2"; shift 2 ;;
      *) die "import 不认识的参数：$1" ;;
    esac
  done
  mkdir -p "$VOCAB_DIR"
  if [ "$FROM_TERMS" = "1" ]; then
    [ -f "${LIB}/quiz/terms.json" ] || die "库里没有 quiz/terms.json —— 先在出笔记时把课件术语登记进术语表。"
    $PY - "$MAIN_JSON" "${LIB}/quiz/terms.json" "$COURSE" <<'PY'
import json, sys, datetime, os

f, tf, only = sys.argv[1], sys.argv[2], sys.argv[3]
t = json.load(open(tf, encoding='utf-8'))
terms = t.get('terms') or {}
d = {}
if os.path.exists(f):
    d = json.load(open(f, encoding='utf-8'))
words = d.get('words') or []
have = {w.get('term', '').lower() for w in words}
nid = int(d.get('nextId') or 1)
added = 0
for code, items in sorted(terms.items()):
    if only and code != only:
        continue
    for it in items or []:
        if not isinstance(it, dict):
            continue
        en = (it.get('en') or '').strip()
        if not en or en.lower() in have:
            continue
        words.append({'id': nid, 'term': en, 'definition': (it.get('zh') or '（待补充）'),
                      'course': code, 'source': 'quiz/terms.json 术语表',
                      'box': 1, 'streak': 0, 'lastReviewed': None,
                      'addedAt': datetime.datetime.now().strftime('%Y-%m-%d %H:%M')})
        have.add(en.lower())
        nid += 1
        added += 1
d['words'] = words
d['nextId'] = nid
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"从术语表导入 {added} 个新词进主册（原有的不重复加）。")
if added:
    print('已收词：' + '、'.join(w['term'] for w in words[-added:]))
PY
    exit 0
  fi
  [ -n "$FILE" ] || die "import 要 --file 词表文件 或 --from-terms"
  [ -f "$FILE" ] || die "词表文件不存在：${FILE}"
  BOOK="${BOOK:-自定义}"
  F="${VOCAB_DIR}/${BOOK}.json"
  $PY - "$F" "$FILE" <<'PY'
import json, sys, datetime, os

f, src = sys.argv[1], sys.argv[2]
pairs = []
for i, line in enumerate(open(src, encoding='utf-8', errors='replace'), 1):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('\t', 1)
    term = parts[0].strip()
    dfn = parts[1].strip() if len(parts) > 1 else '（待补充）'
    if term:
        pairs.append((term, dfn))
if not pairs:
    sys.exit('ERROR: 词表里没有可导入的词（每行一词，或 term<TAB>释义）。')
d = {}
if os.path.exists(f):
    d = json.load(open(f, encoding='utf-8'))
words = d.get('words') or []
have = {w.get('term', '').lower() for w in words}
nid = int(d.get('nextId') or 1)
added = 0
for term, dfn in pairs:
    if term.lower() in have:
        continue
    words.append({'id': nid, 'term': term, 'definition': dfn, 'course': '',
                  'source': f'词表导入（{os.path.basename(src)}）',
                  'box': 1, 'streak': 0, 'lastReviewed': None,
                  'addedAt': datetime.datetime.now().strftime('%Y-%m-%d %H:%M')})
    have.add(term.lower())
    nid += 1
    added += 1
d['words'] = words
d['nextId'] = nid
os.makedirs(os.path.dirname(f), exist_ok=True)
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"导入 {added} 词进册「{os.path.basename(f)[:-5]}」（原有的不重复加）。")
PY
  exit 0
fi

# ---------------------------------------------------------------- inbox
if [ "$CMD" = "inbox" ]; then
  ACTION="${1:-list}"; shift 2>/dev/null || true
  TERM=""; DEF=""; COURSE=""; SOURCE=""; ID=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lib)    [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; VOCAB_DIR="${LIB}/vocab"; MAIN_JSON="${VOCAB_DIR}/vocab.json"; IB="${VOCAB_DIR}/inbox.json"; shift 2 ;;
      --term)   [ $# -ge 2 ] || die "--term 后面要跟词"; TERM="$2"; shift 2 ;;
      --def)    [ $# -ge 2 ] || die "--def 后面要跟释义"; DEF="$2"; shift 2 ;;
      --course) [ $# -ge 2 ] || die "--course 后面要跟课程代码"; COURSE="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || die "--source 后面要跟来源"; SOURCE="$2"; shift 2 ;;
      --id)     [ $# -ge 2 ] || die "--id 后面要跟编号"; ID="$2"; shift 2 ;;
      *) die "inbox 不认识的参数：$1" ;;
    esac
  done
  mkdir -p "$VOCAB_DIR"
  IB="${VOCAB_DIR}/inbox.json"
  case "$ACTION" in
    add)
      [ -n "$TERM" ] || die "inbox add 要 --term"
      $PY - "$IB" "$TERM" "$DEF" "$COURSE" "$SOURCE" <<'PY'
import json, sys, datetime, os

f, term, dfn, course, source = sys.argv[1:6]
d = {}
if os.path.exists(f):
    try:
        d = json.load(open(f, encoding='utf-8'))
    except Exception:
        d = {}
words = d.get('words') or []
if any(w.get('term', '').lower() == term.lower() for w in words):
    print('（收词箱里已有这个词。）')
    sys.exit(0)
nid = int(d.get('nextId') or 1)
words.append({'id': nid, 'term': term, 'definition': dfn or '（待补充）',
              'course': course or '', 'source': source or '自动探测',
              'addedAt': datetime.datetime.now().strftime('%Y-%m-%d %H:%M')})
d['words'] = words
d['nextId'] = nid + 1
os.makedirs(os.path.dirname(f), exist_ok=True)
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"收词箱 +1：[{nid}] {term}（来源：{source or '自动探测'}）—— 用户确认后才进正式词库")
PY
      ;;
    list)
      $PY - "$IB" <<'PY'
import json, sys, os
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    d = {}
words = [w for w in (d.get('words') or []) if isinstance(w, dict)]
if not words:
    print('收词箱是空的。')
    sys.exit(0)
print(f'—— 收词箱（{len(words)} 个待确认）——')
for w in words:
    tag = ' · '.join(x for x in (w.get('course'), w.get('source')) if x)
    print(f"  [{w.get('id')}] {w.get('term')} —— {w.get('definition')}（{tag or '无来源'}）")
print('确认：vocab.sh inbox accept --id N   丢弃：vocab.sh inbox dismiss --id N')
PY
      ;;
    accept)
      [ -n "$ID" ] || die "inbox accept 要 --id"
      [ -f "$IB" ] || die "收词箱是空的。"
      $PY - "$IB" "$MAIN_JSON" "$ID" <<'PY'
import json, sys, datetime, os

ib, mf, id_ = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(ib, encoding='utf-8'))
words = d.get('words') or []
w = next((x for x in words if x.get('id') == id_), None)
if not w:
    sys.exit(f'ERROR: 收词箱里没有编号 {id_}。')
words.remove(w)
d['words'] = words
json.dump(d, open(ib, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
md = {}
if os.path.exists(mf):
    md = json.load(open(mf, encoding='utf-8'))
mwords = md.get('words') or []
if any(x.get('term', '').lower() == w['term'].lower() for x in mwords):
    print(f"（{w['term']} 已在主册，收词箱里这份丢掉。）")
else:
    nid = int(md.get('nextId') or 1)
    mwords.append({'id': nid, 'term': w['term'], 'definition': w.get('definition') or '（待补充）',
                   'course': w.get('course') or '', 'source': w.get('source') or '收词箱',
                   'box': 1, 'streak': 0, 'lastReviewed': None,
                   'addedAt': datetime.datetime.now().strftime('%Y-%m-%d %H:%M')})
    md['words'] = mwords
    md['nextId'] = nid + 1
    print(f"已收进主册：[{nid}] {w['term']}（来源：{w.get('source')} · 盒1）")
os.makedirs(os.path.dirname(mf), exist_ok=True)
json.dump(md, open(mf, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
      ;;
    dismiss)
      [ -n "$ID" ] || die "inbox dismiss 要 --id"
      [ -f "$IB" ] || die "收词箱是空的。"
      $PY - "$IB" "$ID" <<'PY'
import json, sys

ib, id_ = sys.argv[1], int(sys.argv[2])
d = json.load(open(ib, encoding='utf-8'))
words = d.get('words') or []
w = next((x for x in words if x.get('id') == id_), None)
if not w:
    sys.exit(f'ERROR: 收词箱里没有编号 {id_}。')
words.remove(w)
d['words'] = words
json.dump(d, open(ib, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"已丢弃：{w['term']}（来源：{w.get('source')}）")
PY
      ;;
    *) die "inbox 的动作：list / add / accept / dismiss" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------- hint
if [ "$CMD" = "hint" ]; then
  HINT_CFG="${VOCAB_FAKE_CONFIG:-$CONFIG}"
  WD="${VOCAB_FAKE_WEEKDAY:-$(date +%u)}"
  LINE="$($PY - "$LIB" "$WD" "$HINT_CFG" <<'PY'
import json, os, sys

lib, wd, cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
DEFAULT_HINTS = {
    '1': 'city不city来背单词', '2': 'cityuniversity', '3': '又一城学子背单词了',
    '4': 'hello Hong Kong study', '5': '考我单词', '6': '我想背单词', '7': '我想背单词',
}
cfg = {}
try:
    cfg = json.load(open(cfg_path, encoding='utf-8'))
except Exception:
    cfg = {}
v = cfg.get('vocab') or {}
if v.get('hint') is False:
    sys.exit(0)
hints = DEFAULT_HINTS.copy()
custom = v.get('hints')
if isinstance(custom, dict):
    for k in list(hints):
        s = str(custom.get(k) or '').strip()
        if s:
            hints[k] = s
phrase = hints.get(str(wd)) or '我想背单词'
# 空库判定：主册与收词箱都没词 → 不推空气
empty = True
if lib and os.path.isdir(lib):
    vd = os.path.join(lib, 'vocab')
    for f in (os.path.join(vd, 'vocab.json'), os.path.join(vd, 'inbox.json')):
        try:
            d = json.load(open(f, encoding='utf-8'))
            if d.get('words'):
                empty = False
                break
        except Exception:
            pass
if empty:
    print('今日有人味儿的提醒：还没有词可背——出笔记时收几个试试')
else:
    print(f'今日有人味儿的提醒：如果你想背单词，在这里说或者另开窗口说'
          f'「我想背单词 / {phrase}」——说哪个都能触发')
PY
)" || true
  [ -n "$LINE" ] && printf '%s\n' "$LINE"
  exit 0
fi

die "未知命令：$CMD"
