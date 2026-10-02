#!/usr/bin/env bash
# 学期归档脚本 · 自检
#
# 为什么要有它：这个脚本会**搬动使用者的资料**，是全套里唯一动文件的东西。
# 所以它必须被证明：
#   · 预演绝不落地（说了「什么都没动」就得真的什么都没动）
#   · 真跑之后资料一份不少（原位置清空、归档区到位、跨学期资产原地保留）
#   · 该拒绝时必须拒绝（重复归档 / 学期对不上 / 不像库的目录）
#   · 归档区里留了回退办法
#
# 样本全是临时的假库，不含任何真实课程/学校信息。
#
# 用法：  bash scripts/selftest_archive_term.sh
# 退出码：0 = 脚本行为正常；1 = 有故障

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVER="$HERE/archive_term.sh"
INIT="$HERE/init_library.sh"
# 公共运行时（Python 真跑验证 + UTF-8 + Windows 路径），与被测脚本同一份
. "$HERE/_common.sh"
[ -n "$PY" ] || { echo "错误：没找到 Python 3（试过 python3 / python / py -3）"; exit 1; }
[ -f "$ARCHIVER" ] || { echo "错误：找不到 $ARCHIVER"; exit 1; }
[ -f "$INIT" ] || { echo "错误：找不到 $INIT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail + 1)); }

# 造一个假库（含 config，指向临时 HOME）
mk_lib() {
  local root="$1" term="$2"
  mkdir -p "$root/home/.workbuddy"
  bash "$INIT" "$root/lib" > /dev/null
  $PY - "$root/lib/COURSES.md" "$term" <<'PY'
import sys
p, term = sys.argv[1], sys.argv[2]
t = open(p, encoding='utf-8').read().replace('<YYYY-YYX>', term)
open(p, 'w', encoding='utf-8').write(t)
PY
  printf '{"library": "%s", "term": "%s"}\n' "$root/lib" "$term" \
    > "$root/home/.workbuddy/study-coach.json"
  printf '笔记甲\n' > "$root/lib/notes/DEMO101_第1讲复习笔记.md"
  printf '笔记乙\n' > "$root/lib/notes/DEMO101_第2讲复习笔记.md"
  printf '课件\n'   > "$root/lib/materials/90001_L1 intro.pptx"
  printf '转写\n'   > "$root/lib/transcripts/rec1.md"
  printf '作业\n'   > "$root/lib/assignments/DEMO102_论文.md"
}

run() { HOME="$1/home" bash "$ARCHIVER" "${@:2}" 2>&1; }
rc_of() { HOME="$1/home" bash "$ARCHIVER" "${@:2}" > /dev/null 2>&1; echo $?; }

printf '\n学期归档脚本自检\n────────────────────────────────\n'

# ── ① 预演不许动任何东西 ────────────────────────────────────────────────
R="$TMP/a"; mk_lib "$R" "2026-27A"
out="$(run "$R" --lib "$R/lib")"
if printf '%s' "$out" | grep -q "预演" && [ -f "$R/lib/notes/DEMO101_第1讲复习笔记.md" ] \
   && [ ! -e "$R/lib/archive/2026-27A" ]; then
  ok "预演只打印、不落地（资料未动，归档区未建）"
else
  bad "预演动了东西 —— 这是最不该犯的错"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

if printf '%s' "$out" | grep -q "mv  notes/" && printf '%s' "$out" | grep -q "cp  quiz"; then
  ok "预演清单把「移动」与「复制」分开列了"
else
  bad "预演清单没有分清移动与复制"
fi

# ── ② 真跑：资料一份不少 ────────────────────────────────────────────────
run "$R" --lib "$R/lib" --yes --to 2026-27B > /dev/null 2>&1
moved=0
for d in notes materials transcripts assignments; do
  [ -d "$R/lib/archive/2026-27A/$d" ] && moved=$((moved + 1))
done
if [ "$moved" -eq 4 ] && [ "$(ls "$R/lib/archive/2026-27A/notes" | wc -l | tr -d ' ')" -eq 2 ]; then
  ok "归档区收全了：notes 2 份 + materials/transcripts/assignments 都在"
else
  bad "归档区内容不全（找到 $moved/4 个目录）"
fi

if [ -z "$(ls -A "$R/lib/notes")" ] && [ -f "$R/lib/inspection/log.tsv" ] \
   && [ -f "$R/lib/quiz/bank.json" ]; then
  ok "原位置已清空、骨架已重建、跨学期的 quiz/ 原地保留"
else
  bad "原位置或骨架不对（notes 残留 / 骨架没重建 / 题库丢了）"
  ls -a "$R/lib/notes" "$R/lib/quiz" 2>&1 | sed 's/^/       /'
fi

if grep -q "回退" "$R/lib/archive/2026-27A/ARCHIVE.md" 2>/dev/null \
   && grep -q "mv " "$R/lib/archive/2026-27A/ARCHIVE.md"; then
  ok "归档清单写了回退办法（搬回去的命令）"
else
  bad "归档清单没有回退办法"
fi

if [ "$($PY -c 'import json,sys;print(json.load(open(sys.argv[1])).get("term"))' \
        "$R/home/.workbuddy/study-coach.json")" = "2026-27B" ]; then
  ok "--to 把新学期的 term 写进了配置"
else
  bad "--to 没有更新配置里的 term"
fi

# ── ③ 不删东西：归档后文件总数只增不减 ─────────────────────────────────
before="$(find "$R/lib" -type f | wc -l | tr -d ' ')"
R2="$TMP/b"; mk_lib "$R2" "2026-27A"
n0="$(find "$R2/lib" -type f | wc -l | tr -d ' ')"
run "$R2" --lib "$R2/lib" --yes > /dev/null 2>&1
n1="$(find "$R2/lib" -type f | wc -l | tr -d ' ')"
if [ "$n1" -ge "$n0" ]; then
  ok "从不删除：文件数 ${n0} → ${n1}（归档 + 重建骨架，只增不减）"
else
  bad "文件少了：${n0} → ${n1} —— 有东西被删掉"
fi

# ── ④ 该拒绝的要拒绝 ───────────────────────────────────────────────────
rc="$(rc_of "$R" --lib "$R/lib" --yes)"
if [ "$rc" != "0" ]; then
  ok "重复归档被拒绝（退出码 ${rc}）"
else
  bad "重复归档没有被拦住 —— 第二次会把第一份归档覆盖掉"
fi

R3="$TMP/c"; mk_lib "$R3" "2026-27A"
$PY - "$R3/lib/COURSES.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(t.replace('2026-27A', '2026-27D'))
PY
rc="$(rc_of "$R3" --lib "$R3/lib" --term 2026-27E --yes)"
if [ "$rc" != "0" ] && run "$R3" --lib "$R3/lib" --term 2026-27E 2>&1 | grep -q "对不上"; then
  ok "COURSES.md 与要归档的学期对不上 → 拒绝，并说清哪个对不上"
else
  bad "学期不一致没有被拦住"
fi

R4="$TMP/d"; mkdir -p "$R4/home/.workbuddy" "$R4/empty"
printf '{"library": "%s/empty", "term": "2026-27A"}\n' "$R4" > "$R4/home/.workbuddy/study-coach.json"
rc="$(rc_of "$R4" --yes)"
if [ "$rc" != "0" ]; then
  ok "不像学习库的目录被拒绝（没有 COURSES.md）"
else
  bad "对着一个空目录也照跑 —— 迟早会搬错地方"
fi

# ── ⑤ 缺 term 时不许瞎猜 ───────────────────────────────────────────────
R5="$TMP/e"; mk_lib "$R5" "2026-27A"
printf '{"library": "%s/lib"}\n' "$R5" > "$R5/home/.workbuddy/study-coach.json"
$PY - "$R5/lib/COURSES.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(re.sub(r'\s*"term": "2026-27A",', '', t))
PY
rc="$(rc_of "$R5" --lib "$R5/lib" --yes)"
if [ "$rc" != "0" ] && run "$R5" --lib "$R5/lib" --yes 2>&1 | grep -q "不知道要归档哪个学期"; then
  ok "没有学期标识时明确报错，不猜"
else
  bad "没有学期标识却照跑 —— 会把资料归到一个错误名字下"
fi

printf '────────────────────────────────\n'
if [ "$fail" -eq 0 ]; then
  printf '全部通过（%d 项）\n' "$pass"
  exit 0
fi
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"
exit 1
