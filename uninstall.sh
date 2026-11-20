#!/usr/bin/env bash
# ============================================
# AIStudio2API for SillyTavern 一键卸载
#   curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/uninstall.sh | bash
#   指定酒馆目录：... | bash -s -- /path/to/SillyTavern
# 默认删插件和面板、保留 ~/aistudio2api/（程序与账号）；会单独问要不要连账号一起删
# ============================================
set -uo pipefail

NAME="AIStudio2API"
APP_DIR="${AISTUDIO2API_HOME:-$HOME/aistudio2api}"

BLUE='\033[1;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }
ask() {
  local reply="" def="$2"
  # 没有可用终端（非交互环境）一律按「否」，不替用户做主
  if ! { : </dev/tty; } 2>/dev/null; then return 1; fi
    printf "  ${BOLD}%s${NC} [%s] " "$1" "$([ "$def" = y ] && echo Y/n || echo y/N)" >/dev/tty
    read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}AIStudio2API for SillyTavern${NC} · 卸载       ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

is_st() { [ -f "$1/server.js" ] && [ -d "$1/public/scripts/extensions" ]; }
ST_DIR="${1:-}"
if [ -z "$ST_DIR" ]; then
  for d in "$PWD" "$PWD/SillyTavern" "$HOME/SillyTavern" "$HOME/sillytavern" "$HOME/st" "$HOME/ST" "$PWD/.."; do
    if is_st "$d"; then ST_DIR="$d"; break; fi
  done
fi
if [ -z "$ST_DIR" ]; then
  found="$(find "$HOME" -maxdepth 4 -name server.js -path '*illy*avern*' 2>/dev/null | head -1)"
  [ -n "$found" ] && ST_DIR="$(dirname "$found")"
fi
[ -n "$ST_DIR" ] && is_st "$ST_DIR" || die "找不到 SillyTavern。进到酒馆目录再运行，或在命令末尾加：bash -s -- /酒馆/路径"
ST_DIR="$(cd "$ST_DIR" && pwd)"

PLUGIN_DIR="$ST_DIR/plugins/$NAME"
EXT_DIR="$ST_DIR/public/scripts/extensions/third-party/$NAME"
LAUNCHER="${PREFIX:-/nonexistent}/bin/aistudio2api"

echo "  将删除："
[ -d "$PLUGIN_DIR" ] && echo "    插件  $PLUGIN_DIR"
[ -d "$EXT_DIR" ]    && echo "    面板  $EXT_DIR"
[ -f "$ST_DIR/aistudio2api-st.log" ] && echo "    日志  $ST_DIR/aistudio2api-st.log"
echo "  保留（下一步单独问）："
[ -d "$APP_DIR" ] && echo "    程序与账号  $APP_DIR"
echo ""

if [ ! -d "$PLUGIN_DIR" ] && [ ! -d "$EXT_DIR" ] && [ ! -d "$APP_DIR" ]; then
  warn "没有找到已安装的 AIStudio2API，无需卸载"
  exit 0
fi
ask "确认卸载？" n || { warn "已取消"; exit 0; }

# 先停程序（插件启动的或单独启动的都算）
if pgrep -f "$APP_DIR/aistudio2api" >/dev/null 2>&1; then
  info "停止 AIStudio2API"
  pkill -TERM -f "$APP_DIR/aistudio2api" 2>/dev/null
  for _ in $(seq 1 5); do pgrep -f "$APP_DIR/aistudio2api" >/dev/null 2>&1 || break; sleep 1; done
  pkill -KILL -f "$APP_DIR/aistudio2api" 2>/dev/null
  ok "已停止"
fi

rm -rf "$PLUGIN_DIR" "$EXT_DIR" "$ST_DIR/aistudio2api-st.log"
ok "已删除插件和面板"

if [ -d "$APP_DIR" ]; then
  echo ""
  echo -e "  ${YELLOW}$APP_DIR 里有程序和已导入的 Google 账号（auth/），删了要重新导入账号${NC}"
  if ask "连程序和账号一起删除？" n; then
    rm -rf "$APP_DIR"
    [ -f "$LAUNCHER" ] && grep -q aistudio2api-termux "$LAUNCHER" 2>/dev/null && rm -f "$LAUNCHER"
    ok "已删除 $APP_DIR"
  else
    ok "已保留 ${APP_DIR}（重新安装后账号直接可用）"
  fi
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}${BOLD}✓ 卸载完成${NC}，重启酒馆后面板消失"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "  重新安装：curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash"
echo ""
