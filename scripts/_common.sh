#!/usr/bin/env bash
# _common.sh — 所有 bash 脚本共用的运行时初始化（被 source，不单独跑）
#
# 为什么要有它：Python 解析逻辑早先在 15 个脚本里各复制了一份，而且每份都有同一个坑——
# `python3` 分支只看 `command -v`，不真跑。Windows 自带一个假的 python3.exe
# （WindowsApps 里的商店跳转占位符），`command -v` 能找到它，一跑就失败，
# 结果所有脚本都选中这个假货、后面全挂。一个坑修 15 遍迟早漏一遍，所以收成一份。
#
# 它做四件事：
#   ① 选 Python：python3 → python → py -3，**每个候选都真跑一次验证 ≥3.8**
#   ② UTF-8：导出 PYTHONUTF8 / PYTHONIOENCODING —— 中文 Windows 控制台默认 GBK，
#      Python 一打印 ✓ ✗ ⚠️ 就抛 UnicodeEncodeError
#   ③ Windows Git Bash（MSYS）下把 HOME / TMPDIR / WORKBUDDY_HOME 规范成
#      `C:/Users/...` 混合格式 —— bash 和原生 Windows Python 都认这种写法；
#      `/c/Users/...` 只有 bash 认，`C:\Users\...` 在 bash 里转义麻烦
#   ④ 提供 sc_path：把任何来源的路径（配置里的反斜杠、~、/c/ 前缀）统一成上述格式
#
# 用法（脚本开头）：
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#   [ -n "$PY" ] || die "没找到 Python 3 ..."
#   调用时 $PY **不要加引号**（"py -3" 需要拆成两个词）

# 重复 source 无副作用
if [ -z "${_SC_COMMON_LOADED:-}" ]; then
_SC_COMMON_LOADED=1

# ---------------------------------------------------------------- 平台
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) SC_MSYS=1 ;;
  *)                    SC_MSYS=0 ;;
esac
# 仅供 selftest_common.sh 在 macOS/Linux 上模拟 Git Bash 行为，日常不要设
[ -n "${SC_FORCE_MSYS:-}" ] && SC_MSYS="$SC_FORCE_MSYS"

# ---------------------------------------------------------------- ④ 路径规范化
# sc_path <路径>：输出规范化后的路径；空输入输出空
sc_path() {
  local p="${1:-}"
  [ -n "$p" ] || { printf ''; return 0; }
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  if [ "$SC_MSYS" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    # cygpath -m：C:\a\b、/c/a/b、/tmp/x 都统一成 C:/a/b 形式
    p="$(cygpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  fi
  printf '%s' "$p"
}

if [ "$SC_MSYS" -eq 1 ]; then
  # Git Bash 会把以 / 开头的参数自动改写成 Windows 路径（如 /courses/123 → C:/Program Files/Git/courses/123），
  # Canvas API 路径会被改坏。路径规范化统一由 sc_path 显式完成，关掉隐式转换。
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
  HOME="$(sc_path "$HOME")"; export HOME
  TMPDIR="$(sc_path "${TMPDIR:-/tmp}")"; export TMPDIR
  [ -n "${WORKBUDDY_HOME:-}" ] && { WORKBUDDY_HOME="$(sc_path "$WORKBUDDY_HOME")"; export WORKBUDDY_HOME; }
fi

# ---------------------------------------------------------------- ② UTF-8
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ---------------------------------------------------------------- ① Python
# 已由上层（比如 bin/sc 或 selftest.sh）选好并导出时直接沿用，不重复探测
_sc_py_ok() { # 候选命令（可多词）→ 0 表示是真的 Python ≥ 3.8
  # shellcheck disable=SC2086
  $1 -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 8) else 1)' >/dev/null 2>&1
}
if [ -n "${SC_PY_REAL:-}" ] && _sc_py_ok "$SC_PY_REAL"; then
  :   # 上层已选好真 Python，沿用
elif [ -n "${PY:-}" ] && [ "${PY}" != "sc_py" ] && _sc_py_ok "$PY"; then
  SC_PY_REAL="$PY"
else
  SC_PY_REAL=""
  for _c in python3 python "py -3"; do
    command -v "${_c%% *}" >/dev/null 2>&1 || continue
    if _sc_py_ok "$_c"; then SC_PY_REAL="$_c"; break; fi
  done
  unset _c
fi
export SC_PY_REAL

# Windows 原生 Python 往 stdout 写的换行是 \r\n，bash 的 $(...) 只去掉 \n，
# 于是 LIB="$($PY ...)" 会得到 "C:/lib\r" —— 路径永远「不存在」，而且报错信息里看不出 \r。
# 所以在 MSYS 下 $PY 指向一个去 \r 的包装函数；退出码照传 Python 自己的。
sc_py() {
  # shellcheck disable=SC2086
  { $SC_PY_REAL "$@"; } | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

if [ -z "$SC_PY_REAL" ]; then
  PY=""
elif [ "$SC_MSYS" -eq 1 ]; then
  PY="sc_py"
else
  PY="$SC_PY_REAL"
fi
# PY 不 export：MSYS 下它是函数名 sc_py，子进程里没有这个函数。
# 子进程各自 source 本文件，靠导出的 SC_PY_REAL 免去重复探测。

fi
