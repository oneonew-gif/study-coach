#!/usr/bin/env bash
# init_library.sh — 建学习资料库骨架（幂等，绝不覆盖已有文件）
#
# 用法：init_library.sh <库目录>
# 例：  init_library.sh ~/WorkBuddy/study-library

set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "用法: init_library.sh <库目录>" >&2
  exit 1
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$DIR"/notes "$DIR"/assignments "$DIR"/quiz \
         "$DIR"/materials "$DIR"/transcripts "$DIR"/recordings \
         "$DIR"/plans "$DIR"/training "$DIR"/archive \
         "$DIR"/inspection/snapshots "$DIR"/inspection/reports

copy_if_absent() {
  local src="$1" dst="$2" label="$3"
  if [ -f "$dst" ]; then
    echo "  跳过（已存在）: $label"
  elif [ -f "$src" ]; then
    cp "$src" "$dst"
    echo "  新建        : $label"
  else
    echo "  缺失模板    : $src"
  fi
}

echo "资料库：$DIR"
echo
echo "目录   : notes/ assignments/ quiz/ materials/ transcripts/ recordings/ plans/ training/ archive/ inspection/  （已就绪）"
echo "文件   :"
copy_if_absent "$SKILL_DIR/templates/COURSES.template.md"     "$DIR/COURSES.md"      "COURSES.md（课程索引，待填）"
copy_if_absent "$SKILL_DIR/templates/WORKFLOWS.template.md"   "$DIR/WORKFLOWS.md"    "WORKFLOWS.md（工作流与红线，待填）"
copy_if_absent "$SKILL_DIR/references/course-rules-template.md" "$DIR/course-rules.md" "course-rules.md（各课出题规律，待填）"
copy_if_absent "$SKILL_DIR/scripts/draw_quiz.js"             "$DIR/quiz/draw_quiz.js" "quiz/draw_quiz.js（抽题器）"
copy_if_absent "$SKILL_DIR/templates/inspection-README.md"   "$DIR/inspection/README.md" "inspection/README.md（巡检说明）"

# 题库与术语表先建空的：COURSES.md 的说明里会提到这两个文件，
# 文件不存在它们就成了「断链」，新库一装出来就是红的 —— 那会教人忽略体检报告。
if [ ! -f "$DIR/quiz/bank.json" ]; then
  printf '{\n  "questions": []\n}\n' > "$DIR/quiz/bank.json"
  echo "  新建        : quiz/bank.json（空题库，逐个 append）"
fi
if [ ! -f "$DIR/quiz/terms.json" ]; then
  printf '{\n  "source": "手动积累",\n  "extractedAt": "%s",\n  "terms": {}\n}\n' \
    "$(date +%Y-%m-%d)" > "$DIR/quiz/terms.json"
  echo "  新建        : quiz/terms.json（空术语表，逐课登记原词）"
fi
[ -f "$DIR/inspection/log.tsv" ] || printf '时间\t动作\t课程数\t变动数\t结果\n' > "$DIR/inspection/log.tsv"

echo
echo "下一步：照 SKILL.md 的「首次使用 · 安装引导」往下走。"
