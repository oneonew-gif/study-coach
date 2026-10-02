#!/usr/bin/env bash
# install.sh — study-coach 一键安装器（macOS / Linux）
#
# 为什么要有它：手动安装要过七道坎（找 skills 目录、改目录名、装 Python、跑预检…），
# 每道坎都会掉人。这个脚本把坎全吃掉：一条命令装完，装不了的话在第一步就说清楚为什么。
#
# 用法：
#   install.sh                      # 默认：从 GitHub main 下载，装到 ~/.workbuddy/skills/study-coach
#   install.sh --dir DIR            # 指定安装位置（默认 ~/.workbuddy/skills/study-coach）
#   install.sh --zip FILE.zip       # 从本地 zip 安装（离线包 / 自检用）
#   install.sh --from-dir DIR       # 从本地已解压目录安装（CI 冒烟 / 自检用）
#   install.sh --no-preflight       # 装完不跑环境预检（自检里单独控制）
#   install.sh --sha256 <hash>      # 校验下载/zip 的 SHA-256（防篡改；macOS 用 shasum，Linux 用 sha256sum）
#
# 环境变量：
#   STUDY_COACH_URLS   覆盖下载候选列表（分号分隔；测试坏 URL 报错用）
#   STUDY_COACH_DEST   等价于 --dir
#
# 退出码：0 = 装好；1 = 环境或下载失败（报告里说清楚缺什么、怎么补）
#
# Mac/Linux 兼容性约定：本脚本只做加法，不改引擎任何现有文件；
# 已有安装会被备份为 study-coach.bak-<时间戳>，资料库（在库目录，不在引擎目录）不受影响。

set -u

REPO="oneonew-gif/study-coach"
REPO_ZIP="https://github.com/${REPO}/archive/refs/heads/main.zip"
# 四路候选：codeload 直连 → API zipball（认 GITHUB_TOKEN）→ 两个镜像。
# 已知现象：仓库刚推送后，GitHub 的匿名下载端点（codeload / 匿名 zipball）可能要过一阵才就绪，
# 而 API + token 路径立即可用 —— 所以 api 候选放第二位，且环境里有 GITHUB_TOKEN 就自动带上。
DEFAULT_URLS="${REPO_ZIP};https://api.github.com/repos/${REPO}/zipball/main;https://ghproxy.net/${REPO_ZIP};https://gh-proxy.com/${REPO_ZIP}"

say()  { printf '%s\n' "$*"; }
die()  { say "✗ $*"; exit 1; }

verify_sha() {
  [ -z "${EXPECTED_SHA:-}" ] && return 0
  [ -f "$WORK/engine.zip" ] || return 0
  local h=""
  if command -v shasum >/dev/null 2>&1; then
    h="$(shasum -a 256 "$WORK/engine.zip" | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then
    h="$(sha256sum "$WORK/engine.zip" | cut -d' ' -f1)"
  else
    die "--sha256 需要 shasum（macOS）或 sha256sum（Linux），本机都没有"
  fi
  if [ "$h" != "${EXPECTED_SHA}" ]; then
    die "SHA-256 校验失败：期望 ${EXPECTED_SHA}，实际 ${h}。下载可能被篡改或不完整，已中止安装。"
  fi
  say "   SHA-256 校验通过"
}

DEST="${STUDY_COACH_DEST:-${WORKBUDDY_HOME:-$HOME/.workbuddy}/skills/study-coach}"
SRC_ZIP=""
SRC_DIR=""
DO_PREFLIGHT=1
EXPECTED_SHA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)         [ $# -ge 2 ] || die "--dir 后面要跟目录"; DEST="$2"; shift 2 ;;
    --zip)         [ $# -ge 2 ] || die "--zip 后面要跟 zip 文件路径"; SRC_ZIP="$2"; shift 2 ;;
    --from-dir)    [ $# -ge 2 ] || die "--from-dir 后面要跟目录"; SRC_DIR="$2"; shift 2 ;;
    --no-preflight) DO_PREFLIGHT=0; shift ;;
    --sha256)      [ $# -ge 2 ] || die "--sha256 后面要跟哈希值"; EXPECTED_SHA="$2"; shift 2 ;;
    *) die "不认识的参数：${1}（用法见脚本头部注释）" ;;
  esac
done
[ -n "${SRC_ZIP:-}" ] && [ -n "${SRC_DIR:-}" ] && die "--zip 和 --from-dir 二选一"

say ""
say "study-coach 一键安装器"
say "──────────────────────────────────────────────"

# ---------------------------------------------------------------- ① 平台
UNAME="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME" in
  Darwin) say "① 平台：macOS ✅" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      say "① 平台：Windows WSL ✅"
    else
      say "① 平台：Linux ✅"
    fi ;;
  MINGW*|MSYS*|CYGWIN*)
    say "① 平台：Windows Git Bash ✅（Windows 官方路径）"
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    case "$DEST" in
      *[Oo]ne[Dd]rive*) say "   ⚠️ 安装位置在 OneDrive 同步目录里，同步锁文件会让脚本偶发失败；建议 --dir 换到本地目录" ;;
    esac ;;
  *)
    die "不认识的平台：${UNAME}。macOS / Linux 直接跑本脚本；Windows 见 README 平台支持表。" ;;
esac

# ---------------------------------------------------------------- ② 下载/取源
WORK="$(mktemp -d)" || die "无法创建临时目录（磁盘满？权限不够？）"
trap 'rm -rf "$WORK"' EXIT

fetch() { # fetch URL OUTFILE → 0 成功
  local url="$1" out="$2" hdr=""
  case "$url" in
    *api.github.com*)
      [ -n "${GITHUB_TOKEN:-}" ] && hdr="Authorization: token ${GITHUB_TOKEN}" ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$hdr" ]; then
      curl -fsSL -H "$hdr" --connect-timeout 10 --max-time 180 -o "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    else
      curl -fsSL --connect-timeout 10 --max-time 180 -o "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    return 1
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$hdr" ]; then
      wget -q --timeout=30 --header="$hdr" -O "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    else
      wget -q --timeout=30 -O "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    return 1
  else
    return 2   # 没有 curl 也没有 wget
  fi
}

if [ -n "$SRC_DIR" ]; then
  [ -d "$SRC_DIR" ] || die "--from-dir 目录不存在：$SRC_DIR"
  [ -f "$SRC_DIR/SKILL.md" ] || die "--from-dir 里没有 SKILL.md —— 确认给的是引擎目录根"
  say "② 来源：本地目录 $SRC_DIR"
  if [ -n "${EXPECTED_SHA:-}" ]; then
    say "   ⚠️ --sha256 仅对 --zip / 下载生效，--from-dir 模式下不经过 zip，已忽略校验"
  fi
elif [ -n "$SRC_ZIP" ]; then
  [ -f "$SRC_ZIP" ] || die "--zip 文件不存在：$SRC_ZIP"
  cp "$SRC_ZIP" "$WORK/engine.zip"
  verify_sha
  say "② 来源：本地 zip $SRC_ZIP"
else
  say "② 来源：GitHub（下载中，国内网络慢的话会自动换镜像…）"
  OK_URL=""
  IFS=';' read -r -a URLS <<EOF
${STUDY_COACH_URLS:-$DEFAULT_URLS}
EOF
  for u in ${URLS[@]+"${URLS[@]}"}; do
    [ -n "$u" ] || continue
    if fetch "$u" "$WORK/engine.zip"; then OK_URL="$u"; break; fi
  done
  if [ -z "$OK_URL" ]; then
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
      die "这台机器没有 curl 也没有 wget。请先安装其一，或按 README 手动下载 zip 后跑：install.sh --zip <文件>"
    fi
    die "所有下载地址都失败了。常见原因：① 网络不通/被墙 → 开代理重跑；② 仓库刚推送不久、GitHub 匿名下载端点还没就绪 → 等几小时重试；③ 都不行就手动下载 ${REPO_ZIP} 后跑：install.sh --zip <下载的文件>"
  fi
  say "   下载成功（${OK_URL}）"
  verify_sha
fi

# ---------------------------------------------------------------- ③ 解压 / 组装
say "③ 解压并整理目录…"
STAGE="$WORK/study-coach"

if [ -n "$SRC_DIR" ]; then
  mkdir -p "$STAGE"
  # tar 管道排除 .git/.github —— 用临时文件中转，避免管道只看末尾退出码的坑
  tar -C "$SRC_DIR" --exclude .git --exclude .github -cf "$WORK/src.tar" . \
    || die "打包源目录失败：$SRC_DIR"
  tar -C "$STAGE" -xf "$WORK/src.tar" \
    || die "解包到目标失败：$STAGE"
  rm -f "$WORK/src.tar"
else
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$WORK/engine.zip" -d "$WORK/unzip" || die "zip 解压失败——文件可能下载不完整"
  else
    # 引擎还没装，用不了 _common.sh —— 这里就地真跑验证（防 Windows 商店假 python3.exe）
    PYBIN=""
    for c in python3 python "py -3"; do
      command -v "${c%% *}" >/dev/null 2>&1 || continue
      $c -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1 && { PYBIN="$c"; break; }
    done
    [ -n "$PYBIN" ] || die "没有 unzip 也没有可用的 Python 3，解压不了。装一个 unzip（brew install unzip / apt install unzip）或 Python 3 后重跑"
    $PYBIN - "$WORK/engine.zip" "$WORK/unzip" <<'PYEOF' || die "zip 解压失败——文件可能下载不完整"
import sys, zipfile, os
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
os.makedirs(sys.argv[2], exist_ok=True)
PYEOF
  fi
  # GitHub archive zip 顶层目录是 study-coach-main；本地打包可能是别的名字——统一取唯一顶层目录
  TOPS="$(ls -d "$WORK/unzip"/*/ 2>/dev/null | wc -l | tr -d ' ')"
  [ "$TOPS" = "1" ] || die "zip 顶层结构不符合预期（应只有一个顶层目录），请确认来源"
  mv "$(ls -d "$WORK/unzip"/*/ | head -1)" "$STAGE"
fi

[ -f "$STAGE/SKILL.md" ] || die "引擎不完整：根目录没有 SKILL.md。压缩包来源不对，重新获取"
[ -f "$STAGE/scripts/preflight.sh" ] || die "引擎不完整：scripts/preflight.sh 缺失"

# ---------------------------------------------------------------- ④ 落位（旧的先备份）
say "④ 安装到 $DEST"
PARENT="$(dirname "$DEST")"
mkdir -p "$PARENT" || die "创建目录失败：${PARENT}（权限不够？）"
if [ -e "$DEST" ]; then
  BAK="${DEST}.bak-$(date +%Y%m%d%H%M%S)"
  mv "$DEST" "$BAK" || die "旧安装挪去备份失败：$BAK"
  say "   已有安装备份为：${BAK}（你的资料库在别处，不受影响）"
fi
mv "$STAGE" "$DEST" || die "落位失败：$DEST"

# ---------------------------------------------------------------- ⑤ 环境预检
if [ "$DO_PREFLIGHT" -eq 1 ]; then
  say "⑤ 环境预检："
  if bash "$DEST/scripts/preflight.sh"; then
    :
  else
    RC=$?
    say ""
    say "⚠️ 环境预检没全过（退出码 ${RC}）。引擎文件已装好，把上面缺的东西补齐后"
    say "   重跑：bash $DEST/scripts/preflight.sh"
  fi
fi

# ---------------------------------------------------------------- ⑥ 收尾
say ""
say "──────────────────────────────────────────────"
say "✅ study-coach 引擎已装到：$DEST"
say ""
say "下一步：打开你的 AI 助手（WorkBuddy 等），对它说："
say ""
say "  用 study-coach 帮我学习，我还没装过，先走安装引导。"
say ""
say "Agent 会带你建资料库、接 Canvas（可选）、配置每日提醒。"
say "统一入口：$DEST/bin/sc <子命令>（Windows 的 cmd/PowerShell 里用 bin\\sc.cmd，会自动转给 Git Bash）"
say "   例：$DEST/bin/sc doctor    $DEST/bin/sc help"
say ""
say "非 WorkBuddy 平台：请设置环境变量 WORKBUDDY_HOME 指向你的配置目录"
say "（默认 ~/.workbuddy），否则脚本找不到 study-coach.json 和 Canvas token。"
say "例：export WORKBUDDY_HOME=~/.config/study-coach"
exit 0
