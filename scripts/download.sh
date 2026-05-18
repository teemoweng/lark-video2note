#!/usr/bin/env bash
# 把 抖音 / 哔哩哔哩 / 小红书 / YouTube 的视频链接下载成本地 mp4
# 用法: ./download.sh <url> <output_dir>
# 输出: 同时打印 JSON 到 stdout，字段 file, title, platform, author, duration_s, source_url

set -euo pipefail

URL_RAW="${1:?need url or share text}"
OUT_DIR="${2:?need output dir}"
mkdir -p "$OUT_DIR"

# 1. 从分享文本里抠 URL（抖音/小红书分享口令带乱码）
URL=$(echo "$URL_RAW" | grep -oE 'https?://[^ ]+' | head -1)
[ -z "$URL" ] && { echo "no url found in: $URL_RAW" >&2; exit 1; }

# 2. 识别平台
case "$URL" in
  *douyin.com*|*iesdouyin*) PLATFORM=douyin ;;
  *bilibili.com*|*b23.tv*)  PLATFORM=bilibili ;;
  *xiaohongshu.com*|*xhslink*) PLATFORM=xhs ;;
  *youtube.com*|*youtu.be*) PLATFORM=youtube ;;
  *) PLATFORM=generic ;;
esac

# 3. 下载
UA_IOS='Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15'
TMP_JSON="$OUT_DIR/.meta.json"

case "$PLATFORM" in
  douyin)
    # 抖音不走 yt-dlp（要 fresh cookies），直接用 iesdouyin share API
    # 1) 短链解析为 video_id
    FINAL_URL=$(curl -sLI -A "$UA_IOS" "$URL" -o /dev/null -w '%{url_effective}')
    VIDEO_ID=$(echo "$FINAL_URL" | grep -oE 'video/[0-9]+' | head -1 | cut -d/ -f2)
    [ -z "$VIDEO_ID" ] && { echo "could not parse douyin video id from $FINAL_URL" >&2; exit 1; }
    # 2) 拉 share 页解析 play_addr + 元信息
    SHARE_HTML="$OUT_DIR/.share.html"
    curl -sL -A "$UA_IOS" "https://www.iesdouyin.com/share/video/$VIDEO_ID/" -o "$SHARE_HTML"
    PLAY_URL=$(grep -oE '"play_addr":\{[^}]*"url_list":\[[^]]*\]' "$SHARE_HTML" \
      | grep -oE 'https:[^"]*playwm[^"]*' | head -1 | sed 's/\\u002F/\//g')
    # 抖音也有图文笔记（aweme_type 68 之类），play_addr 不存在
    if [ -z "$PLAY_URL" ]; then
      cat >&2 <<EOF
NOT_A_VIDEO: 这条抖音链接看起来是图文笔记，不是视频。
建议改用 defuddle skill 抓取文本内容来总结，而不是走 video2note 流程。
EOF
      rm -f "$SHARE_HTML"
      exit 2
    fi
    TITLE=$(grep -oE '"desc":"[^"]*"' "$SHARE_HTML" | head -1 | sed 's/"desc":"//;s/"$//' | python3 -c 'import sys,json;print(json.loads("\""+sys.stdin.read()+"\""))' 2>/dev/null || echo "douyin-$VIDEO_ID")
    AUTHOR=$(grep -oE '"nickname":"[^"]*"' "$SHARE_HTML" | head -1 | sed 's/"nickname":"//;s/"$//' | python3 -c 'import sys,json;print(json.loads("\""+sys.stdin.read()+"\""))' 2>/dev/null || echo "unknown")
    DURATION=$(grep -oE '"duration":[0-9]+' "$SHARE_HTML" | head -1 | cut -d: -f2)
    DURATION_S=$((${DURATION:-0} / 1000))
    SAFE_TITLE=$(echo "$TITLE" | tr -d '/\\:*?"<>|' | cut -c1-60)
    OUT_FILE="$OUT_DIR/douyin-$SAFE_TITLE.mp4"
    curl -sL -A "$UA_IOS" "$PLAY_URL" -o "$OUT_FILE"
    rm -f "$SHARE_HTML"
    ;;
  bilibili|youtube|xhs|generic)
    # 走 yt-dlp（小红书可能需要 --cookies-from-browser chrome/firefox）
    YTDLP=$(command -v yt-dlp || echo /tmp/yt-dlp-nightly)
    [ -x "$YTDLP" ] || { echo "yt-dlp not installed" >&2; exit 1; }
    COOKIES_ARG=()
    [ "$PLATFORM" = "xhs" ] && COOKIES_ARG=(--cookies-from-browser chrome)
    YTDLP_ERR="$OUT_DIR/.ytdlp-stderr.log"
    set +e
    "$YTDLP" ${COOKIES_ARG[@]+"${COOKIES_ARG[@]}"} \
      -f "bv*+ba/b" \
      --merge-output-format mp4 \
      --print-json \
      -o "$OUT_DIR/$PLATFORM-%(title).60s.%(ext)s" \
      "$URL" > "$TMP_JSON" 2> "$YTDLP_ERR"
    YTDLP_EXIT=$?
    set -e
    if [ $YTDLP_EXIT -ne 0 ]; then
      # 识别"这不是视频"的几类错误，给调用方一个明确出口（exit 2）
      # yt-dlp 在遇到图文/纯文章/不支持的内容时常见关键词
      if grep -qiE "no video|unsupported url|no video formats|no media found|not a video|requested format not available|empty media" "$YTDLP_ERR"; then
        cat >&2 <<EOF
NOT_A_VIDEO: 这条链接看起来不是视频内容（很可能是图文笔记 / 纯文章 / 不支持的页面）。
建议改用 defuddle skill 抓取文本内容来总结，而不是走 video2note 流程。
原始 yt-dlp 报错：
$(tail -3 "$YTDLP_ERR")
EOF
        rm -f "$YTDLP_ERR" "$TMP_JSON"
        exit 2
      fi
      # 其它失败原因（网络、cookies、格式问题等）原样抛出
      cat "$YTDLP_ERR" >&2
      rm -f "$YTDLP_ERR" "$TMP_JSON"
      exit 1
    fi
    OUT_FILE=$(python3 -c "import json;d=json.load(open('$TMP_JSON'));print(d.get('_filename') or d.get('filepath'))")
    TITLE=$(python3 -c "import json;print(json.load(open('$TMP_JSON')).get('title',''))")
    AUTHOR=$(python3 -c "import json;d=json.load(open('$TMP_JSON'));print(d.get('uploader') or d.get('channel') or '')")
    DURATION_S=$(python3 -c "import json;print(int(json.load(open('$TMP_JSON')).get('duration') or 0))")
    rm -f "$TMP_JSON" "$YTDLP_ERR"
    ;;
esac

[ -f "$OUT_FILE" ] || { echo "download failed, no output file" >&2; exit 1; }
SIZE=$(stat -f%z "$OUT_FILE" 2>/dev/null || stat -c%s "$OUT_FILE")
[ "$SIZE" -lt 10000 ] && { echo "downloaded file too small ($SIZE bytes), likely failed" >&2; exit 1; }

python3 -c "
import json
print(json.dumps({
  'file': '$OUT_FILE',
  'title': '''$TITLE'''.strip() or 'untitled',
  'platform': '$PLATFORM',
  'author': '''$AUTHOR'''.strip() or 'unknown',
  'duration_s': int('$DURATION_S' or 0),
  'source_url': '$URL',
  'size_bytes': $SIZE,
}, ensure_ascii=False))
"
