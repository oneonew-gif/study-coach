# study-coach · 通用 A+ 学习教练

把课件、课堂录音变成复习笔记；辅导作业与论文；抽题刷题备考；定期巡检 Canvas 看课件与截止日期的变动。**所有课程数据存你自己机器上，不经过任何第三方**。

本目录是**引擎**：方法论 + 脚本 + 模板。它不含任何人的课程数据 —— 装好后走一遍安装引导，会生成属于你自己的「资料库」。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| macOS | ✅ 完整支持 | 主开发平台，全功能实测 |
| Linux | ✅ 支持 | 与 macOS 同为 bash + python3 + node 生态（GitHub Actions CI 持续验证） |
| Windows + Git Bash | 🔶 实验性 | 装 [Git for Windows](https://git-scm.com/download/win)（自带 bash）+ Python 3 + Node 18 即可；CI 在 windows-latest 持续验证，遇到问题欢迎提 issue |
| Windows + WSL2 | 🔶 可用 | 在 WSL Ubuntu 里装 python3 + nodejs 后按 Linux 方式使用 |
| Windows 原生（cmd/PowerShell） | ❌ 不支持 | 脚本依赖 bash，请用上面两条路径 |
| iOS / Android | ❌ 不支持 | 需要能跑本地脚本的 agent 宿主，手机上没有 |

> Windows 注意：**必须用 Git Bash 或 WSL** 打开终端跑脚本，不能用 PowerShell/cmd。Python 装成 `python` 也行，脚本会自动回退识别。

---

## 一键安装（macOS / Linux，推荐）

不想看下面两节的话，打开终端粘贴这一行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/oneonew-gif/study-coach/main/install.sh)
```

它会自动完成：下载引擎 → 放进 `~/.workbuddy/skills/study-coach/` → 跑环境预检 → 告诉你下一步对 AI 说什么。

- **已有旧安装会自动备份**为 `study-coach.bak-时间戳`（你的资料库在别处，不受影响）；重跑同一命令 = 升级
- **校验完整性**：发布时会在 CHANGELOG/本仓库贴出当版 `engine.zip` 的 SHA-256，加 `--sha256 <hash>` 校验可防镜像/中间人篡改（例：`bash <(curl -sL ...) --sha256 abc123...`）
- 离线安装 / 指定目录 / 镜像候选等用法见 `install.sh` 头部注释（`--zip`、`--from-dir`、`--dir`）
- Windows 用户用 Git Bash 或 WSL 直接跑本脚本即可，无需另找安装器

---

## 一、装到哪

解压后把整个 `study-coach/` 目录放进：

```
~/.workbuddy/skills/study-coach/
```

装完后目录结构应为：

```
~/.workbuddy/skills/study-coach/
├── README.md          ← 本文件（给你看）
├── INSTALL.md         ← 给 agent 看的安装指令（把包丢给 agent 说"帮我安装"即可）
├── SKILL.md           ← 给 agent 读的引擎说明
├── CHANGELOG.md       ← 版本历史
├── scripts/           ← 全部可执行脚本
├── references/        ← 笔记模板 / Canvas API 说明 / 出题规律模板
└── templates/         ← 建库用的骨架模板
```

装完**先跑自检**（30–60 秒）：

```bash
bash ~/.workbuddy/skills/study-coach/scripts/preflight.sh   # 环境够不够
bash ~/.workbuddy/skills/study-coach/scripts/selftest.sh    # 引擎自身可信吗
```

两个都全绿再往下。`preflight` 会把缺什么、怎么装讲清楚。

---

## 二、环境要求（先看这个）

| 需要 | 说明 |
|---|---|
| macOS 或 Linux | **原生 Windows 跑不了**（脚本是 bash 的）。装 WSL 后在 WSL 里用；Git Bash 部分可用但不保证 |
| bash ≥ 3.2 | macOS / Linux 自带 |
| python3 ≥ 3.8 | macOS 自带；Windows WSL 里 `sudo apt install python3` |
| node ≥ 18 | 只影响抽题器；没有时其余功能照常 |
| 能访问你们学校的 Canvas | 只在接 Canvas 时需要 |

---

## 三、第一次怎么用

装好后，对这个 agent 说：

> 用 study-coach 帮我学习。我还没装过，先走安装引导。

Agent 会带你走这六步（细节都在 SKILL.md 里，你不用背）：

| 步骤 | 谁动手 |
|---|---|
| ① 建资料库（问你放哪，建议 `~/WorkBuddy/study-library`） | agent 跑 `init_library.sh` |
| ①½ 问你有没有已整理的学习文件（课件/笔记/录音/题库）要导入 | 有 → 你指定文件夹，agent 只读扫描、给你确认清单后才复制（原件不动）；没有 → 跳过 |
| ② 接 Canvas（可选，但强烈建议） | **你自己**去拿 token（见下） |
| ③ 拉课程 → 生成课程索引 | agent |
| ④ 问你这学期几门课、AI 政策 | **你回答**（API 拿不到，必须人告诉） |
| ⑤ 验收（`canvas.sh doctor` 应打印你的名字） | agent |

**安装引导会生成**：

- `~/.workbuddy/study-coach.json` —— 配置指针（库在哪、Canvas 域名、当前学期）
- `~/WorkBuddy/study-library/`（或你指定的路径）—— 你的资料库，以后所有笔记/题库/巡检快照都在这

### 你要准备的四样东西

1. **Canvas token**（可选，但接了才能自动巡检课件和截止日期）：
   - 浏览器登录你们学校的 Canvas
   - 左上角头像 → **Account** → **Settings**
   - 往下滚到 **Approved Integrations** → **+ New Access Token**
   - 名字随便填（例如 `study-coach`），点 **Generate Token**
   - **token 只显示这一次，立刻复制**，离开页面就再也看不到
   - 拿到后贴给 agent，它会存到 `~/.workbuddy/.canvas-token`（权限 600，不进资料库、不进任何备份）
   - ⚠️ token = 你 Canvas 账号的权限。别截图发人、别贴进聊天记录
2. **这学期修哪几门课**（课程代码 + 名称）
3. **你们学校怎么称呼这个学期**（如 "2026-27 Semester A"）
4. **每门课允不允许用 AI、允许到什么程度** —— 问老师或看课程大纲。**agent 不会替你猜这个**

### 没拿到 token 也能用

agent 会走「手动流派」：你自己从 Canvas 下载课件放进 `materials/`，其余功能照常。**不要因为没有 token 就放弃** —— 这套的大头（笔记、作业辅导、抽题）都在库内，不依赖 Canvas。

---

## 四、这东西的三条硬边界

1. **Canvas 只读**：所有 Canvas 请求都走 `scripts/canvas.sh`，它只实现了 HTTP GET。**它无法提交作业、发帖、改成绩** —— 这是架构保证的，不是提示词承诺。有一个自检脚本会持续断言这件事（`selftest_canvas_readonly.sh`）。
2. **禁 AI 课不代写**：课程政策禁止或不明时，产出会挂明确的横幅标明「本课禁止/疑似禁止 AI 代写」，**不给你可粘贴的正文**。每门课的政策存在你的库里，由你确认。
3. **API 拿不到的信息必须问人**：AI 政策、评分权重细则、上课进度。agent 宁可标「待补充」也不编。

---

## 五、日常怎么说

| 你说 | 它做什么 |
|---|---|
| 「出 SS 前缀某课 第 N 讲的复习笔记」 | 结合课件 + 录音转写生成结构化笔记（默认中英双版） |
| 「帮我做 XX 作业」 | 出作战包：审题 → 提纲 → 资料定位 → 检查清单 |
| 「考我 <课程代码>」/「从题库抽 10 题」 | 抽题、逐题问、记错题 |
| 「巡检」/「这周 Canvas 有什么变化」 | 抓快照对比，出变动报告 |
| 「最近有什么要交」/「deadline」 | 生成紧急度分层的 DEADLINES.md 看板；也可让 agent 建每日提醒自动化，到点播报临期作业 |
| 「导出日历」 | 把未交作业导出成 deadline.ics（含提前 1 天 + 1 小时双层提醒），双击导入 Apple / Google Calendar——WorkBuddy 没开也有系统弹窗；重跑覆盖不重复导入 |
| 「开每日待办播报」 | 每天 1 条汇总：Deadline 临期 + 复习笔记欠账 + 预习缺口（`daily_digest.sh`，判定跟 PROGRESS 走）；几点播报、预习提前几讲都由你自己定 |
| 「开每周复盘」 | 每周 1 条趋势：本周产出 + 学习债涨消 + Deadline 未来一周 + 下周预告 + 总评（`weekly_digest.sh`，报告存档在 `digest/`） |
| 「我想背单词」「考我单词」 | 背课程里的活词：出笔记时收词、术语表导入、手动加词（`vocab.sh`，莱特纳 5 盒，越不熟越常出现）；建议单开一个对话窗口背，词库状态不丢 |
| 「考我第 5 讲的单词」/「最近三讲的词快刷一遍」 | 按讲次抽词（`--lecture N` / `--recent N`），复习前先过一遍本讲词汇；每份复习笔记末尾自带「背单词」模块表 |
| 「库体检」/「检查一下库」 | 跑 12 项体检，看库与引擎有没有漂移 |
| 「学期结束了」 | 归档当学期，库根清空准备新学期 |

**笔记跟着课程时间走**：课件提前传到 Canvas 不等于这节课上过。库里有个 `PROGRESS` 块记着每门课「上到第几讲」——上完新课要更新它，agent 才能分清「缺笔记」和「课还没上」。

---

## 六、给对方的自检

这个包自带一套「验证工具本身」的机制，你可以不信任我们的说明，自己验：

```bash
bash ~/.workbuddy/skills/study-coach/scripts/selftest.sh
```

它跑全部注入式自检，验的是「**该报错的会不会报错**」，不是「跑不崩」：

| 自检 | 验什么 |
|---|---|
| `ai_banner` | 横幅检查器正向必过、反向必须报错 |
| `terms` | 术语检查器该报的报、干净文档不误报 |
| `lib_doctor` | 库体检器：干净新库不报错 + 注入的病全被抓到 |
| `draw_quiz` | 抽题器同 seed 可复现、选项真的打乱、答案集齐 |
| `canvas_readonly` | 全盘扫写方法断言为零；没凭据时确实报错（不出假绿灯） |
| `archive_term` | 学期归档脚本预演不动文件、不删除任何东西 |
| `package_skill` | 打包器带隐私要拒绝、清单不齐要拒绝 |
| `daily_digest` | 每日待办播报三块输出、预习提前量边界 |
| `deadlines` | Deadline 看板分层、ics 导出与拒绝生成红线 |
| `vocab` | 背词教练收词/分盒/讲次抽词、空库不编词 |
| `weekly_digest` | 每周复盘五块输出、学习债趋势比对 |
| `install` | 一键安装器落位、备份、坏 zip 拒装（注入式不联网） |

> 自检项由 `selftest.sh` 自动发现 `scripts/selftest_*.sh`，数量随版本增长，以实际输出为准。

**任何一个 ❌ 都说明引擎不可信，先修再用。**

---

## 七、常见问题

**Q：我学校不用 Canvas（用 Moodle / Blackboard）？**
只能走「手动流派」，自动巡检不可用。其余（笔记/作业/抽题）完全正常 —— 它们只依赖你放进资料库的文件。这套脚本目前没写 Moodle 适配器。

**Q：跑自检报 `python3 太旧`？**
装新版 python3 再跑。体检/检查器需要 ≥3.8。

**Q：装完跟 agent 说话，它没反应？**
确认装到 `~/.workbuddy/skills/study-coach/`（目录名别改，SKILL.md 里的脚本路径依赖这个名字）。确认 `SKILL.md` 存在且没改名。

**Q：想升级引擎？**
用新包覆盖 `~/.workbuddy/skills/study-coach/`，跑 `selftest.sh` 全绿即可。**你的课程数据在资料库里，不在引擎目录**，覆盖不丢。升级后跑一次 `lib_doctor.py` 确认库跟得上。

**Q：可以让 agent 改这个 skill 吗？**
可以，引擎装到你机器上就归你——改脚本、调流程、适配自己的平台都行。改完跑 `selftest.sh`，全绿说明没破坏内置保障。注意：升级覆盖引擎目录会冲掉本地改动，改动多的话先备份。

**Q：怎么知道手上是哪一版？**
```bash
head -6 ~/.workbuddy/skills/study-coach/SKILL.md     # 看 version
cat ~/.workbuddy/skills/study-coach/CHANGELOG.md     # 看改过什么
```

**Q：这个 skill 收集我的数据吗？**
不。所有数据都在你自己的机器：配置 `~/.workbuddy/study-coach.json`、token `~/.workbuddy/.canvas-token`（600）、资料库你自己选的路径。脚本不联网上传任何东西（除 Canvas 只读 API）。

---

## 八、版本

看 `CHANGELOG.md`。当前版本以 `SKILL.md` 第 5 行 `version:` 为准。
