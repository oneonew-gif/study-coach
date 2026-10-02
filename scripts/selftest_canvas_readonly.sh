#!/usr/bin/env bash
# Canvas 只读架构 · 自检（硬红线 ① 的机械保障）
#
# 硬红线 ① 说「Canvas 只读，靠架构不靠自觉」。架构承诺也得能被验 ——
# 否则哪天有人往 canvas.sh 里加一行 `-X POST` 交个作业，谁也不会发现。
#
# 这个自检做两件事：
#   ① 静态断言：canvas.sh / canvas_inspect.sh 的非注释代码里，没有任何写方法
#      （POST / PUT / PATCH / DELETE / --data）
#   ② 行为断言：没凭据时 canvas.sh 必须**报错**，不许静默成功
#      （假的绿灯比红灯危险）
#
# 用法：  bash scripts/selftest_canvas_readonly.sh
# 退出码：0 = 架构未被破坏；1 = 有写方法或行为不对

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 公共运行时（Python 真跑验证 + UTF-8 + Windows 路径），与被测脚本同一份
. "$HERE/_common.sh"
[ -n "$PY" ] || { echo "错误：没找到 Python 3（试过 python3 / python / py -3）"; exit 1; }

TARGETS="canvas.sh canvas_inspect.sh deadlines.sh"
pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "Canvas 只读架构 · 自检"
echo

# ---------------------------------------------------------------- ① 静态
# 只看非注释行：脚本头部那段说明里**故意**写着「没有 POST/PUT/PATCH/DELETE」，
# 拿它当证据会自己骗自己。
#
# 两条规则：
#   · 写方法（-X POST / --request PUT）——无论出现在哪一行都算，这个没有歧义
#   · 请求体（--data / -d / --upload-file）——**只在同行有 curl/wget 时才算**，
#     否则 `tr -d`、`[ -d "$LIB" ]`、`find -name` 全会误报
SCAN="$HERE/.readonly_scan.py"
cat > "$SCAN" <<'PY'
import re, sys, pathlib

VERB = [
    (re.compile(r"-X\s*['\"]?(POST|PUT|PATCH|DELETE)\b", re.I), "-X 写方法"),
    (re.compile(r"--request\s*['\"]?(POST|PUT|PATCH|DELETE)\b", re.I), "--request 写方法"),
]
BODY = [
    (re.compile(r"--data(-raw|-binary|-urlencode)?\b", re.I), "请求体 --data"),
    (re.compile(r"(?:^|\s)-d\s"), "-d 请求体"),
    (re.compile(r"--upload-file\b", re.I), "--upload-file"),
    (re.compile(r"(?:^|\s)-T\s"), "-T 上传"),
]

hits, gets = [], 0
for name in sys.argv[1:]:
    p = pathlib.Path(name)
    if not p.is_file():
        hits.append(f"{name}: 文件不存在")
        continue
    for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        s = line.strip()
        if s.startswith("#"):
            continue
        if re.search(r"\bcurl\b|\bwget\b", line):
            if re.search(r"-X\s*GET\b", line):
                gets += 1
            for pat, what in BODY:
                if pat.search(line):
                    hits.append(f"{p.name}:{i} 出现{what} → {s[:70]}")
        for pat, what in VERB:
            if pat.search(line):
                hits.append(f"{p.name}:{i} 出现{what} → {s[:70]}")

for h in hits:
    print(h)
print(f"# 统计：curl -X GET 出现 {gets} 次")
sys.exit(1 if hits else 0)
PY

OUT="$($PY "$SCAN" "$HERE/canvas.sh" "$HERE/canvas_inspect.sh" 2>&1)"; RC=$?
rm -f "$SCAN"
if [ "$RC" -eq 0 ]; then
  ok "静态断言通过：非注释代码里没有任何写方法、没有 curl 请求体"
else
  bad "发现写方法 —— 硬红线 ① 被破坏了"
  printf '%s\n' "$OUT" | grep -v '^# 统计' | sed 's/^/       /'
fi

# 反向验证这个断言不是空的：文件里必须真的有 curl -X GET，否则上面那条等于没测
GETS="$(printf '%s\n' "$OUT" | sed -n 's/^# 统计：curl -X GET 出现 \([0-9]*\) 次/\1/p')"
if [ -n "$GETS" ] && [ "$GETS" -gt 0 ]; then
  ok "断言非空：脚本里确实有 ${GETS} 处 curl -X GET（不是拿空文件在测）"
else
  bad "脚本里找不到任何 curl -X GET —— 这个只读断言是空的，测不出东西"
fi

# ---------------------------------------------------------------- ② 行为
# 用一个空 HOME 跑，保证「没有凭据」这个前提成立，
# 这样自检结果跟你本机有没有配 token 无关。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$(env -u CANVAS_TOKEN -u CANVAS_BASE_URL HOME="$TMP" \
       bash "$HERE/canvas.sh" doctor 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE "ERROR|错误|token|凭据"; then
  ok "没有凭据时 canvas.sh 明确报错（不会给假的绿灯）"
else
  bad "没有凭据时 canvas.sh 竟然退出码 ${RC} —— 它可能给出了假的成功"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# 用法说明必须能离线打印（用户在接不上时也要能自查）
OUT="$(env HOME="$TMP" bash "$HERE/canvas.sh" help 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "只读"; then
  ok "canvas.sh help 离线可用，且写明只读"
else
  bad "canvas.sh help 不可用（退出码 ${RC}）"
fi

# ---------------------------------------------------------------- ③ 跨学期
# diff 不需要 Canvas 凭据 —— 它只读已有快照。所以这里能直接验「跨学期不硬比」。
# 这一条是学期标识存在的全部理由：课程代码会复用、课件会撞名，
# 拿新学期的数据对上旧学期的快照，会报出整屏假变动。
# Python 解析：python3 → python → py -3（Windows 兼容，W2）
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
  PY=python
elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
  PY="py -3"
fi
LIB="$TMP/lib"
mkdir -p "$LIB/inspection/snapshots" "$LIB/inspection/reports"
printf '{"version":2,"term":"2026-27A","collectedAt":"2026-09-01T09:00:00+08:00",' \
  > "$LIB/inspection/snapshots/20260901-090000.json"
printf '"courses":[{"id":1,"code":"DEMO101","name":"假课","files":[],"assignments":[],"moduleItems":[],"announcements":[]}]}\n' \
  >> "$LIB/inspection/snapshots/20260901-090000.json"
printf '{"version":2,"term":"2026-27B","collectedAt":"2026-12-15T09:00:00+08:00",' \
  > "$LIB/inspection/snapshots/20261215-090000.json"
printf '"courses":[{"id":1,"code":"DEMO101","name":"假课","files":[{"id":9,"name":"L1.pptx","size":10,"updatedAt":"2026-12-15T08:00:00+08:00"}],"assignments":[],"moduleItems":[],"announcements":[]}]}\n' \
  >> "$LIB/inspection/snapshots/20261215-090000.json"

OUT="$(env -u CANVAS_TOKEN -u CANVAS_BASE_URL HOME="$TMP" \
       bash "$HERE/canvas_inspect.sh" diff --lib "$LIB" 2>&1)"; RC=$?
if printf '%s' "$OUT" | grep -q "跨学期" && ! printf '%s' "$OUT" | grep -q "新增课件"; then
  ok "跨学期时跳过逐项对比（没把新学期课件报成「新增」）"
else
  bad "跨学期还把新学期数据当变动报出来了 —— 学期标识白加了"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

if printf '%s' "$OUT" | grep -q "本次共 \*\*0\*\* 项变动"; then
  bad "跨学期报告写成了「本次共 0 项变动」—— 这正是我们自己反复强调的假绿灯"
else
  ok "跨学期报告没有伪装成「0 项变动」"
fi

# 跨学期 ≠ 首次巡检：早先 cross_term 把上一份快照置空，报告里同时出现
# 「跨学期已跳过对比」和「首次巡检只建基线」，后者是假话。
if printf '%s' "$OUT" | grep -q "首次巡检"; then
  bad "跨学期报告冒充「首次巡检只建基线」—— 上一份快照明明存在"
else
  ok "跨学期报告没有冒充首次巡检"
fi

# 同学期时该比就要比（别为了防假变动把功能关死）
$PY - "$LIB/inspection/snapshots/20260901-090000.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['term'] = '2026-27B'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False)
PY
OUT="$(env -u CANVAS_TOKEN -u CANVAS_BASE_URL HOME="$TMP" \
       bash "$HERE/canvas_inspect.sh" diff --lib "$LIB" 2>&1)"; RC=$?
if printf '%s' "$OUT" | grep -q "新增课件"; then
  ok "同学期时正常逐项对比（功能没被防呆关死）"
else
  bad "同学期也不对比了 —— 防呆把主功能一起关了"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# 读取失败必须可见：快照带 fetchErrors 时，即使内容没变也**不许**断言「无变动」——
# 那可能只是没读到。早先 fetch 失败静默写空数组，两头都失败就会报出假「无变动」。
printf '{"version":2,"term":"2026-27B","collectedAt":"2026-12-16T09:00:00+08:00",' \
  > "$LIB/inspection/snapshots/20261216-090000.json"
printf '"fetchErrors":[{"courseId":"1","kind":"files","message":"401 boom"}],' \
  >> "$LIB/inspection/snapshots/20261216-090000.json"
printf '"courses":[{"id":1,"code":"DEMO101","name":"假课","files":[{"id":9,"name":"L1.pptx","size":10,"updatedAt":"2026-12-15T08:00:00+08:00"}],"assignments":[],"moduleItems":[],"announcements":[]}]}\n' \
  >> "$LIB/inspection/snapshots/20261216-090000.json"
OUT="$(env -u CANVAS_TOKEN -u CANVAS_BASE_URL HOME="$TMP" \
       bash "$HERE/canvas_inspect.sh" diff --lib "$LIB" 2>&1)"; RC=$?
if printf '%s' "$OUT" | grep -q "读取失败"; then
  ok "快照带 fetchErrors 时报告如实提示读取失败"
else
  bad "fetchErrors 没进报告 —— 失败照样被吞了"
fi
if printf '%s' "$OUT" | grep -q '\*\*无变动\*\*'; then
  bad "有读取失败还敢下「无变动」的结论 —— 假绿灯复活了"
else
  ok "有读取失败时不假装「无变动」（警告里引用这个词不算下结论）"
fi

echo
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ] && echo "✅ 只读架构完好" || echo "❌ 只读承诺已被破坏"

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
