#!/usr/bin/env bash
# preflight.sh — 环境预检：这套工具能不能在你这台机器上跑
#
# 为什么要有它：本套引擎是 bash + python3 + node 写的，只在 macOS / Linux
# （以及 Windows 上的 WSL）验证过。原生 Windows 的 cmd / PowerShell **跑不了** ——
# 与其装到一半才炸，不如在门口先把话说清楚。
#
# 用法：
#   preflight.sh           完整报告
#   preflight.sh --line    只出一行结论（给 selftest.sh 之类调用）
#
# 退出码：0 = 可以跑；1 = 缺必需项；2 = 平台不支持

set -u

QUIET=0
[ "${1:-}" = "--line" ] && QUIET=1

OK=0
PROBLEMS=""
OPTIONAL_LACKING=""

say()  { [ "$QUIET" -eq 0 ] && printf '%s\n' "$*"; return 0; }
good() { say "  ✅ $1"; }
note() { say "  ·  $1"; }
warn() { say "  !  $1"; PROBLEMS="${PROBLEMS}${2:-$1}; "; }
# fatal = 缺必需项（退出码 1）；unsupported = 平台不支持（退出码 2）。
# 早先两者共用一个出口全变 2，文档承诺的「1 = 缺必需项」永远走不到。
fatal(){ say "  ✗  $1"; PROBLEMS="${PROBLEMS}${2:-$1}; "; OK=1; }
unsupported(){ say "  ✗  $1"; PROBLEMS="${PROBLEMS}${2:-$1}; "; OK=2; }

ver_ge() { # 实际版本 最低版本 → 0 满足
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,A,"."); m=split(b,B,".");
    for(i=1;i<=(n>m?n:m);i++){x=A[i]+0;y=B[i]+0;if(x>y)exit 0;if(x<y)exit 1}
    exit 0}'
}

say ""
say "环境预检 · 这套工具能不能在你这台机器上跑"
say "──────────────────────────────────────────────"

# ---------------------------------------------------------------- ① 平台
UNAME="$(uname -s 2>/dev/null || echo unknown)"
PLATFORM_HINT=""
case "$UNAME" in
  Darwin) good "平台：macOS（${UNAME}）—— 官方验证过的平台" ;;
  Linux)
    # WSL 判别：/proc/version 里有 microsoft 字样
    if grep -qi microsoft /proc/version 2>/dev/null; then
      good "平台：Windows WSL（Linux 内核）—— 受支持路径"
      note "   提醒：资料库与 ~/.workbuddy 都在 WSL 文件系统里，别混用 Windows 侧的路径"
    else
      good "平台：Linux（${UNAME}）"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    warn "平台：Windows Git Bash（${UNAME}）—— 实验性支持（CI 持续验证中）" "Windows-GitBash"
    PLATFORM_HINT="Git Bash 下建议用 Git for Windows 自带的 bash 运行本脚本；遇到路径/权限类报错可改用 WSL。"
    ;;
  *)
    unsupported "平台：${UNAME} —— 没有验证过。原生 Windows（cmd / PowerShell）跑不了本套脚本" "平台不支持"
    PLATFORM_HINT="Windows 用户二选一：装 Git for Windows 用 Git Bash（实验性），或装 WSL（Ubuntu）按 Linux 方式跑。"
    ;;
esac

# ---------------------------------------------------------------- ② 必需项
say ""
say "必需"

# bash
if command -v bash >/dev/null 2>&1; then
  BASHVER="$(bash --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9]+(\.[0-9]+)*).*/\1/')"
  if [ -n "$BASHVER" ] && ver_ge "$BASHVER" "3.2"; then
    good "bash $BASHVER"
  else
    warn "bash 版本过旧（${BASHVER}，需要 3.2+）" "bash 过旧"
  fi
else
  fatal "找不到 bash" "缺 bash"
fi

# Python：python3 → python → py -3 三级回退（Windows 兼容，W2）
# Windows 上 Python 装完叫 python 或 py，没有 python3 这个名字
PY=""
PY_NAME=""
if command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"; PY_NAME="python3"
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
  PY="$(command -v python)"; PY_NAME="python"
elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
  PY="py"; PY_NAME="py -3"
fi
if [ -n "$PY" ]; then
  PYVER="$("$PY" --version 2>&1 | awk '{print $2}')"
  if ver_ge "$PYVER" "3.8"; then
    good "python3 ${PYVER}（${PY_NAME}：${PY}）"
  else
    fatal "python3 ${PYVER} 太旧（体检/检查器需要 3.8+）" "python3 过旧"
  fi
else
  fatal "找不到 Python 3（lib_doctor / check_ai_banner / check_terms 都靠它。Windows 用户：装 python.org 的 Python 后重开终端）" "缺 python3"
fi

# node：选装口径 —— 只影响抽题器，README/SKILL.md 都说「没有时其余功能照常」。
# 早先误判成 fatal，跟文档口径自相矛盾，没装 node 的人会被这句吓退。
NODE="$(command -v node 2>/dev/null || true)"
if [ -n "$NODE" ]; then
  NODEVER="$("$NODE" --version 2>/dev/null | sed 's/^v//')"
  if ver_ge "$NODEVER" "18"; then
    good "node $NODEVER"
  else
    warn "node $NODEVER 太旧（抽题器需要 18+）" "node 过旧"
  fi
else
  warn "找不到 node —— 只有抽题器不可用，其余功能照常" "缺 node"
fi

# 配置目录可写
CFGDIR="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
if [ -d "$CFGDIR" ] && [ -w "$CFGDIR" ]; then
  good "配置目录可写：$CFGDIR"
elif [ -d "$CFGDIR" ]; then
  warn "配置目录不可写：${CFGDIR}（凭据与库路径存不进去）" "配置目录不可写"
else
  note "配置目录还不存在：${CFGDIR}（安装引导会建）"
fi

# ---------------------------------------------------------------- ③ 选装
say ""
say "选装（缺了会降级，但流程不会停）"

if [ -n "$PY" ]; then
  for pair in "pypdf|pypdf|读 PDF 课件" \
              "pptx|python-pptx|读 PPTX 课件" \
              "docx|python-docx|读 DOCX 大纲"; do
    mod="${pair%%|*}"; rest="${pair#*|}"
    pipname="${rest%%|*}"; label="${rest#*|}"
    if "$PY" -c "import $mod" >/dev/null 2>&1; then
      good "${pipname}（${label}）"
    else
      note "没有 ${pipname}（${label}）—— 提取课件文本时会退到别的路径"
      OPTIONAL_LACKING="${OPTIONAL_LACKING}${pipname} "
    fi
  done
fi

for t in pdftotext pandoc soffice; do
  if command -v "$t" >/dev/null 2>&1; then
    good "命令行工具 $t"
  else
    note "没有 ${t}（有就用，没有就走 Python 库）"
  fi
done

# ---------------------------------------------------------------- ④ 结论
say ""
say "──────────────────────────────────────────────"

if [ -n "$OPTIONAL_LACKING" ] && [ "$QUIET" -eq 0 ]; then
  say "想装齐可选依赖："
  say "  $PY -m pip install ${OPTIONAL_LACKING}"
  say ""
fi

if [ -n "$PLATFORM_HINT" ]; then
  say "$PLATFORM_HINT"
  say ""
fi

case "$OK" in
  0)
    if [ -n "$PROBLEMS" ]; then
      LINE="环境可用，但有提醒：$PROBLEMS"
      say "结论：可以跑，但先看一眼上面的提醒。"
    else
      LINE="环境齐备，可以跑"
      say "结论：环境齐备。可以跑安装引导了。"
    fi
    ;;
  1) LINE="环境缺必需项：$PROBLEMS" ;;
  2) LINE="平台/环境不支持：$PROBLEMS" ;;
esac

if [ "$OK" -eq 1 ] || [ "$OK" -eq 2 ]; then
  say "结论：**现在还跑不起来**。上面标 ✗ 的项必须解决。"
  say "  常见装法："
  say "    macOS        brew install python node"
  say "    Ubuntu/Debian sudo apt install python3 nodejs"
  say "    Windows      先装 WSL，再在 WSL 里照 Ubuntu 那行装"
fi

if [ "$QUIET" -eq 1 ]; then
  printf '%s\n' "$LINE"
fi

exit "$OK"
