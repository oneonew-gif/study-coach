# CHANGELOG

本引擎的改动记录。**规则：改了 `SKILL.md` 的 `version`，就必须在这里顶部补一条。**
不补的话 `lib_doctor.py` 的「引擎版本记录」检查会报错 —— 这条检查存在的理由很实在：
没有它，升级过几次之后就没人说得清「现在这版跟上次差在哪」，于是谁也不敢再改。

版本号约定：`主.次.修`
- **主**：改了红线（使用者的行为约束变了）
- **次**：新增工作线 / 新增脚本 / 新增机械保障
- **修**：措辞、措辞性错误、文档修正

倒序排列，最新在最上。

---

## 1.19.4 — 2026-10-01 · 遗留问题收口（N1–N10）

第二轮复查发现的 10 个待完善点全部落地。对 WorkBuddy 主路径用户零影响（默认行为不变），对非 WorkBuddy 平台用户是把半吊子的支持补完整。

### 高优先级
- **N1 `--sha256` 补全发布端**：`package_skill.sh` 打包后自动计算 `engine.zip` 的 SHA-256，写入 `<zip>.sha256` 文件并打印到终端。用户安装时 `bash install.sh --zip <包> --sha256 <hash>` 即可校验，防镜像/中间人篡改。之前只有校验端没有生成端。
- **N2 `package_skill.sh` 隐私路径**：`PRIVACY_FILE` 从 `${HOME}/.workbuddy/...` 改为 `${WORKBUDDY_HOME:-$HOME/.workbuddy}/...`，与其余脚本对齐。之前是 L2 唯一遗漏的脚本。

### 中优先级
- **N3 `--from-dir` + `--sha256` 警告**：from-dir 模式不经过 zip，校验会静默跳过。现在同给时弹警告说明已忽略。
- **N4 错误消息动态路径**：`lib_doctor.py` 学期标识警告、`check_terms.py` 找不到库目录的报错，从硬编码 `~/.workbuddy/study-coach.json` 改为显示实际 CONFIG 路径。
- **N5 `canvas_inspect.sh` 归档提示**：从硬编码 `~/.workbuddy/skills/study-coach/scripts/archive_term.sh` 改为"引擎 scripts/ 目录下的 archive_term.sh"，适配自定义安装路径。

### 低优先级
- **N6 WORKBUDDY_HOME 回归检查**：`selftest.sh` 新增静态扫描——所有定义 CONFIG/TOKEN_FILE/CFGDIR/PRIVACY_FILE 的脚本必须用 `${WORKBUDDY_HOME:-...}`，不能硬编码 `$HOME/.workbuddy`。
- **N7 脚本头部注释**：canvas.sh、deadlines.sh、canvas_inspect.sh、archive_term.sh、lib_doctor.py 的配置路径注释改用 `<WORKBUDDY_HOME>` 占位符并说明默认值。
- **N8 `present_files` 平台说明具体化**：补充 Claude Desktop/Codex→文件附件、Cursor/Trae→内联预览的对应做法。
- **N9 `install.sh` DEST 联动**：默认安装路径从 `$HOME/.workbuddy/skills/study-coach` 改为 `${WORKBUDDY_HOME:-$HOME/.workbuddy}/skills/study-coach`，引擎与配置同根。
- **N10 `install.sh` 收尾提示**：非 WorkBuddy 平台用户安装后提示设置 `WORKBUDDY_HOME` 环境变量。

### 验证
- 全量自检 12/12 通过（含新增的 WORKBUDDY_HOME 回归检查）
- package_skill.sh SHA-256 生成冒烟测试通过
- install.sh `--from-dir` + `--sha256` 警告冒烟测试通过

---

## 1.19.3 — 2026-10-01 · Agent 平台通用性补全（问题二方案 A）

脚本层早在 1.19.2 就通过 `WORKBUDDY_HOME` 实现了路径解耦，但 SKILL.md 的行为剧本仍深度绑定 WorkBuddy（automation/rrule/automationIds/present_files），非 WorkBuddy 平台的 agent 读了会被要求做不存在的事。本版给每处 WorkBuddy 专属指令加了平台降级说明。

### 改动（仅 SKILL.md，无脚本改动）
- **巡检配置**（线四 ①）：第 2 步建 automation/rrule 处加「非 WorkBuddy 平台无此机制：跳过此步，告知使用者用系统 cron/任务计划或手动运行」；第 3 步 `automationIds` 标注「仅 WorkBuddy 需要，其他平台留空」
- **配置示例 JSON**：`automationIds` 字段加注释「仅 WorkBuddy 需要；其他平台留空」
- **每日待办播报**（线四 ⑦）：建每日 rrule 处加降级说明——跳过建 rrule，把时间和预习提前量记进配置，告知使用者手动运行或用 cron
- **每周复盘**（线四 ⑦）：建周 rrule 处加同类降级说明
- **`present_files` 交付**（线一、线四巡检报告、导出日历、交付清单共 4 处）：统一加「非 WorkBuddy 平台用文件附件/预览功能代替」
- **配置路径**：巡检配置写 JSON 处补充「非 WorkBuddy 平台路径为 `$WORKBUDDY_HOME/study-coach.json`」

### 设计取舍
- 采用方案 A（加降级说明）而非方案 B（重写为平台中立）：WorkBuddy 仍是主路径，保持主路径指令的简洁精确；非 WorkBuddy 平台只需读括号内的降级提示即可
- Windows 安装问题未改动：用户确认 Windows 现状（Git Bash / WSL）对 agent 代装场景已够用

---

## 1.19.2 — 2026-10-01 · 可移植性与健壮性加固（L 批）

在 1.19.1 的 review 修复基础上，处理低优先级但影响长期可维护性的问题。**L3（背词梗词本地化）用户选择保留，未改动。**

### 可移植性
- **L1 `present_files` 平台说明**：SKILL.md 运行前提节与 INSTALL.md 开头注明 `present_files` 是 WorkBuddy 专有工具，其他 agent 平台用等价的文件预览/附件功能代替。正文中 5 处 `present_files` 引用保持不变（WorkBuddy 用户直接可用）。
- **L2 `WORKBUDDY_HOME` 环境变量**：所有读取配置/凭据的脚本（canvas.sh、canvas_inspect.sh、deadlines.sh、daily_digest.sh、weekly_digest.sh、vocab.sh、archive_term.sh、preflight.sh、lib_doctor.py、check_terms.py）改为从 `WORKBUDDY_HOME` 环境变量读取配置目录，默认 `~/.workbuddy`。非 WorkBuddy 平台设置该变量即可迁移，无需改脚本。

### 健壮性
- **L4 `install.sh` 失败处理补全**：`mktemp -d` 加 `|| die`；`tar | tar` 管道改为临时文件中转（`tar -cf src.tar` + `tar -xf src.tar`），避免管道只看末尾退出码导致首个 tar 失败被静默忽略。
- **L5 `install.sh` Python 解压**：`zipfile.ZipFile(...).extractall(...)` 改为 `with zipfile.ZipFile(...) as z: z.extractall(...)`，确保文件句柄在 Windows 等平台上及时释放。

### 文档
- **L6 `SKILL.md` description 精简**：从约 500 字（塞满全部触发词）精简到约 150 字（核心功能 + 高频触发词），避免超过部分平台的字段长度上限。完整触发词已在正文各工作线中列明，不损失功能。

### 验证
- 全量自检 12/12 通过
- `WORKBUDDY_HOME` 冒烟测试：canvas.sh 与 lib_doctor.py 均正确读取自定义路径下的配置

---

## 1.19.1 — 2026-10-01 · 文档真相修复与安装安全加固（review 批）

一次全面 review 揪出的「文档说谎」与安全短板。引擎运行时脚本零改动，全是文档与安装器修正。

### 修复（文档与事实对齐）
- **H2 `COURSES.template.md`**：学期归档一节把 `quiz/` 从「移动」列表里拿掉。实际 `archive_term.sh` 对 `quiz/` 是**复制**（原地保留，跨学期复用），模板早先写成移动，与工具行为矛盾。
- **H3 `templates/inspection-README.md`**：分页局限从「单次最多 100 条、未跟随」改为「已跟随 `Link: rel="next"`，上限 25 页」。`canvas.sh` 早在 1.9.1 就实现了翻页，文档一直没跟上（假红灯）。
- **M1 自检数量口径**：README 自检表从 7 项补全到实际 12 项（补 `daily_digest` / `deadlines` / `vocab` / `weekly_digest` / `install`）；INSTALL.md 的「7/7 全绿」改为「全部通过（数量随版本变化）」。`selftest.sh` 本就是自动发现，文档却写死了旧数字。
- **M3 `SKILL.md` 脚本表**：补上遗漏的 `deadlines.sh` / `daily_digest.sh` / `weekly_digest.sh` / `vocab.sh` / `package_skill.sh`。
- **H1 `install.sh`**：Windows Git Bash 分支不再提不存在的 `install.ps1`。README 同步改为「Git Bash / WSL 直接跑本脚本」。
- **M4 平台口径**：install.sh 的 Git Bash 文案与 README 平台表对齐为「实验性支持」。

### 安全加固
- **H5 token 写入**：`references/canvas-api.md` 与 `SKILL.md` 的凭据写入命令从 `printf '%s' '<token>'` 改为 `read -s -p` 交互输入，避免 token 明文进 shell 历史（文档自己反复强调别贴 token，却让它进 history）。
- **H4 `install.sh --sha256`**：新增可选哈希校验。下载或 `--zip` 安装后，若指定 `--sha256 <hash>`，用 `shasum`（macOS）/ `sha256sum`（Linux）核对 `engine.zip`，不一致直接中止。README 一键安装节补充说明。

### 说明
- `lib_doctor.py` 的 `SELFTEST_COVERAGE` 表经查 `preflight.sh` 已在其中（映射到 `selftest.sh` 的内联检查），**M2 无需改动**。

---

## 1.19.0 — 2026-09-25 · 批一：macOS/Linux 一键安装器（install.sh）· W 系列延续

### 新增
- **`install.sh`（引擎根目录）**：macOS/Linux 一键安装。自动完成下载（四路候选含镜像回退 + `GITHUB_TOKEN` 感知）→ 解压改名（GitHub archive 顶层目录自动归位 `study-coach`）→ 落位 `~/.workbuddy/skills/study-coach/` → 旧安装自动备份 `.bak-时间戳` → 跑 preflight → 打印下一步指引。支持 `--dir / --zip / --from-dir / --no-preflight`，重跑即升级。
- **`scripts/selftest_install.sh`（12 项，注入式不联网）**：正常落位、.git 排除、备份可寻回、zip 顶层改名、坏 zip 拒装、缺 SKILL.md 拒装、preflight 开关、下载失败给手动方案、参数互斥。
- README「一键安装」节（macOS/Linux 一行命令）；INSTALL.md 加 `--zip` 偷懒装法；CI 三平台加 install.sh 冒烟步。

### 修复 / 已知现象
- **新仓库 GitHub 匿名下载端点延迟**：仓库刚推送后 `archive/refs/heads` 与匿名 zipball 返回 404（带 token 的 API zipball 立即可用）。install.sh 候选列表第二位放 API zipball 并自动附带 `GITHUB_TOKEN`，报错文案写明三种原因与手动兜底。

### 兼容性承诺
- 引擎现有脚本**零改动**；不带参数的打包输出与 1.18.0 同口径（批三加 `--portable` 时加断言锁死）。Mac 手动安装路径不变。

---

## 1.18.0 — 2026-09-25 · Deadline 导出系统日历（ics）· 笔记背单词模块 · 讲次抽词

### 新增

- **`deadlines.sh ics` 模式**：把未交作业导出成 `<库根目录>/deadline.ics`——每作业一条 VEVENT（SUMMARY `[课代码] 作业名`，DESCRIPTION 带分值 + 作业链接），内置 VALARM 双层提醒（提前 1 天 + 提前 1 小时）。`--within N` 只导未来 N 天（逾期不混入）；默认逾期超 30 天旧账不导，`--include-late` 放开（误用于 board/brief 明确报错）。
  - 红线：读取失败 / 解析失败时**拒绝生成**——半空的日历比没有更害人；空清单也拒绝，不推空气
  - 格式：全文件 CRLF、`DTSTAMP` 齐全、UID 稳定可复现（`canvas-<作业id>@study-coach`，无 id 时按课+词+时间哈希）——重跑覆盖同一文件，日历里不重复导入
  - **场景钩子**：board 摘要末尾固定一行「想把这些 deadline 灌进系统日历？说『导出日历』就行」
- **复习笔记「背单词」模块**（note-template.md）：中文版末尾固定一节四列表（词 / 释义 / 为什么重要 / 状态）。收词依据四条（录音重复 ≥3 次 / 自测题 / 跨讲复现 / 课件新术语），依据必填、每讲 3–8 个宁缺毋滥；用户给的词进表标「使用者指定」。状态列只是生成时的快照（`待确认` / `已在词库 · 盒 N`），**背词进度绝不回写笔记**——笔记是档案，词库是状态
- **`vocab.sh draw --lecture N | --recent N`**：按讲次抽词（「考我第 5 讲的单词」「最近三讲快刷」）。讲次从词条 `lecture` 字段或 `source` 里的「第N讲」解析（含中文数字一到二十）

### 文档

- SKILL.md：触发词加「导出日历 / 导日历 / 加进日历 / 生成 ics」「考我第几讲的单词」；线四⑦加 ics 用法与红线；线五入口 A 改为笔记模块表收词
- INSTALL.md ⑤½ 扩为六连问（+「要不要导一份进系统日历」，要则当场跑一次 ics 完成首次导入）
- README 日常用法表加「导出日历」「考我第 N 讲的单词」两行

### 自检

- `selftest_deadlines.sh` 18 → 30 项：ics 拒绝生成红线、CRLF、UID 唯一且稳定、VALARM×2、逾期/已提交/无 due 过滤口径、--within/--include-late 边界
- `selftest_vocab.sh` 22 → 26 项：--lecture / --recent 过滤、中文数字讲次解析、二选一冲突拦截

### 过程坑（记两笔）

- `set -e` 下 `[ A ] && [ B ] && die` 当 B 不成立时整条链返回非零直接杀脚本——条件分支必须用 if
- 校验「至少为 1」前先想想 0 是不是合法默认值（--recent 默认 0 = 不过滤）

---

## 1.17.0 — 2026-09-25 · 背词教练（vocab.sh）· 线五

- 新增 `scripts/vocab.sh`：背「课程里的活词」，全引擎唯一有状态写入的脚本（只写 `<库>/vocab/`）
  - **收词四入口**：出笔记顺路收（主通道）/ 三探测器进收词箱（录音转写老师重复 ≥3 次的术语、check_terms 查出的用错术语、错题题干术语）/ 截图贴文本提候选 / 手动加词；**自动来源必须 inbox accept 用户确认后才进主册**
  - **莱特纳 5 盒**：grade --hit 进下一盒、--miss 回盒 1；draw 盒 1、2 优先，不给答案，每词带来源标签
  - **分册**：主册 = 课程词（vocab.json），贴词表可建自定义册（考研/四六级），歧义问一次记配置，默认永远主册
  - **红线**：空库抽词明确报错「我不会编词」；删词/收词打印来源可追溯；词义只来自课程材料或用户原文
- **引导行「今日有人味儿的提醒」**：每日播报、每周复盘末尾固定一行（`vocab.sh hint` 自动带出），句式「我想背单词 / <今日梗词>」；梗词周一至周五排班：city不city来背单词 → cityuniversity → 又一城学子背单词了 → hello Hong Kong study → 考我单词，五句全部写进触发词（说哪个都能触发）；`vocab.hints` 按星期可覆盖、`vocab.hint: false` 关闭、空库不推空气
- SKILL.md：description 触发词补齐；新增「线五 · 背词教练」一节（收词入口、背词会话、引导行、红线、独立窗口推荐用法）；INSTALL.md ⑤½ 扩为五连问（+引导行开关）
- 自检：新增 `selftest_vocab.sh` 22 项（注入式）；daily/weekly 自检各加引导行断言；`lib_doctor` 覆盖率对照表同步
- 坑：`set -u` 下 `$VAR` 后紧跟全角字符（如 `$CMD（详见）`）会被 bash 连字节吃进变量名报 unbound——引用后接全角标点必须用 `${VAR}`；`import --from-terms` 现在打印收进来的词名单

## 1.16.0 — 2026-09-25 · 每周复盘（weekly_digest.sh）

- 新增 `scripts/weekly_digest.sh`（只读）：一条命令五块——
  - 【本周产出】notes/ 近 7 天新增复习笔记 / 预习包（mtime 统计，`--days N` 可调）
  - 【学习债趋势】缺口数 vs 上次快照 `digest/weekly-stats.json`（↑/↓/持平）；判定与 daily_digest 同源，自检里加了同库交叉核对哨
  - 【Deadline 未来一周】内部调 `deadlines.sh brief --within 7`
  - 【下周预告】第 7–14 天要交的（提前心里有数）
  - 【总评】只基于数字的规则式总结，不搞鸡汤
- 报告自动存档 `<库>/digest/weekly-<年-周>.md`；快照与 `.weekly-tmp.json` 是生成物，只许重新生成
- `deadlines.sh` brief 新增 `--from N`（只看第 N – N+within 天，逾期项不混入；--from 只对 brief 生效）——board 模式不受影响，原 18 项自检全绿
- 排程：一条**周** rrule（星期几 + 几点用户定，与每日播报的 rrule 分开，不许合并）；INSTALL.md ⑤½ 扩为四连问
- 自检：新增 `selftest_weekly_digest.sh` 17 项（注入式）；`lib_doctor` 覆盖率对照表同步

## 1.15.0 — 2026-09-25 · 播报时间与预习提前量交给用户定

- `daily_digest.sh` 新增 `--preview-ahead N`（预习提前量，讲；默认 1，限 1–10）：预习缺口从只查「下一讲」改为查 taughtUpTo+1 … +N，缺的讲次一次报全；输出标题带上当前提前量（【预习缺口（提前 N 讲）】）
- 播报时间与预习提前量都改为**由使用者自己定**，不许拿默认值替人拍板：
  - INSTALL.md 引导 ⑤½ 改为三连问——要不要开播报 → 每天几点（用户自己说，进 rrule）→ 预习往前看几讲（默认 1，进 `--preview-ahead`）
  - SKILL.md 每日播报段、README 日常用法表同步
- 自检：`selftest_daily_digest.sh` 增至 16 项（提前量 1/2/3 判定 + 非法值拦截）

## 1.14.0 — 2026-09-25 · 每日待办播报（daily_digest.sh）

- 新增 `scripts/daily_digest.sh`（只读）：一条命令输出三块——
  - 【Deadline 临期】内部调 `deadlines.sh brief`（逾期 + N 天内，默认 3）
  - 【复习笔记欠账】已上过（PROGRESS taughtUpTo 内）但无复习笔记的讲次；判定与 lib_doctor coverage 同源（中文数字讲次解析同款）
  - 【预习缺口】下一讲（taughtUpTo+1）无课前预习包的课
- 全齐时明说「今日无学习债」；PROGRESS 未设置/未核对时如实声明，不硬判
- 实现坑：子脚本直接执行会因 exec 位丢失而 Permission denied —— 统一 `bash "$DEADLINES"` 调用；自检两条断言初版写错（期望值与造数据不符、把「无参数=usage」当错误），已修正
- 自检：新增 `selftest_daily_digest.sh` 12 项（注入式）；`lib_doctor` 覆盖率对照表同步
- 文档：SKILL.md 线四 ⑦ 改为每日播报用 daily_digest（一条 rrule 管全部，不许拆两条）；INSTALL.md ⑤½、README 日常用法表同步

## 1.13.0 — 2026-09-25 · Deadline 情报站（D 批）

- 新增 `scripts/deadlines.sh`（只读，全部请求转发 canvas.sh）：
  - `board`：拉全部在读课程作业 → 按紧急度分层（🔴 已逾期未交 / 🟠 24h / 🟡 3 天 / 🔵 7 天 / ⚪ 21 天 / 更远）生成 `<库根目录>/DEADLINES.md` 看板
  - `brief [--within N]`：只打印临期条目（默认 3 天内 + 全部逾期），供每日提醒自动化消费
- 已提交（`include[]=submission` 识别）与无截止日期的作业不进看板，头部如实报数；条目按截止时间排序，逾期条目带逾期天数
- 读取失败可见：WARN + 看板头部「N 门课读取失败，清单可能不全」，绝不冒充「没有 deadline」
- 日期运算全部在 Python 内完成（`datetime.astimezone` 本地时区），不依赖平台 date 语法（Windows 兼容）
- `canvas.sh assignments` 增加 `include[]=submission` 查询参数（仍纯 GET）
- 自检：新增 `selftest_deadlines.sh` 18 项（注入式假 canvas.sh）；`deadlines.sh` 纳入只读静态断言扫描目标；`lib_doctor` 覆盖率对照表同步
- 文档：SKILL.md 线四新增 ⑦（含每日提醒自动化的提示词形状）；INSTALL.md 引导新增 ⑤½（问用户要不要开每日提醒）；README 日常用法表同步

## 1.12.0 — 2026-09-25 · Windows 兼容第二批（W3/W4/W6）

- **W3**：preflight 识别 WSL（Linux 内核 + /proc/version 微软标记）为受支持路径；Git Bash 文案改为「实验性支持（CI 持续验证）」并给出 Git Bash / WSL 两条 Windows 路径。
- **W4**：新增 GitHub Actions 三平台 CI（ubuntu / macos / windows-latest），每次 push 自动跑 preflight + 自检；Windows 跳过依赖 zip 命令的打包器项，其余 6 项用 selftest 多参数并集跑全。
- **W6**：INSTALL.md 环境表更新（bash 终端要求、Python 名字回退、Windows 两条路径）。
- 本提交起，CI 的 windows-latest 就是「适配 Windows」的持续验收标准。

---

## 1.11.0 — 2026-09-25 · Windows 兼容第一批（W1/W2）

- **W1**：仓库加 `.gitattributes` 强制全仓 LF（Windows git 默认 CRLF 会杀死所有 bash 脚本）；README 加平台支持表（macOS ✅ / Linux ✅ / Git Bash 🔶 / WSL 🔶 / 原生 cmd ❌ / 手机 ❌）。
- **W2**：全部 bash 脚本的 Python 调用改为三级回退 `python3 → python → py -3`（Windows 的 Python 不叫 python3）：canvas.sh、canvas_inspect.sh、archive_term.sh、preflight.sh、5 个 selftest 脚本；`$PY` 调用统一不加引号（"py -3" 需拆词）；找不到时报错信息列出试过的三个名字并给 Windows 指引。
- 全量自检 7/7 通过（macOS）；Windows 真机验证由后续 GitHub Actions CI（W4）承担。

---

## 1.10.0 — 2026-09-24 · 安装引导新增「导入已有学习文件」步骤（①½）

- **新增**：安装引导在建库后必问「有没有已整理的学习文件（课件/笔记/录音/题库）想导入」。选没有 → 照旧流程；选有 → 用户点名目录 → agent **只读扫描**出分类清单 → **用户确认后才复制**。
- 写死的安全红线：只碰用户点名的目录、扫描永远先于写入、**只复制不移动不删原件**、同名冲突问用户不许静默覆盖。
- 适配场景：开学数周后才装 skill 的学生，手里的课件和笔记先收编进库，笔记覆盖率判定才有起点。
- 改动文件：`SKILL.md`（引导 ①½ 全流程）、`INSTALL.md`（五步改六步）、`README.md`（安装表同步）。

---

## 1.9.2 — 2026-09-24 · selftest 多参数并集修复（G 批第 3 条）

- **修复**：`selftest.sh terms draw_quiz` 早先多个名字互相覆盖、静默只跑最后一个 —— 「以为跑了两项、实际只跑一项」的假安心。现在多名字 = 并集都跑（去重）；点名了不存在的自检项会明确报错并退出 2，不再吞掉。
- 用法注释同步更新；本条由外部 review（豆包 16 条之 #15 后半）触发。

---

## 1.9.1 — 2026-09-24 · 外部 review 修复批（F 批）

一次外部（另一 AI）review 提了 16 条问题。逐条对代码核真：12 条完全成立、
2 条属设计取舍（保留待议）、1 条半对、1 条不成立。本版修掉其中全部**正确性 bug**，
每条修复都补了对应的注入式自检用例。

### 修复

- `package_skill.sh` —— zip 清单改用 `unzip -Z1` 提取。早先解析 `unzip -l` 的
  日期列，正则写死 macOS 的 MM-DD-YYYY；Linux 输出 YYYY-MM-DD 时文件数恒为 0，
  **整条打包链在 Linux 上必挂**。自检加回归守卫（⑦）。
- `lib_doctor.py` 中文讲次解析 —— 「第二十讲」被逐字加和算成 12（错得像个合法讲次）。
  改为十进制解析：二十→20、二十一→21。顺带修掉 `L04` 与 `L4` 被当成两个讲次的
  前导零问题。自检 ⑭。
- `canvas_inspect.sh` 读取失败可见化 —— 早先 fetch 失败只打一行 stderr，快照里
  静默写空数组：token 中途失效 → 下期报整屏假删除；两头都失败 → 假「无变动」，
  与自己的降级文案矛盾。现在失败记入快照 `fetchErrors`，报告头部明示
  「N 项读取失败，相关删除不可信」，且**有失败时拒绝下「无变动」结论**。自检 ④。
- `canvas_inspect.sh` 跨学期文案矛盾 —— 早先跨学期把上一份快照置 None，
  `first_run` 误判为 True，同一份报告既说「跨学期已跳过对比」又说「首次巡检只建基线」
  （后者是假话）。拆成独立分支。自检 ③。
- `canvas.sh` 分页 —— 跟随 `Link: rel="next"`（上限 25 页），大课（>100 文件/作业）
  不再被静默截断。仍是纯 GET，只读架构不变。
- `preflight.sh` —— ① 缺 node 从 fatal 降为 warn，与文档「只影响抽题器」口径对齐；
  ② 退出码语义修正：缺必需项=1（早先 fatal 全置 2，文档承诺的 1 永远走不到），
  平台不支持=2。selftest.sh 钉住两条回归。
- `lib_doctor.py` 覆盖率递归 —— materials/notes 改用递归扫描，按课程建子目录的库
  不再整门漏判；课程归属按相对路径匹配。自检 ⑯。
- `lib_doctor.py` —— `latest_mtime` 支持单个文件（course-rules.md 早先被当目录传
  os.walk，信号静默永不触发）；删除「孤儿脚本」死代码。自检 ⑮。
- `draw_quiz.js` —— answerIndex 缺失/越界的题从池中剔除并 stderr 告警（早先答案栏
  会打出 `undefined`）；`--n` 非正整数明确报错（早先静默出 0 题空卷）。自检 ⑤⑥。

### 核真后保留原样（外部 review 的其余条目）

- 题库无 term 维度、download 无 URL 校验：属设计取舍，待议。
- selftest filter「拼错不报错」：不实，拼错会 exit 2 明确报错（多参数覆盖属实，
  顺带记录）。横幅 find 定位脆弱：不成立（横幅按定义在文件最顶部，首命中即本身）。
- term 无工具强制：夸大 —— lib_doctor 的 term 检查机械抓三处不一致。

---

## 1.9.0 — 2026-09-24 · 引擎开放修改

### 为什么有这版

v1.8.0 的 INSTALL.md 里有一条硬边界「不许改脚本、不许改目录名」——这与「引擎装到你机器上就归你」的设计意图自相矛盾。这版把限制改成知情约定：**欢迎修改，但改完要跑自检验证**。

### 变更

- `INSTALL.md` 第 4 节从「三条硬边界」改为「修改与升级（欢迎改，但要知道这些）」：
  ① 改完跑 `selftest.sh`，全绿才算改得没破坏保障，建议在 CHANGELOG 留本地记录
  ② 升级覆盖引擎目录会冲掉本地改动，改动多先备份
  ③ Canvas 只读仍是安全架构，开放写操作须用户明确确认
  ④ API 拿不到的信息必须问用户（不变）。
- `README.md` FAQ 新增「可以让 agent 改这个 skill 吗」。

---

## 1.8.0 — 2026-09-24 · agent 自助安装

### 为什么有这版

v1.7.0 的包只有给人看的 README——收到包的用户得自己解压、自己找目录、自己跑脚本。
这版把"安装"变成 agent 能独立完成的事：**用户只需要把 zip 整个丢给任意 agent，
说一句"帮我安装这个 skill"**。

### 新增

- `INSTALL.md` —— 写给**任意 AI agent** 的安装指令：这是什么、环境确认、
  装到哪（目录名不许改）、preflight + selftest 两道闸（有 ❌ 必须停下）、
  装完立刻引导安装五步、安装 agent 自身的三条硬边界、装完怎么验收。

### 文档

- `README.md` 目录结构图中补上 `INSTALL.md`，并注明它的定位（给人看的 vs 给 agent 看的）。

---

## 1.7.0 — 2026-09-24 · 对外发布版

这版只为一个目标：**让别人拿到包就能用**。

### 为什么值得单独发一版

上一版起引擎就是「引擎 + 数据分离」的，但**分享链路没走完**：手工 zip 已经漏过一次文件
（v1.3.1 包比引擎少 7 个文件），新 SKILL.md 会点名这些脚本 —— 对方拿到
「SKILL.md 引用一堆不存在脚本」的包，一上手全是断链，还会以为是自己装错了。

### 新增

- `scripts/package_skill.sh` —— 打包器，五道硬关卡：
  ① 版本号与 CHANGELOG 同步 ② 全量自检（`--no-selftest` 可跳） ③ 隐私扫描
  （源目录 + 从 zip 解出**双查**） ④ SKILL.md 点名的脚本必须存在 ⑤ 文件数与包内清单一致。
  任何一关不过就拒绝打包。
- `scripts/selftest_package_skill.sh` —— 打包器自检（6 个注入用例）：
  干净引擎能出包、隐私注入被拒、版本不同步被拒、断链引用被拒、脚本丢失被拒、
  自检失败不放行。
- `README.md` —— **给拿到包的人看的**（SKILL.md 是给 agent 读的）：
  装到哪、环境要求（Windows 需 WSL）、第一次说什么、要准备什么（token 拿法）、
  拿不到 token 的降级、三条硬边界、自检怎么跑、常见问题。
- 隐私清单分两层：**格式类内置**（课号模式、绝对路径前缀），**个人标识外置**
  到 `~/.workbuddy/study-coach-privacy.txt`（引擎目录之外，永不进包）。
  设计理由：清单里若写着自己的用户名/学校，它随包发出去恰恰是要防的事，
  而且扫描器会扫中自己。

### 修正（示例课号中性化）

引擎里 6 处拿真实课号当例子（`SKILL.md` 的 PROGRESS 示例与举例、`check_terms.py`
用法示例与术语表样例、`archive_term.sh` 注释、`COURSES.template.md`、旧 CHANGELOG 条目）
全部换成 `<课程代码>` 类占位符 —— 对方读到不会再困惑，agent 也不会把它们当成
「用户已有的课」。自检样本里的编造课号同步改为 `DEMO101/102`。

### 教训

- **打包器差点打出一个扫不干净的包**：隐私清单写在引擎里 → 扫描器自命中 →
  要么清单外置、要么永远打不出包。规则「清单不进包」现在由架构保证。
- 本机 BSD grep 不支持 `\b`，数字词边界要手写 `(^|[^0-9])…([^0-9]|$)`。

---

## 1.6.0 — 2026-09-24

**主题：给这套系统装上唯一的时间锚 —— 学期（term）。**

起因是一个具体的隐患：库是平的（`notes/` `materials/` … 直接堆在库根），学期信息此前只
存在于人类可读的引言行里。下学期一到，三门事会同时出事：课程代码复用（`<课程代码>` 再开，
但老师/分值/AI 红线全变，`### <课程代码>` 只能存一份）、课件文件名撞车、**巡检快照只有一份** ——
新学期第一次巡检会跟旧学期快照逐项对比，报出整屏假变动。而「假绿灯」正是本引擎反复
强调最危险的东西。

本版做法是「加标识、不动目录」：目录结构一个没改（所有脚本的路径解析逻辑保持不变），
只把学期变成一个**机器可读且被校验**的字段。

新增

- `scripts/archive_term.sh` —— **学期滚动**。把当学期产物搬进 `<库>/archive/<学期>/`，
  跨学期要复用的（`quiz/` `COURSES.md` `course-rules.md`）只复制一份快照、原地保留，
  然后重建空骨架。安全设计是本脚本的重点，因为它是全套里**唯一动使用者文件**的东西：
  默认只预演、必须 `--yes` 才落地；**从不删除**（归档区已存在就拒绝，不覆盖旧归档）；
  三处 `term` 不一致时拒绝执行；不碰使用者手写的文档正文。归档区留 `ARCHIVE.md`，
  里面写明回退命令（搬回去就是一行 `mv`）。
- `scripts/selftest_archive_term.sh` —— 11 项注入式自检，验的正是上面那些承诺：
  预演绝不落地、归档后文件数只增不减、重复归档/学期对不上/不像库的目录都必须被拒。

改动

- `lib_doctor.py` 从 11 项检查扩到 **12 项**，新增 `term`：校验**三处**学期标识
  （`study-coach.json` / `SYNC-BLOCK` / `PROGRESS`）是否一致，缺失时报「三处都没有学期标识」
  而不是静默通过；并检查最新快照属于哪个学期，跨学期时给出归档指引。
- `canvas_inspect.sh`：快照加上 `term`（快照格式 `version: 2`）；
  **跨学期时不做逐项对比**，报告里明确写「已跳过逐项对比」并指向 `archive_term.sh` ——
  不再伪造 diff，也不写「本次共 0 项变动」这种假绿灯。同学期照旧正常比对（防呆没把主功能关死）。
- `COURSES.template.md`：两个声明块带 `term`，新增「附三：学期标识（term）」讲清学期切换流程。
- `init_library.sh`：建库时一并建 `archive/`，让归档区在第一天就可见。
- `SKILL.md`：第 0 步、安装引导 ①③⑤、库体检、硬红线 ⑦、交付前自检都接入 `term`；
  新增「学期标识（term）」与「学期滚动」两节。
- `lib_doctor.py` 的文档引用检查多一条解析基准：库文档合理地会点名引擎脚本
  （如 `scripts/archive_term.sh`），这类引用现在按**引擎根**解析，不再误报断链。

为什么值得单独发一版：在这之前，「这批资料属于哪个学期」这件事**没有任何机械保障**，
全靠人的记忆和文件命名习惯。规则只靠记性就等于没有 —— 这是 1.5.0 立的规矩，本版继续照做。

---

## 1.5.0 — 2026-09-24

**主题：把「靠自觉的纪律」换成「可验的检查」。** 本版补的都是同一类洞：规则写得很清楚，
但没人验 —— 于是规则只在 Agent 记得的时候存在。

新增

- `scripts/check_terms.py` —— **术语纪律检查器**（硬红线 ⑤ 的机械保障）。三种模式：
  `--check` 核验产物的术语用词、`--audit` 核验术语表里的「原词」在课件/转写里查不查得到、
  `--lint` 体检术语表格式。判定分两级：命中 `avoid` 表的**同义替换**判错、拦交付；
  写法近似的**拼写漂移**只报「疑似」、不拦交付（它会误报，误报的检查器一旦拦交付就会被绕过）。
- `scripts/selftest.sh` —— **自检总入口**。自动发现 `selftest_*.sh` 跑一遍并汇总。
  引擎里每个脚本现在都有对应自检，验的都是「该报的时候会不会报」。
- `scripts/selftest_lib_doctor.sh` / `selftest_draw_quiz.sh` / `selftest_terms.sh` /
  `selftest_canvas_readonly.sh` —— 四项自检。其中 `selftest_canvas_readonly.sh` 把
  **硬红线 ①（Canvas 只读）** 从架构承诺变成静态断言：全盘扫描脚本里有没有写方法。
- `scripts/preflight.sh` —— **环境预检**。先说清这套工具需要 bash + python3(≥3.8) + node(≥18)，
  以及原生 Windows 跑不了（需 WSL）。缺什么、怎么装、能不能跑，一次讲完，
  不再装到一半才炸。
- 本文件。

改动

- `lib_doctor.py` 从 9 项检查扩到 **11 项**，新增：
  - `engine-health` —— 引擎卫生：每个脚本有没有自检覆盖（按**显式对照表**核，不靠「文件里提到过」——
    初版就是那样，结果一个只在注释里被提过一嘴的脚本也被判成「验过了」，我自己的测试正好踩中）、
    **shell 里有没有 `$变量` 紧贴中文**（这个坑在本版开发中连咬两次，且都藏在出错分支里 ——
    平时不跑，一报错就二次崩）、可执行位有没有丢、**SKILL.md 点名的脚本是否真实存在**。
  - `changelog` —— 版本号与 CHANGELOG 是否同步。
- `canvas.sh doctor` 的退出码改成如实反映：
  **凭据不全、网址不通、token 无效、被拒 → 返回非 0**。
  原先这些情况返回 0 并打印「跳过」，会被读成「安装完成」—— 那正是本 Skill 反复强调要避免的假绿灯。
- `init_library.sh` 建库时一并创建空的 `quiz/bank.json` 与 `quiz/terms.json`。
  原先 `COURSES.md` 会引到这两个还不存在的文件，**新库一装出来就是 2 个错误** ——
  会教人从第一天起就学会无视体检报告。
- `SKILL.md` 新增「运行前提 · 先跑环境预检」与「引擎自检」两节；安装引导加 ⓪ 步；
  线一 / 线二 接入术语检查器；硬红线 ⑤ 从「一句话规则」升级为「规则 + 检查器 + 自检」；
  硬红线 ⑦ 补「改版本必须补 CHANGELOG」；兜底表补跨平台与术语表为空两行。

为什么值得单独发一版：这三条（术语纪律、脚本自检、环境前提）此前都**没有任何机械保障**，
全靠 Agent 记得。规则一旦只靠记性，就等于没有。

## 1.4.0 — 2026-09-24

**主题：补上缺掉的那个动作 —— 「库与引擎对齐」。**

新增

- `scripts/lib_doctor.py` —— **库体检**（只读，不改任何文件）。9 项检查：配置与库根目录 ·
  骨架完整性 · 引擎↔库副本一致性（哈希）· 文档引用（断链 / 过期别名）· 课程索引回流 ·
  笔记覆盖率 · 凭据泄漏扫描（硬红线 ②）· AI 横幅状态 · Canvas 接入与巡检状态。

改动

- `COURSES.md` 顶部加 **SYNC-BLOCK**：课程结构类信息（截止日期 / 分值 / AI 政策 / 课程增删）
  一有变化就必须回写并更新 `syncedAt`。没有它，课程索引迟早变成第二个过期倒计时。
- `COURSES.md` 再加 **PROGRESS** 块（本版内追加）：记每门课**已经上到第几讲**。
  起因是一次真实误判 —— 覆盖率检查拿「`materials/` 里有几份课件」当进度，
  把提前上传的下一讲课件算成了「缺笔记」，同时把真正缺的几讲淹掉。
  **课件存在 ≠ 这节课上过。**
- 硬红线加 ⑦「库与引擎不许漂移」；库内同一件事只留一份在用实现（抽题器归一为
  `quiz/draw_quiz.js`，旧版进 `quiz/_archive/`）。

## 1.3.1 — 2026-09-24

修正

- `check_ai_banner.py --scan` 把「无横幅」全部误报成「挂载异常」——
  用 `r["ok"]` 判断状态是错的：无横幅本身不是错，只是状态。
  改为按 `type` 判定，并单独分出 `error` 类。原单文件判定模式回归通过。

## 1.3.0 — 2026-09-24

**主题：横幅分三类。** 起因是测试暴露的漏网 —— 有一门课是「可 AI 构思、不可代写」，
既不是全面禁、也不是允许，旧的两版横幅覆盖不到它，于是**漏挂了**。

新增

- `scripts/check_ai_banner.py` —— 横幅合规检查器（硬红线 ③ 的机械保障），
  含 `--scan <目录>` 批量看状态。
- `scripts/selftest_ai_banner.sh` —— 检查器自检，6 个中性样本，正反各 3 个。
  理由：**别信一个从不报错的检查器。**

改动

- 横幅扩为三版：① 全面禁 AI ② 部分禁（可构思不可代写）③ 政策未确认。
- 明确「挂横幅」的适用范围：**只对「提交物形态」的产物挂**（论文 / 报告正文、示范段落、
  翻译稿、习题解答、展示稿）；复习笔记、题库、术语表、作战计划**不挂**。
  判据一句话：**这段内容有没有可能被直接复制进提交文件。**

## 1.2.0 — 2026-09-24

**主题：拦截权交回使用者。**

改动

- 硬红线 ③ 从「禁 AI 课不给任何可粘贴的英文正文」改为「**代写可以，但必须挂横幅**」。
  代写、翻译、重写都允许，是否使用由使用者自行判断；唯一约束是横幅必须挂到位。
  仍然禁止的只剩一件事：**伪造或代跑查重结果**（那是伪造证据）。
- 自检清单与兜底表同步改措辞。

## 1.1.0 — 2026-09-24

新增

- **线四 · Canvas 巡检**（引擎从三条线变四条线）。
- `scripts/canvas_inspect.sh` —— 巡检引擎：抓快照 + 比对变动（公告 / 课件 / 作业截止日期 /
  模块条目 / 课程增删），全部转发给 `canvas.sh`，自身不发 HTTP。
- 硬红线 ⑥「巡检要先拿到许可」：排程到点**先问再跑**，**沉默不等于同意**。
- 自检清单 +2 项，兜底表 +5 行。

## 1.0.0 — 2026-09-24

首个版本。从「个人版 Skill」重构为**引擎 / 数据分离**的通用形态。

- `SKILL.md`：第 0 步判断装没装 → 首次使用五步引导 → 三条工作线（笔记 / 作业 / 备考）→
  硬红线 ①~⑤ → 交付前自检 → 兜底降级表 → 数据层说明。
- `scripts/canvas.sh` —— **唯一的 Canvas 出口，只实现 HTTP GET**。硬红线 ①（Canvas 只读）
  靠的是这个架构约束，不是提示词里的「请不要提交」。
- `scripts/draw_quiz.js` —— 抽题器，强制打乱选项并重算答案字母。
  起因：源题库 131 题里 93 题答案都在 B 位（71%），直接刷等于练位置记忆，蒙 B 就能拿七成。
- `scripts/init_library.sh` —— 建库骨架，幂等。
- `references/` 与 `templates/` —— 笔记模板、Canvas API 备忘、课程索引与偏好文件模板。
