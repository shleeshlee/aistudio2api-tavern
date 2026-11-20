#!/usr/bin/env bash
# ============================================
# AIStudio2API for SillyTavern —— 安装 / 更新 / 卸载，一条命令
#   curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash
# 运行后选 1 安装 / 2 更新 / 3 卸载。
# 免交互：... | bash -s -- install|update|uninstall [酒馆目录]
# 装的东西：酒馆插件 + 前端面板 + AIStudio2API 程序本体（~/aistudio2api/）
# 程序优先从上游下载，上游不可用时改用备份 fork
# ============================================
set -uo pipefail

REPO="https://github.com/shleeshlee/aistudio2api-tavern.git"
SOURCES=("Mag1cFall/AIStudio2API" "shleeshlee/AIStudio2API") # 上游在前，备份 fork 在后
NAME="AIStudio2API"
APP_DIR="${AISTUDIO2API_HOME:-$HOME/aistudio2api}"
RAW="https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh"

BLUE='\033[1;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }
# curl | bash 时 stdin 是脚本本身，提问从终端读；没有终端一律按「否」
ask() {
  local reply="" def="$2"
  has_tty || return 1
  printf "  ${BOLD}%s${NC} [%s] " "$1" "$([ "$def" = y ] && echo Y/n || echo y/N)" >/dev/tty
  read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

IS_TERMUX=false
[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && IS_TERMUX=true

# ---------- 参数 ----------
ACTION=""
case "${1:-}" in
  1|install)   ACTION=install;   shift ;;
  2|update)    ACTION=update;    shift ;;
  3|uninstall) ACTION=uninstall; shift ;;
esac
ST_ARG="${1:-}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}AIStudio2API for SillyTavern${NC}              ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ---------- 找酒馆 ----------
is_st() { [ -f "$1/server.js" ] && [ -d "$1/public/scripts/extensions" ]; }
ST_DIR="$ST_ARG"
if [ -z "$ST_DIR" ]; then
  for d in "$PWD" "$PWD/SillyTavern" "$HOME/SillyTavern" "$HOME/sillytavern" "$HOME/st" "$HOME/ST" "$PWD/.."; do
    if is_st "$d"; then ST_DIR="$d"; break; fi
  done
fi
if [ -z "$ST_DIR" ]; then
  found="$(find "$HOME" -maxdepth 4 -name server.js -path '*illy*avern*' 2>/dev/null | head -1)"
  [ -n "$found" ] && ST_DIR="$(dirname "$found")"
fi
[ -n "$ST_DIR" ] && is_st "$ST_DIR" || die "找不到 SillyTavern。进到酒馆目录再运行，或在命令末尾加：bash -s -- install /酒馆/路径"
ST_DIR="$(cd "$ST_DIR" && pwd)"

PLUGIN_DIR="$ST_DIR/plugins/$NAME"
EXT_DIR="$ST_DIR/public/scripts/extensions/third-party/$NAME"
CONFIG="$ST_DIR/config.yaml"
ST_PORT="$(grep -E '^port:' "$CONFIG" 2>/dev/null | head -1 | awk '{print $2}')"
ST_PORT="${ST_PORT:-8000}"
CURRENT="$(cat "$APP_DIR/.termux-version" 2>/dev/null || true)"

INSTALLED=false
[ -d "$PLUGIN_DIR" ] && INSTALLED=true

# ---------- 菜单 ----------
if [ -z "$ACTION" ]; then
  echo -e "  酒馆：$ST_DIR"
  if $INSTALLED; then
    echo -e "  状态：${GREEN}已安装${NC}  程序 ${CURRENT:-未下载}"
  else
    echo -e "  状态：未安装"
  fi
  echo ""
  echo "    1) 安装"
  echo "    2) 更新"
  echo "    3) 卸载"
  echo ""
  if has_tty; then
    printf "  ${BOLD}请选择 [1-3]：${NC}" >/dev/tty
    read -r choice </dev/tty || choice=""
  else
    choice=1 # 非交互环境默认安装，兼容旧用法
  fi
  case "$choice" in
    1) ACTION=install ;;
    2) ACTION=update ;;
    3) ACTION=uninstall ;;
    *) die "没有这个选项：$choice" ;;
  esac
  echo ""
fi

if [ "$ACTION" = update ] && ! $INSTALLED; then
  warn "还没安装，改为执行安装"
  ACTION=install
fi

# ---------- 通用：程序进程、酒馆进程 ----------
program_running() { pgrep -f "$APP_DIR/aistudio2api" >/dev/null 2>&1; }

stop_program() {
  program_running || return 0
  pkill -TERM -f "$APP_DIR/aistudio2api" 2>/dev/null
  for _ in $(seq 1 5); do program_running || return 0; sleep 1; done
  pkill -KILL -f "$APP_DIR/aistudio2api" 2>/dev/null
  sleep 1
}

find_st_pid() {
  local pid cwd
  for pid in $(pgrep -f "node.*server\.js" 2>/dev/null); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ "$cwd" = "$ST_DIR" ] && { echo "$pid"; return 0; }
  done
  return 1
}

stop_st() {
  kill "$1" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
  kill -9 "$1" 2>/dev/null
}

start_st() {
  # setsid 让酒馆脱离当前终端会话，关掉这个窗口不会带走它
  if command -v setsid >/dev/null 2>&1; then
    (cd "$ST_DIR" && setsid nohup node server.js >"$ST_DIR/aistudio2api-st.log" 2>&1 </dev/null &)
  else
    (cd "$ST_DIR" && nohup node server.js >"$ST_DIR/aistudio2api-st.log" 2>&1 </dev/null &)
  fi
}

# ============================================
# 卸载
# ============================================
if [ "$ACTION" = uninstall ]; then
  echo "  将删除："
  [ -d "$PLUGIN_DIR" ] && echo "    插件  $PLUGIN_DIR"
  [ -d "$EXT_DIR" ]    && echo "    面板  $EXT_DIR"
  [ -f "$ST_DIR/aistudio2api-st.log" ] && echo "    日志  $ST_DIR/aistudio2api-st.log"
  [ -d "$APP_DIR" ] && { echo "  下一步单独问："; echo "    程序与账号  $APP_DIR"; }
  echo ""
  if [ ! -d "$PLUGIN_DIR" ] && [ ! -d "$EXT_DIR" ] && [ ! -d "$APP_DIR" ]; then
    warn "没有找到已安装的 AIStudio2API，无需卸载"
    exit 0
  fi
  ask "确认卸载？" n || { warn "已取消"; exit 0; }

  if program_running; then
    info "停止 AIStudio2API"
    stop_program
    ok "已停止"
  fi
  rm -rf "$PLUGIN_DIR" "$EXT_DIR" "$ST_DIR/aistudio2api-st.log"
  ok "已删除插件和面板"

  if [ -d "$APP_DIR" ]; then
    echo ""
    echo -e "  ${YELLOW}${APP_DIR} 里有程序和已导入的 Google 账号（auth/），删了要重新导入账号${NC}"
    if ask "连程序和账号一起删除？" n; then
      rm -rf "$APP_DIR"
      LAUNCHER="${PREFIX:-/nonexistent}/bin/aistudio2api"
      [ -f "$LAUNCHER" ] && grep -q aistudio2api-termux "$LAUNCHER" 2>/dev/null && rm -f "$LAUNCHER"
      ok "已删除 ${APP_DIR}"
    else
      ok "已保留 ${APP_DIR}（重新安装后账号直接可用）"
    fi
  fi

  ST_PID="$(find_st_pid || true)"
  if [ -n "$ST_PID" ] && ask "重启酒馆让面板消失？" y; then
    stop_st "$ST_PID"; start_st
    ok "酒馆已在后台重启"
  fi
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "  ${GREEN}${BOLD}✓ 卸载完成${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  重新安装：curl -fsSL $RAW | bash"
  echo ""
  exit 0
fi

# ============================================
# 安装 / 更新
# ============================================
ok "酒馆目录：$ST_DIR"

# ---------- 依赖 ----------
pkg_install() { # 只装缺的，不顺带升级已装的库（升级到一半被杀会弄坏 curl）
  if $IS_TERMUX; then
    apt-get install -y --no-upgrade "$@" </dev/null \
      || { apt-get update </dev/null && apt-get install -y --no-upgrade "$@" </dev/null; }
  elif command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
    apt-get install -y --no-upgrade "$@" </dev/null
  else
    return 1
  fi
}
NEED=()
command -v git  >/dev/null 2>&1 || NEED+=(git)
command -v curl >/dev/null 2>&1 || NEED+=(curl)
command -v tar  >/dev/null 2>&1 || NEED+=(tar)
if $IS_TERMUX; then
  command -v proot >/dev/null 2>&1 || NEED+=(proot)
  [ -s "$PREFIX/etc/tls/cert.pem" ] || NEED+=(ca-certificates)
  [ -e "$PREFIX/etc/resolv.conf" ]  || NEED+=(resolv-conf)
fi
if [ ${#NEED[@]} -gt 0 ]; then
  info "安装依赖：${NEED[*]}"
  pkg_install "${NEED[@]}" || die "依赖安装失败，请手动安装：${NEED[*]}"
fi
command -v node >/dev/null 2>&1 || die "缺少 node（酒馆本身需要它，先把酒馆装好）"
ok "依赖齐全"
if $IS_TERMUX && [ ! -s "$PREFIX/etc/resolv.conf" ]; then
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$PREFIX/etc/resolv.conf"
fi

# ---------- 插件 + 前端面板 ----------
if [ -d "$PLUGIN_DIR/.git" ]; then
  info "更新插件"
  git -C "$PLUGIN_DIR" fetch -q --depth 1 origin main </dev/null \
    && git -C "$PLUGIN_DIR" reset -q --hard origin/main \
    || die "插件更新失败（GitHub 连不上？开梯子再试）"
else
  info "下载插件"
  rm -rf "$PLUGIN_DIR"
  git clone -q --depth 1 "$REPO" "$PLUGIN_DIR" </dev/null || die "插件下载失败（GitHub 连不上？开梯子再试）"
fi
rm -rf "$EXT_DIR" && mkdir -p "$EXT_DIR" && cp -R "$PLUGIN_DIR/extension/." "$EXT_DIR/"
ok "插件：plugins/$NAME"
ok "面板：public/scripts/extensions/third-party/$NAME"

if [ -f "$CONFIG" ]; then
  if grep -qE '^enableServerPlugins:[[:space:]]*true' "$CONFIG"; then
    ok "enableServerPlugins 已开启"
  elif grep -qE '^enableServerPlugins:' "$CONFIG"; then
    sed -i.bak -E 's/^enableServerPlugins:.*/enableServerPlugins: true/' "$CONFIG"
    ok "已开启 enableServerPlugins（原配置备份为 config.yaml.bak）"
  else
    printf '\nenableServerPlugins: true\n' >> "$CONFIG"
    ok "已在 config.yaml 追加 enableServerPlugins: true"
  fi
else
  warn "还没有 config.yaml（酒馆没启动过）：首次启动后把 enableServerPlugins 改成 true 再重启"
fi

# ---------- 程序本体：先下载到临时目录，进程停了再换上 ----------
asset_name() {
  local tag="$1" os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 1 ;; esac
  echo "aistudio2api-$tag-$os-$arch"
}
latest_tag() { # 输出「版本 来源仓库」
  local src u
  for src in "${SOURCES[@]}"; do
    u="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$src/releases/latest" 2>/dev/null)" || continue
    [[ "$u" == */tag/* ]] || continue
    echo "${u##*/tag/} $src"
    return 0
  done
  return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NEW_BIN=""
TAG=""
if read -r TAG SRC < <(latest_tag); then
  [ "$SRC" = "${SOURCES[0]}" ] || warn "上游不可用，改用备份 $SRC"
  if [ "$TAG" = "$CURRENT" ] && [ -x "$APP_DIR/aistudio2api" ]; then
    ok "AIStudio2API 程序已是最新 $TAG"
  else
    PKG="$(asset_name "$TAG")" || die "这台设备不支持（$(uname -s) $(uname -m)）"
    info "下载 AIStudio2API ${TAG}（约 75MB）"
    got=false
    for src in "$SRC" "${SOURCES[@]}"; do
      if curl -fL --progress-bar "https://github.com/$src/releases/download/$TAG/$PKG.tar.gz" -o "$TMP/pkg.tar.gz" \
         && tar -xzf "$TMP/pkg.tar.gz" -C "$TMP" && [ -f "$TMP/$PKG/aistudio2api" ]; then
        got=true; break
      fi
      warn "从 $src 下载失败，换下一个来源"
    done
    if $got; then NEW_BIN="$TMP/$PKG/aistudio2api"; else warn "程序下载失败，面板第一次点 ▶ 时会再试"; fi
  fi
else
  if [ -x "$APP_DIR/aistudio2api" ]; then
    warn "查不到最新版本，沿用已装的 ${CURRENT:-程序}"
  else
    warn "查不到最新版本（GitHub 连不上？），程序会在面板第一次点 ▶ 时再下载"
  fi
fi

swap_program() {
  [ -n "$NEW_BIN" ] || return 0
  if program_running; then
    warn "AIStudio2API 正在运行（不是酒馆插件启动的），这次没换程序；停掉它后再选「更新」"
    return 0
  fi
  mkdir -p "$APP_DIR"
  cp "$NEW_BIN" "$APP_DIR/aistudio2api" && chmod 755 "$APP_DIR/aistudio2api"
  echo "$TAG" > "$APP_DIR/.termux-version"
  ok "程序：${APP_DIR}（${CURRENT:+$CURRENT → }${TAG}）"
}

# ---------- 酒馆：重启/启动 + 验收 ----------
VERIFIED=false
verify() {
  for _ in $(seq 1 40); do
    if curl -s -m 2 "http://127.0.0.1:$ST_PORT/api/plugins/aistudio2api/status" 2>/dev/null | grep -q '"status"'; then
      VERIFIED=true
      ok "验收通过：酒馆已加载 AIStudio2API 插件"
      return 0
    fi
    sleep 1
  done
  warn "40 秒内没等到插件响应。酒馆启动日志：$ST_DIR/aistudio2api-st.log"
}

echo ""
ST_PID="$(find_st_pid || true)"
if [ -n "$ST_PID" ]; then
  warn "酒馆正在运行（PID ${ST_PID}），要重启才能用上新插件"
  if ask "现在自动重启酒馆？" y; then
    stop_st "$ST_PID"
    # 酒馆退出时插件会带走它启动的程序，等程序退干净再换
    for _ in $(seq 1 5); do program_running || break; sleep 1; done
    swap_program
    start_st
    info "酒馆已在后台重启，等待插件加载…"
    verify
  else
    swap_program
    warn "请手动重启酒馆"
  fi
else
  swap_program
  if ask "酒馆没在运行，现在启动它？" y; then
    start_st
    info "酒馆已在后台启动，等待插件加载…"
    verify
  else
    warn "下次启动酒馆后生效"
  fi
fi

# ---------- 完成 ----------
echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
if $VERIFIED; then
  echo -e "  ${GREEN}${BOLD}✓ $([ "$ACTION" = update ] && echo 更新 || echo 安装)成功${NC}"
else
  echo -e "  ${YELLOW}${BOLD}! 已完成，重启酒馆后生效${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════════${NC}"
cat <<EOF

  打开酒馆 http://127.0.0.1:$ST_PORT → 扩展栏里的蓝色「AIStudio2API」面板
    ▶ 启动 / ■ 停止；点面板打开管理页面添加账号
  接入：API 连接 → Chat Completion → 来源 Google AI Studio → 反向代理选「AIStudio2API」

  以后更新、卸载：再运行同一条命令，选 2 或 3

EOF
