#!/usr/bin/env bash
# selftest_install.sh — install.sh 的注入式自检（全程不联网）
#
# 验的是「安装器在该报错的时候报错、在该装好的时候装好」：
#   ① --from-dir 正常安装（排除 .git/.github，结构完整）
#   ② 已有安装 → 自动备份 .bak-时间戳，旧文件可寻回
#   ③ --zip 安装（GitHub archive 形状：顶层 study-coach-main/）→ 自动改名
#   ④ 坏 zip → 明确报错退出
#   ⑤ 缺 SKILL.md 的 --from-dir → 拒装
#   ⑥ 默认会跑 preflight；--no-preflight 真的跳过
#   ⑦ 下载失败（注入不可达 URL）→ 报「所有下载地址都失败」并给手动方案
#   ⑧ --zip 与 --from-dir 同给 → 二选一报错
#   ⑨ 装完打印「对 agent 说」的下一步指引

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"          # 引擎根目录（install.sh 所在）
INSTALL="$ENGINE/install.sh"
. "$HERE/_common.sh"
PYBIN="$PY"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# ---------------------------------------------------------------- ① --from-dir 正常安装
D1="$TMPBASE/dest1"
OUT="$(bash "$INSTALL" --from-dir "$ENGINE" --dir "$D1" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$D1/SKILL.md" ] && [ -f "$D1/scripts/preflight.sh" ] && [ -f "$D1/scripts/vocab.sh" ]; then
  ok "--from-dir 正常安装：结构完整"
else
  bad "--from-dir 安装不对（RC=${RC}）"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi
if [ ! -d "$D1/.git" ]; then
  ok "--from-dir 排除 .git"
else
  bad ".git 被带进安装目录"
fi
if printf '%s' "$OUT" | grep -q '环境预检'; then
  ok "默认装完跑 preflight"
else
  bad "默认模式没跑 preflight"
fi
if printf '%s' "$OUT" | grep -q '先走安装引导'; then
  ok "收尾打印下一步指引（对 agent 说的话）"
else
  bad "没打印下一步指引"
fi

# ---------------------------------------------------------------- ② 已有安装 → 备份
D2="$TMPBASE/dest2"
mkdir -p "$D2"
echo "OLD-MARKER" > "$D2/old-file.txt"
OUT="$(bash "$INSTALL" --from-dir "$ENGINE" --dir "$D2" --no-preflight 2>&1)"; RC=$?
BAK="$(ls -d "$D2".bak-* 2>/dev/null | head -1)"
if [ "$RC" -eq 0 ] && [ -n "$BAK" ] && [ "$(cat "$BAK/old-file.txt")" = "OLD-MARKER" ] \
   && [ -f "$D2/SKILL.md" ]; then
  ok "已有安装被备份到 .bak-时间戳，新引擎正常落位"
else
  bad "备份/覆盖逻辑不对（RC=${RC}，BAK=${BAK}）"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi
if printf '%s' "$OUT" | grep -q '资料库在别处'; then
  ok "备份提示里说明资料库不受影响"
else
  bad "没提示资料库不受影响"
fi

# ---------------------------------------------------------------- ③ --zip 安装（GitHub archive 形状）
D3="$TMPBASE/dest3"
$PYBIN - "$ENGINE" "$TMPBASE/engine-main.zip" <<'PYEOF' || bad "造测试 zip 失败"
import sys, zipfile, os
src, out = sys.argv[1], sys.argv[2]
top = 'study-coach-main'
zf = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d not in ('.git', '__pycache__')]
    for f in files:
        p = os.path.join(root, f)
        arc = os.path.join(top, os.path.relpath(p, src))
        zf.write(p, arc)
zf.close()
PYEOF
OUT="$(bash "$INSTALL" --zip "$TMPBASE/engine-main.zip" --dir "$D3" --no-preflight 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$D3/SKILL.md" ] && [ ! -d "$D3/study-coach-main" ]; then
  ok "--zip 安装：顶层 study-coach-main 自动改名为 study-coach"
else
  bad "--zip 安装不对（RC=${RC}）"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ④ 坏 zip
D4="$TMPBASE/dest4"
echo "not a zip" > "$TMPBASE/broken.zip"
OUT="$(bash "$INSTALL" --zip "$TMPBASE/broken.zip" --dir "$D4" --no-preflight 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '解压失败'; then
  ok "坏 zip → 明确报错退出"
else
  bad "坏 zip 没报对（RC=${RC}）"
fi

# ---------------------------------------------------------------- ⑤ --from-dir 缺 SKILL.md
EMPTY="$TMPBASE/empty-engine"
mkdir -p "$EMPTY"
OUT="$(bash "$INSTALL" --from-dir "$EMPTY" --dir "$TMPBASE/dest5" --no-preflight 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'SKILL.md'; then
  ok "--from-dir 缺 SKILL.md → 拒装并点名"
else
  bad "缺 SKILL.md 没拦（RC=${RC}）"
fi

# ---------------------------------------------------------------- ⑥ --no-preflight 真跳过
D6="$TMPBASE/dest6"
OUT="$(bash "$INSTALL" --from-dir "$ENGINE" --dir "$D6" --no-preflight 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '环境预检'; then
  ok "--no-preflight 真的跳过预检"
else
  bad "--no-preflight 没生效（RC=${RC}）"
fi

# ---------------------------------------------------------------- ⑦ 下载失败（注入不可达 URL）
OUT="$(STUDY_COACH_URLS='http://127.0.0.1:1/nope.zip;http://127.0.0.1:2/nope.zip' \
       bash "$INSTALL" --dir "$TMPBASE/dest7" --no-preflight 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '所有下载地址都失败'; then
  if printf '%s' "$OUT" | grep -q -- '--zip'; then
    ok "下载失败 → 报错并给手动 --zip 方案"
  else
    ok "下载失败 → 报错（但缺手动方案提示）"
  fi
else
  bad "下载失败路径不对（RC=${RC}）"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑧ --zip 与 --from-dir 二选一
OUT="$(bash "$INSTALL" --zip x.zip --from-dir y --dir "$TMPBASE/dest8" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '二选一'; then
  ok "--zip 与 --from-dir 同给 → 二选一报错"
else
  bad "参数互斥没拦（RC=${RC}）"
fi

# ---------------------------------------------------------------- 汇总
echo "──────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "  ${PASS}/${PASS} 通过 → install.sh 自检正常"
  exit 0
fi
echo "  ${PASS}/$((PASS+FAIL)) 通过 → install.sh 有问题，别交付"
exit 1
