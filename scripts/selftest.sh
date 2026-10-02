#!/usr/bin/env bash
# selftest.sh — 自检总入口
#
# 为什么要有它：引擎里每个脚本都该被验过，但「记得挨个跑」这件事本身就不该靠人记。
# 这里自动发现 scripts/selftest_*.sh，跑一遍，汇总成败。
#
# 一个检查器如果从不报错，就等于没有检查器 —— 所以这里验的是「检查器会不会在该报的时候报」，
# 不是「它跑起来没崩」。
#
# 用法：
#   bash scripts/selftest.sh                  跑全部
#   bash scripts/selftest.sh terms            只跑名字含 terms 的
#   bash scripts/selftest.sh terms draw_quiz  跑匹配到这些名字的并集（多个名字都跑，不是只跑最后一个）
#   bash scripts/selftest.sh -v               连通过的项的详细输出也打出来
#
# 退出码：0 = 全过；1 = 有失败；2 = 一个自检项都没找到（含点名了不存在的自检项）

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE=0
FILTERS=()
for a in "$@"; do
  case "$a" in
    -v|--verbose) VERBOSE=1 ;;
    *) FILTERS+=("$a") ;;
  esac
done

# ---------------------------------------------------------------- 收集
# 多个名字 = 并集（每个名字各自匹配一轮，匹配到的都跑，去重）。
# 早先多参数会互相覆盖、静默只跑最后一个 —— 「以为跑了两项、实际只跑一项」的假安心，比失败更危险。
NL=$'\n'
TESTS=""
MISSING=""
if [ "${#FILTERS[@]}" -gt 0 ]; then
  for flt in ${FILTERS[@]+"${FILTERS[@]}"}; do
    found=0
    for f in "$HERE"/selftest_*.sh; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        *"$flt"*)
          found=1
          case "$TESTS" in *"$f"*) ;; *) TESTS="${TESTS}${f}${NL}" ;; esac
          ;;
      esac
    done
    [ "$found" -eq 1 ] || MISSING="${MISSING}${flt} "
  done
  if [ -n "$MISSING" ]; then
    echo "点名的自检项不存在或没匹配到任何 selftest_*.sh：${MISSING% }" >&2
    exit 2
  fi
else
  for f in "$HERE"/selftest_*.sh; do
    [ -f "$f" ] && TESTS="${TESTS}${f}${NL}"
  done
fi

if [ -z "$TESTS" ]; then
  echo "没找到任何自检项。scripts/ 下应有 selftest_*.sh" >&2
  exit 2
fi

# ---------------------------------------------------------------- 环境
echo
echo "自检 · study-coach 引擎"
echo "══════════════════════════════════════════════"

PRE_FAIL=0
if [ -x "$HERE/preflight.sh" ]; then
  ENVLINE="$(bash "$HERE/preflight.sh" --line 2>&1 | tail -1)"
  echo "环境：${ENVLINE}"
  # preflight 由本文件登记为它的自检载体，这里钉住两条回归：
  # ① 退出码语义：缺必需项=1、平台不支持=2（早先全变 2，文档承诺的 1 永远走不到）
  # ② 缺 node 是选装口径：只影响抽题器，不许 fatal 吓退没装 node 的人
  if grep -qE '^fatal\(\)\{.*OK=1' "$HERE/preflight.sh" \
     && grep -qE '^unsupported\(\)\{.*OK=2' "$HERE/preflight.sh"; then
    echo "  ✅ preflight 退出码语义正确（缺必需项=1，平台不支持=2）"
  else
    echo "  ❌ preflight 退出码语义丢了：fatal 应置 OK=1，unsupported 置 OK=2"
    PRE_FAIL=1
  fi
  if grep -q '只有抽题器不可用' "$HERE/preflight.sh"; then
    echo "  ✅ preflight 缺 node 走选装口径，不当 fatal"
  else
    echo "  ❌ preflight 又把缺 node 当 fatal —— 与文档口径矛盾"
    PRE_FAIL=1
  fi
fi

# WORKBUDDY_HOME 回归：所有定义 CONFIG/TOKEN_FILE/CFGDIR/PRIVACY_FILE 的脚本都必须用
# ${WORKBUDDY_HOME:-$HOME/.workbuddy}，不能硬编码 $HOME/.workbuddy。
# 判定：定义了配置路径变量但行内不含 WORKBUDDY_HOME 才算违规
# （正确写法的默认值里虽然含 $HOME/.workbuddy，但整行一定有 WORKBUDDY_HOME）。
HARDCODED=""
for f in "$HERE"/*.sh "$HERE"/*.py; do
  [ -f "$f" ] || continue
  # 只检查定义了配置路径变量的文件
  if grep -qE '^(CONFIG|TOKEN_FILE|CFGDIR|PRIVACY_FILE)\s*=' "$f" 2>/dev/null; then
    if ! grep -qE '^(CONFIG|TOKEN_FILE|CFGDIR|PRIVACY_FILE)\s*=.*WORKBUDDY_HOME' "$f" 2>/dev/null; then
      HARDCODED="${HARDCODED}$(basename "$f") "
    fi
  fi
done
if [ -z "$HARDCODED" ]; then
  echo "  ✅ 所有配置路径脚本都支持 WORKBUDDY_HOME（无硬编码 \$HOME/.workbuddy）"
else
  echo "  ❌ 以下脚本配置路径硬编码了 \$HOME/.workbuddy，未用 WORKBUDDY_HOME：${HARDCODED}"
  PRE_FAIL=1
fi

# Python 选择回归：所有脚本必须经 _common.sh 选 Python（真跑验证）。
# 早先 15 个脚本各写一份「command -v python3 就用它」，会选中 Windows 商店的假 python3.exe。
# 判定：出现「PY=python3」或「PY="python3"」这种不经验证的直接赋值即违规。
BAREPY=""
for f in "$HERE"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in _common.sh|selftest*.sh) continue ;; esac
  if grep -qE '^[[:space:]]*(PY|PYBIN)="?python3?"?[[:space:]]*(;|$)' "$f" \
     || grep -qE 'command -v python3[^|&]*&&[^|]*PY=' "$f"; then
    BAREPY="${BAREPY}$(basename "$f") "
  fi
done
if [ -z "$BAREPY" ]; then
  echo "  ✅ Python 都经 _common.sh 真跑验证选出（不会选中 Windows 商店的假 python3）"
else
  echo "  ❌ 以下脚本绕过 _common.sh 直接认 python3（Windows 上会选中假货）：${BAREPY}"
  PRE_FAIL=1
fi

# ---------------------------------------------------------------- 逐项跑
TOTAL=0; PASS=0; FAILED=""
START_ALL="$(date +%s)"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  （Git Bash 起进程较慢，全部跑完可能要 5–10 分钟，每项都会显示进度，没卡住）" ;;
esac
IS_TTY=0; [ -t 1 ] && IS_TTY=1

while IFS= read -r t; do
  [ -n "$t" ] || continue
  name="$(basename "$t" .sh)"; name="${name#selftest_}"
  TOTAL=$((TOTAL + 1))
  START="$(date +%s)"
  # 进度：终端里先打「运行中」，跑完用结果行覆盖；非终端（日志/agent 捕获）直接逐行打
  if [ "$IS_TTY" -eq 1 ]; then
    printf '  ⏳ %-14s 运行中…\r' "$name"
  else
    printf '  … 正在跑 %s\n' "$name"
  fi
  OUT="$(bash "$t" 2>&1)"; RC=$?
  [ "$IS_TTY" -eq 1 ] && printf '\033[2K'
  COST=$(( $(date +%s) - START ))

  if [ "$RC" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  ✅ %-14s %ds\n' "$name" "$COST"
    if [ "$VERBOSE" -eq 1 ]; then
      printf '%s\n' "$OUT" | sed 's/^/       /'
    fi
  else
    FAILED="${FAILED}${name} "
    printf '  ❌ %-14s 退出码 %s  %ds\n' "$name" "$RC" "$COST"
    printf '%s\n' "$OUT" | sed 's/^/       /'
  fi
done <<EOF
$TESTS
EOF

# ---------------------------------------------------------------- 汇总
COST_ALL=$(( $(date +%s) - START_ALL ))
echo "══════════════════════════════════════════════"
if [ "$PASS" -eq "$TOTAL" ] && [ "$PRE_FAIL" -eq 0 ]; then
  echo "  ${PASS}/${TOTAL} 通过　→ 引擎自检正常（${COST_ALL}s）"
  echo
  exit 0
fi
if [ "$PRE_FAIL" -ne 0 ]; then
  echo "  另有 preflight 口径回归（见上方 ❌），修完再交付。"
fi
echo "  ${PASS}/${TOTAL} 通过　→ 有问题的：${FAILED}"
echo "  自检失败意味着对应的工具**在该报错的时候不报**，别拿着它去交付。"
echo
exit 1
