#!/usr/bin/env bash
# 尝试从平台抓字幕（B站 AI 字幕 / YouTube auto-captions），生成 transcript.txt
# 用法: ./get-captions.sh <url> <output_dir>
# 成功 → 写 $output_dir/transcript.txt，stdout 输出 JSON {"transcript_file":"...","language":"..."}，exit 0
# 失败 → stderr 写原因，exit 1

set -euo pipefail

URL_RAW="${1:?need url}"
OUT_DIR="${2:?need output dir}"
mkdir -p "$OUT_DIR"

URL=$(echo "$URL_RAW" | grep -oE 'https?://[^ ]+' | head -1)
[ -z "$URL" ] && { echo "no url found" >&2; exit 1; }

# 只有这两个平台有靠谱的官方字幕
case "$URL" in
  *bilibili.com*|*b23.tv*|*youtube.com*|*youtu.be*) ;;
  *) echo "platform without reliable captions, skip" >&2; exit 1 ;;
esac

YTDLP=$(command -v yt-dlp || echo /tmp/yt-dlp-nightly)
[ -x "$YTDLP" ] || { echo "yt-dlp not found" >&2; exit 1; }

# B站字幕必须登录态；YouTube 偶尔也需要。默认带上 Chrome cookies。
# 用户没装 Chrome 或没登录时，yt-dlp 会 warning 但仍会尝试匿名抓取，不会硬失败。
COOKIES_ARG=(--cookies-from-browser chrome)

# 抓字幕（含 AI 自动生成的）
# YouTube 偶发 429 限流，做最多 3 次重试，间隔 5s / 15s
ATTEMPTS=3
LOG="$OUT_DIR/.ytdlp-captions.log"
for i in $(seq 1 $ATTEMPTS); do
  "$YTDLP" "${COOKIES_ARG[@]}" --skip-download \
    --write-subs --write-auto-subs \
    --sub-langs "zh-Hans,zh-CN,zh,en,en-US" \
    --convert-subs vtt \
    -o "$OUT_DIR/%(id)s.%(ext)s" \
    "$URL" > "$LOG" 2>&1 && break
  if grep -q "HTTP Error 429" "$LOG" && [ "$i" -lt "$ATTEMPTS" ]; then
    SLEEP=$((i * 10 - 5))  # 5s, 15s
    echo "yt-dlp got 429, retry $i/$ATTEMPTS after ${SLEEP}s" >&2
    sleep "$SLEEP"
    continue
  fi
  # 非 429 失败或重试用尽 —— 把日志原样吐出去并退出
  tail -5 "$LOG" >&2
  exit 1
done
tail -5 "$LOG" >&2

# 找到 vtt 文件（优先中文）
VTT=$(ls "$OUT_DIR"/*.zh-Hans.vtt "$OUT_DIR"/*.zh-CN.vtt "$OUT_DIR"/*.zh.vtt "$OUT_DIR"/*.en.vtt "$OUT_DIR"/*.vtt 2>/dev/null | head -1)
[ -z "$VTT" ] && { echo "no captions file produced by yt-dlp" >&2; exit 1; }

LANG=$(basename "$VTT" | grep -oE '\.[a-zA-Z-]+\.vtt$' | sed 's/\.vtt$//;s/^\.//')
TRANSCRIPT="$OUT_DIR/transcript.txt"

# 解析 vtt → 时间戳 + 文本，去掉冗余标签和重复行
python3 - "$VTT" "$TRANSCRIPT" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    raw = f.read()
blocks = raw.split("\n\n")
out_lines = []
last_text = ""
for blk in blocks:
    lines = [l.strip() for l in blk.split("\n") if l.strip()]
    if not lines or lines[0].startswith("WEBVTT") or lines[0].startswith("NOTE"):
        continue
    # find timestamp line
    ts = None
    text_lines = []
    for l in lines:
        if "-->" in l:
            ts = l.split(" --> ")[0].split(".")[0]
        elif re.match(r"^\d+$", l):
            continue
        else:
            cleaned = re.sub(r"<[^>]+>", "", l).strip()
            if cleaned and cleaned != last_text:
                text_lines.append(cleaned)
    if ts and text_lines:
        text = " ".join(text_lines)
        if text != last_text:
            out_lines.append(f"{ts}  {text}")
            last_text = text
with open(dst, "w", encoding='utf-8') as f:
    f.write("\n".join(out_lines))
print(len(out_lines))
PY

LINES=$(wc -l < "$TRANSCRIPT")
[ "$LINES" -lt 5 ] && { echo "transcript too short ($LINES lines), likely empty captions" >&2; exit 1; }

# 清理 vtt 中间文件
rm -f "$OUT_DIR"/*.vtt

python3 -c "
import json
print(json.dumps({
  'transcript_file': '$TRANSCRIPT',
  'language': '$LANG',
  'lines': $LINES,
}, ensure_ascii=False))
"
