---
name: lark-video2note
version: 1.0.0
description: "把抖音 / 哔哩哔哩 / 小红书 / YouTube 等平台的视频或音频链接，转成飞书妙记 + 飞书文档归档。当用户**明确要求**把视频转成笔记 / 文稿 / 总结 / 逐字稿 / 归档 / 留档，或显式使用 /video2note 时使用。替代 Get 笔记的能力。⚠️ 仅看到 URL 而无明确意图时，先按全局 CLAUDE.md「URL 链接处理」规则做 triage，不要直接触发本 skill。"
metadata:
  requires:
    bins: ["lark-cli", "curl", "python3"]
---

# 视频链接 → 飞书妙记 + 飞书文档

> **前置条件**：先读 [`../lark-shared/SKILL.md`](../lark-shared/SKILL.md)。
> 已经登录过 lark-cli，且 scope 至少包含：
> `drive:drive`、`docs:document`、`minutes:minutes:readonly`、`minutes:minutes.artifacts:read`、`minutes:minutes.transcript:export`。
> 缺 scope 时按 lark-shared 的提示让用户授权后再继续。

## 触发场景

仅在以下两种情况触发本 skill：

1. **用户明确表达要把视频转成笔记**：消息里包含视频 URL（或分享口令，如「2.33 复制打开抖音…https://v.douyin.com/xxx/」）**且**伴随明确动词——"转成笔记"、"留档"、"归档"、"整理这个视频"、"转成逐字稿/文稿"、"沉淀一下"、"帮我看里面讲了啥" 等
2. **显式触发**：用户使用 `/video2note <url>` 或 `$video2note <url>`

⚠️ **仅看到 URL 而无明确意图时不要触发**。按全局 CLAUDE.md「URL 链接处理」规则先做 triage——看一眼是什么内容，问用户想做什么，再决定是否调用本 skill。

## 配置

skill 的归档目标飞书云盘文件夹 token 存在 `config.json` 里（首次使用前请运行 `bash scripts/setup.sh`）。

Step 0 时务必先读取：

```bash
SKILL_ROOT=~/.claude/skills/lark-video2note
[ -f "$SKILL_ROOT/config.json" ] || { echo "缺少 config.json，请先跑 bash $SKILL_ROOT/scripts/setup.sh" >&2; exit 1; }
FOLDER_TOKEN=$(python3 -c "import json;print(json.load(open('$SKILL_ROOT/config.json'))['folder_token'])")
```

之后所有 `lark-cli drive +upload --folder-token` 和 `lark-cli docs +create --parent-token` 都用 `$FOLDER_TOKEN` 而不是写死的字符串。

- 工作目录：`/tmp/video2note/<timestamp>/`（每次新建，跑完保留 mp4 直到归档完成）

## 工具

| 平台 | 下载方式 | 逐字稿来源 |
|------|---------|------------|
| 抖音 | `iesdouyin.com/share/video/<id>/` 解析 `play_addr` | 妙记 ASR |
| B站 | `yt-dlp` | **优先平台字幕**（默认带 Chrome cookies，B站字幕需登录态）→ 妙记兜底 |
| YouTube | `yt-dlp` | **优先 auto-captions**（默认带 Chrome cookies）→ 妙记兜底 |
| 小红书 | `yt-dlp --cookies-from-browser chrome` | 妙记 ASR |

**两个核心脚本**：

`scripts/download.sh`：下载视频 mp4。输入 URL + 输出目录，输出一行 JSON：
```json
{"file":"...","title":"...","platform":"douyin","author":"...","duration_s":485,"source_url":"...","size_bytes":...}
```

`scripts/get-captions.sh`：尝试从 B站 / YouTube 抓现成字幕。成功输出：
```json
{"transcript_file":"$WORK/transcript.txt","language":"zh-CN","lines":243}
```
失败 exit 1（适用任何没字幕的视频或非 B站/YT 平台）。

## 流程

```bash
# Step 0: 加载配置 + 准备工作目录
SKILL_ROOT=~/.claude/skills/lark-video2note
[ -f "$SKILL_ROOT/config.json" ] || {
  echo "❌ 缺少 config.json，请先运行：bash $SKILL_ROOT/scripts/setup.sh" >&2; exit 1;
}
FOLDER_TOKEN=$(python3 -c "import json;print(json.load(open('$SKILL_ROOT/config.json'))['folder_token'])")
TS=$(date +%s)
WORK="/tmp/video2note/$TS"
mkdir -p "$WORK"

# Step 1: 下载视频（自动识别平台）
# 关键：捕获 exit code
set +e
META=$(bash ~/.claude/skills/lark-video2note/scripts/download.sh "<URL_OR_SHARE_TEXT>" "$WORK" 2>"$WORK/.dl-err")
DL_EXIT=$?
set -e

# Exit code 2 = "这不是视频"。立即停止本 skill 流程，路由到 defuddle
if [ $DL_EXIT -eq 2 ]; then
  # 把 .dl-err 里 NOT_A_VIDEO 那段原样转给用户，并主动建议改走 defuddle
  # 不要继续 Step 2-4，不要上传、不要建妙记、不要建 docx
  cat "$WORK/.dl-err" >&2
  # 然后用 defuddle 抓那条 URL 的文本内容，按用户原意做总结/归档
  exit 0
fi

# 其它非零 exit 是真失败（网络/cookies/格式），按"失败回退"小节处理
[ $DL_EXIT -ne 0 ] && { cat "$WORK/.dl-err" >&2; exit $DL_EXIT; }

# 解析 META：file / title / platform / author / duration_s / source_url

# Step 2: 拿逐字稿 —— 先试平台字幕，没有再走妙记
# 关键判断：抖音 / 小红书直接跳过，进 Step 2b。B站 / YouTube 先试 Step 2a
PLATFORM=$(echo "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin)["platform"])')

# Step 2a: 尝试平台字幕（仅 B站 / YouTube 有意义）
TRANSCRIPT_FILE=""
MINUTE_URL=""
if [ "$PLATFORM" = "bilibili" ] || [ "$PLATFORM" = "youtube" ]; then
  if CAPTIONS=$(bash ~/.claude/skills/lark-video2note/scripts/get-captions.sh "<URL>" "$WORK" 2>/dev/null); then
    TRANSCRIPT_FILE=$(echo "$CAPTIONS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["transcript_file"])')
    # 拿到字幕 → 跳过妙记，直奔 Step 3
  fi
fi

# Step 2b: 没拿到字幕 → 走完整妙记 ASR 流程（上传云盘 → 生成妙记 → 拉产物）
if [ -z "$TRANSCRIPT_FILE" ]; then
  # 2b-i: 上传到飞书云盘 视频笔记 文件夹
  # 注意：drive +upload 要求 --file 是相对于 CWD 的相对路径
  cd "$WORK"
  FILE_BASENAME=$(basename "$(echo "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin)["file"])')")
  TITLE=$(echo "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"])')
  lark-cli drive +upload \
    --file "./$FILE_BASENAME" \
    --folder-token $FOLDER_TOKEN \
    --name "$TITLE.mp4"
  # → 记录 data.file_token 为 FILE_TOKEN

  # 2b-ii: 生成妙记（异步）
  lark-cli minutes +upload --file-token "$FILE_TOKEN"
  # → 返回 data.minute_url；从 URL 末段取 minute_token

  # 2b-iii: 等妙记跑完，拉逐字稿 + AI 总结
  # 等待时间随视频时长自适应：
  #   ≤ 10 分钟视频：首次 sleep 90s，最多 5 次重试 × 30s
  #   10-30 分钟视频：首次 sleep 240s，最多 10 次重试 × 60s
  #   > 30 分钟视频：首次 sleep 480s，最多 20 次重试 × 60s（最长 ~28 分钟）
  # 长视频期间可以用 lark-cli minutes minutes get --minute-token <token> 看进度
  lark-cli vc +notes --minute-tokens "$MINUTE_TOKEN"
  # → data.notes[0].artifacts.transcript_file 是本地逐字稿路径
  # → AI summary 字段忽略（我们自己写更密的）
  TRANSCRIPT_FILE="$WORK/minutes/$MINUTE_TOKEN/transcript.txt"
fi

# 走到这里：TRANSCRIPT_FILE 一定有了
# 字幕路径下 MINUTE_URL 为空，文档里就不写「飞书妙记」那一行
# 妙记路径下 MINUTE_URL 写到元信息 callout 里

# Step 3: 由你（Claude）基于逐字稿撰写结构化文档，并落成飞书 docx
# 重要：即使有妙记 summary 也不要直接用，那个总结太瘦
# 用下方「文档结构」模板，自己读完逐字稿写一版密度更高的版本
# 把内容写进 note.xml（CWD 必须是 $WORK）

# 3a. 短视频（XML < 40KB，对应大约 ≤ 20 分钟内容）— 一次性创建
cd "$WORK"
# ... 写入 note.xml（见下方模板）...
lark-cli docs +create \
  --api-version v2 \
  --parent-token $FOLDER_TOKEN \
  --content @./note.xml
# 注意：v2 用 --content（不是 --markdown）和 --parent-token（不是 --folder-token）
# --content 支持 @file，但 file 必须是 CWD 相对路径
# 文档默认 XML 格式，标题从 <title> 自动提取，不要传 --title
# → 返回 data.document.url

# 3b. 长视频（XML ≥ 40KB，对应大约 > 20 分钟内容）— 骨架 + 分段追加
# 长内容一次性 POST 容易超字数限制或被截。建议拆 3 段：
#   ① 创建骨架：标题 + 元信息 callout + 执行摘要 + 核心论点 + 占位 heading
#   ② 用 docs +update --command append 追加：完整论证链路 + Demo + 名词解释 + 金句
#   ③ 再 append：逐字稿章节
# 例：
#   lark-cli docs +update --api-version v2 --doc <url_or_token> \
#       --mode append --content @./part2.xml
# 写入前用 wc -c note.xml 看大小，> 40KB 走 3b
# 参考：飞书 docs v2 推荐"先建骨架再 append"，详见 lark-doc skill

# Step 4: 给用户回结果
# 输出 docx URL（绝对路径形式，方便 ⌘+Click）
# 如果走的是妙记路径，附带妙记 URL；走字幕路径则不提
```

### 文档结构（11 大块，固定顺序）

使用飞书 docx XML 格式（不要用 markdown，markdown 不支持 callout）。
模板和示例见 [`references/doc-template.xml`](references/doc-template.xml)。

```
1. <title>{视频标题}</title>
2. 📍 来源信息 callout（light-blue）— 平台/作者/时长/原视频/妙记/归档日期
3. ✨ 执行摘要 callout（light-yellow）— 一段话讲清作者真正想说什么，3-5 行
4. 🎯 核心论点 — 一句话立场
5. 🧭 完整论证链路 — 按视频推进逻辑切 4-6 个 h2 小节，每节用「叙述段落 + 必要时穿插 bullet」的方式写
6. 🎬 Demo 实操（如视频里有 demo）— 几段叙述讲清楚步骤
7. 📚 名词解释 — 只解释 2-4 个真正生僻的（如 Ontology、FDE、AIP），用大白话 + 类比
8. 💬 金句原文 callout（light-gray）— 最多 3 句
9. 📜 逐字稿 callout 头（medium-gray）+ 章节列表说明
10. h2 章节标题 + blockquote 引用块装原文（按 5-7 个主题切分，每个标题带 emoji + 时间戳）
```

### 撰写要求（基于真实使用反馈）

**叙述优先，bullet 谨慎**：完整论证链路和 Demo 部分主要用段落，不要无脑列 bullet。bullet 只在以下情况用：
- 真正是并列的清单（如三家产品对比、几个数字统计）
- 步骤型分解（但每条要写完整句子）

bullet 之间一定要有衔接句，避免读者跳着扫一遍只看到散点。

**名词解释要"看了能懂"**：
- 只解释非通用术语，跳过 CLI / PR / star / SKU / ROI 这种业内常识
- 用大白话 + 实例/类比，不要照搬词典定义
- 举例：解释 Ontology 时类比"传统数据库像字典只能查，Ontology 像说明书能让人照着改"

**金句压到 3 句以内**：选「能代表作者核心立场 / 最有传播性 / 最锐利」的，宁缺毋滥。

**口误修正**：在名词解释或行文里温和指出明显口误（如视频里说"Clang code"实指"Claude Code"），但不要在逐字稿原文里改动。

**配色规范**（callout 用）：
- `light-blue` 元信息 · `light-yellow` 摘要/重点 · `light-red` 关键问题/警示
- `light-purple` 理论/定义 · `light-green` Demo 上下文 · `light-gray` 引语
- `medium-gray` 整段往后退（如逐字稿头）

`platform_cn` 映射：`douyin=抖音`、`bilibili=哔哩哔哩`、`xhs=小红书`、`youtube=YouTube`、`generic=未知平台`。

## 返回给用户

跑完后给用户的简短回复格式：

字幕路径（B站/YT 有字幕，跳过妙记）：
```
✅ 已归档（{x 分 x 秒} · 平台：{平台} · 作者：{author}）

📄 文档：{docx_url}
📝 逐字稿来源：平台 AI 字幕

（执行摘要前 1-2 句）
```

妙记路径（抖音/小红书，或 B站/YT 没字幕）：
```
✅ 已归档（{x 分 x 秒} · 平台：{平台} · 作者：{author}）

📄 文档：{docx_url}
🎬 妙记：{minute_url}

（执行摘要前 1-2 句）
```

## 关键约束

1. **drive +upload 的 --file 必须是相对路径**（CLI 限制），上传前必须 `cd "$WORK"`
2. **抖音不要走 yt-dlp**：当前 yt-dlp 抖音 extractor 要 fresh cookies，share API 更稳
3. **小红书需要登录态**：用户 Chrome 没登录小红书时直接报错，不要静默卡住
4. **字幕优先**：B站 / YouTube 先试 `get-captions.sh`，拿到字幕直接跳过妙记，省 8-15 分钟
5. **妙记是异步的**：minutes +upload 返回的瞬间内容是空的，按 Step 2b-iii 节奏轮询
6. **不要动「第二大脑」Base**：归档目标只有云盘 `视频笔记` 文件夹，保持精简
7. **不删除本地 mp4 直到 docx 创建成功**，方便失败时不丢源

## 失败回退

- **download.sh exit code 2（NOT_A_VIDEO）**：链接是图文笔记 / 纯文章 / 不支持的页面，不是视频。立即停止 video2note 流程，转告用户并**主动**改用 defuddle skill 抓文本来总结。不要重试，不要上传，不要建妙记。
- 其它下载失败（exit 1）：把 download.sh 的 stderr 原样给用户，提示是否是分享口令格式有误 / cookies 失效 / 网络问题
- 上传失败：保留本地 mp4，提示用户磁盘空间或飞书云盘配额
- 妙记 vc +notes 一直返回 artifact 未就绪：检查 `lark-cli minutes minutes get --minute-token <token>` 看妙记是否还在处理；超过 10 分钟仍未好，把妙记 URL 直接给用户让其手动等

## 权限

| 操作 | 所需 scope |
|------|-----------|
| 上传到云盘 | `drive:drive` |
| 移动文件 | `drive:drive` |
| 创建文档 | `docs:document` |
| 生成妙记 | （随上传走，无额外 scope）|
| 读妙记总结 | `minutes:minutes.artifacts:read` |
| 读逐字稿 | `minutes:minutes.transcript:export` |
| 读妙记元信息 | `minutes:minutes:readonly` |
