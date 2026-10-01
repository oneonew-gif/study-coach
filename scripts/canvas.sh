#!/usr/bin/env bash
# canvas.sh — 只读 Canvas 客户端
#
# 为什么存在：如果 Agent 直接对着 Canvas 手写 curl，那「只读」就只是一句口头承诺。
# 本脚本把**所有** Canvas 请求收敛到这一个出口，并且只实现 HTTP GET ——
# 它没有、也不会实现任何 POST / PUT / PATCH / DELETE，
# 因此在物理上无法提交作业、发送消息、改成绩或改动任何课程内容。
#
# 用法：
#   canvas.sh doctor                      自检（凭据 + 连通性 + 文件权限）
#   canvas.sh self                        当前用户信息
#   canvas.sh courses                     在读课程列表
#   canvas.sh assignments <course_id>     某课作业与截止日期
#   canvas.sh syllabus <course_id>        某课 syllabus
#   canvas.sh modules <course_id>         某课模块与条目
#   canvas.sh announcements <course_id>   某课公告
#   canvas.sh files <course_id>           某课文件列表
#   canvas.sh page <course_id> <url>      某课某个页面
#   canvas.sh raw <path>                  任意其他路径（仍强制 GET）
#   canvas.sh download <url> <out_path>   下载课程文件（GET，不带凭据头，可跟重定向）
#
# 凭据（两者都不在资料库里，所以资料库可以随便备份、分享）：
#   <WORKBUDDY_HOME>/study-coach.json   { "canvas": { "baseUrl": "https://..." } }
#   <WORKBUDDY_HOME>/.canvas-token      单行 personal access token，权限 600
#   WORKBUDDY_HOME 默认为 ~/.workbuddy，可通过环境变量覆盖。
#   也可用环境变量 CANVAS_BASE_URL / CANVAS_TOKEN 临时覆盖。

set -euo pipefail

WORKBUDDY_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
CONFIG="$WORKBUDDY_HOME/study-coach.json"
TOKEN_FILE="$WORKBUDDY_HOME/.canvas-token"
CANVAS_BASE_SRC=""
CANVAS_TOKEN_SRC=""

# ---- Python 解析：python3 → python → py -3（Windows 兼容，W2）----
# 用法：$PY 调用时**不要加引号**（"py -3" 需要拆成两个词）
if [ -z "${PY:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
    PY=python
  elif command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    PY="py -3"
  fi
fi
[ -n "$PY" ] || die "没找到 Python 3 —— 试过 python3 / python / py -3 三个名字都不在 PATH 里。装好 Python 3.8+ 后重试。"

warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

pretty() {
  # 从 stdin 读，避免把大响应塞进 shell 参数（多页合并后可能几百 KB）
  $PY -m json.tool 2>/dev/null || cat
}

load() {
  if [ -n "${CANVAS_BASE_URL:-}" ]; then
    CANVAS_BASE_SRC="环境变量"
  else
    CANVAS_BASE_SRC=""
    if [ -f "$CONFIG" ]; then
      CANVAS_BASE_URL="$($PY - "$CONFIG" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(((d.get('canvas') or {}).get('baseUrl') or '').strip())
except Exception:
    print('')
PY
)"
      [ -n "$CANVAS_BASE_URL" ] && CANVAS_BASE_SRC="配置文件"
    fi
  fi
  CANVAS_BASE_URL="${CANVAS_BASE_URL:-}"

  if [ -n "${CANVAS_TOKEN:-}" ]; then
    CANVAS_TOKEN_SRC="环境变量"
  else
    CANVAS_TOKEN_SRC=""
    if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
      CANVAS_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
      [ -n "$CANVAS_TOKEN" ] && CANVAS_TOKEN_SRC="token 文件"
    fi
  fi
  CANVAS_TOKEN="${CANVAS_TOKEN:-}"
}

normalize_base() {
  local b="$1"
  b="${b%/}"
  case "$b" in
    */api/v1) b="${b%/api/v1}" ;;
    */api)    b="${b%/api}" ;;
  esac
  printf '%s' "$b"
}

get() {
  load
  [ -n "$CANVAS_BASE_URL" ] || die "还没配置 Canvas 网址。见 references/canvas-api.md 的接入步骤。"
  [ -n "$CANVAS_TOKEN" ]    || die "没找到 Canvas token（$TOKEN_FILE 不存在或为空）。"

  local base path="$1"; shift
  base="$(normalize_base "$CANVAS_BASE_URL")"
  local first_url="$base/api/v1$path"

  # 分页：Canvas 单页最多 100 条，超出部分在响应头 Link: <...>; rel="next" 里。
  # 不跟随的话，大课（文件/作业 > 100）会被**静默截断**——
  # 上次快照全、这次只剩第一页，diff 就会把第 101 个起的课件全报成「被删除」。
  local tmp status rc=0
  tmp="$(mktemp -d)"

  local page_url="$first_url" pages=0 hdr outp
  while [ -n "$page_url" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt 25 ]; then
      warn "分页超过 25 页，停止翻页 —— 结果可能不全，稍后重跑可续"
      break
    fi
    hdr="${tmp}/hdr"
    outp="${tmp}/page${pages}"
    rc=0
    status="$(curl -sS -o "$outp" -D "$hdr" -w '%{http_code}' -X GET \
          -H "Authorization: Bearer $CANVAS_TOKEN" \
          -H "Accept: application/json" \
          "$@" "$page_url")" || rc=$?
    if [ "$rc" != 0 ]; then
      rm -rf "$tmp"
      die "请求发不出去 —— 检查网址能否访问：$base"
    fi
    [ "$status" = "200" ] && { page_url="$(next_link "$hdr")"; continue; }

    # 非 200：按老规矩处理（翻页只发生在 200 的路上）
    body="$(cat "$outp" 2>/dev/null || true)"
    rm -rf "$tmp"
    case "$status" in
      401) die "401 未授权 —— token 无效或已过期，请重新生成一个（见 references/canvas-api.md）。" ;;
      403) warn "403 无权限。学生账号读文件列表被拒是常见情况（取决于学校设置），不代表 token 坏了。"; printf '%s' "$body" | pretty ;;
      404) die "404 资源不存在 —— 检查 course_id 是否正确。" ;;
      429) die "429 被限流 —— 等 30 秒到 1 分钟再试，或缩小查询范围。" ;;
      *)   warn "HTTP $status"; printf '%s' "$body" | pretty ;;
    esac
    return 0
  done

  if [ "$pages" -eq 1 ]; then
    cat "${tmp}/page1" | pretty
  else
    if $PY - "$tmp" "${tmp}/merged" <<'PY' 2>/dev/null
import glob, json, sys
pages = sorted(glob.glob(sys.argv[1] + "/page*"))
merged = []
for p in pages:
    d = json.load(open(p, encoding="utf-8"))
    if not isinstance(d, list):        # 非数组端点不合并，原样给第一页
        open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False))
        raise SystemExit(0)
    merged.extend(d)
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(merged, ensure_ascii=False))
PY
    then cat "${tmp}/merged" | pretty
    else cat "${tmp}/page1" | pretty
    fi
  fi
  rm -rf "$tmp"
}

next_link() {
  # 从响应头里取 Link: <...>; rel="next" 的 URL（没有就输出空）
  $PY - "$1" <<'PY' 2>/dev/null || true
import re, sys
try:
    h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    raise SystemExit
m = re.search(r'(?mi)^link:\s*(.*)', h)
if m:
    for part in m.group(1).split(','):
        mm = re.search(r'<([^>]*)>\s*;\s*rel="?next"?', part)
        if mm:
            print(mm.group(1))
            break
PY
}

get_soft() {
  # 同 get，但失败返回 1 而不 die —— 用于「多个候选路径，取第一个能用的」。
  # 仍然只走 get，所以只读保证不受影响。
  local out rc=0
  out="$(get "$@" 2>/dev/null)" || rc=$?
  [ "$rc" = 0 ] || return 1
  printf '%s\n' "$out"
}

cmd_doctor() {
  # 退出码是这条命令的意义所在：
  #   0 = 真的连上了（200）
  #   1 = 没连上 —— 凭据不全、网址不通、token 无效、被拒
  # 「没连上」必须是非 0：否则会被读成「安装完成」，那正是我们要避免的假绿灯。
  load
  echo "== Canvas 只读客户端自检 =="
  echo
  echo "凭据"
  if [ -n "$CANVAS_BASE_URL" ]; then
    echo "  网址   : $CANVAS_BASE_URL  （来自${CANVAS_BASE_SRC}）"
  elif [ -f "$CONFIG" ]; then
    echo "  配置   : $CONFIG"
    echo "  网址   : (空)  <- 还没填"
  else
    echo "  配置   : 不存在  <- 还没接入"
  fi

  if [ -n "$CANVAS_TOKEN" ]; then
    if [ "$CANVAS_TOKEN_SRC" = "环境变量" ]; then
      echo "  Token  : 已就位  （来自环境变量，本次有效）"
    else
      local perm
      perm="$(stat -f '%Lp' "$TOKEN_FILE" 2>/dev/null || stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
      printf '  Token  : 已就位  （来自 token 文件，权限 %s）' "$perm"
      [ "$perm" = "600" ] && echo || echo "  <- 建议 chmod 600 $TOKEN_FILE"
    fi
  else
    echo "  Token  : 不存在  <- 还没接入"
  fi

  echo
  echo "连通性"
  if [ -z "$CANVAS_BASE_URL" ] || [ -z "$CANVAS_TOKEN" ]; then
    echo "  ✗ 没验成：凭据不全，无法确认能否连上。"
    echo "    两条出路：① 按 SKILL.md「安装引导 ②」把 token 和网址配好，再跑一次；"
    echo "              ② 拿不到 token 就走「手动流派」，自己下载课件——功能照常，只是少了自动取数。"
    return 1
  fi

  local base tmp status rc=0
  base="$(normalize_base "$CANVAS_BASE_URL")"
  tmp="$(mktemp)"
  status="$(curl -sS -o "$tmp" -w '%{http_code}' -X GET \
        -H "Authorization: Bearer $CANVAS_TOKEN" \
        -H "Accept: application/json" \
        "$base/api/v1/users/self")" || rc=$?
  echo "  GET $base/api/v1/users/self -> HTTP ${status:-000}"
  local ok=0
  if [ "$rc" != 0 ]; then
    echo "  ✗ 请求发不出去 —— 网址是否正确、网络是否可达？"
    ok=1
  else
    case "$status" in
      200) $PY - "$tmp" <<'PY' 2>/dev/null || cat "$tmp"
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  ✓ 已连上：{d.get('name','?')}（用户 id {d.get('id','?')}）")
PY
        ;;
      401) echo "  ✗ token 无效或已过期 —— 重新生成一个"; ok=1 ;;
      403) echo "  ✗ 无权限 —— 学校可能限制了 API 访问，走手动流派"; ok=1 ;;
      *)   echo "  ✗ 非预期响应（HTTP ${status:-000}）"; cat "$tmp"; ok=1 ;;
    esac
  fi
  rm -f "$tmp"
  if [ "$ok" != 0 ]; then
    echo
    echo "  → 自检未通过。修好接入再继续；或改走手动流派（自己下课件，其余照常）。"
  fi
  return "$ok"
}

cmd_self()          { get "/users/self"; }
cmd_courses()       { get "/courses?enrollment_state=active&per_page=100"; }
cmd_assignments()   { [ $# -ge 1 ] || die "用法: canvas.sh assignments <course_id>"; get "/courses/$1/assignments?per_page=100&order_by=due_at&include%5B%5D=submission"; }
cmd_syllabus()      { [ $# -ge 1 ] || die "用法: canvas.sh syllabus <course_id>";    get "/courses/$1?include%5B%5D=syllabus"; }
cmd_modules()       { [ $# -ge 1 ] || die "用法: canvas.sh modules <course_id>";     get "/courses/$1/modules?include%5B%5D=items&per_page=100"; }
cmd_announcements() {
  # Canvas 的公告有两个等价入口，不同学校/版本可用性不一样，按顺序试。
  # 用 get_soft 容错：万一两个都读不到，返回空表而不是让整条巡检链路崩掉。
  [ $# -ge 1 ] || die "用法: canvas.sh announcements <course_id>"
  get_soft "/courses/$1/discussion_topics?only_announcements=true&per_page=50" \
    || get_soft "/courses/$1/announcements?per_page=50" \
    || { warn "读不到公告（两个入口都失败）—— 可能学校限制了该接口。"; printf '[]\n'; }
}
cmd_files()         { [ $# -ge 1 ] || die "用法: canvas.sh files <course_id>";       get "/courses/$1/files?per_page=100"; }
cmd_page()          { [ $# -ge 2 ] || die "用法: canvas.sh page <course_id> <page_url>"; get "/courses/$1/pages/$2"; }
cmd_raw()           { [ $# -ge 1 ] || die "用法: canvas.sh raw <path>";              get "$1"; }

cmd_download() {
  [ $# -ge 2 ] || die "用法: canvas.sh download <url> <out_path>"
  local url="$1" out="$2" rc=0
  mkdir -p "$(dirname "$out")"
  # Canvas 的文件 URL 是预签名地址，不需要（也不应该）携带 Bearer 头
  curl -sSL -o "$out" "$url" || rc=$?
  [ "$rc" = 0 ] || die "下载失败。检查 URL 是否有效、是否已过期（预签名 URL 有时效）。"
  if [ -s "$out" ]; then
    printf '已下载: %s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
  else
    rm -f "$out"
    die "下载内容为空 —— URL 可能已过期，重新跑 canvas.sh files <course_id> 取一个新的。"
  fi
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in
    doctor)        cmd_doctor "$@" ;;
    self)          cmd_self "$@" ;;
    courses)       cmd_courses "$@" ;;
    assignments)   cmd_assignments "$@" ;;
    syllabus)      cmd_syllabus "$@" ;;
    modules)       cmd_modules "$@" ;;
    announcements) cmd_announcements "$@" ;;
    files)         cmd_files "$@" ;;
    page)          cmd_page "$@" ;;
    raw)           cmd_raw "$@" ;;
    download)      cmd_download "$@" ;;
    -h|--help|help) usage ;;
    *) die "未知命令：${cmd}。跑 canvas.sh help 看用法。" ;;
  esac
}

main "$@"
