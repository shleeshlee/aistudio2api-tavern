#!/usr/bin/env bash
# ============================================
# AIStudio2API for SillyTavern 一键安装
#   curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash
#   指定酒馆目录：... | bash -s -- /path/to/SillyTavern
# 装好的东西：酒馆插件 + 前端面板 + AIStudio2API 程序本体（~/aistudio2api/）
# 再次运行即更新；卸载见 uninstall.sh
# ============================================
set -uo pipefail

REPO="https://github.com/shleeshlee/aistudio2api-tavern.git"
UPSTREAM="Mag1cFall/AIStudio2API"
NAME="AIStudio2API"
APP_DIR="${AISTUDIO2API_HOME:-$HOME/aistudio2api}"

BLUE='\033[1;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# curl | bash 时 stdin 是脚本本身，提问从终端读
ask() { # ask "问题" 默认(y/n)
  local reply="" def="$2"
  # 没有可用终端（非交互环境）一律按「否」，不替用户做主
  if ! { : </dev/tty; } 2>/dev/null; then return 1; fi
    printf "  ${BOLD}%s${NC} [%s] " "$1" "$([ "$def" = y ] && echo Y/n || echo y/N)" >/dev/tty
    read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

IS_TERMUX=false
[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && IS_TERMUX=true

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}AIStudio2API for SillyTavern${NC} · 一键安装   ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ---------- 1. 找酒馆 ----------
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
ok "酒馆目录：$ST_DIR"

# ---------- 2. 依赖 ----------
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

# ---------- 3. 插件 + 前端面板 ----------
PLUGIN_DIR="$ST_DIR/plugins/$NAME"
EXT_DIR="$ST_DIR/public/scripts/extensions/third-party/$NAME"
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

CONFIG="$ST_DIR/config.yaml"
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

# ---------- 4. 程序本体 ----------
asset_name() {
  local tag="$1" os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 1 ;; esac
  echo "aistudio2api-$tag-$os-$arch"
}
latest_tag() {
  local u
  u="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$UPSTREAM/releases/latest")" || return 1
  [[ "$u" == */tag/* ]] || return 1
  echo "${u##*/tag/}"
}

CURRENT="$(cat "$APP_DIR/.termux-version" 2>/dev/null || true)"
TAG="$(latest_tag)" || TAG=""
if [ -z "$TAG" ]; then
  if [ -x "$APP_DIR/aistudio2api" ]; then
    warn "查不到最新版本，沿用已装的 ${CURRENT:-程序}"
  else
    warn "查不到最新版本（GitHub 连不上？），程序会在面板第一次点 ▶ 时再下载"
  fi
elif [ "$TAG" = "$CURRENT" ] && [ -x "$APP_DIR/aistudio2api" ]; then
  ok "AIStudio2API 程序已是最新 $TAG"
elif pgrep -f "$APP_DIR/aistudio2api" >/dev/null 2>&1; then
  warn "AIStudio2API 正在运行，跳过程序更新；停掉后在面板点「更新」"
else
  PKG="$(asset_name "$TAG")" || die "这台设备不支持（$(uname -s) $(uname -m)）"
  TMP="$(mktemp -d)"
  info "下载 AIStudio2API ${TAG}（约 75MB）"
  if curl -fL --progress-bar "https://github.com/$UPSTREAM/releases/download/$TAG/$PKG.tar.gz" -o "$TMP/pkg.tar.gz" \
     && tar -xzf "$TMP/pkg.tar.gz" -C "$TMP" && [ -f "$TMP/$PKG/aistudio2api" ]; then
    mkdir -p "$APP_DIR"
    cp "$TMP/$PKG/aistudio2api" "$APP_DIR/aistudio2api" && chmod 755 "$APP_DIR/aistudio2api"
    echo "$TAG" > "$APP_DIR/.termux-version"
    ok "程序：${APP_DIR}（${TAG}）"
  else
    warn "程序下载失败，面板第一次点 ▶ 时会再试"
  fi
  rm -rf "$TMP"
fi
if $IS_TERMUX && [ ! -s "$PREFIX/etc/resolv.conf" ]; then
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$PREFIX/etc/resolv.conf"
fi

# ---------- 5. 重启 / 启动酒馆并验收 ----------
ST_PORT="$(grep -E '^port:' "$CONFIG" 2>/dev/null | head -1 | awk '{print $2}')"
ST_PORT="${ST_PORT:-8000}"

find_st_pid() {
  local pid cwd
  for pid in $(pgrep -f "node.*server\.js" 2>/dev/null); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ "$cwd" = "$ST_DIR" ] && { echo "$pid"; return 0; }
  done
  return 1
}

start_st() {
  # setsid 让酒馆脱离当前终端会话，关掉这个窗口不会带走它
  if command -v setsid >/dev/null 2>&1; then
    (cd "$ST_DIR" && setsid nohup node server.js >"$ST_DIR/aistudio2api-st.log" 2>&1 </dev/null &)
  else
    (cd "$ST_DIR" && nohup node server.js >"$ST_DIR/aistudio2api-st.log" 2>&1 </dev/null &)
  fi
}

VERIFIED=false
verify() {
  local i
  for i in $(seq 1 40); do
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
  warn "酒馆正在运行（PID ${ST_PID}），要重启才能加载插件"
  if ask "现在自动重启酒馆？" y; then
    kill "$ST_PID" 2>/dev/null
    for _ in $(seq 1 10); do kill -0 "$ST_PID" 2>/dev/null || break; sleep 1; done
    start_st
    info "酒馆已在后台重启，等待插件加载…"
    verify
  else
    warn "请手动重启酒馆"
  fi
else
  if ask "酒馆没在运行，现在启动它？" y; then
    start_st
    info "酒馆已在后台启动，等待插件加载…"
    verify
  else
    warn "下次启动酒馆后生效"
  fi
fi

# ---------- 6. 完成 ----------
echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
if $VERIFIED; then
  echo -e "  ${GREEN}${BOLD}✓ 安装成功${NC}"
else
  echo -e "  ${YELLOW}${BOLD}! 已安装，重启酒馆后生效${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════════${NC}"
cat <<EOF

  打开酒馆 http://127.0.0.1:$ST_PORT → 扩展栏里的蓝色「AIStudio2API」面板
    ▶ 启动 / ■ 停止；点面板打开管理页面添加账号
  接入：API 连接 → Chat Completion → 来源 Google AI Studio → 反向代理选「AIStudio2API」

  卸载：curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/uninstall.sh | bash

EOF
