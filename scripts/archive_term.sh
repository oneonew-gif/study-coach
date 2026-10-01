#!/usr/bin/env bash
# archive_term.sh — 学期滚动：把当学期的资料整体归档，再重建空骨架
#
# 干什么：学期结束时，把这一学期的产物搬进 <库>/archive/<学期>/，
#         让新学期从干净的目录开始。**不删除任何东西**，全部是 mv / cp。
#
# 为什么需要它：课程代码会复用（同一门课明年还开，但老师、分值、AI 红线全变），
#   课件命名会撞（带 Canvas 课程 id 的文件名跨学期重名），巡检快照只有一份 —— 不归档，新旧学期就会
#   混在同一批目录里，体检的覆盖率判定和巡检的变动比对都会失去时间锚。
#
# 用法：
#   archive_term.sh                        # 预演：只打印将要发生什么（默认）
#   archive_term.sh --yes                  # 真的执行
#   archive_term.sh --term 2026-27A        # 指定归档哪个学期（默认取配置的 term）
#   archive_term.sh --to 2026-27B --yes    # 归档后把新学期的 term 写进配置
#   archive_term.sh --lib DIR              # 指定库（默认读 <WORKBUDDY_HOME>/study-coach.json，WORKBUDDY_HOME 默认 ~/.workbuddy）
#   archive_term.sh help
#
# 移动（mv）→ archive/<学期>/：
#   notes/ materials/ transcripts/ recordings/ assignments/ plans/ inspection/
# 复制（cp，原地保留）→ archive/<学期>/_carried/：
#   quiz/ COURSES.md course-rules.md     ← 跨学期仍要用，所以只存一份快照
#
# 会拒绝执行的情况：
#   archive/<学期>/ 已经存在（防止重复归档把上一份覆盖掉）
#   配置里的 term 与 COURSES.md 里的 term 不一致（先把两边改成一致）
#   指定的库目录里没有 COURSES.md（那不像一个学习库）

set -euo pipefail

# ---- Python 解析：python3 → python → py -3（Windows 兼容，W2）----
# 用法：$PY 调用时**不要加引号**（"py -3" 需要拆成两个词）
if [ -z "${PY:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
    PY=python
  elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    PY="py -3"
  fi
fi
[ -n "$PY" ] || die "没找到 Python 3 —— 试过 python3 / python / py -3 三个名字都不在 PATH 里。"

WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"
LIB="${CANVAS_LIB:-}"
LIB_SRC=""
TERM="${CANVAS_TERM:-}"
TERM_SRC=""
TO_TERM=""
YES=0

# 学期专属的产物：整体搬进归档区
MOVE_DIRS="notes materials transcripts recordings assignments plans inspection"
# 跨学期复用的资产：只复制一份快照进归档区，原地保留
CARRY_ITEMS="quiz COURSES.md course-rules.md"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) YES=1; shift ;;
      --term)   [ $# -ge 2 ] || die "--term 后面要跟学期标识，例如 2026-27A"; TERM="$2"; TERM_SRC="命令行"; shift 2 ;;
      --to)     [ $# -ge 2 ] || die "--to 后面要跟新学期标识"; TO_TERM="$2"; shift 2 ;;
      --lib)    [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; LIB_SRC="命令行"; shift 2 ;;
      help|-h|--help) usage; exit 0 ;;
      *) die "不认识的参数：$1（用 help 看用法）" ;;
    esac
  done
}

load_config() {
  [ -f "${CONFIG}" ] || return 0
  local pair cfg_lib="" cfg_term=""
  pair="$($PY - "${CONFIG}" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
print(str(d.get('library') or '').strip() + '\t' + str(d.get('term') or '').strip())
PY
)"
  IFS=$'\t' read -r cfg_lib cfg_term <<< "${pair}" || true
  if [ -z "${LIB}" ] && [ -n "${cfg_lib}" ]; then LIB="${cfg_lib}"; LIB_SRC="study-coach.json"; fi
  if [ -z "${TERM}" ] && [ -n "${cfg_term}" ]; then TERM="${cfg_term}"; TERM_SRC="study-coach.json"; fi
}

# 从 COURSES.md 的两个声明块里取 term，返回 用空格 分隔的值
courses_terms() {
  $PY - "${LIB}/COURSES.md" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    text = open(sys.argv[1], encoding='utf-8').read()
except Exception:
    sys.exit(0)
out = []
for label in ('SYNC-BLOCK', 'PROGRESS'):
    m = re.search(r'<!--\s*' + label + r'\s*v1\s*(\{.*?\})\s*-->', text, re.S)
    if not m:
        continue
    try:
        v = json.loads(m.group(1)).get('term')
    except Exception:
        v = None
    if v and '<' not in str(v):
        out.append(str(v).strip())
print(' '.join(sorted(set(out))))
PY
}

set_config_term() {
  local new="$1"
  [ -f "${CONFIG}" ] || { note "  （没有配置文件，跳过：请手工在 study-coach.json 加 \"term\": \"${new}\"）"; return 0; }
  $PY - "${CONFIG}" "${new}" <<'PY'
import json, sys
path, new = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path, encoding='utf-8'))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d['term'] = new
json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
open(path, 'a', encoding='utf-8').write('\n')
print(f"  配置已更新：term = {new}")
PY
}

count_files() {
  local d="$1"
  if [ -f "${d}" ]; then echo 1; return 0; fi
  [ -d "${d}" ] || { echo 0; return 0; }
  find "${d}" -type f 2>/dev/null | wc -l | tr -d ' '
}

# ── 主流程 ─────────────────────────────────────────────────────────────────
parse_args "$@"
load_config

[ -n "${LIB}" ] || die "找不到库目录。用 --lib 指定，或先跑安装引导写 study-coach.json"
LIB="${LIB/#\~/${HOME}}"
[ -d "${LIB}" ] || die "库目录不存在：${LIB}"
[ -f "${LIB}/COURSES.md" ] || die "这个目录里没有 COURSES.md，不像一个学习库：${LIB}"
[ "${LIB}" != "${HOME}" ] || die "库目录不能是家目录本身"

[ -n "${TERM}" ] || die "不知道要归档哪个学期。用 --term 指定，或先给 study-coach.json 填 \"term\""
case "${TERM}" in */*|*..*) die "学期标识不能带路径分隔符：${TERM}" ;; esac

CTERMS="$(courses_terms || true)"
if [ -n "${CTERMS}" ]; then
  for t in ${CTERMS}; do
    [ "${t}" = "${TERM}" ] || die "COURSES.md 写的是 ${t}，与要归档的 ${TERM} 对不上 —— 先把两边改成一致"
  done
fi

ARCHIVE_DIR="${LIB}/archive/${TERM}"

note "== 学期归档 · 预演 =="
note
note "资料库   : ${LIB}${LIB_SRC:+  （来自${LIB_SRC}）}"
note "归档学期 : ${TERM}${TERM_SRC:+  （来自${TERM_SRC}）}"
note "归档到   : ${ARCHIVE_DIR}"
note
note "将【移动】进归档（原位置清空，由骨架重建）："
MOVED=""
for d in ${MOVE_DIRS}; do
  if [ -d "${LIB}/${d}" ]; then
    n="$(count_files "${LIB}/${d}")"
    MOVED="${MOVED}${d}:${n} "
    printf '  mv  %-14s → archive/%s/   （%s 个文件）\n' "${d}/" "${TERM}" "${n}"
  fi
done
[ -n "${MOVED}" ] || note "  （没有可移动的目录）"

note
note "将【复制】进归档（原地保留一份快照）："
CARRIED=""
for item in ${CARRY_ITEMS}; do
  if [ -e "${LIB}/${item}" ]; then
    n="$(count_files "${LIB}/${item}")"
    CARRIED="${CARRIED}${item}:${n} "
    printf '  cp  %-14s → archive/%s/_carried/   （%s 个文件）\n' "${item}" "${TERM}" "${n}"
  fi
done
[ -n "${CARRIED}" ] || note "  （没有可复制的条目）"

note
if [ "${YES}" -eq 0 ]; then
  note "以上只是预演，**什么都没动**。确认无误后加 --yes 真跑："
  note "  bash ${BASH_SOURCE[0]} --yes"
  exit 0
fi

[ -e "${ARCHIVE_DIR}" ] && die "归档目录已存在，拒绝覆盖：${ARCHIVE_DIR}
（要重新归档就先把它改名或移走 —— 这个脚本从不删东西）"

mkdir -p "${ARCHIVE_DIR}"
note "== 执行 =="
note

for d in ${MOVE_DIRS}; do
  if [ -d "${LIB}/${d}" ]; then
    mv "${LIB}/${d}" "${ARCHIVE_DIR}/${d}"
    note "  已移动 ${d}/"
  fi
done

mkdir -p "${ARCHIVE_DIR}/_carried"
for item in ${CARRY_ITEMS}; do
  if [ -e "${LIB}/${item}" ]; then
    cp -R "${LIB}/${item}" "${ARCHIVE_DIR}/_carried/${item}"
    note "  已复制 ${item}"
  fi
done

# 归档清单：写清怎么回退，别让人对着一个目录猜
{
  echo "# 归档 · ${TERM}"
  echo
  echo "- 归档时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "- 原始库根：${LIB}"
  echo "- 学期标识：${TERM}"
  echo
  echo "## 移入本目录（原位置已清空）"
  echo
  for pair in ${MOVED}; do
    echo "- \`${pair%%:*}/\` —— ${pair#*:} 个文件"
  done
  echo
  echo "## 仅存快照（原位置保留）"
  echo
  for pair in ${CARRIED}; do
    echo "- \`_carried/${pair%%:*}\` —— ${pair#*:} 个文件"
  done
  echo
  echo "## 回退办法"
  echo
  echo "本脚本从不删除任何东西，回退就是搬回去："
  echo
  echo '```bash'
  echo "cd \"${ARCHIVE_DIR}\""
  for d in ${MOVE_DIRS}; do
    echo "[ -d \"${d}\" ] && mv \"${d}\" \"${LIB}/${d}\""
  done
  echo '```'
  echo
  echo "> 库根的 \`COURSES.md\` / \`WORKFLOWS.md\` 从未被本脚本改动过，"
  echo "> 新学期的课程索引需要你（或 agent）另行填写。"
} > "${ARCHIVE_DIR}/ARCHIVE.md"

# 重建空骨架（init_library.sh 是幂等的：已有的东西一律不碰）
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -x "${SKILL_DIR}/scripts/init_library.sh" ]; then
  bash "${SKILL_DIR}/scripts/init_library.sh" "${LIB}" | sed 's/^/  /'
else
  die "找不到 init_library.sh，骨架没重建 —— 手工建回：${MOVE_DIRS}"
fi

note
note "✅ 已归档到 ${ARCHIVE_DIR}"
note "   清单与回退办法见：${ARCHIVE_DIR}/ARCHIVE.md"
note

if [ -n "${TO_TERM}" ]; then
  set_config_term "${TO_TERM}"
  note "  新学期：${TO_TERM}"
else
  note "提醒：现在配置里的 term 还是 ${TERM}。新学期开始前把它改成新的："
  note "  bash ${BASH_SOURCE[0]} --to <新学期> --yes   # 或手工改 study-coach.json"
fi

note
note "接下来还要手工做两件事（脚本不碰你写的文档）："
note "  1. COURSES.md 顶部两个声明块：term 改成新学期，PROGRESS 的 taughtUpTo 归零，"
note "     并用新学期的大纲重写课程速查、关键日期、AI 政策"
note "  2. 确认 study-coach.json 的 term 与 COURSES.md 的 term 一致，然后跑："
note "     $PY ${SKILL_DIR}/scripts/lib_doctor.py --only term,skeleton"
