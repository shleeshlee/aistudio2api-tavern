#!/usr/bin/env bash
# AIStudio2API for SillyTavern 一键安装
#   在酒馆目录或其上级目录运行：
#   curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash
#   指定酒馆目录：... | bash -s -- /path/to/SillyTavern
set -euo pipefail

REPO="https://github.com/shleeshlee/aistudio2api-tavern.git"
PLUGIN_NAME="AIStudio2API"

say() { printf '\033[1;34m[AIStudio2API]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[AIStudio2API] %s\033[0m\n' "$*" >&2; exit 1; }

is_st() { [ -f "$1/server.js" ] && [ -d "$1/public/scripts/extensions" ]; }

ST_DIR="${1:-}"
if [ -z "$ST_DIR" ]; then
  for d in "$PWD" "$PWD/SillyTavern" "$HOME/SillyTavern" "$PWD/.."; do
    if is_st "$d"; then ST_DIR="$d"; break; fi
  done
fi
[ -n "$ST_DIR" ] && is_st "$ST_DIR" || die "找不到 SillyTavern 目录。进到酒馆目录再运行，或在命令末尾加：bash -s -- /酒馆/路径"
ST_DIR="$(cd "$ST_DIR" && pwd)"
say "酒馆目录：$ST_DIR"

command -v git >/dev/null 2>&1 || die "缺少 git"
command -v node >/dev/null 2>&1 || die "缺少 node"

# 安卓 Termux：程序要靠 proot 修 DNS
if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && ! command -v proot >/dev/null 2>&1; then
  say "安装 proot"
  apt-get install -y --no-upgrade proot </dev/null \
    || { apt-get update </dev/null && apt-get install -y --no-upgrade proot </dev/null; } \
    || die "proot 安装失败，可以先单独运行：pkg install proot"
fi

PLUGIN_DIR="$ST_DIR/plugins/$PLUGIN_NAME"
EXT_DIR="$ST_DIR/public/scripts/extensions/third-party/$PLUGIN_NAME"

if [ -d "$PLUGIN_DIR/.git" ]; then
  say "更新插件"
  git -C "$PLUGIN_DIR" pull --ff-only -q </dev/null
else
  rm -rf "$PLUGIN_DIR"
  say "下载插件"
  git clone -q --depth 1 "$REPO" "$PLUGIN_DIR" </dev/null
fi

rm -rf "$EXT_DIR"
mkdir -p "$EXT_DIR"
cp -R "$PLUGIN_DIR/extension/." "$EXT_DIR/"
say "前端扩展已装到 public/scripts/extensions/third-party/$PLUGIN_NAME"

CONFIG="$ST_DIR/config.yaml"
if [ -f "$CONFIG" ]; then
  if grep -qE '^enableServerPlugins:[[:space:]]*true' "$CONFIG"; then
    :
  elif grep -qE '^enableServerPlugins:' "$CONFIG"; then
    sed -i.bak -E 's/^enableServerPlugins:.*/enableServerPlugins: true/' "$CONFIG"
    say "已打开 config.yaml 的 enableServerPlugins"
  else
    printf '\nenableServerPlugins: true\n' >> "$CONFIG"
    say "已在 config.yaml 追加 enableServerPlugins: true"
  fi
else
  say "还没有 config.yaml（酒馆没启动过）；首次启动后把其中 enableServerPlugins 改成 true 再重启"
fi

cat <<EOF

  安装完成，重启酒馆后生效。
  使用：扩展栏里的蓝色「AIStudio2API」面板，点右边 ▶ 启动（第一次会自动下载程序）；
        点面板本身打开管理页面添加账号；
        API 连接 → Chat Completion → 来源 Google AI Studio → 反向代理选「AIStudio2API」。

EOF
