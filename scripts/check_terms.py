#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_terms.py — 术语纪律检查器（硬红线 ⑤ 的机械保障）

硬红线 ⑤：英文产物里，凡课程材料出现过的术语，必须用材料里的原词，不得替换同义词
（材料写 `adolescent-limited`，就不能写 `youth-restricted`）。目的是让英文输出与课堂
材料一致，便于英文考试作答。

这条规则原先只写在 SKILL.md 里，靠 Agent 自觉 —— 那跟没有一样。本脚本把它变成可验的事。

三种模式：
  --check <文档>   核验一份产物：术语用的是不是原词                （默认模式）
  --audit          核验术语表本身：库里的「原词」在课件/转写里找得到吗
  --lint           体检术语表格式（缺字段、重复、avoid 写法不对）

判定分两级，**故意不一样重**：

  ✗ 错误   命中 `avoid` 表 —— 库里明确登记过「不许这么写」，是硬证据，拦交付
  ! 疑似   写法与库内原词近似但不等（编辑距离 ≤2）—— 可能是拼写漂移，
           也可能只是长得像的无关词。**必须人看一眼，所以不拦交付**

为什么「疑似」不直接判错：它会有误报。一个会误报的检查器如果拦交付，使用者很快
就会学会绕过它 —— 那就等于没有检查器。宁可它响得多、人来判，也不要它静默放行。

用法：
  python3 check_terms.py --library <库> --course <课程代码> <文档>...
  python3 check_terms.py <文档> [更多文档...]        # 库读 study-coach.json
  python3 check_terms.py --audit --library <库>      # 术语表 vs 课件/转写原文
  python3 check_terms.py --lint  --library <库>      # 只体检术语表
  python3 check_terms.py --json <文档>

术语表格式（<库>/quiz/terms.json）：

  {
    "terms": {
      "<课程代码>": [
        { "en": "thick description", "zh": "厚描",
          "avoid": ["dense description", "thick depiction"] }   ← avoid 可选
      ]
    }
  }

`avoid` 填「这门课不许用的说法」。它不会自己长出来 —— 每次老师/助教纠正过你的用词、
或你发现材料里另有一种写法，就登记进来。**没有 avoid，这个检查器就只剩拼写漂移可查**，
边界会在报告里如实说明。

退出码：0 = 无错误；1 = 有错误；2 = 用法错误；3 = 术语表不可用
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_CONFIG = Path(os.environ.get("WORKBUDDY_HOME", str(Path.home() / ".workbuddy"))).expanduser() / "study-coach.json"

# 近似匹配的下限。太短的词做编辑距离会被误报淹没（如 norms / forms / norns）。
FUZZY_MIN_LEN = 6          # 6~7 字符只认距离 1；≥8 字符认距离 2
FUZZY_STRICT_LEN = 8
MAX_FLAGS_PER_TERM = 3     # 同一个原词的疑似写法最多报几条
MAX_FLAGS_TOTAL = 40

# 归一化时丢弃的字符（保留 a-z0-9 与撇号），连字符统一变空格
NORM_DROP_RE = re.compile(r"[^a-z0-9' ]+")
TOKEN_RE = re.compile(r"[a-z0-9']+")

# 组合 / 对照 标签（如 "intervention / prevention"、"manslaughter vs murder"），
# 这类条目本来就不是课件上的一句原文，审计时单独归类
LABEL_HINT_RE = re.compile(r"\s(?:vs|versus)\s|\(|\)")


# ------------------------------------------------------------------ 工具
def load_library(explicit=None):
    """返回 (库路径, 来源说明)。库路径不存在则返回 (None, 原因)。"""
    if explicit:
        p = Path(explicit).expanduser()
        return (p, "--library 指定") if p.is_dir() else (None, f"目录不存在：{p}")
    if DEFAULT_CONFIG.is_file():
        try:
            cfg = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))
        except Exception as e:
            return None, f"{DEFAULT_CONFIG} 不是合法 JSON：{e}"
        lib = (cfg.get("library") or "").strip()
        if lib:
            p = Path(lib).expanduser()
            return (p, str(DEFAULT_CONFIG)) if p.is_dir() else (None, f"配置里的库目录不存在：{p}")
    return None, f"找不到库目录（配置 {DEFAULT_CONFIG} 缺失，也没给 --library）"


def norm(s):
    """归一化：小写、连字符/破折号→空格、丢弃标点、压空格。

    连字符差异在这里被抹平（`adolescent-limited` == `adolescent limited`），
    因为那不是「换词」，只是书写习惯。真·换词检测交给 avoid 表与近似匹配。
    """
    s = s.replace("\u2019", "'").replace("\u2013", "-").replace("\u2014", "-")
    s = s.lower().replace("-", " ")
    s = NORM_DROP_RE.sub(" ", s)
    return re.sub(r"\s+", " ", s).strip()


def units_of(entry):
    """把一条术语拆成可比对的单元。

    `ontology / epistemology / methodology` → 三个单元
    `social information processing (SIP)`   → 一个单元（丢掉括注）
    返回 [(单元归一化串, 是否组合标签)]
    """
    raw = (entry.get("en") or "").strip()
    if not raw:
        return []
    is_label = bool(LABEL_HINT_RE.search(raw))
    out = []
    for part in re.split(r"\s*/\s*", raw):
        part = re.sub(r"\([^)]*\)", " ", part)          # 丢括注，只留正词
        n = norm(part)
        if n:
            out.append((n, is_label))
    return out


def word_boundary_hit(hay_norm, needle_norm):
    """needle 是否作为一个完整词组出现在 hay 里（空格已是词边界）。"""
    if not needle_norm:
        return False
    pat = r"(?<![a-z0-9])" + re.escape(needle_norm) + r"(?![a-z0-9])"
    return re.search(pat, hay_norm) is not None


def lev(a, b, cutoff):
    """编辑距离，超过 cutoff 提前返回 cutoff+1（只用来做「像不像」的判断）。"""
    if abs(len(a) - len(b)) > cutoff:
        return cutoff + 1
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        best = cur[0]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
            if cur[j] < best:
                best = cur[j]
        if best > cutoff:
            return cutoff + 1
        prev = cur
    return prev[-1]


def ngrams(tokens, k):
    return [" ".join(tokens[i:i + k]) for i in range(len(tokens) - k + 1)]


# ------------------------------------------------------------------ 术语表
def load_terms(lib, course=None):
    """返回 (terms_dict, meta, 错误信息)。terms_dict: {课程代码: [条目]}"""
    path = lib / "quiz" / "terms.json"
    if not path.is_file():
        return None, None, f"找不到术语表：{path}（先积累术语，再谈术语纪律）"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        return None, None, f"术语表不是合法 JSON：{e}"

    terms = data.get("terms")
    if not isinstance(terms, dict):
        return None, None, "术语表缺 `terms` 对象（格式见脚本 --help）"

    if course:
        code = course.upper()
        if code not in terms:
            return None, None, f"术语表里没有 {code}。可选：{', '.join(sorted(terms))}"
        terms = {code: terms[code]}

    n = sum(len(v) for v in terms.values() if isinstance(v, list))
    if n == 0:
        return None, None, ("术语表存在但一条术语都没有 —— **无从校验**。"
                            "先把课件里的术语登记进 quiz/terms.json")
    meta = {"path": str(path), "total": n,
            "source": data.get("source") or "未标注",
            "extractedAt": data.get("extractedAt") or "未标注"}
    return terms, meta, None


def lint_terms(terms):
    """体检术语表自身。返回 (errors, warns, infos)。"""
    errors, warns, infos = [], [], []

    # 先收齐所有原词，才能判「avoid 项是不是撞了别的原词」
    canonical = {}
    for course in sorted(terms):
        for i, it in enumerate(terms[course] or []):
            if isinstance(it, dict) and (it.get("en") or "").strip():
                canonical.setdefault(norm(it["en"]), f"{course}[{i}]")

    for course in sorted(terms):
        items = terms[course]
        if not isinstance(items, list):
            errors.append(f"{course} 不是数组")
            continue
        seen = {}
        for i, it in enumerate(items):
            if not isinstance(it, dict):
                errors.append(f"{course}[{i}] 不是对象")
                continue
            en = (it.get("en") or "").strip()
            zh = (it.get("zh") or "").strip()
            if not en:
                errors.append(f"{course}[{i}] 缺 `en` 字段")
            if not zh:
                warns.append(f"{course}[{i}]（{en or '空'}）缺 `zh` —— 中英双版产物会少一半")
            if not en:
                continue

            key = norm(en)
            if key in seen:
                warns.append(f"{course} 重复条目：`{en}`（与第 {seen[key] + 1} 条重复）")
            else:
                seen[key] = i

            bad_list = it.get("avoid")
            if bad_list is not None and not isinstance(bad_list, list):
                errors.append(f"{course} 的 `{en}`：avoid 应该是数组")
                continue
            for bad in bad_list or []:
                if not isinstance(bad, str) or not bad.strip():
                    errors.append(f"{course} 的 `{en}`：avoid 里有空的或用错的写法")
                    continue
                nb = norm(bad)
                if nb == key:
                    warns.append(f"{course} 的 `{en}`：avoid 里写了它自己")
                elif nb in canonical:
                    errors.append(f"{course} 的 `{en}`：avoid 项 `{bad}` 同时是"
                                  f"{canonical[nb]} 的原词 —— 自相矛盾，检查器会来回报")
            if bad_list is None:
                infos.append(f"{course} 的 `{en}` 没有 avoid（可选，但填了才拦得住同义替换）")
    return errors, warns, infos


def collect_avoid(terms):
    """{归一化 avoid 写法: (课程, 原词)}"""
    table = {}
    for course in sorted(terms):
        for it in terms[course] or []:
            if not isinstance(it, dict):
                continue
            en = (it.get("en") or "").strip()
            for bad in it.get("avoid") or []:
                if isinstance(bad, str) and bad.strip():
                    table.setdefault(norm(bad), (course, en))
    return table


def collect_all_units(terms):
    """库里全部原词单元（跨课程）——用来避免把「另一个术语的原词」误报成近似漂移。"""
    allu = set()
    for course in terms:
        for it in terms[course] or []:
            if isinstance(it, dict):
                for u, _ in units_of(it):
                    allu.add(u)
    return allu


# ------------------------------------------------------------------ 核验产物
def check_doc(path, terms, use_fuzzy=True):
    """核验一份文档。返回结果字典。"""
    res = {"file": str(path), "ok": True, "errors": [], "suspects": [],
           "used": [], "unused": [], "notes": []}

    p = Path(path)
    if not p.is_file():
        res["ok"] = False
        res["errors"].append(f"文件不存在：{path}")
        return res

    try:
        raw = p.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        res["ok"] = False
        res["errors"].append(f"读不了：{e}")
        return res

    doc_norm = norm(raw)
    tokens = TOKEN_RE.findall(doc_norm)
    avoid = collect_avoid(terms)
    all_units = collect_all_units(terms)

    # ① avoid 命中：库里登记过「不许这么写」
    seen_avoid = set()
    for bad_norm, (course, en) in sorted(avoid.items()):
        if bad_norm in seen_avoid:
            continue
        if word_boundary_hit(doc_norm, bad_norm):
            seen_avoid.add(bad_norm)
            res["errors"].append(
                f"[{course}] 用了登记的禁用写法 `{bad_norm}`，该课原词是 `{en}`")

    # ② 逐条术语：用了原词 / 没用到但在文档里找到近似写法 / 完全没露面
    flags = 0
    for course in sorted(terms):
        for it in terms[course] or []:
            if not isinstance(it, dict):
                continue
            en = (it.get("en") or "").strip()
            units = units_of(it)
            if any(word_boundary_hit(doc_norm, u) for u, _ in units):
                res["used"].append((course, en))
                continue

            hit, hit_label = None, False
            if use_fuzzy and flags < MAX_FLAGS_TOTAL:
                for unit, is_label in units:
                    if len(unit) < FUZZY_MIN_LEN:
                        continue
                    got = fuzzy_hit(unit, tokens, all_units)
                    if got:
                        hit, hit_label = got, is_label
                        break
            if hit:
                flags += 1
                res["suspects"].append(
                    (course, f"文档里写的是 `{hit}`，该课原词是 `{en}`",
                     "（该条目像组合/对照标签，参考价值有限）" if hit_label else ""))
            else:
                res["unused"].append((course, en))

    res["ok"] = not res["errors"]
    res["notes"].append(f"命中库内原词 {len(res['used'])} 处，未出现 {len(res['unused'])} 条")
    if not avoid:
        res["notes"].append("术语表里没有任何 `avoid` 登记 —— 同义替换查不出来，只查了拼写漂移")
    if not use_fuzzy:
        res["notes"].append("已关闭近似匹配（--no-fuzzy）")
    return res


def fuzzy_hit(unit, tokens, all_units):
    """在文档里找「跟原词很像但不是原词」的写法。找不到返回 None。"""
    k = len(unit.split())
    if k == 0:
        return None
    cutoff = 1 if len(unit) < FUZZY_STRICT_LEN else 2
    head = unit[0]
    best = None
    for g in ngrams(tokens, k):
        if g == unit or g in all_units:
            continue                       # 是原词、或本身是另一个术语 → 不算漂移
        if abs(len(g) - len(unit)) > cutoff or g[:1] != head:
            continue
        d = lev(unit, g, cutoff)
        if d <= cutoff:
            if best is None or d < best[0]:
                best = (d, g)
            if d == 1:
                break
    return best[1] if best else None


# ------------------------------------------------------------------ 审术语表
def audit_sources(lib):
    """把库里的课件抽取文本与课堂转写拼成一份「原文语料」。"""
    chunks = []
    scanned = []
    for sub in ("materials", "transcripts"):
        d = lib / sub
        if not d.is_dir():
            continue
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            for fn in files:
                if Path(fn).suffix.lower() not in (".txt", ".md"):
                    continue
                fp = Path(root) / fn
                try:
                    chunks.append(fp.read_text(encoding="utf-8", errors="replace"))
                    scanned.append(fp.relative_to(lib).as_posix())
                except Exception:
                    pass
    return " ".join(chunks), scanned


def audit_terms(lib, terms):
    """术语表 vs 课件/转写原文：库里的「原词」在材料里真的这么写吗。"""
    corpus, scanned = audit_sources(lib)
    out = {"scanned": scanned, "found": [], "missing": [],
           "missing_label": [], "no_corpus": not corpus}
    if not corpus:
        return out
    corpus_norm = norm(corpus)
    for course in sorted(terms):
        for it in terms[course] or []:
            if not isinstance(it, dict):
                continue
            en = (it.get("en") or "").strip()
            for unit, is_label in units_of(it):
                if word_boundary_hit(corpus_norm, unit):
                    out["found"].append((course, en, unit))
                elif is_label:
                    out["missing_label"].append((course, en))
                else:
                    out["missing"].append((course, en))
                break        # 一条术语只判一次（用第一个单元代表）
    return out


# ------------------------------------------------------------------ 主流程
def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description="术语纪律检查器",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="要核验的产物（--check 模式）")
    ap.add_argument("--library", "-l", default=None, help="库目录（默认读 study-coach.json）")
    ap.add_argument("--course", "-c", default=None, help="只核验这门课的术语")
    ap.add_argument("--audit", action="store_true", help="审术语表：原词在课件/转写里找得到吗")
    ap.add_argument("--lint", action="store_true", help="只体检术语表格式")
    ap.add_argument("--no-fuzzy", action="store_true", help="关闭近似匹配（只查 avoid 命中）")
    ap.add_argument("--json", action="store_true", help="机器可读输出")
    args = ap.parse_args(argv)

    lib, src = load_library(args.library)
    if lib is None:
        print(f"错误：{src}", file=sys.stderr)
        return 2

    terms, meta, err = load_terms(lib, args.course)
    if terms is None:
        print(f"术语表不可用：{err}", file=sys.stderr)
        return 3

    # ---- lint ----
    if args.lint:
        errors, warns, infos = lint_terms(terms)
        if args.json:
            print(json.dumps({"errors": errors, "warns": warns, "infos": infos},
                             ensure_ascii=False, indent=2))
            return 1 if errors else 0
        print(f"术语表体检 · {meta['path']}（{meta['total']} 条，源：{meta['source']}）\n")
        for e in errors:
            print(f"  ✗ {e}")
        for w in warns:
            print(f"  ! {w}")
        if not errors and not warns:
            print("  ✓ 格式没问题")
        if infos and not errors:
            print(f"  · {len(infos)} 条没填 avoid（可选）")
        print(f"\n  错误 {len(errors)} ／ 提醒 {len(warns)}")
        return 1 if errors else 0

    # ---- audit ----
    if args.audit:
        a = audit_terms(lib, terms)
        if args.json:
            print(json.dumps(a, ensure_ascii=False, indent=2))
            return 0
        if a["no_corpus"]:
            print("审不了：materials/ 与 transcripts/ 里没有可读的文本。\n"
                  "  这个模式靠课件抽取文本与课堂转写做比对，库里没有文本就无从下手。\n"
                  "  （这不是故障 —— 手动流派的库也可能确实还没归档文本。）")
            return 3
        print(f"术语表审计 · 对 {len(a['scanned'])} 份原文语料\n")
        print(f"  ✓ 能在材料原文里找到：{len(a['found'])} 条")
        if a["missing"]:
            print(f"\n  ! 找不到原词的 {len(a['missing'])} 条 —— 可能是记录时写岔了，"
                  f"也可能是该讲课件还没归档：")
            for course, en in a["missing"]:
                print(f"      [{course}] {en}")
        if a["missing_label"]:
            print(f"\n  · 组合/对照标签 {len(a['missing_label'])} 条"
                  f"（如 `a / b`、`x vs y`，本就不是课件原句，不用当真）：")
            for course, en in a["missing_label"]:
                print(f"      [{course}] {en}")
        print("\n  说明：找不到 ≠ 错了。它只是提示「这条原词缺少材料出处」，"
              "该人工确认，或者补上对应课件。")
        return 0

    # ---- check（默认）----
    if not args.files:
        print(__doc__)
        return 2

    results = [check_doc(f, terms, use_fuzzy=not args.no_fuzzy) for f in args.files]

    if args.json:
        print(json.dumps({"meta": meta, "results": results}, ensure_ascii=False, indent=2))
        return 1 if any(not r["ok"] for r in results) else 0

    for r in results:
        mark = "✅" if r["ok"] else "❌"
        print(f"{mark} {os.path.basename(r['file'])}")
        for n in r["notes"]:
            print(f"   · {n}")
        for e in r["errors"]:
            print(f"   ✗ {e}")
        for course, msg, extra in r["suspects"]:
            print(f"   ! 疑似  [{course}] {msg} {extra}".rstrip())
    bad = sum(1 for r in results if not r["ok"])
    sus = sum(len(r["suspects"]) for r in results)
    if sus:
        print(f"\n   疑似 {sus} 处 —— 人看一眼再决定。这类判断会有误报，所以不拦交付。")
    print(f"\n{len(results)} 个文件，{len(results) - bad} 无错误，{bad} 有错误")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
