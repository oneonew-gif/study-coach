#!/usr/bin/env bash
# canvas_inspect.sh — Canvas 变动巡检（只读）
#
# 干什么：把 Canvas 上的课程状态抓成快照，跟上一份比对，告诉你
#         「这周 Canvas 上增添了 / 删减了 / 改动了什么」＋「当前截止日期全景」。
#
# 只读保证：本脚本**不直接发任何 HTTP 请求**，全部转发给同目录的 canvas.sh，
#          而 canvas.sh 只实现 GET。想破口必须同时改两个文件 —— 这是刻意的。
#          本脚本也**不会**执行任何「校准」动作，只产出报告，改不改由使用者决定。
#
# 用法：
#   canvas_inspect.sh collect [--lib DIR]   抓一份快照存档，并打印摘要
#   canvas_inspect.sh diff    [--lib DIR]   比对最近两份快照，输出变动报告
#   canvas_inspect.sh run     [--lib DIR]   先 collect 再 diff（一次跑完）
#   canvas_inspect.sh status                上次巡检时间、快照数、凭据状态
#   canvas_inspect.sh help
#
# 产出（全部在**使用者自己的资料库**里，不进 Skill 目录）：
#   <库>/inspection/snapshots/<时间戳>.json   原始快照（带学期标识 term）
#   <库>/inspection/reports/<时间戳>.md       变动报告
#   <库>/inspection/log.tsv                   巡检流水
#
# 库路径来源：--lib 参数 > 环境变量 CANVAS_LIB > <WORKBUDDY_HOME>/study-coach.json 的 library
# 学期标识来源：环境变量 CANVAS_TERM > <WORKBUDDY_HOME>/study-coach.json 的 term
#   快照会盖上学期的章；比对时若两份快照不同学期，**不做逐项对比**，
#   否则新学期的数据对上旧学期快照会报出整屏假变动。

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
[ -n "$PY" ] || { printf 'ERROR: 没找到 Python 3 —— 试过 python3 / python / py -3。\n' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANVAS="${HERE}/canvas.sh"
WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"

LIB="${CANVAS_LIB:-}"
LIB_SRC=""
TERM="${CANVAS_TERM:-}"
TERM_SRC=""
SNAP_DIR=""
REPORT_DIR=""
LOG=""

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

resolve_lib() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --lib) [ $# -ge 2 ] || die "--lib 后面要跟目录"; LIB="$2"; LIB_SRC="命令行"; shift 2 ;;
      *) die "不认识的参数：$1" ;;
    esac
  done

  if [ -f "${CONFIG}" ]; then
    local pair
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
    local cfg_lib="" cfg_term=""
    IFS=$'\t' read -r cfg_lib cfg_term <<< "${pair}" || true
    if [ -z "${LIB}" ] && [ -n "${cfg_lib}" ]; then
      LIB="${cfg_lib}"; LIB_SRC="study-coach.json"
    fi
    if [ -z "${TERM}" ] && [ -n "${cfg_term}" ]; then
      TERM="${cfg_term}"; TERM_SRC="study-coach.json"
    fi
  fi

  [ -n "${LIB}" ] || die "还没配置资料库路径。把 library 写进 ${CONFIG}（见 SKILL.md 安装引导），或用 --lib 指定。"
  [ -d "${LIB}" ] || die "资料库不存在：${LIB}"

  SNAP_DIR="${LIB}/inspection/snapshots"
  REPORT_DIR="${LIB}/inspection/reports"
  LOG="${LIB}/inspection/log.tsv"
  mkdir -p "${SNAP_DIR}" "${REPORT_DIR}"
  [ -f "${LOG}" ] || printf '时间\t动作\t课程数\t变动数\t结果\n' > "${LOG}"
}

degrade() {
  # Canvas 拿不到数据时的正式降级路径 —— 不要因为没 token 就让用户卡住
  cat >&2 <<EOF

──────────────────────────────────────────────
无法巡检：Canvas 读不到数据。

原因：$1

两条出路：

  ① 修好 Canvas 接入（推荐）
     跑 ${CANVAS} doctor 看是网址还是 token 的问题。
     接好之后巡检才有意义。

  ② 走手动流派
     Canvas 用不了时，自己把改动过的课件下载到
     ${LIB}/materials/ ，其余流程照常。
     这样只是少了「自动发现变化」，不是没有学习教练。

注意：巡检**不会**因为读不到数据就假装「无变动」。
      读不到就是读不到，宁可报错，也不给你一个会让你误判的绿灯。
──────────────────────────────────────────────
EOF
}

# ── collect ────────────────────────────────────────────────────────────────

fetch() {
  # fetch <course_id> <kind>  ->  ${tmp}/<cid>.<kind>.json（失败则写空数组并记入失败清单）
  local cid="$1" kind="$2"
  local out="${tmp}/${cid}.${kind}.json"
  local err="${tmp}/${cid}.${kind}.err"
  if "$CANVAS" "${kind}" "${cid}" > "${out}" 2>"${err}"; then
    :
  else
    printf '[]\n' > "${out}"
    local msg
    msg="$(head -c 160 "${err}" 2>/dev/null | tr '\n' ' ' || true)"
    printf '  ⚠ %s 读取失败：%s\n' "${kind}" "${msg}" >&2
    # 失败必须留痕：光往 stderr 打一行，报告里照样是"读到了 0 条"。
    # 记进快照的 fetchErrors，diff 才能明说「这部分变动不可信」。
    printf '%s\t%s\t%s\n' "${cid}" "${kind}" "${msg}" >> "${tmp}/fetch-errors.tsv"
  fi
  rm -f "${err}"
}

cmd_collect() {
  resolve_lib "$@"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  local rc=0
  "$CANVAS" courses > "${tmp}/courses.json" 2>"${tmp}/courses.err" || rc=$?
  if [ "${rc}" != 0 ]; then
    degrade "$(head -c 300 "${tmp}/courses.err" 2>/dev/null | tr '\n' ' ' || echo '未知错误')"
    exit 2
  fi

  # 逐门课抓四类数据
  local cid ccode cname n=0
  while IFS=$'\t' read -r cid ccode cname; do
    [ -n "${cid}" ] || continue
    n=$((n + 1))
    printf '  抓取 %s %s ...\n' "${ccode:-$cid}" "${cname}" >&2
    fetch "${cid}" announcements
    fetch "${cid}" files
    fetch "${cid}" assignments
    fetch "${cid}" modules
  done < <($PY - "${tmp}/courses.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    d = []
if isinstance(d, dict):
    d = d.get('courses') or []
for c in d:
    if not isinstance(c, dict):
        continue
    code = c.get('course_code') or c.get('sis_course_id') or ''
    print(f"{c.get('id')}\t{code}\t{(c.get('name') or '').replace(chr(9), ' ')}")
PY
)

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local out="${SNAP_DIR}/${ts}.json"

  $PY - "${tmp}" "${out}" "${TERM}" <<'PY'
import datetime, json, os, sys

tmp, out = sys.argv[1], sys.argv[2]
term = (sys.argv[3] if len(sys.argv) > 3 else '').strip() or None

def rd(path):
    try:
        d = json.load(open(path, encoding='utf-8'))
    except Exception:
        return []
    if isinstance(d, dict):
        for k in ('courses', 'announcements', 'files', 'assignments', 'modules', 'items'):
            if isinstance(d.get(k), list):
                return d[k]
        return []
    return d if isinstance(d, list) else []

courses = rd(os.path.join(tmp, 'courses.json'))
errors = []
err_path = os.path.join(tmp, 'fetch-errors.tsv')
if os.path.exists(err_path):
    for line in open(err_path, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 2:
            errors.append({'courseId': parts[0], 'kind': parts[1],
                           'message': parts[2] if len(parts) > 2 else ''})

snap = {
    'version': 2,
    'term': term,
    'collectedAt': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
    'fetchErrors': errors,
    'courses': [],
}

for c in courses:
    if not isinstance(c, dict):
        continue
    cid = c.get('id')
    code = c.get('course_code') or c.get('sis_course_id') or str(cid)

    ann = rd(os.path.join(tmp, f'{cid}.announcements.json'))
    files = rd(os.path.join(tmp, f'{cid}.files.json'))
    asg = rd(os.path.join(tmp, f'{cid}.assignments.json'))
    mods = rd(os.path.join(tmp, f'{cid}.modules.json'))

    items = []
    for m in mods:
        if not isinstance(m, dict):
            continue
        for it in (m.get('items') or []):
            if not isinstance(it, dict):
                continue
            items.append({
                'id': it.get('id'),
                'title': it.get('title') or '',
                'type': it.get('type') or '',
                'module': m.get('name') or '',
                'url': it.get('html_url') or '',
            })

    snap['courses'].append({
        'id': cid,
        'code': code,
        'name': c.get('name') or '',
        'announcements': [
            {'id': a.get('id'), 'title': a.get('title') or '',
             'postedAt': a.get('posted_at'), 'url': a.get('html_url')}
            for a in ann if isinstance(a, dict)
        ],
        'files': [
            {'id': f.get('id'),
             'name': f.get('display_name') or f.get('filename') or '',
             'updatedAt': f.get('updated_at'), 'size': f.get('size'),
             'url': f.get('url'),
             'folder': (f.get('folder') or {}).get('full_name')
                       if isinstance(f.get('folder'), dict) else None}
            for f in files if isinstance(f, dict)
        ],
        'assignments': [
            {'id': a.get('id'), 'name': a.get('name') or '',
             'dueAt': a.get('due_at'), 'points': a.get('points_possible'),
             'updatedAt': a.get('updated_at'), 'published': a.get('published'),
             'url': a.get('html_url')}
            for a in asg if isinstance(a, dict)
        ],
        'moduleItems': items,
    })

os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(snap, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

nc = len(snap['courses'])
nf = sum(len(c['files']) for c in snap['courses'])
na = sum(len(c['assignments']) for c in snap['courses'])
nm = sum(len(c['moduleItems']) for c in snap['courses'])
nn = sum(len(c['announcements']) for c in snap['courses'])
print(f'课程 {nc} 门 · 文件 {nf} · 作业 {na} · 模块条目 {nm} · 公告 {nn}')
PY

  local counts
  counts="$($PY - "${out}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print(f"{len(d['courses'])}\t{sum(len(c['files']) for c in d['courses'])}\t{sum(len(c['assignments']) for c in d['courses'])}\t{sum(len(c['moduleItems']) for c in d['courses'])}")
PY
)"
  printf '%s\tcollect\t%s\t-\t快照已存 %s\n' "$(date '+%Y-%m-%d %H:%M')" "${counts%%$'\t'*}" "$(basename "${out}")" >> "${LOG}"

  echo
  echo "✅ 快照已存：${out}"
  echo "   ${counts%%$'\t'*}"
  local nerr=0
  [ -f "${tmp}/fetch-errors.tsv" ] && nerr="$(awk 'END{print NR+0}' "${tmp}/fetch-errors.tsv")"
  if [ "${nerr}" -gt 0 ]; then
    echo "   ⚠ 有 ${nerr} 项数据读取失败（已记入快照 fetchErrors，diff 会如实提示哪些变动不可信）"
  fi
  echo "   学期标识：${TERM:-（未设置 —— 建议在 study-coach.json 填 term）}"
  echo
  echo "下一步：canvas_inspect.sh diff  （比对上次，出变动报告）"
}

# ── diff ───────────────────────────────────────────────────────────────────

cmd_diff() {
  resolve_lib "$@"

  local n
  n="$(find "${SNAP_DIR}" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n}" -lt 1 ]; then
    echo "还没有任何快照。先跑：canvas_inspect.sh collect" >&2
    exit 3
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local out="${REPORT_DIR}/${ts}.md"

  $PY - "${SNAP_DIR}" "${out}" <<'PY'
import datetime, glob, json, os, sys

snap_dir, out = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(snap_dir, '*.json')))
cur = json.load(open(files[-1], encoding='utf-8'))
prev = json.load(open(files[-2], encoding='utf-8')) if len(files) >= 2 else None

term_cur = str(cur.get('term') or '').strip()
term_prev = str((prev or {}).get('term') or '').strip()
term_known = bool(term_cur and term_prev)
# 首次巡检 = 没有上一份快照。**跨学期不算首次** —— 早先把跨学期的 prev 置成 None，
# 结果同一份报告里既说「跨学期已跳过对比」又说「首次巡检只建基线」，后者是假话。
first_run = prev is None
# 跨学期不做逐项对比：课程代码会复用、课件会撞名，硬比只会报出整屏假变动
cross_term = bool(prev) and term_known and term_cur != term_prev
comparable = prev is not None and not cross_term
cur_errs = cur.get('fetchErrors') or []

def fmt(iso):
    if not iso:
        return '—'
    try:
        s = str(iso).replace('Z', '+00:00')
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.astimezone().strftime('%m-%d %H:%M')
    except Exception:
        return str(iso)

def key_by(lst, k='id'):
    return {x.get(k): x for x in lst if isinstance(x, dict) and x.get(k) is not None}

L = []
L.append(f"# Canvas 巡检报告 · {datetime.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M')}")
L.append("")
L.append(f"- **本次快照**：{fmt(cur.get('collectedAt'))}")
if term_cur:
    L.append(f"- **学期标识**：{term_cur}")
if cross_term:
    L.append(f"- **对比基准**：{fmt((prev or {}).get('collectedAt'))}（学期 {term_prev or '未标注'}）")
    L.append("- ⚠ **跨学期，已跳过逐项对比** —— 课程代码会复用、课件会撞名，硬比会报出整屏假变动。下面只列当前状态。")
    L.append("  上一学期的资料应先用引擎 `scripts/` 目录下的 `archive_term.sh` 归档。")
elif prev:
    L.append(f"- **对比基准**：{fmt(prev.get('collectedAt'))}")
    if not term_known:
        L.append("- ⚠ 该快照没有学期标记（升级前生成的），无法确认是否跨学期 —— 若刚换学期，这份对比请自行打个问号。")
else:
    L.append("- **对比基准**：无（首次巡检，下面只列当前状态）")
L.append(f"- **在读课程**：{len(cur.get('courses', []))} 门")
if cur_errs:
    kinds = sorted({str(e.get('kind') or '?') for e in cur_errs})
    L.append(f"- 🔥 **本次快照有 {len(cur_errs)} 项数据读取失败**（{'、'.join(kinds)}）—— "
             "失败的那几类读到的是**空数据**，变动清单里对应的「删除/消失」不可信")
L.append("")

changes_total = 0
changed_courses = []   # (code, [行])
unchanged = []
calibrate = []

cur_by_code = {c.get('code') or str(c.get('id')): c for c in cur.get('courses', [])}
prev_by_code = {c.get('code') or str(c.get('id')): c for c in (prev or {}).get('courses', [])}

# 课程本身的新增/消失
if comparable:
    added_courses = [k for k in cur_by_code if k not in prev_by_code]
    gone_courses = [k for k in prev_by_code if k not in cur_by_code]
    if added_courses or gone_courses:
        L.append("## 课程变化")
        for k in added_courses:
            L.append(f"- 🟠 **新增课程** `{k}` {cur_by_code[k].get('name','')}")
            changes_total += 1
        for k in gone_courses:
            L.append(f"- ⚠ **课程从列表消失** `{k}` {prev_by_code[k].get('name','')} —— 可能是退课、也可能只是 enrollment 状态变了")
            changes_total += 1
        L.append("")

buckets = []
for code, c in cur_by_code.items():
    rows = []
    p = prev_by_code.get(code)

    # 首次巡检只建立基线：把全部内容当「新增」列出来只会制造噪音，直接跳过
    if first_run:
        continue
    # 跨学期：不做逐项对比（报告头已说明理由）；截止日期全景照常出
    if cross_term:
        continue

    # 公告
    ca, pa = key_by(c.get('announcements', [])), key_by((p or {}).get('announcements', []))
    for i in ca:
        if i not in pa:
            rows.append(f"- 🟡 **新公告** 「{ca[i]['title']}」（{fmt(ca[i].get('postedAt'))}）")
    for i in pa:
        if i not in ca:
            rows.append(f"- 🟡 **公告消失** 「{pa[i]['title']}」")

    # 课件文件
    cf, pf = key_by(c.get('files', [])), key_by((p or {}).get('files', []))

    def size_of(f):
        sz = f.get('size')
        if not isinstance(sz, (int, float)):
            return ''
        if sz >= 1048576:
            return f"，{sz/1048576:.1f} MB"
        if sz >= 1024:
            return f"，{round(sz/1024)} KB"
        return f"，{int(sz)} B"

    for i in cf:
        if i not in pf:
            rows.append(f"- 🟠 **新增课件** `{cf[i]['name']}`（{fmt(cf[i].get('updatedAt'))}{size_of(cf[i])}）")
            calibrate.append((code, cf[i]['name'], '新增'))
        else:
            if cf[i].get('updatedAt') != pf[i].get('updatedAt') or cf[i].get('size') != pf[i].get('size'):
                rows.append(f"- 🔵 **课件被改动** `{cf[i]['name']}`（{fmt(pf[i].get('updatedAt'))} → {fmt(cf[i].get('updatedAt'))}{size_of(cf[i])}）")
                calibrate.append((code, cf[i]['name'], '改动'))
            elif cf[i].get('name') != pf[i].get('name'):
                rows.append(f"- 🔵 **课件改名** `{pf[i]['name']}` → `{cf[i]['name']}`")
    for i in pf:
        if i not in cf:
            rows.append(f"- ⚠ **课件被删除** `{pf[i]['name']}`")

    # 作业（deadline 变更是最要命的）
    casg, pasg = key_by(c.get('assignments', [])), key_by((p or {}).get('assignments', []))
    for i in casg:
        a = casg[i]
        if i not in pasg:
            rows.append(f"- 🔴 **新增作业** 「{a['name']}」截止 {fmt(a.get('dueAt'))}（{a.get('points') or '—'} 分）")
        else:
            b = pasg[i]
            if a.get('dueAt') != b.get('dueAt'):
                rows.append(f"- 🔴 **截止日期变更** 「{a['name']}」{fmt(b.get('dueAt'))} → **{fmt(a.get('dueAt'))}**")
            if a.get('points') != b.get('points'):
                rows.append(f"- 🔴 **分值变更** 「{a['name']}」{b.get('points')} → {a.get('points')}")
            if a.get('published') != b.get('published'):
                rows.append(f"- 🔴 **发布状态变更** 「{a['name']}」{b.get('published')} → {a.get('published')}")
    for i in pasg:
        if i not in casg:
            rows.append(f"- ⚠ **作业被删除/隐藏** 「{pasg[i]['name']}」（原截止 {fmt(pasg[i].get('dueAt'))}）")

    # 模块条目
    cm, pm = key_by(c.get('moduleItems', [])), key_by((p or {}).get('moduleItems', []))
    for i in cm:
        if i not in pm:
            rows.append(f"- 🟠 **模块新增** [{cm[i].get('module')}] {cm[i].get('title')}")
    for i in pm:
        if i not in cm:
            rows.append(f"- 🟡 **模块移除** [{pm[i].get('module')}] {pm[i].get('title')}")

    if rows:
        changes_total += len(rows)
        buckets.append((code, c.get('name', ''), rows))
    elif comparable:
        unchanged.append(code)

if cross_term:
    L.append("## 一、变动清单")
    L.append("")
    L.append(f"**跨学期（{term_prev or '未标注'} → {term_cur or '未标注'}），本次未做逐项对比。** "
             "课程代码会复用、课件会撞名，硬比只会报出整屏假变动；当前状态见下文。")
    L.append("")
elif first_run:
    L.append("## 一、变动清单")
    L.append("")
    L.append("**首次巡检，本次只建立基线。** 没有上一份快照可比，把现在所有内容都列成「新增」只会制造噪音，所以不列。")
    L.append("")
    L.append("下一次巡检起，这里就会出现真正的「增添 / 删减 / 改动」。")
    L.append("")
elif buckets:
    L.append("## 一、变动清单")
    L.append("")
    for code, name, rows in buckets:
        L.append(f"### {code} · {name}")
        L.extend(rows)
        L.append("")
elif comparable:
    L.append("## 一、变动清单")
    L.append("")
    if cur_errs:
        L.append(f"⚠ 本次有 {len(cur_errs)} 项数据读取失败 —— **不能断言「无变动」**，"
                 "可能只是没读到。修好接入后重跑一次巡检，再下结论。")
    else:
        L.append("**无变动。** Canvas 上跟上次巡检相比没有任何增添、删减或改动。")
    L.append("")

# 当前截止日期全景
L.append("## 二、当前截止日期全景（直接来自 Canvas）")
L.append("")
now = datetime.datetime.now(datetime.timezone.utc)
upcoming = []
for code, c in cur_by_code.items():
    for a in c.get('assignments', []):
        d = a.get('dueAt')
        if not d:
            continue
        try:
            dt = datetime.datetime.fromisoformat(str(d).replace('Z', '+00:00'))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
        except Exception:
            continue
        upcoming.append((dt, code, a))
upcoming.sort(key=lambda x: x[0])

future = [u for u in upcoming if u[0] >= now]
if future:
    L.append("| 日期 | 课程 | 作业 | 分值 |")
    L.append("|---|---|---|---|")
    for dt, code, a in future[:30]:
        L.append(f"| {dt.astimezone().strftime('%m-%d %H:%M')} | {code} | {a.get('name','')} | {a.get('points') or '—'} |")
    if len(future) > 30:
        L.append(f"| … | | 还有 {len(future)-30} 项 | |")
else:
    L.append("（Canvas 上暂无未到期的作业）")
L.append("")

# 需要校准的课件
if calibrate:
    L.append("## 三、建议校准的课件")
    L.append("")
    for code, name, kind in calibrate:
        L.append(f"- `{code}` **{name}**（{kind}）→ 可跑校准链路：下载 → 提取 → 按课件原词校准既有笔记 → 更新题库")
    L.append("")
    L.append("> 校准是重活，**先问使用者同不同意**，别自动开跑。")
    L.append("")

if unchanged:
    L.append("## 四、无变动的课")
    L.append("")
    L.append("、".join(unchanged))
    L.append("")

L.append("---")
L.append("")
if cross_term:
    L.append(f"**本次未做变动比对**（跨学期：{term_prev} → {term_cur}）。"
             "当前状态已存成新快照，下次巡检起就与同学期的快照对比。")
else:
    L.append(f"本次共 **{changes_total}** 项变动。")
    if cur_errs:
        L.append(f"⚠ 快照含 {len(cur_errs)} 项读取失败 —— 涉及失败类别的「删除/消失」不可信，修复后重跑。")
L.append("报告由 `canvas_inspect.sh` 生成，原始快照在 `inspection/snapshots/`。")

os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, 'w', encoding='utf-8').write("\n".join(L) + "\n")
print("\n".join(L))
print(f"\n[报告已存] {out}")
PY

  local cnt
  cnt="$(grep -c '^- ' "${out}" 2>/dev/null || echo 0)"
  printf '%s\tdiff\t-\t%s\t报告 %s\n' "$(date '+%Y-%m-%d %H:%M')" "${cnt}" "$(basename "${out}")" >> "${LOG}"
}

cmd_run() {
  cmd_collect "$@"
  echo
  echo "──────────────────────────────────────────────"
  cmd_diff "$@"
}

cmd_status() {
  resolve_lib "$@"
  echo "== Canvas 巡检状态 =="
  echo
  echo "资料库   : ${LIB}${LIB_SRC:+  （来自${LIB_SRC}）}"
  echo "学期标识 : ${TERM:-（未设置，快照不会盖章）}${TERM_SRC:+  （来自${TERM_SRC}）}"
  echo "快照目录 : ${SNAP_DIR}"
  local n
  n="$(find "${SNAP_DIR}" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  echo "快照数   : ${n}"
  if [ "${n}" -ge 1 ]; then
    local last
    last="$(find "${SNAP_DIR}" -name '*.json' | sort | tail -1)"
    echo "最近快照 : $(basename "${last}")"
  fi
  local r
  r="$(find "${REPORT_DIR}" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  echo "报告数   : ${r}"
  echo
  echo "凭据"
  if [ -f "${CONFIG}" ]; then
    echo "  配置   : ${CONFIG}"
  else
    echo "  配置   : 不存在（库路径需用 --lib 指定）"
  fi
  "${CANVAS}" doctor 2>&1 | grep -E 'Token|网址' | sed 's/^ */  /' || true
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local cmd="$1"; shift
  case "${cmd}" in
    collect) cmd_collect "$@" ;;
    diff)    cmd_diff "$@" ;;
    run)     cmd_run "$@" ;;
    status)  cmd_status "$@" ;;
    -h|--help|help) usage ;;
    *) die "未知命令：${cmd}。跑 canvas_inspect.sh help 看用法。" ;;
  esac
}

main "$@"
