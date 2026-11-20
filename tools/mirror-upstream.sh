#!/usr/bin/env bash
# 把上游 AIStudio2API 备份到 fork：
#   1. 源码：fork 的 main 跟上游同步
#   2. 发布包：上游最新版的命令行包 + Windows 包，复制到 fork 同名 release
#   3. 编译依赖：上游构建用的 SpiderMonkey / libwebp 静态库，复制到 fork 的 deps-* release
# 上游删库或停更时，安装脚本和插件自动改用 fork；必要时可用 fork 的源码 + 依赖自行编译。
# 需要已登录的 gh。每天由 LaunchAgent 运行，可重复运行。
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

UP="Mag1cFall/AIStudio2API"
FORK="${AISTUDIO2API_FORK:-shleeshlee/AIStudio2API}"
log() { echo "$(date '+%F %T') $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 源码 ----------
if ! gh repo view "$UP" >/dev/null 2>&1; then
  log "上游不可访问（删库或改名？），本次只保留 fork 现状"
  exit 0
fi
if gh repo sync "$FORK" --source "$UP" >/dev/null 2>&1; then
  log "源码已同步"
else
  log "源码同步失败（fork 有自己的改动时需要手动合并）"
fi

# ---------- 2. 发布包 ----------
TAG="$(gh release view -R "$UP" --json tagName -q .tagName 2>/dev/null || true)"
if [ -z "$TAG" ]; then
  log "上游没有可用的 release"
elif gh release view "$TAG" -R "$FORK" >/dev/null 2>&1; then
  log "发布包 $TAG 已备份"
else
  mkdir -p "$TMP/rel"
  if gh release download "$TAG" -R "$UP" -D "$TMP/rel" \
       -p '*-linux-*.tar.gz' -p '*-darwin-*.tar.gz' -p '*-windows-*.zip'; then
    NOTES="备份自上游 [$UP $TAG](https://github.com/$UP/releases/tag/$TAG)，文件未改动。上游可用时请优先使用上游。"
    gh release create "$TAG" -R "$FORK" --title "$TAG" --notes "$NOTES" "$TMP/rel"/* >/dev/null \
      && log "发布包 $TAG 已备份（$(ls "$TMP/rel" | wc -l | tr -d ' ') 个文件）" \
      || log "发布包 $TAG 上传失败"
  else
    log "发布包 $TAG 下载失败"
  fi
fi

# ---------- 3. 编译依赖 ----------
ACTION="$(gh api "repos/$FORK/contents/.github/actions/static-libraries/action.yml" -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)"
SM="$(printf '%s\n' "$ACTION" | sed -nE 's/^[[:space:]]*SPIDERMONKEY:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
WEBP="$(printf '%s\n' "$ACTION" | sed -nE 's/^[[:space:]]*LIBWEBP:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
if [ -z "$SM" ] || [ -z "$WEBP" ]; then
  log "读不到编译依赖版本（上游构建方式可能变了），跳过"
  exit 0
fi
DEPS_TAG="deps-sm-$SM-webp-$WEBP"
if gh release view "$DEPS_TAG" -R "$FORK" >/dev/null 2>&1; then
  log "编译依赖 $DEPS_TAG 已备份"
  exit 0
fi
mkdir -p "$TMP/deps"
if gh release download "$SM" -R Mag1cFall/firefox -D "$TMP/deps" -p 'spidermonkey-*' \
   && gh release download "$WEBP" -R Mag1cFall/libwebp -D "$TMP/deps" -p 'libwebp-*'; then
  NOTES="上游构建所需静态库备份：SpiderMonkey ${SM}（Mag1cFall/firefox，MPL-2.0）、libwebp ${WEBP}（Mag1cFall/libwebp，BSD）。用法见上游 .github/actions/static-libraries/action.yml，下载地址换成本 release。"
  gh release create "$DEPS_TAG" -R "$FORK" --title "$DEPS_TAG" --notes "$NOTES" --latest=false "$TMP/deps"/* >/dev/null \
    && log "编译依赖 $DEPS_TAG 已备份" \
    || log "编译依赖上传失败"
else
  log "编译依赖下载失败"
fi
