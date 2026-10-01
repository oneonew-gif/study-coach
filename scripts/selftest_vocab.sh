#!/usr/bin/env bash
# vocab.sh · 自检（注入式）
#
# 背词教练的承诺：
#   ① 不编词 —— 空库抽词必须报错并给收词指引
#   ② 抽词不给答案，每词带来源标签与编号；盒 1、2 优先
#   ③ 莱特纳盒子机械升降：答对进盒、答错回盒 1
#   ④ 自动来源必经收词箱：accept 才进主册，dismiss 就丢弃
#   ⑤ 引导行按星期排班（五句梗词），可配置关闭；空库不推空气
#
# 用法：  bash scripts/selftest_vocab.sh
# 退出码：0 = 全过；1 = 有失败

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "背词教练 · 自检"
echo

BIN="$(mktemp -d)"
LIB="$(mktemp -d)"
TMPHOME="$(mktemp -d)"
trap 'rm -rf "$BIN" "$LIB" "$TMPHOME"' EXIT

cp "$HERE/vocab.sh" "$BIN/"
V="bash $BIN/vocab.sh --lib $LIB"

# ---------------------------------------------------------------- ① 不编词
OUT="$($V draw 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "我不会编词"; then
  ok "空库抽词明确报错并给收词指引（不编词）"
else
  bad "空库抽词没拦住（退出码 ${RC}）"
fi

# ---------------------------------------------------------------- ② add → draw
$V add --term "thick description" --def "厚描" --course DEMO101 --source "第3讲课件" >/dev/null
$V add --term "moral disengagement" --def "道德推脱" --course DEMO101 --source "第3讲课件" >/dev/null
OUT="$($V add --term "thick description" 2>&1)"
if printf '%s' "$OUT" | grep -q "已经在册"; then
  ok "重复加词被拦（同册去重）"
else
  bad "重复加词没去重"
fi

OUT="$($V draw --n 5 2>&1)"
if printf '%s' "$OUT" | grep -q "thick description" \
   && printf '%s' "$OUT" | grep -q "DEMO101 · 第3讲课件" \
   && ! printf '%s' "$OUT" | grep -q "厚描"; then
  ok "抽词带来源标签、不漏答案"
else
  bad "抽词输出不对（该有来源、不该有释义）"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ②½ 讲次过滤（--lecture / --recent）
$V add --term "collective efficacy" --def "集体效能" --course DEMO101 --source "第5讲课件" >/dev/null
$V add --term "etic" --def "客位的" --course DEMO101 --source "第五讲课件" >/dev/null

OUT="$($V draw --lecture 3 --n 10 2>&1)"
if printf '%s' "$OUT" | grep -q "thick description" \
   && ! printf '%s' "$OUT" | grep -q "collective efficacy"; then
  ok "--lecture 3 只出第 3 讲的词"
else
  bad "--lecture 3 过滤不对"
fi

OUT="$($V draw --recent 1 --n 10 2>&1)"
if printf '%s' "$OUT" | grep -q "collective efficacy" && printf '%s' "$OUT" | grep -q "etic" \
   && ! printf '%s' "$OUT" | grep -q "thick description"; then
  ok "--recent 1 只出最近一讲（含中文数字「第五讲」解析）"
else
  bad "--recent 1 过滤不对（中文数字讲次可能没解析）"
fi

OUT="$($V draw --recent 2 --n 10 2>&1)"
if printf '%s' "$OUT" | grep -q "thick description" && printf '%s' "$OUT" | grep -q "etic"; then
  ok "--recent 2 覆盖两讲全部 4 词"
else
  bad "--recent 2 数量不对"
fi

OUT="$($V draw --lecture 3 --recent 1 2>&1)"
if printf '%s' "$OUT" | grep -q "二选一"; then
  ok "--lecture 与 --recent 同用明确报错"
else
  bad "--lecture/--recent 冲突没拦"
fi

# ---------------------------------------------------------------- ③ 莱特纳盒子
$V grade --id 1 --hit >/dev/null
OUT="$($V grade --id 1 --miss 2>&1)"
if printf '%s' "$OUT" | grep -q "回盒 1"; then
  ok "答错打回盒 1"
else
  bad "答错没回盒 1"
fi
$V grade --id 1 --hit >/dev/null
BOX="$(python3 -c "import json;print(json.load(open('$LIB/vocab/vocab.json'))['words'][0]['box'])")"
if [ "$BOX" = "2" ]; then
  ok "答对进下一盒（盒1 → 盒2）"
else
  bad "答对没进盒（读到盒 ${BOX}）"
fi

OUT="$($V grade --id 999 --hit 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "编号不存在时明确报错"
else
  bad "编号不存在没报错（退出码 ${RC}）"
fi

# ---------------------------------------------------------------- ④ stats
OUT="$($V stats 2>&1)"
if printf '%s' "$OUT" | grep -q "主册：4 词" && printf '%s' "$OUT" | grep -q "盒1:3"; then
  ok "stats 盒分布正确"
else
  bad "stats 输出不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑤ 收词箱
$V inbox add --term "self-efficacy" --def "自我效能" --source "错题探测" >/dev/null
OUT="$($V inbox list 2>&1)"
if printf '%s' "$OUT" | grep -q "self-efficacy" && printf '%s' "$OUT" | grep -q "1 个待确认"; then
  ok "探测器来的词先进收词箱（不直接进主册）"
else
  bad "收词箱流程不对"
fi
$V inbox dismiss --id 1 >/dev/null
OUT="$($V inbox accept --id 1 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  ok "dismiss 后 accept 明确报错（词没被偷偷收进）"
else
  bad "dismiss 过的词还能 accept —— 红线失守"
fi
$V inbox add --term "self-efficacy" --def "自我效能" --source "错题探测" >/dev/null
$V inbox accept --id 2 >/dev/null
OUT="$($V stats 2>&1)"
if printf '%s' "$OUT" | grep -q "主册：5 词"; then
  ok "accept 后词进主册（带原来源）"
else
  bad "accept 没进主册"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑥ 分册导入
printf 'resilience\t心理韧性\nattribution style\t归因风格\n' > "$LIB/wordlist.tsv"
OUT="$($V import --file "$LIB/wordlist.tsv" --book 考研冲刺 2>&1)"
if printf '%s' "$OUT" | grep -q "导入 2 词"; then
  ok "词表文件导入自定义册"
else
  bad "词表导入失败"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi
OUT="$($V import --file "$LIB/wordlist.tsv" --book 考研冲刺 2>&1)"
if printf '%s' "$OUT" | grep -q "导入 0 词"; then
  ok "分册同样去重"
else
  bad "分册没去重"
fi
OUT="$($V draw --book 考研冲刺 --n 5 2>&1)"
if printf '%s' "$OUT" | grep -q "resilience" && ! printf '%s' "$OUT" | grep -q "thick description"; then
  ok "分册抽词隔离（不混主册）"
else
  bad "分册抽词串了"
fi

# ---------------------------------------------------------------- ⑦ 从术语表导入
mkdir -p "$LIB/quiz"
printf '{"terms":{"DEMO101":[{"en":"thick description","zh":"厚描"},{"en":"emic","zh":"主位的"}]}}' > "$LIB/quiz/terms.json"
OUT="$($V import --from-terms 2>&1)"
if printf '%s' "$OUT" | grep -q "导入 1 个新词" \
   && printf '%s' "$OUT" | grep -q "emic"; then
  ok "术语表导入主册（已有的 thick description 不重复加）"
else
  bad "术语表导入不对"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- ⑧ remove 可追溯
OUT="$($V remove --term "emic" 2>&1)"
if printf '%s' "$OUT" | grep -q "已删除" && printf '%s' "$OUT" | grep -q "术语表"; then
  ok "删词可追溯（打印来源）"
else
  bad "删词没带溯源信息"
fi

# ---------------------------------------------------------------- ⑨ 引导行排班
OUT="$(VOCAB_FAKE_WEEKDAY=1 $V hint 2>&1)"
if printf '%s' "$OUT" | grep -q "今日有人味儿的提醒" && printf '%s' "$OUT" | grep -q "city不city来背单词"; then
  ok "周一引导行 = city不city来背单词"
else
  bad "周一引导行不对"
fi
PHRASE_OK=1
for pair in "2:cityuniversity" "3:又一城学子背单词了" "4:hello Hong Kong study" "5:考我单词"; do
  d="${pair%%:*}"; p="${pair#*:}"
  OUT="$(VOCAB_FAKE_WEEKDAY=$d $V hint 2>&1)"
  printf '%s' "$OUT" | grep -q "$p" || PHRASE_OK=0
done
[ "$PHRASE_OK" = "1" ] && ok "周二至周五排班正确（cityuniversity / 又一城 / hello Hong Kong study / 考我单词）" \
  || bad "周中某天的梗词排班不对"
OUT="$(VOCAB_FAKE_WEEKDAY=6 $V hint 2>&1)"
if printf '%s' "$OUT" | grep -q "我想背单词"; then
  ok "周末回落到通用句（我想背单词）"
else
  bad "周末引导行没兜底"
fi

# ---------------------------------------------------------------- ⑩ 引导行配置
mkdir -p "$TMPHOME/.workbuddy"
printf '{"vocab":{"hint":false}}' > "$TMPHOME/.workbuddy/study-coach.json"
OUT="$(HOME="$TMPHOME" VOCAB_FAKE_WEEKDAY=1 $V hint 2>&1)"
if [ -z "$OUT" ]; then
  ok "vocab.hint=false 时引导行整行消失"
else
  bad "hint 关闭后还有输出：${OUT}"
fi
printf '{"vocab":{"hints":{"1":"山城学子背单词了"},"hint":true}}' > "$TMPHOME/.workbuddy/study-coach.json"
OUT="$(HOME="$TMPHOME" VOCAB_FAKE_WEEKDAY=1 $V hint 2>&1)"
if printf '%s' "$OUT" | grep -q "山城学子背单词了"; then
  ok "按星期几自定义梗词生效"
else
  bad "自定义梗词没生效"
fi

# ---------------------------------------------------------------- ⑪ 用法与降级
OUT="$($V 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "用法"; then
  ok "无参数时打印用法（退出码 0）"
else
  bad "无参数调用行为不对（退出码 ${RC}）"
fi
OUT="$($V draw --lib /nonexistent_dir_xyz 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "资料库不存在"; then
  ok "库不存在时明确报错"
else
  bad "库不存在时退出码 ${RC}"
fi

echo
echo "结果：${pass} 通过 / ${fail} 失败"
[ "${fail}" -eq 0 ] && echo "✅ 背词教练行为正确" || echo "❌ 有行为偏离承诺"
exit $([ "${fail}" -eq 0 ] && echo 0 || echo 1)
