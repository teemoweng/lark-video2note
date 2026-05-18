#!/usr/bin/env bash
# lark-video2note 首次配置脚本
# 用法: bash scripts/setup.sh

set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$SKILL_ROOT/config.json"

echo "═══════════════════════════════════════════════════════════"
echo "  lark-video2note 配置向导"
echo "═══════════════════════════════════════════════════════════"
echo

# ── Step 1：依赖检查 ────────────────────────────────────────
echo "▶ 检查依赖..."
MISSING=()
for bin in lark-cli yt-dlp curl python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    MISSING+=("$bin")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "  ❌ 缺少以下命令：${MISSING[*]}"
  echo
  echo "  安装提示："
  for bin in "${MISSING[@]}"; do
    case "$bin" in
      lark-cli) echo "    • lark-cli：npm install -g @larksuite/cli";;
      yt-dlp)   echo "    • yt-dlp：brew install yt-dlp（macOS） 或 pip install yt-dlp";;
      curl)     echo "    • curl：系统自带，几乎不会缺";;
      python3)  echo "    • python3：brew install python";;
    esac
  done
  exit 1
fi
echo "  ✅ 依赖齐全"
echo

# ── Step 2：lark-cli 登录态检查 ─────────────────────────────
echo "▶ 检查 lark-cli 登录状态..."
if ! lark-cli auth status >/dev/null 2>&1; then
  echo "  ❌ 未登录 lark-cli"
  echo
  echo "  请先运行："
  echo "    lark-cli auth login --scope \"drive:drive docs:document minutes:minutes:readonly minutes:minutes.artifacts:read minutes:minutes.transcript:export\""
  echo
  echo "  完成授权后重新跑本脚本。"
  exit 1
fi
echo "  ✅ 已登录"
echo

# ── Step 3：飞书云盘文件夹 ─────────────────────────────────
EXISTING_TOKEN=""
if [ -f "$CONFIG" ]; then
  EXISTING_TOKEN=$(python3 -c "import json,sys;print(json.load(open('$CONFIG')).get('folder_token',''))" 2>/dev/null || echo "")
fi

if [ -n "$EXISTING_TOKEN" ]; then
  echo "▶ 检测到已有配置：folder_token=$EXISTING_TOKEN"
  read -r -p "  是否保留现有配置？[Y/n] " keep
  if [[ ! "$keep" =~ ^[Nn]$ ]]; then
    echo "  ✅ 保留现有配置，跳过文件夹设置"
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ 配置完成。可以开始使用："
    echo "     在 Claude Code 里贴视频链接 + 「转成笔记」即可。"
    echo "═══════════════════════════════════════════════════════════"
    exit 0
  fi
fi

echo "▶ 配置飞书云盘目标文件夹（视频和文档将归档到此处）"
echo "  请选择："
echo "    1) 帮我新建一个文件夹（默认在云盘根目录）"
echo "    2) 我已有文件夹，直接给你 token"
echo
read -r -p "  选择 [1/2]：" choice

case "$choice" in
  1)
    read -r -p "  新文件夹名（回车默认 '视频笔记'）：" folder_name
    folder_name="${folder_name:-视频笔记}"
    read -r -p "  建在哪个父文件夹下？（回车留空 = 云盘根目录；否则输入父文件夹 token）：" parent_token
    if [ -n "$parent_token" ]; then
      result=$(lark-cli drive +create-folder --folder-token "$parent_token" --name "$folder_name")
    else
      result=$(lark-cli drive +create-folder --name "$folder_name")
    fi
    folder_token=$(echo "$result" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['folder_token'])")
    folder_url=$(echo "$result" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['url'])")
    echo "  ✅ 已创建：$folder_url"
    ;;
  2)
    read -r -p "  请输入文件夹 token：" folder_token
    if [ -z "$folder_token" ]; then
      echo "  ❌ token 不能为空"
      exit 1
    fi
    ;;
  *)
    echo "  ❌ 无效选项"
    exit 1
    ;;
esac

# ── Step 4：写入 config.json ──────────────────────────────
read -r -p "  路径标记（仅显示用，回车默认 'Claude产出/视频笔记/'）：" hint
hint="${hint:-Claude产出/视频笔记/}"

cat > "$CONFIG" <<JSON
{
  "folder_token": "$folder_token",
  "folder_path_hint": "$hint"
}
JSON

echo
echo "═══════════════════════════════════════════════════════════"
echo "  ✅ 配置完成！已写入：$CONFIG"
echo
echo "  下一步："
echo "    在 Claude Code 里贴视频链接 + 「转成笔记」即可触发。"
echo
echo "  可选优化："
echo "    把 README.md 中「全局 URL Triage 规则」一节贴到你的"
echo "    ~/.claude/CLAUDE.md 里，会让 Claude 更聪明地判断意图。"
echo "═══════════════════════════════════════════════════════════"
