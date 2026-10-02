#!/usr/bin/env bash
# package_skill.sh — 把本引擎打成可分享的 zip，打不出来就明说
#
# 为什么需要它：手工 zip 已经漏过一次文件（v1.3.1 包比引擎少 7 个文件），
# 而新 SKILL.md 会点名这些脚本 —— 对方拿到"SKILL.md 引用一堆不存在脚本"的包，
# 一上手全是断链，还会以为是自己装错了。手工动作没有机制保障，就得有工具。
#
# 这条链上每个关卡都是硬的，缺一不可：
#   ① 版本号与 CHANGELOG 同步 —— 没有它，别人说不清手上是哪一版
#   ② 全量自检 —— 不打包一个自己都没验过的引擎
#   ③ 隐私扫描（源 + zip 内双查）—— 把个人课号/学校/用户名发出去等于把情报发出去
#   ④ 清单一致 —— SKILL.md 点名的脚本必须真实存在且真的进了包
#
# 用法：
#   bash package_skill.sh                    # 默认：跑全量自检 → 打包到 ~/WorkBuddy/
#   bash package_skill.sh --no-selftest      # 跳过全量自检（快；只建议自检刚跑过时用）
#   bash package_skill.sh --out <path>       # 指定输出 zip 路径
#
# ⚠️ 隐私清单是按**当前使用者**写的（见 PRIVACY_PATTERNS）。换人使用要改成自己的标识。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${HERE}/.." && pwd)"
SKILL_NAME="$(basename "${SKILL_DIR}")"
SKILLS_ROOT="$(cd "${SKILL_DIR}/.." && pwd)"

DO_SELFTEST=1
OUT=""

while [ $# -ge 1 ]; do
  case "$1" in
    --no-selftest) DO_SELFTEST=0; shift ;;
    --out)         [ $# -ge 2 ] || { echo "✗ --out 后面要跟路径" >&2; exit 2; }
                   OUT="$2"; shift 2 ;;
    -h|--help)     awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "✗ 不认识的参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1" >&2; }
note() { printf '  ·  %s\n' "$1"; }

# ---------------------------------------------------------------- 隐私清单
# 分两层：
#   内置（写死在下面，随包分享）—— 只放**格式类**模式：课号格式、绝对路径前缀。
#     这些对任何人都成立，不含个人标识。
#   外部（~/.workbuddy/study-coach-privacy.txt，一行一个正则，大小写不敏感）——
#     放**个人标识**：用户名、学校、旧工作区 id、真实课程 id 等。
#     它在引擎目录之外，**永远不会被打进包**，也不会被自己扫中。
#     文件不存在时只用内置清单，并提醒一句。
# 按人换：把外部文件里的模式换成你自己的标识再打包。

BUILTIN_PRIVACY='SS[0-9]{4}'
# 大小写敏感：任何绝对路径都不该出现在引擎里。只放 /Users/ —— /home/ 会误杀
# 测试里的 "$root/home/" 拼接写法；Linux 使用者可自行在此追加 /home/。
SENSITIVE_PATTERNS='/Users/'

PRIVACY_FILE="${WORKBUDDY_HOME:-$HOME/.workbuddy}/study-coach-privacy.txt"
PRIVACY_EXTRA=""
if [ -f "${PRIVACY_FILE}" ]; then
  PRIVACY_EXTRA="$(grep -vE '^\s*(#|$)' "${PRIVACY_FILE}" | tr '\n' '|' | sed 's/|$//')"
fi

scan_text() { # 输入走 stdin；命中详情输出到 stdout，命中数写进全局 HITS
  HITS=0
  local all="${BUILTIN_PRIVACY}"
  [ -n "${PRIVACY_EXTRA}" ] && all="${all}|${PRIVACY_EXTRA}"
  local n1 n2
  n1="$(grep -icE "${all}" || true)"
  n2="$(printf '%s' "${SENSITIVE_PATTERNS}" | tr ' ' '\n' | grep -v '^$' | while IFS= read -r pat; do
         grep -cF -- "${pat}" || true
       done | awk '{s+=$1} END{print s+0}')"
  HITS=$(( n1 + n2 ))
  if [ "${HITS}" -gt 0 ]; then
    grep -inE "${all}" || true
    printf '%s' "${SENSITIVE_PATTERNS}" | tr ' ' '\n' | grep -v '^$' | while IFS= read -r pat; do
      grep -nF -- "${pat}" || true
    done
  fi
  return 0
}

# ---------------------------------------------------------------- ① 版本号
SKILL_MD="${SKILL_DIR}/SKILL.md"
[ -f "${SKILL_MD}" ] || { bad "引擎根没有 SKILL.md（这不是一个 skill 目录？）"; exit 1; }
VERSION="$(grep -E '^version:' "${SKILL_MD}" | awk '{print $2}' | head -1)"
[ -n "${VERSION}" ] || { bad "SKILL.md 没有 version: 字段"; exit 1; }

CHANGELOG="${SKILL_DIR}/CHANGELOG.md"
if [ ! -f "${CHANGELOG}" ]; then
  bad "引擎根没有 CHANGELOG.md —— 版本历史落不了盘，别人没法判断拿到的是哪一版"
  exit 1
fi
if ! grep -q "^## ${VERSION} " "${CHANGELOG}"; then
  bad "SKILL.md 写的是 ${VERSION}，但 CHANGELOG.md 最新条目不是它 —— 版本记录与实际不同步"
  exit 1
fi
ok "版本 ${VERSION}，CHANGELOG 同步"

echo
echo "== 打包 ${SKILL_NAME} v${VERSION} =="

# ---------------------------------------------------------------- ② 全量自检
if [ "${DO_SELFTEST}" -eq 1 ]; then
  echo
  note "跑全量自检（约 40 秒）……"
  if bash "${HERE}/selftest.sh" >/dev/null 2>&1; then
    ok "引擎自检全绿"
  else
    bad "引擎自检没过 —— 先修自检，别打包一个不可信的引擎（自检确有把握时可 --no-selftest 跳过）"
    bash "${HERE}/selftest.sh" 2>&1 | grep -E '❌' | head -5 >&2 || true
    exit 1
  fi
else
  note "按参数跳过全量自检"
fi

# ---------------------------------------------------------------- ③ 源目录隐私扫描
echo
echo "关卡 ③ 隐私扫描（源目录）"
HITS_TOTAL=0
while IFS= read -r -d '' f; do
  scan_text < "${f}" > /tmp/pkg-scan-out.$$ || true
  if [ "${HITS}" -gt 0 ]; then
    bad "隐私命中：${f#${SKILL_DIR}/}"
    sed 's/^/       /' /tmp/pkg-scan-out.$$ >&2
    HITS_TOTAL=$((HITS_TOTAL + HITS))
  fi
done < <(find "${SKILL_DIR}" -type f \( -name "*.md" -o -name "*.sh" -o -name "*.py" -o -name "*.js" -o -name "*.tsv" -o -name "*.json" -o -name "*.ps1" -o -name "*.cmd" -o -path "*/bin/sc" \) -print0)
rm -f /tmp/pkg-scan-out.$$
if [ "${HITS_TOTAL}" -eq 0 ]; then
  ok "源目录隐私零命中"
else
  bad "源目录有 ${HITS_TOTAL} 处隐私 —— 先清干净，再谈打包"
  exit 1
fi

# ---------------------------------------------------------------- ④ SKILL.md 点名的脚本必须存在
echo
echo "关卡 ④ SKILL.md 点名的脚本"
MISSING=""
N_SCRIPTS=0
while IFS= read -r rel; do
  N_SCRIPTS=$((N_SCRIPTS + 1))
  [ -f "${SKILL_DIR}/${rel}" ] || MISSING="${MISSING} ${rel}"
done < <(grep -oE 'scripts/[A-Za-z0-9_-]+\.(sh|py|js)' "${SKILL_MD}" | sort -u)
if [ -z "${MISSING}" ]; then
  ok "SKILL.md 点名的 ${N_SCRIPTS} 个脚本都在引擎里"
else
  bad "SKILL.md 点名了这些脚本，但文件不存在：${MISSING}"
  exit 1
fi

# ---------------------------------------------------------------- 打包
echo
[ -n "${OUT}" ] || OUT="${HOME}/WorkBuddy/${SKILL_NAME}-skill-v${VERSION}.zip"
mkdir -p "$(dirname "${OUT}")"
if [ -e "${OUT}" ]; then
  note "输出路径已存在，覆盖：${OUT}"
  rm -f "${OUT}"    # 先删：zip 对已存在的坏文件不会覆盖而是报错
fi

TMPDIR_PKG="$(mktemp -d /tmp/pkg-skill-XXXXXX)"
trap 'rm -rf "${TMPDIR_PKG}"' EXIT

# 复制到暂存目录再打，排除垃圾，保证 zip 内顶层就是 <skill_name>/
cp -R "${SKILL_DIR}" "${TMPDIR_PKG}/${SKILL_NAME}"
find "${TMPDIR_PKG}/${SKILL_NAME}" \( -name ".DS_Store" -o -name "__pycache__" -o -name "*.pyc" \) -delete

SRC_COUNT="$(find "${TMPDIR_PKG}/${SKILL_NAME}" -type f | wc -l | tr -d ' ')"

(cd "${TMPDIR_PKG}" && zip -r -q "${OUT}" "${SKILL_NAME}")
[ -f "${OUT}" ] || { bad "zip 没打出来：${OUT}"; exit 1; }
ok "打包完成：${OUT}"

# ---------------------------------------------------------------- ⑤ zip 内校验
echo
echo "关卡 ⑤ zip 内校验"

# 用 -Z1（zipinfo 模式）只列条目名，目录以 / 结尾。
# 为什么不用 unzip -l：它的日期列格式因平台而异（macOS 输出 MM-DD-YYYY，
# Linux 输出 YYYY-MM-DD），早先的正则写死了 macOS 格式，Linux 上文件数恒为 0，
# 整个打包链路必挂 —— 这是外部 review 实测抓出来的可移植性 bug。
ZIP_LIST="$(unzip -Z1 "${OUT}" 2>/dev/null || true)"
# 只数非目录条目（find -type f 的口径），目录条目 zip -r 会自动加
ZIP_COUNT="$(printf '%s\n' "${ZIP_LIST}" | awk 'NF && !/\/$/ {n++} END {print n+0}')"
if [ "${ZIP_COUNT}" = "${SRC_COUNT}" ]; then
  ok "文件数一致：${ZIP_COUNT}"
else
  bad "文件数不一致：源 ${SRC_COUNT} vs zip ${ZIP_COUNT} —— 有东西没进包"
  exit 1
fi

ZIP_HITS=0
while IFS= read -r zrel; do
  [ -z "${zrel}" ] && continue
  case "${zrel}" in */) continue ;; esac
  scan_text < <(unzip -p "${OUT}" "${zrel}") > /tmp/pkg-zscan-out.$$ || true
  if [ "${HITS}" -gt 0 ]; then
    bad "zip 内隐私命中：${zrel}"
    sed 's/^/       /' /tmp/pkg-zscan-out.$$ >&2
    ZIP_HITS=$((ZIP_HITS + HITS))
  fi
done < <(printf '%s\n' "${ZIP_LIST}")
rm -f /tmp/pkg-zscan-out.$$
if [ "${ZIP_HITS}" -eq 0 ]; then
  ok "zip 内容隐私零命中（从包里解出来验的，不是抄暂存目录）"
else
  bad "zip 里有 ${ZIP_HITS} 处隐私 —— 删掉这个包：${OUT}"
  exit 1
fi

# SKILL.md 点名的脚本在 zip 里也真在（拿 zip 自己的清单整行精确匹配）
ZMISS=""
while IFS= read -r rel; do
  printf '%s\n' "${ZIP_LIST}" | grep -Fxq "${SKILL_NAME}/${rel}" || ZMISS="${ZMISS} ${rel}"
done < <(grep -oE 'scripts/[A-Za-z0-9_-]+\.(sh|py|js)' "${TMPDIR_PKG}/${SKILL_NAME}/SKILL.md" | sort -u)
if [ -z "${ZMISS}" ]; then
  ok "SKILL.md 点名的脚本全部进了包"
else
  bad "以下脚本没进包：${ZMISS}"
  exit 1
fi

SIZE="$(du -h "${OUT}" | awk '{print $1}')"

# 计算 SHA-256，供 install.sh --sha256 校验使用（防镜像/中间人篡改）
SHA_OUT="${OUT}.sha256"
if command -v shasum >/dev/null 2>&1; then
  SHA="$(shasum -a 256 "${OUT}" | cut -d' ' -f1)"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "${OUT}" | cut -d' ' -f1)"
else
  SHA=""
fi
if [ -n "${SHA}" ]; then
  printf '%s  %s\n' "${SHA}" "$(basename "${OUT}")" > "${SHA_OUT}"
  ok "SHA-256：${SHA}"
  note "   校验文件：${SHA_OUT}（安装时 bash install.sh --zip <包> --sha256 ${SHA}）"
else
  note "本机无 shasum/sha256sum，跳过 SHA-256 生成"
fi

echo
echo "✅ ${SKILL_NAME} v${VERSION} → ${OUT}（${SRC_COUNT} 文件 / ${SIZE}）"
echo "   发给别人前最后一步：把本文件 + README.md 一起看一遍，确认没有遗漏的交付说明。"
