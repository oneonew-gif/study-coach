#!/usr/bin/env bash
# preflight.sh — 环境预检：这套工具能不能在你这台机器上跑
#
# 为什么要有它：本套引擎是 bash + python3 + node 写的，跑在 macOS / Linux /
# Windows（Git Bash 为官方路径，WSL 也可）。cmd / PowerShell 不能直接跑 .sh，
# 要经 bin\sc.cmd 转给 Git Bash —— 与其装到一半才炸，不如在门口先把话说清楚。
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
    good "平台：Windows Git Bash（${UNAME}）—— Windows 官方路径"
    note "   提醒：Git Bash 起进程比 macOS 慢，完整自检可能要 5–10 分钟，属正常"
    ;;
  *)
    unsupported "平台：${UNAME} —— 没有验证过。原生 Windows（cmd / PowerShell）不能直接跑 .sh" "平台不支持"
    PLATFORM_HINT="Windows 用户：装 Git for Windows（自带 Git Bash），然后用 bin\\sc.cmd 或在 Git Bash 里运行；一键安装见 README 的 install.ps1。"
    ;;
esac

# 公共运行时（真跑验证的 Python 选择、UTF-8、Windows 路径规范化）
# shellcheck source=_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

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

# Python：由 _common.sh 选（python3 → python → py -3，每个候选**真跑**验证 ≥3.8）。
# 只看 command -v 会选中 Windows 商店的假 python3.exe（能找到、一跑就失败）。
if [ -n "$PY" ]; then
  PYVER="$($PY -c 'import platform; print(platform.python_version())' 2>/dev/null)"
  good "python ${PYVER}（${SC_PY_REAL}）"
else
  # 区分「有假货」和「真没装」，Windows 用户最常卡在前者
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    fatal "找到了 python 命令但跑不起来或版本 < 3.8（Windows 上多半是商店占位符）。装 python.org 的 Python 3（勾 Add to PATH），或在「设置 → 应用 → 应用执行别名」里关掉 python.exe / python3.exe，然后重开终端" "Python 不可用"
  else
    fatal "找不到 Python 3（lib_doctor / check_ai_banner / check_terms 都靠它）。Windows：winget install Python.Python.3.12 后重开终端" "缺 python3"
  fi
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

# 路径风险：中文/空格用户名（C:\Users\张三）、网盘同步目录（OneDrive 接管桌面/文档）
# 只靠肉眼看路径判断不了能不能用，所以真写一个中文名文件再读回来。
check_path_risks() { # 标签 路径
  local label="$1" p="$2" probe_dir
  [ -n "$p" ] || return 0
  if printf '%s' "$p" | LC_ALL=C grep -q '[^ -~]'; then
    note "${label}含非 ASCII 字符（中文用户名等）：${p}"
  fi
  case "$p" in *" "*) note "${label}含空格：${p}（脚本已全程加引号，这里只是提示）" ;; esac
  case "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" in
    *onedrive*|*dropbox*|*icloud*|*"google drive"*|*坚果云*|*baidunetdisk*)
      warn "${label}在网盘同步目录里：${p}。同步时文件会被锁、或只剩云端占位，脚本会偶发读写失败；建议放到不同步的本地目录（如 C:/study-library）" "${label}在同步目录" ;;
  esac
  # 实测：在该路径（或其最近的已存在父目录）下用 Python 写读一个中文名文件
  probe_dir="$p"
  while [ -n "$probe_dir" ] && [ ! -d "$probe_dir" ]; do
    [ "$probe_dir" = "$(dirname "$probe_dir")" ] && break
    probe_dir="$(dirname "$probe_dir")"
  done
  if [ -n "$PY" ] && [ -d "$probe_dir" ] && [ -w "$probe_dir" ]; then
    if $PY - "$probe_dir" >/dev/null 2>&1 <<'PYEOF'
import os, sys
f = os.path.join(sys.argv[1], ".sc-预检 probe.txt")
try:
    with open(f, "w", encoding="utf-8") as h:
        h.write("✓ 中文")
    with open(f, encoding="utf-8") as h:
        ok = h.read() == "✓ 中文"
finally:
    try: os.remove(f)
    except OSError: pass
sys.exit(0 if ok else 1)
PYEOF
    then
      good "${label}可正常读写中文文件名：${probe_dir}"
    else
      warn "${label}下 Python 读写中文文件名失败：${probe_dir}。换一个纯英文的本地路径（如 C:/study-library），或设 WORKBUDDY_HOME 指向英文路径" "${label}路径读写失败"
    fi
  fi
}
check_path_risks "配置目录" "$CFGDIR"
LIBCFG="$CFGDIR/study-coach.json"
if [ -n "$PY" ] && [ -f "$LIBCFG" ]; then
  LIBPATH="$($PY -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("library",""))' "$LIBCFG" 2>/dev/null)"
  [ -n "$LIBPATH" ] && check_path_risks "资料库" "$(sc_path "$LIBPATH")"
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
    if $PY -c "import $mod" >/dev/null 2>&1; then
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
  say "  ${SC_PY_REAL} -m pip install ${OPTIONAL_LACKING}"
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
  say "    Windows      PowerShell 里跑：winget install Git.Git Python.Python.3.12 OpenJS.NodeJS.LTS（或直接用 install.ps1）"
fi

if [ "$QUIET" -eq 1 ]; then
  printf '%s\n' "$LINE"
fi

exit "$OK"
