# Canvas 只读接入指引

供「首次使用 · 安装引导」的 ②③ 步使用。**本文写给使用者看**，Agent 可以按需原文转述。

---

## 一、为什么不装 MCP，而是直接调 API

装 MCP 服务器要多一个第三方依赖、挑 Node 版本、还要在客户端点「信任」。本 Skill 改成一个脚本直接调 Canvas REST API —— 少一层依赖，也少一层权限面。

代价是「只读」不再由别人保证。所以本 Skill 自带 `scripts/canvas.sh`，它**只实现 HTTP GET**，是通往 Canvas 的唯一出口。这是刻意的架构约束：**脚本里没有 POST，就不可能误交作业。**

---

## 二、拿 token（这一步只能你自己做）

1. 浏览器登录你们学校的 Canvas
2. 点左上角头像 → **Account** → **Settings**
3. 页面往下滚，找到 **Approved Integrations**，点 **+ New Access Token**
4. 名字随便填（例如 `study-coach`），过期时间可留空，点 **Generate Token**
5. **token 只显示这一次**，立刻复制。离开页面就再也看不到了

### ⚠️ 三件必须知道的事

1. **token 等于你 Canvas 账号的权限。** 别截图发给任何人，别贴进聊天记录或文档。
2. **它存在 `~/.workbuddy/.canvas-token`（权限 600），不在资料库里。** 所以你的资料库可以随便备份、打包、发给同学，不会跟着泄漏凭据。
3. **如果看不到 `+ New Access Token` 选项** —— 说明你们学校禁用了个人 token。这不是你做错了什么，也不用折腾。**直接走「手动流派」**：自己从 Canvas 下载课件放进 `materials/`，其余流程完全照常，只是少了自动取数。

---

## 三、写入凭据

⚠️ **不要把 token 直接敲进命令行**——那会让它明文出现在 shell 历史里。用下面这条（输入不显示，写完回车）：

```bash
~/.workbuddy/skills/study-coach/bin/sc token      # 推荐：所有平台通用（Windows：bin\sc.cmd token），不回显、去掉 \r
# 或：
read -s -p '粘贴 Canvas token，回车确认（输入不显示）：' t && printf '%s' "$t" > ~/.workbuddy/.canvas-token && unset t
chmod 600 ~/.workbuddy/.canvas-token
```

如果你确实用 `printf '%s' '...'` 直接写，执行前先关历史：`unset HISTFILE`（或命令前加一个空格，前提是 `HISTCONTROL=ignorespace`）。

再把学校网址填进 `~/.workbuddy/study-coach.json`：

```jsonc
{
  "library": "/绝对路径/到你的资料库",
  "canvas": { "baseUrl": "https://canvas.yourschool.edu" }
}
```

**网址格式**：只写到域名。以下都是错的：

| 写法 | 问题 |
|---|---|
| `https://canvas.yourschool.edu/` | 结尾多余的斜杠（脚本会容错，但别写） |
| `https://canvas.yourschool.edu/api/v1` | **多了 `/api/v1`** —— 脚本会剥掉，但别依赖这个容错 |
| `canvas.yourschool.edu` | 少了 `https://` |
| `https://canvas.yourschool.edu/courses/12345` | 带上了课程路径 |

---

## 四、验收

```bash
~/.workbuddy/skills/study-coach/bin/sc canvas doctor     # = scripts/canvas.sh doctor
```

看到 `✓ 已连上：<你的名字>` 就是通了。

---

## 五、可用命令（全部是 GET）

| 命令 | 拿到什么 |
|---|---|
| `canvas.sh doctor` | 自检：凭据、权限、连通性 |
| `canvas.sh self` | 当前用户信息 |
| `canvas.sh courses` | 在读课程列表（含 course_id） |
| `canvas.sh assignments <course_id>` | 作业与截止日期 |
| `canvas.sh syllabus <course_id>` | 该课 syllabus |
| `canvas.sh modules <course_id>` | 模块与条目 |
| `canvas.sh announcements <course_id>` | 公告 |
| `canvas.sh files <course_id>` | 文件列表（含可下载 URL） |
| `canvas.sh page <course_id> <url>` | 某个页面 |
| `canvas.sh download <url> <路径>` | 下载课程文件（仍是 GET） |
| `canvas.sh raw <path>` | 任意其他只读路径 |

对应 Canvas REST API：`/api/v1/courses`、`/courses/:id/assignments`、`/courses/:id?include[]=syllabus`、`/courses/:id/modules`、`/courses/:id/files`、`/users/self`。官方文档：https://developerdocs.instructure.com/

---

## 六、报错对照

| 现象 | 含义 | 怎么办 |
|---|---|---|
| `000` / 请求发不出去 | 域名写错或网络不通 | 检查 `baseUrl`，浏览器能不能打开这个地址 |
| `401 Unauthorized` | token 无效或已过期 | 重新生成一个，覆盖 `.canvas-token` |
| `403 Forbidden` | 有权限问题 | 学生账号读 `files` 被拒是**常见情况**（取决于学校设置），**不代表 token 坏了**。走手动下载 |
| `404 Not Found` | `course_id` 写错 | 重跑 `canvas.sh courses` 核对 id |
| `429 Too Many Requests` | 被限流 | 等 30 秒到 1 分钟；减少查询范围，加 `per_page` 限制 |
| 下载出来是空文件 | 预签名 URL 过期 | 重跑 `canvas.sh files` 取一个新的 URL |

**已知限制**：部分学校的 Canvas 只允许 API 读一部分资源；quiz 相关接口通常只支持 Classic Quizzes，不支持 New Quizzes。对本流程影响不大 —— 题库是自建的，不从 Canvas 拉。

---

## 七、隐私与合规

- 只读自己的课程数据，不碰其他学生
- 下载内容只存本地，仅供学习参考
- **不要**用 API 提交作业、发帖、改设置、动小组 —— 脚本层面做不到，也请不要绕过脚本去试
- 部分院校对 API 访问有额外规定，接入前可留意学校 IT 政策
