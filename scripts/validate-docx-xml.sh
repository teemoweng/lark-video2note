#!/usr/bin/env bash
# validate-docx-xml.sh — Catch common 飞书 docx XML schema mistakes before upload.
#
# Why this exists:
#   The Lark docs API silently accepts unknown tags/attrs and either drops them
#   or escapes them as visible literal text. A document gets "created
#   successfully" with broken rendering — the user only notices when they open
#   the doc in Lark UI. This script makes the failure loud and early.
#
# Usage:
#   bash validate-docx-xml.sh <path-to-note.xml>
#
# Exit codes:
#   0 — no forbidden patterns found
#   1 — at least one forbidden pattern found (each violation printed to stderr)
#   2 — invalid arguments / file not found
#
# Forbidden patterns (each based on real bugs observed in the wild):
#   - <text>...</text>          # 飞书 docx 没有这个标签，写出来会被服务器转义成可见字符串
#   - <docx>...                 # 不需要根标签包裹，直接 <title>... 起步
#   - <?xml ...?>               # 同上
#   - background_color=         # 应该是 kebab-case background-color
#   - border_color=             # 同上
#   - emoji_id="..."            # 应该是 emoji="字符"，不是名称 id

set -euo pipefail

FILE="${1:-}"

if [ -z "$FILE" ]; then
  echo "Usage: validate-docx-xml.sh <path-to-note.xml>" >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "validate-docx-xml: file not found: $FILE" >&2
  exit 2
fi

declare -a CHECKS=(
  '<text>|<p> instead — <text> is not a valid 飞书 docx tag and will render as literal &lt;text&gt; in the doc'
  '<docx>|do not wrap in <docx> root — start directly with <title>...</title>'
  '<?xml|do not include <?xml ...?> declaration — start directly with <title>...</title>'
  'background_color=|use background-color= (kebab-case)'
  'border_color=|use border-color= (kebab-case)'
  'emoji_id=|use emoji="字符" (literal emoji char, not a name id)'
)

VIOLATIONS=0
for entry in "${CHECKS[@]}"; do
  pattern="${entry%%|*}"
  fix_hint="${entry#*|}"
  if grep -nF "$pattern" "$FILE" >/dev/null 2>&1; then
    echo "❌ forbidden pattern '$pattern' in $FILE" >&2
    grep -nF "$pattern" "$FILE" | head -3 | sed 's/^/    /' >&2
    echo "   ↳ fix: $fix_hint" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "" >&2
  echo "validate-docx-xml: $VIOLATIONS forbidden pattern(s) found — rewrite note.xml per references/doc-template.xml before uploading" >&2
  exit 1
fi

echo "[validate-docx-xml] $FILE passes ($(wc -c < "$FILE" | tr -d ' ') bytes)" >&2
exit 0
