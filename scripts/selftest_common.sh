#!/usr/bin/env bash
# selftest_common.sh — _common.sh 的注入式自检（在 macOS/Linux 上模拟 Windows 的坑）
#
# 验的是 Windows 上「静默失败」的那几类：
#   ① PATH 里有一个假 python3（Windows 商店占位符：能被 command -v 找到，一跑就失败）→ 必须跳过它
#   ② 所有候选都是假的 → PY 为空（让调用方明确报错，而不是带着假货往下跑）
#   ③ 导出了 PYTHONUTF8 / PYTHONIOENCODING
#   ④ 模拟 Git Bash：$PY 的输出里 \r 被去掉（原生 Windows Python 写 \r\n）且退出码照传
#   ⑤ 模拟 Git Bash：sc_path 把 ~ 展开、交给 cygpath 规范化
#   ⑥ 中文 + 空格路径原样穿过 sc_path（非 MSYS 下不许被改写）
#   ⑦ 统一入口 bin/sc：分发、未知子命令、token 安全写入（中文路径/去 \r/不回显/空输入不写）
#   ⑧ 换行符：bash 脚本 LF、.cmd/.ps1 CRLF、.gitattributes 在、install.ps1 纯 ASCII

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/_common.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REALPY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { REALPY="$(command -v "$c")"; break; }; done
[ -n "$REALPY" ] || { echo "本机没有 Python，无法自检"; exit 1; }

echo "公共运行时 · 自检"
echo

# 假 python3：模拟 WindowsApps 占位符
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' > "$FAKE/python3"
chmod +x "$FAKE/python3"
REAL="$TMP/realbin"; mkdir -p "$REAL"
ln -s "$REALPY" "$REAL/python"

# ① 假 python3 在前、真 python 在后
GOT="$(env -u PY -u SC_PY_REAL -u _SC_COMMON_LOADED PATH="$FAKE:$REAL:/usr/bin:/bin" \
       bash -c ". '$COMMON'; printf '%s' \"\$SC_PY_REAL\"")"
if [ "$GOT" = "python" ]; then
  ok "跳过假 python3（商店占位符），选中真 python"
else
  bad "假 python3 没被识破：选中了「${GOT}」"
fi

# ② 只有假货
ONLYFAKE="$TMP/onlyfake"; mkdir -p "$ONLYFAKE"
cp "$FAKE/python3" "$ONLYFAKE/python3"; cp "$FAKE/python3" "$ONLYFAKE/python"
for t in uname tr cat; do ln -s "$(command -v $t)" "$ONLYFAKE/$t"; done
GOT="$(env -u PY -u SC_PY_REAL -u _SC_COMMON_LOADED PATH="$ONLYFAKE" \
       "$(command -v bash)" -c ". '$COMMON'; printf '[%s]' \"\$PY\"")"
if [ "$GOT" = "[]" ]; then
  ok "只有假 Python 时 PY 为空（调用方会明确报错）"
else
  bad "只有假 Python 时 PY 不该有值：${GOT}"
fi

# ③ UTF-8
GOT="$(env -u _SC_COMMON_LOADED bash -c ". '$COMMON'; printf '%s/%s' \"\$PYTHONUTF8\" \"\$PYTHONIOENCODING\"")"
if [ "$GOT" = "1/utf-8" ]; then
  ok "导出 PYTHONUTF8=1 与 PYTHONIOENCODING=utf-8"
else
  bad "UTF-8 环境变量没设对：${GOT}"
fi
GOT="$(env -u _SC_COMMON_LOADED LANG=C LC_ALL=C bash -c ". '$COMMON'; \$PY -c 'print(\"✓ 中文 ⚠️\")'" 2>&1)"
if [ "$GOT" = "✓ 中文 ⚠️" ]; then
  ok "C locale 下 Python 照样能打印 ✓ / 中文 / emoji"
else
  bad "Python 打印符号失败：${GOT}"
fi

# ④ 模拟 Git Bash：\r 去除 + 退出码照传
CRPY="$TMP/crbin"; mkdir -p "$CRPY"
cat > "$CRPY/python3" <<EOF
#!/bin/sh
case "\$*" in
  *version_info*) exec "$REALPY" "\$@" ;;
esac
printf 'C:/lib\r\n'
exit 3
EOF
chmod +x "$CRPY/python3"
GOT="$(env -u PY -u SC_PY_REAL -u _SC_COMMON_LOADED SC_FORCE_MSYS=1 PATH="$CRPY:$PATH" \
       bash -c ". '$COMMON'; v=\"\$(\$PY -c x)\"; rc=\$?; printf '%s|%s|%s' \"\$PY\" \"\$v\" \"\$rc\"")"
if [ "$GOT" = "sc_py|C:/lib|3" ]; then
  ok "模拟 Git Bash：Python 输出的 \\r 被去掉，退出码照传"
else
  bad "CRLF 处理不对：$(printf '%s' "$GOT" | od -c | head -2 | tr -s ' ')"
fi

# ⑤ 模拟 Git Bash：sc_path 调 cygpath -m
CYG="$TMP/cygbin"; mkdir -p "$CYG"
printf '#!/bin/sh\n# 假 cygpath：/c/xxx → C:/xxx\nshift; [ "$1" = "--" ] && shift\nprintf "%%s" "$1" | sed -E "s#^/([a-z])/#\\\\U\\\\1:/#"\n' > "$CYG/cygpath"
chmod +x "$CYG/cygpath"
GOT="$(env -u _SC_COMMON_LOADED SC_FORCE_MSYS=1 HOME=/c/Users/demo PATH="$CYG:$PATH" \
       bash -c ". '$COMMON'; printf '%s|%s' \"\$HOME\" \"\$(sc_path '~/study lib')\"")"
if [ "$GOT" = "C:/Users/demo|C:/Users/demo/study lib" ]; then
  ok "模拟 Git Bash：HOME 与 ~ 路径规范成 C:/ 混合格式"
else
  bad "路径规范化不对：${GOT}"
fi

# ⑥ 中文 + 空格路径在非 MSYS 下原样保留
GOT="$(env -u _SC_COMMON_LOADED bash -c ". '$COMMON'; sc_path '/data/张三 的库/notes'")"
if [ "$GOT" = "/data/张三 的库/notes" ]; then
  ok "中文 + 空格路径原样穿过 sc_path"
else
  bad "中文路径被改写：${GOT}"
fi

# ⑦ 统一入口 bin/sc
ENGINE="$(cd "$HERE/.." && pwd)"
SC="$ENGINE/bin/sc"
if [ -f "$SC" ]; then
  [ "$(bash "$SC" path)" = "$ENGINE" ] && ok "bin/sc path 指向引擎目录" || bad "bin/sc path 输出不对"
  bash "$SC" no-such-cmd >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "bin/sc 未知子命令退出码 2" || bad "bin/sc 未知子命令退出码应为 2，实际 $rc"
  # token 写入：中文 + 空格配置目录、管道输入、不回显、权限 600（NTFS 跳过权限）
  TD="$TMP/张三 cfg"
  OUT="$(printf 'tok-XYZ\r\n' | WORKBUDDY_HOME="$TD" bash "$SC" token 2>&1)"
  if [ "$(cat "$TD/.canvas-token" 2>/dev/null)" = "tok-XYZ" ]; then
    ok "sc token 写入中文路径，\\r\\n 被去掉"
  else
    bad "sc token 没写对：$(od -c "$TD/.canvas-token" 2>/dev/null | head -1)"
  fi
  case "$OUT" in *tok-XYZ*) bad "sc token 把 token 回显出来了" ;; *) ok "sc token 不回显 token" ;; esac
  printf '' | WORKBUDDY_HOME="$TMP/empty" bash "$SC" token >/dev/null 2>&1; rc=$?
  { [ "$rc" -ne 0 ] && [ ! -e "$TMP/empty/.canvas-token" ]; } \
    && ok "sc token 空输入不写文件、非零退出" || bad "sc token 空输入竟然写了文件或返回 0"
else
  bad "缺 bin/sc"
fi

# ⑧ 换行符：.sh / bin/sc 必须 LF（CRLF 会让 bash 报 set -u\r），.cmd / .ps1 必须 CRLF
CRLF_BAD=""
for f in "$ENGINE"/scripts/*.sh "$ENGINE"/install.sh "$ENGINE"/bin/sc; do
  [ -f "$f" ] && grep -q $'\r' "$f" && CRLF_BAD="${CRLF_BAD}${f#$ENGINE/} "
done
[ -z "$CRLF_BAD" ] && ok "所有 bash 脚本都是 LF 换行" || bad "这些 bash 脚本带 CRLF：${CRLF_BAD}"
LF_BAD=""
for f in "$ENGINE"/bin/*.cmd "$ENGINE"/*.ps1; do
  [ -f "$f" ] || continue
  # 有任何一行不以 \r 结尾即算违规
  if grep -qv $'\r$' "$f"; then LF_BAD="${LF_BAD}${f#$ENGINE/} "; fi
done
[ -z "$LF_BAD" ] && ok "Windows 脚本（.cmd/.ps1）都是 CRLF 换行" || bad "这些 Windows 脚本不是 CRLF：${LF_BAD}"
if [ -f "$ENGINE/.gitattributes" ] && grep -q 'eol=lf' "$ENGINE/.gitattributes"; then
  ok ".gitattributes 钉住了换行符（防 Windows autocrlf 把 .sh 改坏）"
else
  bad "缺 .gitattributes 或没钉 eol=lf"
fi
# install.ps1 必须纯 ASCII：PowerShell 5.1 按 ANSI 代码页读无 BOM 文件，中文会乱码
if [ -f "$ENGINE/install.ps1" ]; then
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "$ENGINE/install.ps1"; then
    bad "install.ps1 含非 ASCII 字符（PowerShell 5.1 会乱码）"
  else
    ok "install.ps1 纯 ASCII"
  fi
fi

echo
echo "结果：${PASS} 通过 / ${FAIL} 失败"
[ "$FAIL" -eq 0 ] && { echo "✅ 公共运行时可信"; exit 0; }
exit 1
