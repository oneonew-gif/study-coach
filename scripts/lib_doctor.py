#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lib_doctor.py — 学习库体检：检查「库」与「引擎」是否对齐

引擎会升级，库却不会自己跟着走 —— 脚本副本会过期、文档会指向删掉的旧文件、
课程索引会落后于 Canvas。这个脚本把这些漂移一次性照出来。

用法：
  python3 lib_doctor.py                      # 体检默认库（读 <WORKBUDDY_HOME>/study-coach.json，WORKBUDDY_HOME 默认 ~/.workbuddy）
  python3 lib_doctor.py --library <目录>      # 指定库
  python3 lib_doctor.py --json               # 机器可读
  python3 lib_doctor.py --only refs,coverage # 只跑指定检查项
  python3 lib_doctor.py --list               # 列出所有检查项
  python3 lib_doctor.py --deep               # 连 qwenwork-raw / materials 也扫（慢）

检查项：
  env          配置、库根目录
  term         学期标识（配置 / SYNC-BLOCK / PROGRESS 三处是否一致）
  skeleton     库骨架完整性
  engine-sync  引擎脚本 ↔ 库内副本一致性（哈希）
  engine-health 引擎自身卫生：自检覆盖、shell 变量坑、可执行位
  changelog    引擎版本号 ↔ CHANGELOG 是否同步
  refs         库内文档的脚本与路径引用（断链 / 过期别名）
  index-sync   COURSES.md 回流状态（SYNC-BLOCK vs 巡检快照 vs 库内新产物）
  coverage     课件讲次 vs 笔记讲次 覆盖率
  credentials  凭据泄漏扫描（硬红线 ②）
  banners      assignments/ 产物横幅状态汇总（硬红线 ③）
  inspection   Canvas 接入与巡检状态

退出码：0 = 无 error ｜ 1 = 有 error ｜ 2 = 库不可用
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
ENGINE_SCRIPTS = SKILL_DIR / "scripts"
SELF = Path(__file__).resolve()

# 配置/凭据路径默认在 ~/.workbuddy/，可通过 WORKBUDDY_HOME 环境变量覆盖（适配非 WorkBuddy 平台）
WORKBUDDY_HOME = Path(os.environ.get("WORKBUDDY_HOME", str(Path.home() / ".workbuddy"))).expanduser()
CONFIG = WORKBUDDY_HOME / "study-coach.json"
TOKEN_FILE = WORKBUDDY_HOME / ".canvas-token"

# ---------------------------------------------------------------- 规则表
# 引擎已废弃的旧脚本名 → 应该改用的新名字。库里任何文档出现旧名都算「过期引用」。
DEPRECATED_ALIASES = {
    "draw.js": "draw_quiz.js",
}

# 引擎脚本中「应当被复制进库」的镜像（由 init_library.sh 放置）
ENGINE_MIRRORS = {
    "draw_quiz.js": "quiz/draw_quiz.js",
}

SKELETON_DIRS = [
    "notes", "assignments", "quiz", "materials", "transcripts",
    "recordings", "plans", "training", "archive",
    "inspection/snapshots", "inspection/reports",
]

# 引擎脚本 → 负责验它的自检文件。**显式列出，不靠猜。**
# 早先的写法是「在 selftest 文件里搜脚本名」，结果「只是提到过」也算覆盖 ——
# 一个只写注释提一嘴的脚本会被判定成验过了。这种自己骗自己的检查还不如没有。
SELFTEST_COVERAGE = {
    "preflight.sh": "selftest.sh",
    "canvas.sh": "selftest_canvas_readonly.sh",
    "canvas_inspect.sh": "selftest_canvas_readonly.sh",
    "deadlines.sh": "selftest_deadlines.sh",
    "daily_digest.sh": "selftest_daily_digest.sh",
    "weekly_digest.sh": "selftest_weekly_digest.sh",
    "vocab.sh": "selftest_vocab.sh",
    "archive_term.sh": "selftest_archive_term.sh",
    "check_ai_banner.py": "selftest_ai_banner.sh",
    "check_terms.py": "selftest_terms.sh",
    "draw_quiz.js": "selftest_draw_quiz.sh",
    "init_library.sh": "selftest_lib_doctor.sh",
    "lib_doctor.py": "selftest_lib_doctor.sh",
    "package_skill.sh": "selftest_package_skill.sh",
}

SKELETON_FILES = {
    "COURSES.md": "课程索引",
    "WORKFLOWS.md": "工作流与红线",
    "course-rules.md": "各课出题规律",
    "quiz/draw_quiz.js": "抽题器（库内副本）",
    "quiz/bank.json": "题库",
    "quiz/terms.json": "术语表（硬红线 ⑤ 校验的基准）",
    "inspection/README.md": "巡检说明",
    "inspection/log.tsv": "巡检流水",
}

SECTIONS = ["env", "term", "skeleton", "engine-sync", "engine-health", "changelog",
            "refs", "index-sync", "coverage", "credentials", "banners", "inspection"]

SECTION_TITLE = {
    "env": "配置与库根目录",
    "term": "学期标识",
    "skeleton": "库骨架完整性",
    "engine-sync": "引擎 ↔ 库副本一致性",
    "engine-health": "引擎卫生（自检覆盖 / shell 坑）",
    "changelog": "引擎版本记录",
    "refs": "文档引用",
    "index-sync": "课程索引回流",
    "coverage": "笔记覆盖率",
    "credentials": "凭据泄漏扫描",
    "banners": "AI 横幅状态",
    "inspection": "Canvas 接入与巡检",
}

TEXT_EXT = {".md", ".html", ".htm", ".txt", ".json", ".tsv", ".csv",
            ".sh", ".js", ".py", ".yml", ".yaml"}

# 默认不扫的重目录（大、且是原件归档）
SKIP_DIRS = {"qwenwork-raw", "recordings", "materials", "transcripts"}

SCRIPT_REF_RE = re.compile(r"(?<![\w./-])([A-Za-z0-9_][\w.-]*\.(?:js|sh|py))(?![\w])")
PATH_REF_RE = re.compile(r"`([^`<>{}*|\s]+/[^`<>{}*|\s]+\.(?:md|json|html|tsv|js|sh|py|txt|csv))`")
MD_LINK_RE = re.compile(r"\]\((?!https?:|mailto:|#)([^)\s]+?)\)")
HTML_HREF_RE = re.compile(r'href="(?!https?:|//|#|mailto:)([^"]+)"')

# 这些文件里写的是「迁移源侧」的历史路径，不是库内路径，别拿库结构去校验
REF_PATH_EXEMPT_FILES = {"MIGRATION.md", "_migration_log.tsv"}

# 文档里故意留的占位符（给用户照抄的模板），不是断链
PLACEHOLDER_RE = re.compile(r"(?i)(x{3,}|第\s*n\s*讲|week\s*n|第\s*n\s*周|n\s*讲)")

# 「归档说明」这类行天然会提到废弃脚本名，不算过期引用
ARCHIVE_CONTEXT_RE = re.compile(r"(_archive|已归档|归档到|废弃|deprecated)", re.I)
SYNC_BLOCK_RE = re.compile(r"<!--\s*SYNC-BLOCK\s*v1\s*(\{.*?\})\s*-->", re.S)
PROGRESS_BLOCK_RE = re.compile(r"<!--\s*PROGRESS\s*v1\s*(\{.*?\})\s*-->", re.S)

CN_DIGITS = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
             "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}


def cn_num_to_int(s: str):
    """中文数字 → 整数，覆盖 一~九十九。

    早先的写法是逐字加和，「第二十讲」里 '二十' = 2 + 10 = 12 —— 错得
    恰好像个合法讲次，覆盖率判定就跟着错。十位结构必须单独处理：
    二十 = 2×10、二十一 = 2×10+1、十二 = 1×10+2、十 = 10。
    """
    if not s:
        return None
    if "十" in s:
        left, _, right = s.partition("十")
        tens = 1 if not left else CN_DIGITS.get(left)
        ones = 0 if not right else CN_DIGITS.get(right)
        if tens is None or ones is None:
            return None
        return tens * 10 + ones
    total = 0
    for ch in s:
        d = CN_DIGITS.get(ch)
        if d is None:
            return None
        total += d
    return total or None

LIGHT = {"error": "✗", "warn": "!", "info": "·", "ok": "✓"}

# shell 卫生：`$VAR` 紧跟非 ASCII 字符时，变量名会把那个字吞进去。
# 中文环境下这是高频事故（`"退出码 $rc）"` 会被解析成变量 `rc）`），
# 而且往往藏在「出错分支」里 —— 平时不报，一报就炸。
DOLLAR_CJK_RE = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")

VERSION_RE = re.compile(r"^version:\s*(.+?)\s*$", re.M)
CHANGELOG_ENTRY_RE = re.compile(r"^#{2,3}\s*\[?v?(\d+\.\d+\.\d+)\]?", re.M)


# ---------------------------------------------------------------- 工具
class Report:
    def __init__(self):
        self.items = []

    def add(self, level, section, message, hint=""):
        self.items.append({"level": level, "section": section,
                           "message": message, "hint": hint})

    def ok(self, section, message, hint=""):
        self.add("ok", section, message, hint)

    def info(self, section, message, hint=""):
        self.add("info", section, message, hint)

    def warn(self, section, message, hint=""):
        self.add("warn", section, message, hint)

    def error(self, section, message, hint=""):
        self.add("error", section, message, hint)

    def counts(self):
        c = {"error": 0, "warn": 0, "info": 0, "ok": 0}
        for it in self.items:
            c[it["level"]] += 1
        return c


def sha1(path: Path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: Path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def iter_text_files(lib: Path, deep=False):
    for root, dirs, files in os.walk(lib):
        rp = Path(root)
        rel_root = rp.relative_to(lib).parts
        if not deep and rel_root and rel_root[0] in SKIP_DIRS:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in files:
            p = rp / fn
            if p.suffix.lower() in TEXT_EXT:
                yield p


def iter_entry_files(root: Path):
    """递归列出目录下所有文件（跳过隐藏项）；root 本身是文件时只返回它。

    覆盖率扫描必须用这个而不是 iterdir()：materials/notes 按课程建了
    子目录的库，只扫顶层会把整门课的讲次全部漏判。
    """
    if root.is_file():
        yield root
        return
    for r, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in files:
            if not fn.startswith("."):
                yield Path(r) / fn


def latest_mtime(lib: Path, subdirs):
    """子目录（或单个文件）里最新的 mtime。

    参数可以是目录名也可以是**文件名**（如 course-rules.md）。
    早先一律拿去 os.walk —— 文件传进去静默得到空，course-rules.md 的
    「比索引新」信号从此永不触发，不报错，纯属白写。
    """
    newest = None
    for sub in subdirs:
        d = lib / sub
        if d.is_file():
            candidates = [d]
        elif d.is_dir():
            candidates = (Path(r) / fn
                          for r, _dirs, files in os.walk(d) for fn in files)
        else:
            continue
        for p in candidates:
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if newest is None or m > newest[0]:
                newest = (m, p)
    return newest


def ts_to_iso(t):
    if t is None:
        return None
    return dt.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def parse_iso(s):
    if not s:
        return None
    try:
        v = s.replace("Z", "+00:00")
        d = dt.datetime.fromisoformat(v)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.datetime.now().astimezone().tzinfo)
        return d
    except Exception:
        return None


# ---------------------------------------------------------------- 解析库元信息
def load_config(explicit_lib=None):
    """返回 (lib_path | None, config_dict, lib_source)"""
    cfg = {}
    if CONFIG.exists():
        try:
            cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        except Exception:
            cfg = {}
    src = "参数 --library"
    lib = explicit_lib
    if not lib:
        lib = cfg.get("library")
        src = "study-coach.json"
    if not lib:
        return None, cfg, "未配置"
    return Path(lib).expanduser(), cfg, src


def parse_courses_md(path: Path):
    """从 COURSES.md 解析 {课程代码: {'id':.., 'name':..}}；顺序保留。"""
    out = {}
    if not path.exists():
        return out
    text = read_text(path)
    blocks = re.split(r"^###\s+", text, flags=re.M)
    for b in blocks[1:]:
        head = b.splitlines()[0].strip() if b.strip() else ""
        m = re.match(r"^([A-Za-z]{2,6}\s?\d{3,5}[A-Za-z]?)\s*(.*)$", head)
        if not m:
            continue
        code = m.group(1).replace(" ", "").upper()
        name = m.group(2).strip(" ·—-\t")
        seg = b[:600]
        cid = None
        cm = re.search(r"课程ID[^\d]{0,12}(\d{4,})", seg)
        if cm:
            cid = cm.group(1)
        out[code] = {"id": cid, "name": name}
    return out


def norm_session(raw):
    """把各种讲次写法归一成字符串 key：'1' '2' '2a' '10' …"""
    if raw is None:
        return None
    s = str(raw).strip().lower()
    m = re.match(r"^(\d+)([a-z]?)$", s)
    if m:
        num = m.group(1)
        # 去前导零：'L04' 与 'L4' 是同一讲，留着会让同一讲被算成两个 key
        num = str(int(num)) if num else num
        return num + m.group(2)
    return None


def session_from_name(name):
    """从文件名/文本推断讲次 key。"""
    n = name
    m = re.search(r"[Ll](\d+[a-z]?)\b", n)
    if m:
        return norm_session(m.group(1))
    m = re.search(r"[Ww]eek\s*0*(\d+)", n)
    if m:
        return norm_session(m.group(1))
    m = re.search(r"[Ll]ecture\s*0*(\d+)", n)
    if m:
        return norm_session(m.group(1))
    m = re.search(r"第([一二三四五六七八九十]+)讲", n)
    if m:
        v = cn_num_to_int(m.group(1))
        if v is None:
            return None
        return norm_session(v)
    m = re.search(r"第\s*0*(\d+)\s*讲", n)
    if m:
        return norm_session(m.group(1))
    return None


def course_from_name(name, known_codes):
    up = name.upper()
    for code in known_codes:
        if code in up:
            return code
    return None


# ---------------------------------------------------------------- 检查项
def check_env(lib: Path, cfg, rep: Report, ctx):
    if not lib.exists():
        rep.error("env", f"库目录不存在：{lib}", "检查 study-coach.json 的 library 字段")
        return
    if not lib.is_dir():
        rep.error("env", f"library 不是目录：{lib}")
        return
    rep.ok("env", f"库根目录：{lib}", f"来源：{ctx['lib_source']}")
    if not CONFIG.exists():
        rep.warn("env", f"配置文件不存在：{CONFIG}", "跑 SKILL.md 的「首次使用 · 安装引导」")
    else:
        rep.ok("env", f"配置文件：{CONFIG}")
    canvas = (cfg or {}).get("canvas") or {}
    base = (canvas.get("baseUrl") or "").strip()
    if base:
        if base.rstrip("/").endswith("/api/v1"):
            rep.warn("env", f"baseUrl 带了 /api/v1：{base}",
                     "只填到域名，例如 https://canvas.example.edu")
        else:
            rep.ok("env", f"Canvas 域名：{base}")
    else:
        rep.info("env", "未配置 Canvas 域名", "走「手动流派」也完全可用")


# ---------------------------------------------------------------- 学期标识
# 学期标记是这套库里**唯一**的时间锚。格式：<学年>-<学年第几段><学期字母>，如 2026-27A。
TERM_RE = re.compile(r"^\d{4}-\d{2}[A-C]$")


def _block_term(path: Path, rx):
    """从某个声明块里取 term。返回 (值 | None, 为什么没有)。"""
    if not path.exists():
        return None, "文件不存在"
    m = rx.search(read_text(path))
    if not m:
        return None, "块不存在"
    try:
        d = json.loads(m.group(1))
    except Exception:
        return None, "JSON 解析不了"
    if not isinstance(d, dict):
        return None, "块内容不是对象"
    v = d.get("term")
    if v is None:
        return None, "没有 term 字段"
    v = str(v).strip()
    return (v or None), ("空值" if not v else "ok")


def check_term(lib: Path, cfg, rep: Report, ctx):
    """三处学期标识（配置 / SYNC-BLOCK / PROGRESS）是否一致、是否填了。"""
    cfg_term = str((cfg or {}).get("term") or "").strip()
    courses_md = lib / "COURSES.md"
    sync_term, sync_why = _block_term(courses_md, SYNC_BLOCK_RE)
    prog_term, prog_why = _block_term(courses_md, PROGRESS_BLOCK_RE)

    marks = []
    if cfg_term:
        marks.append(("study-coach.json", cfg_term))
    if sync_term:
        marks.append(("SYNC-BLOCK", sync_term))
    if prog_term:
        marks.append(("PROGRESS", prog_term))

    if not marks:
        rep.warn("term", "三处都没有学期标识 —— 学期一换就分不清资料属于哪一学期",
                 f"在 {CONFIG} 加 \"term\": \"2026-27A\"，"
                 "并在 COURSES.md 两个声明块里同步")
        return

    # 模板占位符不算填了
    real = [(k, v) for k, v in marks if "<" not in v]
    for k, v in marks:
        if "<" in v:
            rep.warn("term", f"{k} 的 term 还是模板占位符：{v}",
                     "换成真实学期标识，例如 2026-27A")

    if real:
        values = {v for _, v in real}
        if len(values) > 1:
            rep.error("term",
                      "学期标识不一致：" + " ／ ".join(f"{k}={v}" for k, v in real),
                      "统一成同一个值 —— 不一致会让巡检跨学期对比时报出整屏假变动")
        else:
            rep.ok("term", f"学期标识一致：{values.pop()}（{len(real)} 处）。"
                           "巡检快照与覆盖率判定都据此锚定")

    if not cfg_term:
        rep.warn("term", "配置里没有 term（当前学期）",
                 "study-coach.json 加 \"term\": \"2026-27A\" —— 巡检快照靠它盖章")
    if not sync_term:
        rep.info("term", f"SYNC-BLOCK 缺学期标识（{sync_why}）", "补上，索引才落到具体学期")
    if not prog_term:
        rep.info("term", f"PROGRESS 缺学期标识（{prog_why}）", "补上，覆盖率判定才有时间锚")

    for k, v in real:
        if not TERM_RE.match(v):
            rep.warn("term", f"{k} 的写法不像学期标识：{v}",
                     "建议 <学年>-<学年第几段><学期字母>，例如 2026-27A")

    # 最新快照属于哪个学期 —— 跨学期对比是这里最容易出事的地方
    snaps = sorted((lib / "inspection" / "snapshots").glob("*.json"))
    if snaps:
        try:
            data = json.loads(read_text(snaps[-1]))
        except Exception:
            data = {}
        snap_term = str((data or {}).get("term") or "").strip()
        if not snap_term:
            rep.info("term", f"最新快照没有学期标记（{snaps[-1].name}）",
                     "升级前生成的快照。下次巡检起会带上，届时跨学期对比会被拦住")
        elif real and snap_term != real[0][1]:
            rep.warn("term", f"最新快照属于 {snap_term}，当前学期是 {real[0][1]}",
                     "正常（学期交界）。下次巡检会提示「学期切换」而不做逐项对比；"
                     "确认结束后跑 scripts/archive_term.sh 归档上一学期")


def check_skeleton(lib: Path, rep: Report, ctx):
    miss_dirs = [d for d in SKELETON_DIRS if not (lib / d).is_dir()]
    if miss_dirs:
        rep.warn("skeleton", f"缺 {len(miss_dirs)} 个目录：{', '.join(miss_dirs)}",
                 "重跑 scripts/init_library.sh <库目录>（幂等，不会覆盖已有文件）")
    else:
        rep.ok("skeleton", f"{len(SKELETON_DIRS)} 个骨架目录齐全")

    miss_files = [f for f in SKELETON_FILES if not (lib / f).is_file()]
    if miss_files:
        for f in miss_files:
            rep.warn("skeleton", f"缺文件：{f}（{SKELETON_FILES[f]}）",
                     "重跑 scripts/init_library.sh <库目录>")
    else:
        rep.ok("skeleton", f"{len(SKELETON_FILES)} 个骨架文件齐全")


def check_engine_sync(lib: Path, rep: Report, ctx):
    # ① 引擎脚本 → 应存在于库的镜像
    for eng_name, rel in ENGINE_MIRRORS.items():
        eng = ENGINE_SCRIPTS / eng_name
        dst = lib / rel
        if not eng.exists():
            rep.error("engine-sync", f"引擎脚本缺失：{eng_name}",
                      "Skill 目录不完整，重新安装 study-coach")
            continue
        if not dst.exists():
            rep.warn("engine-sync", f"库内缺副本：{rel}",
                     f"cp {eng} {dst}")
            continue
        if sha1(eng) != sha1(dst):
            rep.warn("engine-sync", f"库内副本已过期：{rel}",
                     f"引擎版本更新了。cp {eng} {dst}")
        else:
            rep.ok("engine-sync", f"{rel} 与引擎一致")

    # ② 库内散落的同名脚本（可能是手工拷贝的旧版）
    engine_names = {p.name for p in ENGINE_SCRIPTS.iterdir() if p.is_file()}
    target_rels = {rel for rel in ENGINE_MIRRORS.values()}
    for f in iter_text_files(lib, deep=False):
        if f.suffix.lower() not in {".js", ".sh", ".py"}:
            continue
        if "_archive" in f.parts:
            # 归档区里的东西刻意留着，不再视为「在用」
            continue
        rel = f.relative_to(lib).as_posix()
        if rel in target_rels:
            continue
        if f.name in engine_names:
            rep.info("engine-sync", f"库内另有同名脚本：{rel}",
                     "确认它不是过期的旧版")
        # 废弃别名脚本
        if f.name in DEPRECATED_ALIASES:
            rep.warn("engine-sync", f"库内留有废弃脚本：{rel}",
                     f"已被 {DEPRECATED_ALIASES[f.name]} 取代。建议归档到 quiz/_archive/ 并删掉引用")


def check_engine_health(lib: Path, rep: Report, ctx):
    """引擎自身的卫生：每个脚本有没有自检、shell 有没有变量坑、可执行位丢没丢。

    为什么把「引擎自己的毛病」放进库体检里：这两者是一起漂的。
    引擎脚本没自检 → 使用者不知道它坏了；shell 变量被中文吞 → 出事时才发现。
    一个只在交付现场才暴露问题的引擎，等于没有引擎。
    """
    scripts = sorted(p for p in ENGINE_SCRIPTS.iterdir()
                     if p.is_file() and not p.name.startswith("."))
    if not scripts:
        rep.error("engine-health", f"引擎目录是空的：{ENGINE_SCRIPTS}", "重新安装 study-coach")
        return

    # ① 自检覆盖：按显式对照表核，不靠「文件里提到过」这种模糊判据
    runner = ENGINE_SCRIPTS / "selftest.sh"
    if not runner.is_file():
        rep.error("engine-health", "缺自检总入口 scripts/selftest.sh",
                  "自检散在各个脚本里、没人一键跑，等于没有")

    names = {p.name for p in scripts}
    # 对照表里写着、实际却没有的 → 表过期
    for eng, st in sorted(SELFTEST_COVERAGE.items()):
        if eng not in names:
            rep.error("engine-health", f"自检对照表里有 `{eng}`，但 scripts/ 里没有",
                      "删掉这行，或把脚本补回来")
        if not (ENGINE_SCRIPTS / st).is_file():
            rep.error("engine-health", f"自检文件缺失：`{st}`（本该验 {eng}）",
                      "补上它，或从对照表里去掉")

    uncovered = [n for n in sorted(names)
                 if not n.startswith("selftest") and n not in SELFTEST_COVERAGE]
    if uncovered:
        rep.warn("engine-health", f"这些脚本没有登记自检：{', '.join(uncovered)}",
                 "在脚本旁加一个 selftest，并登记进 SELFTEST_COVERAGE。"
                 "验收的是「该报的会不会报」，不是它跑不崩")
    else:
        n = len([p for p in scripts if not p.name.startswith("selftest")])
        rep.ok("engine-health", f"{n} 个引擎脚本都有自检覆盖（按对照表核过）")

    # ② shell 变量坑：`$VAR` 紧跟中文会被吞
    #    注释行跳过：说明文字里会刻意写出这个错法当例子，那不是代码。
    hits = []
    for p in scripts:
        if p.suffix != ".sh":
            continue
        for i, line in enumerate(read_text(p).splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            if DOLLAR_CJK_RE.search(line):
                hits.append(f"{p.name}:{i}")
    if hits:
        rep.warn("engine-health",
                 f"shell 里有 $变量紧贴中文的写法（{', '.join(hits[:6])}"
                 f"{' 等' if len(hits) > 6 else ''}）",
                 "变量名会把中文字吞进去，改成 `${VAR}中文`。这类错误常藏在失败分支里，"
                 "平时不跑、一出错就二次崩")
    else:
        rep.ok("engine-health", "shell 脚本无 $变量紧贴中文的写法")

    # ③ 可执行位：SKILL.md 让使用者直接 `$S run`，.sh 丢了 +x 就跑不起来
    noexec = [p.name for p in scripts
              if p.suffix in {".sh", ".py", ".js"} and not os.access(p, os.X_OK)]
    if noexec:
        rep.warn("engine-health", f"这些脚本没有可执行位：{', '.join(noexec)}",
                 "chmod +x 它们。SKILL.md 里是让人直接 ./脚本 跑的")
    else:
        rep.ok("engine-health", "脚本可执行位齐全")

    # ④ SKILL.md 点名的脚本必须真实存在 —— 引擎自己的文档也会断链
    skill_md = SKILL_DIR / "SKILL.md"
    if skill_md.is_file():
        bad_refs = []
        for name in sorted(set(SCRIPT_REF_RE.findall(read_text(skill_md)))):
            if name == SELF.name or (ENGINE_SCRIPTS / name).exists():
                continue
            if name in DEPRECATED_ALIASES:
                bad_refs.append((name, f"已废弃，应写 {DEPRECATED_ALIASES[name]}"))
            else:
                bad_refs.append((name, "scripts/ 里没有这个文件"))
        if bad_refs:
            for name, why in bad_refs:
                rep.error("engine-health", f"SKILL.md 提到 `{name}`，但{why}",
                          "改文档或补文件 —— 照着 SKILL.md 敲命令的人会直接踩空")
        else:
            rep.ok("engine-health", "SKILL.md 里点名的脚本全部存在")


def check_changelog(lib: Path, rep: Report, ctx):
    """版本号与 CHANGELOG 是否同步。

    没有 CHANGELOG 的后果很具体：升级过几次之后，没人说得清「现在这版跟上次差在哪」，
    于是谁也不敢再改。这条检查把「改了版本就得留一句话」变成机械要求。
    """
    skill_md = SKILL_DIR / "SKILL.md"
    if not skill_md.is_file():
        rep.error("changelog", f"找不到 {skill_md}", "重新安装 study-coach")
        return

    m = VERSION_RE.search(read_text(skill_md))
    if not m:
        rep.error("changelog", "SKILL.md 的 frontmatter 里没有 `version:`",
                  "加一行 version，否则无从判断手上这版是新是旧")
        return
    ver = m.group(1).strip().strip("\"'")

    cl = SKILL_DIR / "CHANGELOG.md"
    if not cl.is_file():
        rep.error("changelog", f"引擎没有 CHANGELOG.md（当前版本 {ver}）",
                  "补一份：按版本倒序记「改了什么、为什么改」")
        return

    entries = CHANGELOG_ENTRY_RE.findall(read_text(cl))
    if not entries:
        rep.error("changelog", "CHANGELOG.md 里找不到任何 `## x.y.z` 条目",
                  "每条以 `## 1.2.3` 起头，检查器靠它比对版本号")
        return

    if entries[0] != ver:
        rep.error("changelog",
                  f"版本号已是 {ver}，但 CHANGELOG 最新条目停在 {entries[0]}",
                  "改了版本就要在 CHANGELOG.md 顶部补一条，否则「这版改了啥」"
                  "只存在于聊天记录里，下次没人敢升")
    else:
        rep.ok("changelog", f"版本 {ver} 与 CHANGELOG 一致（共 {len(entries)} 条记录）")


def check_refs(lib: Path, rep: Report, ctx):
    engine_names = {p.name for p in ENGINE_SCRIPTS.iterdir() if p.is_file()}
    lib_basenames = set()
    for f in iter_text_files(lib, deep=True):
        lib_basenames.add(f.name)
        lib_basenames.add(f.parent.name)

    bad_refs = []
    stale_refs = []
    broken_paths = []

    for f in iter_text_files(lib, deep=False):
        if f.suffix.lower() not in {".md", ".html", ".htm"}:
            continue
        rel = f.relative_to(lib).as_posix()
        text = read_text(f)

        # ① 脚本名引用（按行扫；「归档说明」那类行会刻意提到旧名，跳过）
        seen = set()
        for line in text.splitlines():
            if ARCHIVE_CONTEXT_RE.search(line):
                continue
            for m in SCRIPT_REF_RE.finditer(line):
                name = m.group(1)
                if name in seen:
                    continue
                seen.add(name)
                if name == SELF.name:
                    continue
                if name in DEPRECATED_ALIASES:
                    stale_refs.append((rel, name, DEPRECATED_ALIASES[name]))
                    continue
                if name in engine_names:
                    continue
                if name in lib_basenames:
                    continue
                bad_refs.append((rel, name))

        # ② 库内相对路径引用（反引号 + markdown 链接 + html href）
        #    迁移记录类文件写的是源侧路径，跳过
        if f.name in REF_PATH_EXEMPT_FILES:
            continue
        cands = set(PATH_REF_RE.findall(text))
        for lm in MD_LINK_RE.finditer(text):
            t = lm.group(1).strip()
            if t and "/" in t:
                cands.add(t)
        if f.suffix.lower() in {".html", ".htm"}:
            for hm in HTML_HREF_RE.finditer(text):
                t = hm.group(1).strip()
                if t and "/" in t:
                    cands.add(t)
        for t in cands:
            if t.startswith(("http", "/", "~", "#")):
                continue
            if any(ch in t for ch in ("<", ">", "{", "}", "*", "|", "?", "&")):
                continue
            if PLACEHOLDER_RE.search(t):
                continue
            # 相对路径的三种常见写法都认：相对引用者所在目录、相对库根、相对引擎根
            # （库文档合理地会点名引擎里的脚本，例如 `scripts/archive_term.sh`）
            if (f.parent / t).exists() or (lib / t).exists() or (SKILL_DIR / t).exists():
                continue
            if "skills/" in t or ".workbuddy" in t:
                continue
            broken_paths.append((rel, t))

    if stale_refs:
        for rel, name, new in stale_refs:
            rep.error("refs", f"{rel} 引用了已废弃的 {name}",
                      f"改成 {new}")
    if bad_refs:
        for rel, name in bad_refs:
            rep.error("refs", f"{rel} 引用了不存在的脚本：{name}",
                      "改名了还是删了？修正引用或补回文件")
    if broken_paths:
        for rel, t in broken_paths:
            rep.error("refs", f"{rel} 指向不存在的路径：{t}")
    if not (stale_refs or bad_refs or broken_paths):
        rep.ok("refs", "库内文档引用全部有效，无过期别名")


def check_index_sync(lib: Path, rep: Report, ctx):
    courses_md = lib / "COURSES.md"
    if not courses_md.exists():
        rep.error("index-sync", "COURSES.md 不存在", "重跑 init_library.sh")
        return

    text = read_text(courses_md)
    m = SYNC_BLOCK_RE.search(text)
    synced_at = None
    if not m:
        rep.warn("index-sync", "COURSES.md 没有 SYNC-BLOCK（回流机制未启用）",
                 "在文件顶部加 <!-- SYNC-BLOCK v1 {...} --> ；格式见 SKILL.md 的「课程索引回流」")
    else:
        try:
            block = json.loads(m.group(1))
        except Exception:
            rep.error("index-sync", "SYNC-BLOCK 不是合法 JSON", "修好它，否则回流检查失效")
            block = {}
        synced_at = parse_iso(block.get("syncedAt"))
        raw_synced = block.get("syncedAt")
        if isinstance(raw_synced, str) and ("<" in raw_synced or not raw_synced.strip()):
            rep.warn("index-sync", "SYNC-BLOCK 还是模板占位符（syncedAt 没填）",
                     "填成真实时间，例如 2026-09-24T16:30:00+08:00")
        elif not synced_at:
            rep.warn("index-sync", f"SYNC-BLOCK 的 syncedAt 不是合法时间：{raw_synced}")
        else:
            rep.ok("index-sync", f"索引同步于 {synced_at.isoformat(timespec='minutes')}"
                                 f"（来源：{block.get('source') or '未标'}）")
        snap = block.get("snapshot")
        # 与最新快照比对
        snaps = sorted((lib / "inspection" / "snapshots").glob("*.json"))
        if snaps:
            newest = snaps[-1]
            newest_dt = None
            try:
                data = json.loads(read_text(newest))
                newest_dt = parse_iso(data.get("collectedAt"))
            except Exception:
                newest_dt = None
            if newest_dt and (not snap or not parse_iso(snap) or
                              newest_dt > (parse_iso(snap) or dt.datetime.min.replace(
                                  tzinfo=newest_dt.tzinfo))):
                rep.warn("index-sync",
                         f"巡检快照比索引新：快照 {newest_dt.isoformat(timespec='minutes')}",
                         "跑一次回流：拿快照里的作业截止日期核对 COURSES.md 并更新 SYNC-BLOCK")
            else:
                rep.ok("index-sync", f"索引不比最新快照落后（快照 {len(snaps)} 份）")
        else:
            rep.info("index-sync", "还没有巡检快照可比对（未接 Canvas 时正常）")

    # 库内产物是否比索引新
    newest = latest_mtime(lib, ["notes", "assignments", "plans", "course-rules.md"])
    if newest and synced_at:
        nmtime = ts_to_iso(newest[0])
        if dt.datetime.fromtimestamp(newest[0]).astimezone() > synced_at:
            rep.info("index-sync",
                     f"库内有比索引更新的产物：{newest[1].relative_to(lib).as_posix()}"
                     f"（{nmtime}）",
                     "若这一讲/这次改动牵动了课程结构（新作业、截止日期、AI 政策），"
                     "顺手把 COURSES.md 与 SYNC-BLOCK 一起更新")
    elif newest and not synced_at:
        pass


def sess_base(s):
    m = re.match(r"^(\d+)", str(s))
    return int(m.group(1)) if m else None


def parse_progress(courses_md: Path):
    """读 COURSES.md 的 PROGRESS 块：各门课「已经上到第几讲」。"""
    if not courses_md.exists():
        return None
    m = PROGRESS_BLOCK_RE.search(read_text(courses_md))
    if not m:
        return None
    try:
        d = json.loads(m.group(1))
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _missing_sessions(sessions, pool):
    """sessions 里没有对应笔记的那些（笔记讲次 '2' 可覆盖课件讲次 '2b'）。"""
    out = set()
    for s in sessions:
        if s in pool:
            continue
        b = sess_base(s)
        if b is not None and (str(b) in pool or b in pool):
            continue
        out.add(s)
    return out


def check_coverage(lib: Path, rep: Report, ctx):
    """讲次覆盖率。

    **核心原则：笔记跟着课程时间走。**
    课件常常提前好几周就传到 Canvas 了，但还没上到的课不需要（也不该催）笔记 ——
    否则每次体检都会刷一堆「缺第 N 讲笔记」，把真正的缺口淹掉。

    所以先读 COURSES.md 的 PROGRESS 块拿教学进度，只对**已经上过**的讲次报缺口；
    超前的课件单独标成「未到上课时间」。没有进度声明时**不判定**，只报客观计数。
    """
    courses = parse_courses_md(lib / "COURSES.md")
    if not courses:
        rep.warn("coverage", "无法从 COURSES.md 解析课程（缺 `### SSxxxx 名称` 小标题？）")
        return
    codes = set(courses)
    id2code = {m["id"]: c for c, m in courses.items() if m.get("id")}

    progress = parse_progress(lib / "COURSES.md")
    prog_courses = (progress or {}).get("courses") or {}
    if not isinstance(prog_courses, dict):
        prog_courses = {}

    # 课件讲次（递归扫：materials/ 里按课程建子目录是常见组织方式）
    mat_sessions = {}
    if (lib / "materials").exists():
        for f in sorted(iter_entry_files(lib / "materials")):
            # 课程归属：先试前缀里的 Canvas id，再试路径里的课程代码
            # （相对路径串参与匹配，这样 materials/SSxxxx/L03.pdf 也能归对课）
            rel = f.relative_to(lib).as_posix()
            code = None
            pm = re.match(r"^(\d{4,})[_\-]", f.name)
            if pm and pm.group(1) in id2code:
                code = id2code[pm.group(1)]
            if not code:
                code = course_from_name(rel, codes)
            if not code:
                continue
            # 只把「课件」计入，大纲/outline/course plan 不算
            low = rel.lower()
            if any(k in low for k in ("outline", "course plan", "assessment",
                                      "syllabus", "schedule")):
                continue
            s = session_from_name(rel)
            if s:
                mat_sessions.setdefault(code, set()).add(s)

    # 复习笔记 / 课前预习包 分开统计 —— 预习包不能当成复习笔记充数
    # （同样递归扫，notes/ 里的子目录不算新鲜事）
    review, preview, other = {}, {}, {}
    notes_dir = lib / "notes"
    if notes_dir.exists():
        for f in sorted(iter_entry_files(notes_dir)):
            rel = f.relative_to(lib).as_posix()
            code = course_from_name(rel, codes)
            if not code:
                continue
            s = session_from_name(rel)
            if not s:
                continue
            if "预习" in rel:
                preview.setdefault(code, set()).add(s)
            elif "复习" in rel:
                review.setdefault(code, set()).add(s)
            else:
                other.setdefault(code, set()).add(s)
                review.setdefault(code, set()).add(s)

    if progress and not (progress.get("confirmed") is True):
        rep.info("coverage", "教学进度声明尚未与使用者核对（confirmed: false）",
                 "核完把 PROGRESS 的 confirmed 改成 true，之后判定才可全信")

    for code in sorted(courses):
        taught = mat_sessions.get(code, set())
        noted = review.get(code, set())
        prog = prog_courses.get(code)
        limit = prog.get("taughtUpTo") if isinstance(prog, dict) else None
        if not isinstance(limit, int):
            limit = None

        if limit is None:
            if not taught:
                rep.info("coverage", f"{code}：未识别到课件讲次（材料可能未归档）")
            else:
                rep.info("coverage",
                         f"{code}：课件 {len(taught)} 讲 ／ 复习笔记 {len(noted)} 讲"
                         f"（未声明教学进度，不判定该不该有笔记）",
                         "在 COURSES.md 的 PROGRESS 块填 taughtUpTo，之后会自动区分「缺笔记」与「课还没上」")
            continue

        # 该有哪些笔记 = 教学进度（1..taughtUpTo），**不是**课件数量 ——
        # 课件没归档的讲次同样可能缺笔记，拿课件推会漏判。
        due = {str(i) for i in range(1, limit + 1)}
        ahead = sorted({s for s in taught if (sess_base(s) or 0) > limit})
        miss = _missing_sessions(due, noted)

        if miss:
            rep.warn("coverage",
                     f"{code}：已上到第 {limit} 讲，缺复习笔记 → {', '.join(sorted(miss))}",
                     f"已有：{', '.join(sorted(noted)) or '无'}")
        else:
            rep.ok("coverage", f"{code}：已上到第 {limit} 讲，复习笔记无缺口")

        if ahead:
            rep.info("coverage",
                     f"{code}：第 {', '.join(ahead)} 讲课件已上传但还没上到"
                     f"（进度：第 {limit} 讲）",
                     "不需要笔记；想提前准备就出课前预习包")

        nxt = limit + 1
        if str(nxt) in preview.get(code, set()) or nxt in preview.get(code, set()):
            rep.info("coverage", f"{code}：下一讲（第 {nxt} 讲）预习包已就绪")
        else:
            rep.info("coverage", f"{code}：下一讲（第 {nxt} 讲）还没有课前预习包")

    # 进度声明的新鲜度
    as_of = parse_iso((progress or {}).get("asOf"))
    if as_of:
        days = (dt.datetime.now().astimezone() - as_of.astimezone()).days
        if days > 10:
            rep.info("coverage", f"教学进度声明已 {days} 天未更新（asOf {as_of.date()}）",
                     "每周上完新课就更新 PROGRESS 的 taughtUpTo 与 asOf")

    # 作业作战包
    asg_dir = lib / "assignments"
    if asg_dir.is_dir():
        n = len([f for f in iter_entry_files(asg_dir) if f.suffix == ".md"])
        if n:
            rep.info("coverage", f"assignments/ 现有 {n} 份作战包")


def check_credentials(lib: Path, rep: Report, ctx):
    if not TOKEN_FILE.exists():
        rep.info("credentials", "无 token 文件（未接 Canvas 或走了手动流派）")
        return
    mode = TOKEN_FILE.stat().st_mode & 0o777
    if mode != 0o600:
        rep.warn("credentials", f"token 文件权限是 {oct(mode)}，应为 0o600",
                 f"chmod 600 {TOKEN_FILE}")
    else:
        rep.ok("credentials", "token 文件权限 600")

    tok = ""
    try:
        tok = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except Exception:
        pass
    if len(tok) < 16:
        rep.info("credentials", "token 太短，跳过泄漏扫描")
        return

    hits = []
    for f in iter_text_files(lib, deep=ctx.get("deep", False)):
        try:
            if f.stat().st_size > 4 << 20:
                continue
        except OSError:
            continue
        if tok and tok in read_text(f):
            hits.append(f.relative_to(lib).as_posix())

    if hits:
        rep.error("credentials",
                  f"⚠️ 凭据泄漏！token 出现在库内 {len(hits)} 个文件：{', '.join(hits[:5])}",
                  "硬红线 ②：立刻删掉这些出现处并轮换 token。库必须能整个文件夹发人")
    else:
        rep.ok("credentials", f"库内无 token 泄漏（扫了 {len(list(iter_text_files(lib, deep=ctx.get('deep', False))))} 个文本文件）")


def check_banners(lib: Path, rep: Report, ctx):
    checker = ENGINE_SCRIPTS / "check_ai_banner.py"
    asg = lib / "assignments"
    if not checker.exists():
        rep.warn("banners", "找不到 check_ai_banner.py", "Skill 目录不完整")
        return
    if not asg.is_dir() or not any(asg.glob("*.md")):
        rep.info("banners", "assignments/ 还没有 .md 产物")
        return
    try:
        out = subprocess.run(
            [sys.executable, str(checker), "--scan", str(asg), "--json"],
            capture_output=True, text=True, timeout=60)
    except Exception as e:
        rep.warn("banners", f"横幅检查器跑不起来：{e}")
        return
    raw = (out.stdout or "").strip()
    try:
        rows = json.loads(raw)
    except Exception:
        rep.warn("banners", "横幅检查器输出无法解析", raw[:200])
        return
    tally = {}
    for r in rows:
        tally[r.get("type", "?")] = tally.get(r.get("type", "?"), 0) + 1
    label = {"ban": "禁止版", "partial": "不可代写版", "unconfirmed": "未确认版",
             "none": "无横幅"}
    parts = [f"{label.get(k, k)} {v}" for k, v in sorted(tally.items())]
    rep.info("banners", f"assignments/ {len(rows)} 份产物横幅状态：" + " ／ ".join(parts),
             "无横幅 ≠ 不合规：复习笔记/题库/计划本就不该挂")


def check_inspection(lib: Path, cfg, rep: Report, ctx):
    snap_dir = lib / "inspection" / "snapshots"
    snaps = sorted(snap_dir.glob("*.json")) if snap_dir.is_dir() else []
    if snaps:
        latest_dt = ts_to_iso(snaps[-1].stat().st_mtime)
        rep.ok("inspection", f"巡检快照 {len(snaps)} 份，最后一份 {latest_dt}")
        if len(snaps) == 1:
            rep.info("inspection", "只有一份快照（基线）", "下次巡检才有可比的变动")
    else:
        rep.info("inspection", "还没有巡检快照", "接上 Canvas 后先跑一次建立基线")

    log = lib / "inspection" / "log.tsv"
    if log.exists():
        lines = [l for l in read_text(log).splitlines() if l.strip()]
        rep.info("inspection", f"巡检流水 {max(0, len(lines) - 1)} 条记录")

    if not TOKEN_FILE.exists():
        rep.info("inspection", "无 Canvas 凭据 → 巡检会明确报错（不会给假的「无变动」）",
                 "拿 token 的步骤见 SKILL.md「首次使用 · 安装引导」②")

    insp = (cfg or {}).get("inspection") or {}
    if insp.get("enabled"):
        days = ",".join(insp.get("days") or [])
        rep.ok("inspection",
               f"巡检排程已开启：每周 {insp.get('perWeek', '?')} 次"
               f"（{days} {insp.get('time', '')}）")
        if not insp.get("automationIds"):
            rep.warn("inspection", "排程已开但 automationIds 为空",
                     "排程没有真的落成自动化任务")
        if insp.get("askBeforeRun") is not True:
            rep.warn("inspection", "askBeforeRun 不是 true",
                     "硬红线 ⑥：到点必须先问、拿到许可才跑")
    else:
        rep.info("inspection", "未开启巡检排程", "想开就说「设置巡检」")


CHECKS = {
    "env": lambda lib, cfg, rep, ctx: check_env(lib, cfg, rep, ctx),
    "term": lambda lib, cfg, rep, ctx: check_term(lib, cfg, rep, ctx),
    "skeleton": lambda lib, cfg, rep, ctx: check_skeleton(lib, rep, ctx),
    "engine-sync": lambda lib, cfg, rep, ctx: check_engine_sync(lib, rep, ctx),
    "engine-health": lambda lib, cfg, rep, ctx: check_engine_health(lib, rep, ctx),
    "changelog": lambda lib, cfg, rep, ctx: check_changelog(lib, rep, ctx),
    "refs": lambda lib, cfg, rep, ctx: check_refs(lib, rep, ctx),
    "index-sync": lambda lib, cfg, rep, ctx: check_index_sync(lib, rep, ctx),
    "coverage": lambda lib, cfg, rep, ctx: check_coverage(lib, rep, ctx),
    "credentials": lambda lib, cfg, rep, ctx: check_credentials(lib, rep, ctx),
    "banners": lambda lib, cfg, rep, ctx: check_banners(lib, rep, ctx),
    "inspection": lambda lib, cfg, rep, ctx: check_inspection(lib, cfg, rep, ctx),
}


# ---------------------------------------------------------------- 输出
def render(rep: Report, lib, as_json, quiet):
    counts = rep.counts()
    if as_json:
        print(json.dumps({
            "library": str(lib) if lib else None,
            "ok": counts["error"] == 0,
            "counts": counts,
            "findings": rep.items,
        }, ensure_ascii=False, indent=2))
        return

    if not quiet:
        print(f"\n库体检 · {lib}\n{'─' * 66}")
    for sec in SECTIONS:
        items = [i for i in rep.items if i["section"] == sec]
        if not items:
            continue
        if quiet and all(i["level"] in ("ok", "info") for i in items):
            continue
        print(f"\n【{SECTION_TITLE.get(sec, sec)}】")
        for i in items:
            mark = LIGHT.get(i["level"], "?")
            print(f"  {mark} {i['message']}")
            if i["hint"]:
                print(f"      → {i['hint']}")

    print(f"\n{'─' * 66}")
    parts = []
    if counts["error"]:
        parts.append(f"错误 {counts['error']}")
    if counts["warn"]:
        parts.append(f"提醒 {counts['warn']}")
    if counts["info"]:
        parts.append(f"信息 {counts['info']}")
    parts.append(f"通过 {counts['ok']}")
    verdict = "有问题要处理" if counts["error"] else (
        "有提醒，建议看一眼" if counts["warn"] else "一切对齐")
    print("  " + " ／ ".join(parts) + f"　→ {verdict}")
    if counts["error"]:
        print("  错误项：库里存在指向不存在物的引用或凭据泄漏，需要修。")
    print()


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description="学习库体检")
    ap.add_argument("--library", "-l", default=None, help="库目录（默认读 study-coach.json）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--only", default=None, help="只跑这些检查项，逗号分隔")
    ap.add_argument("--list", action="store_true", help="列出所有检查项")
    ap.add_argument("--deep", action="store_true", help="连 materials/qwenwork-raw 一起扫（慢）")
    ap.add_argument("--quiet", "-q", action="store_true", help="只显示需要处理的项")
    args = ap.parse_args(argv)

    if args.list:
        print("检查项：")
        for s in SECTIONS:
            print(f"  {s:<12} {SECTION_TITLE.get(s, s)}")
        return 0

    lib, cfg, lib_source = load_config(args.library)
    if not lib:
        print("错误：找不到库目录。用 --library 指定，或先跑安装引导写 study-coach.json",
              file=sys.stderr)
        return 2
    if not lib.is_dir():
        print(f"错误：库目录不存在 -> {lib}", file=sys.stderr)
        return 2

    wanted = SECTIONS
    if args.only:
        wanted = [s.strip() for s in args.only.split(",") if s.strip()]
        unknown = [s for s in wanted if s not in CHECKS]
        if unknown:
            print(f"错误：未知检查项 {', '.join(unknown)}。用 --list 看有哪些", file=sys.stderr)
            return 2

    rep = Report()
    ctx = {"lib_source": lib_source, "deep": args.deep}
    for s in wanted:
        try:
            CHECKS[s](lib, cfg, rep, ctx)
        except Exception as e:
            rep.error(s, f"检查项 {s} 自身炸了：{type(e).__name__}: {e}")

    render(rep, lib, args.json, args.quiet)
    return 1 if rep.counts()["error"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
