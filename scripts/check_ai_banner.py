#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI 横幅合规检查器 —— 校验「禁 AI 课 / 政策不明」的产物有没有挂上横幅。

为什么需要它：硬红线 ③ 的唯一约束形式就是横幅。如果横幅只靠 Agent 自觉加，
这条红线跟「靠提示词保证只读」一样脆。规则能被脚本验，才算真的立住。

用法：
  check_ai_banner.py <文件> [更多文件...]
  check_ai_banner.py --expect ban <文件>          # 全面禁 AI，必须挂「禁止」版横幅
  check_ai_banner.py --expect partial <文件>      # 部分禁 AI / 明确不可代写，必须挂「不可代写」版
  check_ai_banner.py --expect unconfirmed <文件>  # 政策未确认，必须挂「未确认」版
  check_ai_banner.py --expect none <文件>         # 允许课，不该挂禁用横幅
  check_ai_banner.py --json <文件>                # 机器可读输出
  check_ai_banner.py --scan <目录>                # 批量扫目录下所有 .md 的横幅状态（不判定合规）

退出码：0 = 全部合规；1 = 有不合规项；2 = 用法错误
"""

import sys
import os
import re
import json

# ---- 跨平台兜底（Windows）----
# 中文 Windows 控制台默认 GBK：不重设的话打印 ✓ ✗ ⚠️ 直接 UnicodeEncodeError。
# 经 bash 入口调用时 _common.sh 已设 PYTHONUTF8；这里兜住「agent 在 PowerShell 里直接 python xxx.py」的情况。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def _win_path(s):
    """Git Bash 写进配置的 /c/Users/... 在原生 Windows Python 里不是合法路径，转成 C:/Users/...。"""
    s = str(s).strip()
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])(/.*)?$", s)
        if m:
            return f"{m.group(1).upper()}:{m.group(2) or '/'}"
    return s

BAN_MARK = "本课禁止 AI 代写"
PARTIAL_MARK = "本课规定不可 AI 代写"
UNCONFIRMED_MARK = "政策未确认"

REQUIRED_FIELDS = [
    ("课程：", "缺少「课程：」行"),
    ("政策依据：", "缺少「政策依据：」行"),
    ("由 AI 生成", "缺少「由 AI 生成」声明"),
]

# 后果表述：至少命中一个，否则横幅等于没写清风险
CONSEQUENCE_HINTS = ["检测", "检出", "抄袭", "后果", "处理"]

FOLD_PATTERNS = [
    (re.compile(r"<details", re.I), "横幅被塞进 <details> 折叠块"),
    (re.compile(r"<sub>|font-size\s*:\s*(?:small|x-small|\d+px)", re.I), "横幅被降格成小字"),
    (re.compile(r"<!--.*?-->", re.S), None),  # 占位，注释单独处理
]

HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s")
QUOTE_RE = re.compile(r"^\s{0,3}>\s?")


def strip_frontmatter(lines):
    """跳过 YAML frontmatter（--- 包裹）与 BOM，返回 (起算行号, 剩余行)。"""
    start = 0
    if lines and lines[0].lstrip("\ufeff").strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                start = i + 1
                break
    return start, lines[start:]


def find_banner_block(lines, offset):
    """找第一个非空内容块；返回 (起始行号, 引用块行列表, 是否引用块)。"""
    idx = None
    for i, ln in enumerate(lines):
        if ln.strip():
            idx = i
            break
    if idx is None:
        return None, [], False

    block = []
    is_quote = bool(QUOTE_RE.match(lines[idx]))
    if is_quote:
        j = idx
        while j < len(lines) and (QUOTE_RE.match(lines[j]) or not lines[j].strip()):
            if lines[j].strip() and not QUOTE_RE.match(lines[j]):
                break
            block.append(lines[j])
            j += 1
    else:
        block.append(lines[idx])
    return offset + idx + 1, block, is_quote


def find_details_range(text):
    """返回所有 <details>...</details> 覆盖的字符区间。"""
    spans = []
    for m in re.finditer(r"<details.*?</details>", text, re.I | re.S):
        spans.append((m.start(), m.end()))
    return spans


def check_file(path, expect=None):
    problems = []
    notes = []

    if not os.path.isfile(path):
        return {"file": path, "ok": False, "type": None,
                "problems": [f"文件不存在：{path}"], "notes": []}

    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()

    lines = raw.split("\n")
    offset, body = strip_frontmatter(lines)
    banner_lineno, banner_lines, is_quote = find_banner_block(body, offset)
    banner_text = "\n".join(banner_lines)

    # —— 类型判定 ——
    if BAN_MARK in banner_text:
        btype = "ban"
    elif PARTIAL_MARK in banner_text:
        btype = "partial"
    elif UNCONFIRMED_MARK in banner_text:
        btype = "unconfirmed"
    else:
        btype = None

    # 全文里是否有横幅（用于"放错位置"的诊断）
    anywhere = any(m in raw for m in (BAN_MARK, PARTIAL_MARK, UNCONFIRMED_MARK))

    # —— B1 横幅存在 ——
    if btype is None:
        if anywhere:
            problems.append(
                "B1 横幅存在，但**不是文件第一个内容块** —— 前面还有别的内容"
                "（横幅必须在标题/封面之前，不能放正文里或末尾）")
            # 追加诊断：是不是被折叠了
            for mark in (BAN_MARK, PARTIAL_MARK, UNCONFIRMED_MARK):
                pos = raw.find(mark)
                if pos < 0:
                    continue
                for s, e in find_details_range(raw):
                    if s <= pos < e:
                        problems.append("B3 横幅落在 <details> 折叠块内 —— 折叠即等于没写")
                        break
                else:
                    continue
                break
        else:
            problems.append("B1 找不到任何 AI 横幅（禁 AI 课/政策不明的产物必须挂横幅）")

    # —— B2 形式：必须是引用块 ——
    if btype and not is_quote:
        problems.append("B2 横幅不是 Markdown 引用块（应以 `>` 开头），可能被写成了普通正文或标题")

    # —— B3 未折叠 ——
    if btype and banner_lineno is not None:
        for pat, msg in FOLD_PATTERNS:
            if msg and pat.search(banner_text):
                problems.append(f"B3 {msg}")
        # <details> 覆盖范围检查：横幅整体落在某个 details 区间内
        head = raw.find(banner_text[:20]) if banner_text else -1
        if head >= 0:
            for s, e in find_details_range(raw):
                if s <= head < e:
                    problems.append("B3 横幅落在 <details> 折叠块内")
                    break

    # —— B4-B8 必备要素 ——
    if btype:
        if "⚠️" not in banner_text and "⚠" not in banner_text:
            problems.append("B4 横幅缺少警示符号 ⚠️")
        for needle, msg in REQUIRED_FIELDS:
            if needle not in banner_text:
                problems.append(f"B5 {msg}")
        if not any(h in banner_text for h in CONSEQUENCE_HINTS):
            problems.append(
                "B6 横幅没有写清后果（应出现「检测 / 检出 / 抄袭 / 后果」之一）")
        if btype in ("ban", "partial"):
            # 政策依据不能留空占位
            m = re.search(r"政策依据：\s*`?\s*`?\s*$", banner_text, re.M)
            if m:
                problems.append("B7 横幅的「政策依据」是空的")

    # —— B9 期望类型比对 ——
    if expect:
        if expect == "none" and btype is not None:
            problems.append(f"B9 该课 AI 政策为「允许」，不该挂 {btype} 版横幅")
        elif expect in ("ban", "partial", "unconfirmed") and btype != expect:
            problems.append(
                f"B9 期望「{LABEL[expect]}」横幅，实际为：{LABEL.get(btype, '无')}")

    # —— B10 顶部整洁：横幅前不应有实质内容 ——
    if btype and banner_lineno is not None:
        head_lines = [l for l in lines[:banner_lineno - 1] if l.strip() and l.strip() != "---"]
        if head_lines:
            problems.append(
                f"B10 横幅前还有 {len(head_lines)} 行内容，最顶部不干净："
                f"「{head_lines[0].strip()[:40]}」")

    if btype and banner_lines:
        notes.append(f"横幅起始于第 {banner_lineno} 行，共 {len(banner_lines)} 行")
    elif not btype:
        notes.append("文件第一个内容块不是 AI 横幅")
    notes.append(f"判定类型：{LABEL.get(btype, '无横幅')}")

    return {"file": path, "ok": not problems, "type": btype,
            "problems": problems, "notes": notes}


LABEL = {"ban": "全面禁 AI 版", "partial": "部分禁 AI 版",
         "unconfirmed": "政策未确认版", "none": "无横幅"}


def main(argv):
    expect = None
    as_json = False
    scan_dirs = []
    files = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--expect":
            i += 1
            if i >= len(argv) or argv[i] not in ("ban", "partial", "unconfirmed", "none"):
                print("错误：--expect 只能是 ban / partial / unconfirmed / none", file=sys.stderr)
                return 2
            expect = argv[i]
        elif a == "--scan":
            i += 1
            if i >= len(argv):
                print("错误：--scan 后面要给一个目录", file=sys.stderr)
                return 2
            scan_dirs.append(argv[i])
        elif a == "--json":
            as_json = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            files.append(a)
        i += 1

    # ---- 批量扫描模式：只报状态，不判合规（判断"该不该挂"需要人） ----
    if scan_dirs:
        found = []
        for d in scan_dirs:
            if not os.path.isdir(d):
                print(f"错误：不是目录 -> {d}", file=sys.stderr)
                return 2
            for root, dirs, names in os.walk(d):
                dirs[:] = [x for x in dirs if not x.startswith(".")]
                for n in sorted(names):
                    if n.lower().endswith((".md", ".markdown")):
                        found.append(os.path.join(root, n))
        if not found:
            print("未找到 .md 文件。", file=sys.stderr)
            return 2

        rows = []
        for f in found:
            try:
                r = check_file(f, None)
            except Exception as e:            # 坏文件不该让整轮扫描崩掉
                rows.append((f, "error", f"读取失败：{e}"))
                continue
            # 注意：这里不能用 r["ok"] 判断——无横幅本身不是错，
            # 它只是「状态」；该不该挂要人看目录性质决定。
            rows.append((f, r["type"] or "none", ""))

        if as_json:
            print(json.dumps([{"file": f, "type": t} for f, t, _ in rows],
                             ensure_ascii=False, indent=1))
            return 0

        root_show = ", ".join(scan_dirs)
        print(f"扫描 {root_show}（{len(rows)} 个 .md）\n")
        icon = {"ban": "🟥", "partial": "🟧", "unconfirmed": "🟨",
                "none": "⬜", "error": "⚠️ "}
        label = dict(LABEL)
        label["error"] = "读取异常"
        for f, t, _ in rows:
            rel = os.path.relpath(f, os.path.commonpath(scan_dirs))
            print(f"  {icon.get(t, '?')} {label.get(t, t):<12} {rel}")
        tally = {}
        for _, t, _ in rows:
            tally[t] = tally.get(t, 0) + 1
        print("\n  " + " ／ ".join(f"{label.get(k, k)} {v}" for k, v in tally.items()))
        print("\n  ⬜ 无横幅 ≠ 不合规：复习笔记、题库、计划这类学习工具本就不该挂。")
        print("     只有「提交物形态」的产物（论文/报告正文、示范段落、翻译、习题解答）才必须挂。")
        return 0

    if not files:
        print("错误：至少要给一个文件（或用 --scan <目录>）。用 --help 看用法。", file=sys.stderr)
        return 2

    results = [check_file(f, expect) for f in files]

    if as_json:
        print(json.dumps(results, ensure_ascii=False, indent=1))
    else:
        for r in results:
            mark = "✅" if r["ok"] else "❌"
            print(f"{mark} {os.path.basename(r['file'])}  [{LABEL.get(r['type'], '?')}]")
            for n in r["notes"]:
                print(f"   · {n}")
            for p in r["problems"]:
                print(f"   ✗ {p}")
        bad = sum(1 for r in results if not r["ok"])
        print(f"\n{len(results)} 个文件，{len(results) - bad} 合规，{bad} 不合规")

    return 0 if all(r["ok"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
