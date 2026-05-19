#!/usr/bin/env bash
# wait-for-minute.sh — Poll a Lark 妙记 until ASR transcript is ready, then return artifacts.
#
# Replaces the previous blind-sleep pattern (`sleep 90 && lark-cli vc +notes ...`)
# with an actual readiness probe. Short videos return in ~30-90s; long videos
# don't overshoot.
#
# Usage:
#   bash wait-for-minute.sh <MINUTE_TOKEN> [--max-wait SECONDS] [--interval SECONDS]
#
# Output:
#   stdout — final `vc +notes` JSON response when ready (callers can pipe / parse)
#   stderr — human-readable progress ticks
#
# Exit codes:
#   0 — transcript ready, artifacts downloaded
#   1 — timed out
#   2 — invalid arguments
#
# Readiness signal: transcript file on disk contains real ASR output.
#
# Why "transcript content", not "artifacts.summary":
#   Lark has two pipelines: ASR (transcript) finishes in ~30-60s for short videos.
#   AI summary runs separately and takes 3-10+ MINUTES, even for short clips.
#   The lark-video2note skill explicitly ignores Lark's summary
#   ("妙记 summary 太瘦", see SKILL.md) — it only needs the transcript.
#   So we exit as soon as transcript is ready, not waiting for summary.
#
# Why not minutes.minutes.get for probing:
#   Both `duration` and `cover` populate at UPLOAD time, before ASR runs.
#   They are not useful readiness indicators.
#
# Side effect of polling:
#   Each `vc +notes` call writes/overwrites a small transcript.txt at
#   ./minutes/<MINUTE_TOKEN>/transcript.txt
#   When the minute hasn't been ASR'd yet, it's a ~50-byte header stub.
#   When ASR is done, it contains the actual transcribed lines.
#   Run this script from the directory where you want the final transcript to land.

set -euo pipefail

MINUTE_TOKEN="${1:-}"
MAX_WAIT=600
INTERVAL=10

if [ -z "$MINUTE_TOKEN" ]; then
  echo "Usage: wait-for-minute.sh <MINUTE_TOKEN> [--max-wait SECONDS] [--interval SECONDS]" >&2
  exit 2
fi
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --max-wait)  MAX_WAIT="$2";  shift 2 ;;
    --interval)  INTERVAL="$2";  shift 2 ;;
    *) echo "wait-for-minute: unknown arg: $1" >&2; exit 2 ;;
  esac
done

TRANSCRIPT_PATH="./minutes/${MINUTE_TOKEN}/transcript.txt"
START=$(date +%s)
ATTEMPT=0

# Heuristic: an in-progress transcript has just a header (~50 bytes max).
# A real ASR'd transcript has at least one "说话人" line in it.
transcript_has_content() {
  [ -f "$TRANSCRIPT_PATH" ] || return 1
  grep -q "说话人" "$TRANSCRIPT_PATH" 2>/dev/null
}

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  ELAPSED=$(( $(date +%s) - START ))

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "[wait-for-minute] timeout after ${ELAPSED}s (max=${MAX_WAIT}s)." >&2
    echo "[wait-for-minute] Check manually: https://my.feishu.cn/minutes/$MINUTE_TOKEN" >&2
    exit 1
  fi

  echo "[wait-for-minute] attempt $ATTEMPT (elapsed ${ELAPSED}s) — probing $MINUTE_TOKEN ..." >&2

  RESP=$(lark-cli vc +notes --minute-tokens "$MINUTE_TOKEN" 2>/dev/null || true)

  if [ -n "$RESP" ] && transcript_has_content; then
    BYTES=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')
    echo "[wait-for-minute] ready after ${ELAPSED}s (attempts: $ATTEMPT, transcript: ${BYTES} bytes)" >&2
    echo "$RESP"
    exit 0
  fi

  echo "[wait-for-minute] transcript not ready yet; sleeping ${INTERVAL}s" >&2
  sleep "$INTERVAL"
done
