# INSTALL.md · 给任意 AI Agent 的安装指令

> **如果你是正在读这段话的 AI agent**：用户把本压缩包发给你，并要求"帮我安装这个 skill"。
> 请完整读完本文件再动手。整个过程不需要用户懂命令行——步骤 2 起由你执行。
>
> 本 Skill 的默认路径与工具面向 WorkBuddy 平台（`~/.workbuddy/`、`present_files`、`rrule` 自动化）。若你在其他平台运行，路径请替换为该平台的等价位置，`present_files` 用该平台的文件预览/附件功能代替。

---

## 0. 你拿到的是什么

**study-coach · 通用 A+ 学习教练**：把课件与课堂录音变成结构化复习笔记、辅导作业与论文、抽题刷题备考、定期巡检 Canvas 课件与截止日期变动。

它采用**引擎 + 数据分离**设计：

- 本压缩包 = **引擎**（方法论 + 脚本 + 模板），不含任何人的课程数据；
- 装好后走一遍**安装引导**（见第 3 步），在用户机器上生成属于用户自己的「资料库」；
- 你在安装阶段**不需要**用户提供任何课程信息，也不要替用户编造。

---

## 1. 确认环境（30 秒）

**必须在 bash 里跑本流程**：macOS/Linux 自带；Windows 用 Git Bash（Git for Windows 自带）或 WSL，**不能用 PowerShell / cmd**。

| 要求 | 不满足时 |
|---|---|
| macOS / Linux / Windows(Git Bash 或 WSL) | 原生 Windows（cmd/PowerShell）不支持，先装 Git for Windows 或 WSL |
| bash ≥ 3.2 | macOS/Linux/Git Bash 自带，一般无需处理 |
| Python 3.8+（`python3`、`python` 或 `py -3` 任一） | 缺了**全部功能停摆**；Windows 去 python.org 装，装完重开终端 |
| node ≥ 18 | 只影响抽题器；没有就告知"抽题不可用，其余照常" |

> Windows 提示：脚本会自动识别 `python` / `py -3` 等名字，无需改名。Git Bash 路径为实验性支持（CI 持续验证），遇到问题可换 WSL。

---

## 2. 安装（由你执行）

1. 把压缩包解压，得到 `study-coach/` 目录。
   （偷懒做法：不解压，直接跑 `bash <install.sh路径> --zip <zip路径>`——一步完成解压、改名、落位、备份旧版。）
2. 把整个目录放到该 agent 平台加载 skill 的位置。**目录名必须保持 `study-coach`，不要改名**——SKILL.md 里的脚本路径依赖这个名字。
   - WorkBuddy / 本仓库约定的位置：`~/.workbuddy/skills/study-coach/`
   - 其他平台：放到该平台等价的用户级 skills 目录，规则同上。
3. 确认 `SKILL.md` 存在于该目录根部（`head -6 SKILL.md` 应能看到 `name: study-coach` 和 `version:`）。
4. 依次跑两个检查，**任何输出含 ❌ 就停下如实报告，不要带病交付**：

```bash
bash ~/.workbuddy/skills/study-coach/scripts/preflight.sh   # 环境预检
bash ~/.workbuddy/skills/study-coach/scripts/selftest.sh    # 引擎自检（自动发现全部 selftest_*.sh，1–2 分钟）
```

（若你所在平台 skills 目录不同，把路径换成实际安装路径。）

---

## 3. 安装引导（装完立刻做）

对用户说：安装完成，然后引导用户对你说出这句话并照 SKILL.md 执行：

> **用 study-coach 帮我学习，我还没装过，先走安装引导。**

引导六步（细节以 SKILL.md 为准，你执行）：

| 步骤 | 谁动手 |
|---|---|
| ① 建资料库（问用户放哪，建议 `~/WorkBuddy/study-library`） | 你跑 `scripts/init_library.sh` |
| ①½ 导入已有学习文件：**必问**「有没有已整理的课件/笔记/录音/题库想导入？」 | 没有就直接进 ②；有则按 SKILL.md ①½ 的对话流——用户点名目录 → 只读扫描出清单 → 用户确认后才复制（**只复制不移动不删原件**）→ `lib_doctor.py` 体检 |
| ② 接 Canvas（可选，强烈建议） | **用户自己**去拿 token，你只提供指引（README.md 第三节有完整拿法） |
| ③ 拉课程 → 生成课程索引 | 你 |
| ④ 问用户：这学期几门课、每门课的 AI 政策 | **用户回答**——API 拿不到，你**不许猜、不许编** |
| ⑤ 验收：`scripts/canvas.sh doctor` 应打印用户名字（没 token 则确认手动流派可用） | 你 |
| ⑤½ 问用户六连：①「要不要开每日待办播报？」②要开 → 「每天几点提醒？」（几点由用户自己说，不许拿默认值替人拍板）③「预习往前看几讲？」（默认 1，用户说了算）④「要不要开每周复盘？」（要 → 问星期几 + 几点，建**一条**周 rrule，提示词写「跑 `scripts/weekly_digest.sh`，原样转述输出」）⑤「提醒末尾要带背单词引导吗？」（要 → 配置 `vocab.hint: true`，梗词排班默认即可）⑥「要不要把临期作业导一份进系统日历？」（要 → 跑 `scripts/deadlines.sh ics`，把 deadline.ics 用 present_files 给用户双击导入日历 App，当场完成第一次导出）。每日播报建一条 rrule（时间用用户说的那个，`--preview-ahead N` 进提示词），「没有待办也如实说，一个字不要编」。都不要 → 跳过 | 你建自动化；时间、预习提前量都由用户定 |

用户没拿到 Canvas token 也能用：走「手动流派」，用户自行把课件放进 `materials/`，笔记/作业/抽题全部照常。

---

## 4. 修改与升级（欢迎改，但要知道这些）

本引擎**欢迎修改**：用户可以让自己的 agent 改脚本、调流程、适配自己的平台——这正是「引擎 + 数据分离」的设计意图，引擎装到对方机器上就归对方所有。动手前让用户（和改动的 agent）知道四件事：

1. **改完跑自检**：`scripts/selftest.sh` 全绿说明改动没破坏内置保障；有 ❌ 就先修好或回滚再用。建议顺手在 `CHANGELOG.md` 顶部加一行本地记录，日后升级时好对照。
2. **升级会覆盖引擎目录**：用新包覆盖时，用户数据（资料库）不受影响，但**本地改过的脚本会被冲掉**——改动多的话先备份或留存 diff。
3. **Canvas 只读是安全架构**：`scripts/canvas.sh` 只实现了 GET。如果用户要求开放写操作（提交作业等），先把风险讲清楚、拿到用户明确确认再动，不要默认去改。
4. **API 拿不到的信息（AI 政策、评分细则、上课进度）必须问用户**，宁可标"待补充"也不编。

---

## 5. 装完怎么验证成功了

- `selftest.sh` 输出**全部通过**（数量随版本变化，以实际输出为准）；
- 安装引导走完，`~/.workbuddy/study-coach.json` 已生成、资料库目录存在；
- 用户说「库体检」时 `scripts/lib_doctor.py` 报告 0 错误（新库可能有 1–2 条"等你确认进度"的提醒，属正常）。

---

*本文件面向安装时的 agent。给人看的说明（环境、token 拿法、日常用法、FAQ）在 `README.md`；给 agent 的长期工作指令在 `SKILL.md`。版本看 `SKILL.md` 头部 `version:`，变更史看 `CHANGELOG.md`。*
