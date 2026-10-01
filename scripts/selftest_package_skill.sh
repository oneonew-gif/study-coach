#!/usr/bin/env bash
# selftest_package_skill.sh — 打包器的自检
#
# 验的是「该拒绝的会不会拒绝」，不是「跑不崩」：
#   ① 干净引擎 → 能出包，五关全过
#   ② 注入隐私（课号样本，动态拼接避免本文件自命中）→ 必须拒绝
#   ③ 版本号与 CHANGELOG 不同步 → 必须拒绝
#   ④ SKILL.md 点名不存在的脚本 → 必须拒绝
#   ⑤ 删掉一个被点名的脚本 → 必须拒绝
#   ⑥ 不跳过自检时引擎缺 selftest.sh → 必须拒绝
#
# 每个用例都在**复制出来的引擎副本**上动手，真引擎不被改动。
# 测试 HOME 指向临时目录 → 外部隐私清单不存在 → 顺带验证「只有内置清单也能干活」。

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/pkg-selftest-XXXXXX)"
ENGINE="${TMP}/engine"
HOME_DIR="${TMP}/home"
cp -R "${HERE}/.." "${ENGINE}"
mkdir -p "${HOME_DIR}"
PKG="${ENGINE}/scripts/package_skill.sh"

run() { # HOME 与输出 zip 每个用例自定
  HOME="${HOME_DIR}" bash "${PKG}" --out "${TMP}/$1" "${@:2}" 2>&1
}
rc_of() {
  HOME="${HOME_DIR}" bash "${PKG}" --out "${TMP}/$1" "${@:2}" >/dev/null 2>&1
  echo $?
}

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

# ---------------------------------------------------------------- ① 干净引擎
rc="$(rc_of good.zip --no-selftest)"
if [ "${rc}" = "0" ]; then
  if [ -f "${TMP}/good.zip" ]; then
    ok "干净引擎能出包"
  else
    bad "退出码 0 但 zip 不存在"
  fi
else
  bad "干净引擎被拒绝（退出码 ${rc}）—— 报告会让人以为引擎坏了"
  run good.zip --no-selftest | grep -E '❌' | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ② 注入隐私
# 课号样本用拼接构造，避免本文件里出现会被内置模式命中的字面量
PRIV_NUM=4321
PRIV="SS${PRIV_NUM}"
printf '\n# 注入的隐私样本：学生 %s 的笔记\n' "${PRIV}" >> "${ENGINE}/SKILL.md"
rc="$(rc_of priv.zip --no-selftest)"
out="$(run priv.zip --no-selftest)"
if [ "${rc}" != "0" ] && printf '%s' "${out}" | grep -q "隐私"; then
  ok "注入隐私被拒绝"
else
  bad "带隐私的引擎没被拦住（退出码 ${rc}）—— 这条关卡就白设了"
fi
# 还原（③ 用干净副本，直接重拷 SKILL.md 太粗，先摘掉注入行）
grep -v "${PRIV}" "${ENGINE}/SKILL.md" > "${ENGINE}/SKILL.md.new" && mv "${ENGINE}/SKILL.md.new" "${ENGINE}/SKILL.md"

# ---------------------------------------------------------------- ③ 版本不同步
sed 's/^version: .*/version: 9.9.9/' "${ENGINE}/SKILL.md" > "${ENGINE}/SKILL.md.new" \
  && mv "${ENGINE}/SKILL.md.new" "${ENGINE}/SKILL.md"
rc="$(rc_of ver.zip --no-selftest)"
if [ "${rc}" != "0" ]; then
  ok "版本号与 CHANGELOG 不同步被拒绝"
else
  bad "版本不同步没被拦住 —— 对方将拿不到任何版本线索"
fi
sed 's/^version: .*/version: 1.6.0/' "${ENGINE}/SKILL.md" > "${ENGINE}/SKILL.md.new" \
  && mv "${ENGINE}/SKILL.md.new" "${ENGINE}/SKILL.md"

# ---------------------------------------------------------------- ④ 点名不存在的脚本
printf '\n引用：`scripts/nope_not_real.py`。\n' >> "${ENGINE}/SKILL.md"
rc="$(rc_of ref.zip --no-selftest)"
out="$(run ref.zip --no-selftest)"
if [ "${rc}" != "0" ] && printf '%s' "${out}" | grep -q "不存在"; then
  ok "SKILL.md 点名不存在的脚本被拒绝"
else
  bad "断链引用没被拦住（退出码 ${rc}）—— 对方拿到包就是断链"
fi
grep -v "nope_not_real" "${ENGINE}/SKILL.md" > "${ENGINE}/SKILL.md.new" \
  && mv "${ENGINE}/SKILL.md.new" "${ENGINE}/SKILL.md"

# ---------------------------------------------------------------- ⑤ 被点名的脚本丢失
rm -f "${ENGINE}/scripts/preflight.sh"
rc="$(rc_of lose.zip --no-selftest)"
if [ "${rc}" != "0" ]; then
  ok "点名脚本被删后拒绝打包"
else
  bad "脚本缺失没被拦住 —— 包会缺文件"
fi
cp "${HERE}/preflight.sh" "${ENGINE}/scripts/preflight.sh"

# ---------------------------------------------------------------- ⑥ 不跳过自检时自检失败要拦
# 换成秒败的假 selftest.sh —— 不能让打包器真跑全量自检（会递归回本文件）
mv "${ENGINE}/scripts/selftest.sh" "${ENGINE}/scripts/selftest.sh.bak"
printf '#!/usr/bin/env bash\nexit 1\n' > "${ENGINE}/scripts/selftest.sh"
rc="$(rc_of st.zip)"
mv "${ENGINE}/scripts/selftest.sh.bak" "${ENGINE}/scripts/selftest.sh"
if [ "${rc}" != "0" ]; then
  ok "自检失败时不放行（没打出一个没验过的包）"
else
  bad "自检失败还放行 —— 打了个没验过的包"
fi

# ---------------------------------------------------------------- ⑦ 清单提取的可移植性
# 早先用 unzip -l 的日期列定位条目，正则写死 macOS 的 MM-DD-YYYY ——
# Linux 的 unzip 输出 YYYY-MM-DD，文件数恒为 0，整条打包链必挂。
if grep -q 'unzip -Z1' "${PKG}" && ! grep -q 'unzip -l "${OUT}"' "${PKG}"; then
  ok "zip 清单用 -Z1 提取（与平台日期格式无关）"
else
  bad "打包器又在解析 unzip -l 的日期列 —— Linux 上必挂的坑回来了"
fi

echo
echo "结果：${pass} 通过 / ${fail} 失败"
[ "${fail}" -eq 0 ]
