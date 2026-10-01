#!/usr/bin/env bash
# 库体检器 · 自检
#
# 体检报告是让人「照着修」的，所以它必须两件事都成立：
#   · 干净的库不能报错（否则人会学会无视报告）
#   · 注进去的病必须全都抓到（否则报告是安慰剂）
#
# 做法：用 init_library.sh 建一个真库，再逐个注入病灶，看它抓不抓。
# 引擎侧的病（版本号不同步、脚本缺自检）在**引擎副本**上注入，不动真引擎。
#
# 全程用临时 HOME 跑，跟本机有没有配 Canvas token 无关。
#
# 用法：  bash scripts/selftest_lib_doctor.sh
# 退出码：0 = 体检器可信；1 = 体检器有故障

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
# Python 解析：python3 → python → py -3（Windows 兼容，W2）
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
  PY=python
elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
  PY="py -3"
fi
[ -n $PY ] || { echo "错误：没找到 Python 3（试过 python3 / python / py -3）"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.workbuddy"
cp -R "$ENGINE" "$TMP/engine"

bash "$ENGINE/scripts/init_library.sh" "$TMP/lib" >/dev/null 2>&1
printf '{"library": "%s"}\n' "$TMP/lib" > "$HOME_DIR/.workbuddy/study-coach.json"

LIB="$TMP/lib"
DIAG="$TMP/engine/scripts/lib_doctor.py"

run() { HOME="$HOME_DIR" $PY "$DIAG" "$@" 2>&1; }
rc_of() { HOME="$HOME_DIR" $PY "$DIAG" "$@" >/dev/null 2>&1; echo $?; }

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

# 断到底成功了吗：既看退出码，也看报告里有没有那句话。
# 每项只跑它自己那个检查项 —— 前面注入的病会一直留在库里，
# 不隔离的话后面每个用例的退出码都被污染，测的就不是它自己了。
expect() { # 说明 期望退出码 关键词 检查项
  local label="$1" want_rc="$2" needle="$3" only="$4"
  local out rc
  out="$(run --only "$only")"; rc="$(rc_of --only "$only")"
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$needle"; then
    ok "$label"
  else
    bad "${label}（退出码 ${rc}，期望 ${want_rc}；没找到「${needle}」）"
    printf '%s\n' "$out" | grep -E '^ +(✗|!)' | sed 's/^/       /'
  fi
}

echo "库体检器 · 自检"
echo

# ① 干净的库：不能有 error
if [ "$(rc_of)" = "0" ]; then
  ok "干净的新库：无错误（新用户一装出来就是绿的）"
else
  bad "干净的新库就报错 —— 报告会被人学会无视"
  run | grep -E '^ +✗' | sed 's/^/       /'
fi

# ② 断链路径
printf '# 笔记索引\n\n见 `notes/不存在的笔记.md`。\n' > "$LIB/notes/INDEX.md"
expect "断链路径被抓到" 1 "不存在的路径" refs

# ③ 废弃脚本别名
printf '# 抽题\n\n用 `draw.js` 抽题。\n' > "$LIB/notes/HOWTO.md"
expect "废弃脚本别名被抓到" 1 "已废弃的 draw.js" refs

# ④ 骨架缺失
rm -f "$LIB/quiz/terms.json"
expect "骨架文件缺失被抓到" 0 "缺文件：quiz/terms.json" skeleton

# ⑤ 引擎版本号与 CHANGELOG 不同步（在引擎副本上注入）
sed 's/^version: .*/version: 9.9.9/' "$TMP/engine/SKILL.md" > "$TMP/engine/SKILL.md.new"
mv "$TMP/engine/SKILL.md.new" "$TMP/engine/SKILL.md"
expect "版本号与 CHANGELOG 不同步被抓到" 1 "CHANGELOG 最新条目停在" changelog

# ⑥ 引擎脚本缺自检（在引擎副本上新增一个没人管的脚本）
#    不删已有脚本 —— 删了会同时触发「SKILL.md 引用了不存在的脚本」，测的就不是覆盖这一项了。
printf '#!/usr/bin/env bash\necho "没人给我写自检"\n' > "$TMP/engine/scripts/tool_x.sh"
expect "引擎脚本没登记自检被提醒" 0 "没有登记自检" engine-health

# ⑦ shell 变量坑（在引擎副本上注入）
#    这行不能把错法原样写在本文件里 —— 引擎卫生检查会扫到本文件。
#    所以用变量拼出来，本文件里只有 $DEMO 和 %s。
DEMO='$var'
{ printf '\n# 故意注入的坑\n'
  printf 'demo_bug() { echo "值 %s（示例）"; }\n' "$DEMO"
} >> "$TMP/engine/scripts/canvas.sh"
expect "shell 变量紧贴中文被提醒" 0 "紧贴中文" engine-health

# ⑧ SKILL.md 指向不存在的脚本（照着文档敲命令的人会直接踩空）
printf '\n<!-- 注入：见 `nope_not_real.py` -->\n' >> "$TMP/engine/SKILL.md"
expect "SKILL.md 里的假脚本引用被抓到" 1 "没有这个文件" engine-health

# ⑨ 自检对照表过期：脚本没了，表里还挂着它
rm -f "$TMP/engine/scripts/preflight.sh"
expect "自检对照表过期被抓到" 1 "但 scripts/ 里没有" engine-health

# ⑩-⑫ 学期标识：三处（配置 / SYNC-BLOCK / PROGRESS）必须一致
set_term() { # 库里的两个块
  $PY - "$LIB/COURSES.md" "$1" <<'PY'
import re, sys
p, term = sys.argv[1], sys.argv[2]
t = open(p, encoding='utf-8').read()
t = re.sub(r'"term":\s*"[^"]*"', '"term": "%s"' % term, t)
if '"term"' not in t:
    t = t.replace('{\n', '{\n  "term": "%s",\n' % term, 1)
open(p, 'w', encoding='utf-8').write(t)
PY
}
set_cfg_term() { printf '{"library": "%s", "term": "%s"}\n' "$LIB" "$1" \
                  > "$HOME_DIR/.workbuddy/study-coach.json"; }

set_term "2026-27A"; set_cfg_term "2026-27B"
expect "配置与 COURSES.md 的学期对不上被抓到" 1 "学期标识不一致" term

set_cfg_term "2026-27A"
expect "三处学期标识一致时放行" 0 "学期标识一致" term

set_term "2026-27A"; printf '{"library": "%s"}\n' "$LIB" \
  > "$HOME_DIR/.workbuddy/study-coach.json"
$PY - "$LIB/COURSES.md" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(re.sub(r'\s*"term":\s*"[^"]*",', '', t))
PY
expect "三处都没有学期标识时明确提醒（不是静默通过）" 0 "三处都没有学期标识" term

# ⑬ 快照属于别的学期 → 要报出来（跨学期对比是假变动的源头）
set_term "2026-27B"; set_cfg_term "2026-27B"
mkdir -p "$LIB/inspection/snapshots"
printf '{"version": 2, "term": "2026-27A", "collectedAt": "2026-09-01T09:00:00+08:00", "courses": []}\n' \
  > "$LIB/inspection/snapshots/20260901-090000.json"
expect "快照属于别的学期时被提示" 0 "最新快照属于" term

# ⑭ 中文讲次必须按十进制解析（早先把「第二十讲」算成 12 —— 错得像个合法讲次）
$PY - "$TMP/engine/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import lib_doctor as L
cases = {"第二十讲": "20", "第三十讲": "30", "第二十一讲": "21",
         "第十二讲": "12", "第十讲": "10", "第3讲": "3", "L04": "4"}
bad = {t: L.session_from_name(t) for t, w in cases.items() if L.session_from_name(t) != w}
if bad:
    print(f"解析不对：{bad}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
if [ "$?" = "0" ]; then
  ok "中文讲次与 L04 类写法解析正确（二十→20，不是 12）"
else
  bad "讲次解析有错 —— 覆盖率判定会跟着错"
fi

# ⑮ latest_mtime 必须接受单个文件（course-rules.md 早先被当目录传，信号静默失效）
$PY - "$LIB" "$TMP/engine/scripts" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
import lib_doctor as L
lib = Path(sys.argv[1])
hit = L.latest_mtime(lib, ["course-rules.md"])
if hit and hit[1].name == "course-rules.md":
    sys.exit(0)
print("文件级 mtime 没取到", file=sys.stderr)
sys.exit(1)
PY
if [ "$?" = "0" ]; then
  ok "latest_mtime 支持单个文件（course-rules.md 的新旧能被看到）"
else
  bad "latest_mtime 不认文件 —— course-rules.md 的回流提示永远不触发"
fi

# ⑯ 覆盖率必须递归扫子目录：课件/笔记放在 materials/<课>/ 子目录里不能漏判
mkdir -p "$LIB/materials/DEMO101" "$LIB/notes/DEMO101"
cat > "$LIB/COURSES.md" <<'MD'
# 课程索引

### DEMO101 假课

课程ID：1234

<!-- PROGRESS v1 {"term":"2026-27B","asOf":"2026-09-20T09:00:00+08:00","confirmed":true,"courses":{"DEMO101":{"taughtUpTo":2}}} -->
MD
printf 'x' > "$LIB/materials/DEMO101/L01.pdf"
printf 'x' > "$LIB/materials/DEMO101/L05.pdf"
printf '复习笔记第1讲' > "$LIB/notes/DEMO101/复习笔记L1.md"
expect "子目录里的课件/笔记被递归识别（缺的只剩第2讲）" 0 "缺复习笔记 → 2" coverage
expect "子目录里的超前课件被识别（第5讲还没上到）" 0 "第 5 讲课件已上传但还没上到" coverage

echo
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] && echo "✅ 体检器可信" || echo "❌ 体检器有故障，别信它的报告"

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
