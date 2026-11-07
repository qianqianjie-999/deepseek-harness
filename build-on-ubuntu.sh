#!/usr/bin/env bash
# 在 Ubuntu 上从源码编译并运行 deepseek-harness（Web UI + CLI）
#
# 用法：
#   bash build-on-ubuntu.sh            # 完整：装依赖 -> 构建 -> 起 Web UI
#   bash build-on-ubuntu.sh --deps     # 只装 Node/pnpm/系统依赖
#   bash build-on-ubuntu.sh --build    # 只构建
#   bash build-on-ubuntu.sh --web      # 只启动
#
# 已针对两个真实坑位做了处理：
#   1) engines 要求 node >= 24.9.0（发行版自带的 18/20 不行）
#   2) xlsx 走 cdn.sheetjs.com 且被限速到 ~3KB/s，需断点续传 + sha512 校验

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.9.0}"
PNPM_VERSION="${PNPM_VERSION:-11.28.5}"
NODE_HOME="${NODE_HOME:-/opt/node-v${NODE_VERSION}-linux-x64}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XLSX_URL="https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz"
XLSX_SIZE=2409319
XLSX_SHA512_B64="oLDq3jw7AcLqKWH2AhCpVTZl8mf6X2YReP+Neh0SJUzV/BdZYjth94tG5toiMB1PPrYtxOCfaoUCkvtuH+3AJA=="

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[失败] %s\033[0m\n' "$*" >&2; exit 1; }

install_deps() {
  log "安装系统依赖（原生编译需要 C 编译器 + musl-gcc）"
  if ! command -v gcc >/dev/null || ! command -v musl-gcc >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential musl-tools python3 curl xz-utils
  else
    echo "gcc / musl-gcc 已就绪"
  fi

  if [ ! -x "$NODE_HOME/bin/node" ]; then
    log "安装 Node v${NODE_VERSION} 到 ${NODE_HOME}"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      -o "$tmp/node.tar.xz"
    sudo mkdir -p /opt
    # --no-same-owner：容器/受限环境里 tar 改属主会报 Invalid argument
    sudo tar -xJf "$tmp/node.tar.xz" -C /opt --no-same-owner
    rm -rf "$tmp"
  fi
  export PATH="$NODE_HOME/bin:$PATH"

  local major minor
  major="$(node -p 'process.versions.node.split(".")[0]')"
  minor="$(node -p 'process.versions.node.split(".")[1]')"
  if [ "$major" -lt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -lt 9 ]; }; then
    die "Node 版本过低：$(node -v)，要求 >= v24.9.0"
  fi
  echo "node $(node -v)"

  if [ "$(pnpm -v 2>/dev/null || echo none)" != "$PNPM_VERSION" ]; then
    log "安装 pnpm@${PNPM_VERSION}"
    sudo npm install -g "pnpm@${PNPM_VERSION}"
  fi
  echo "pnpm $(pnpm -v)"
}

# 返回 0 表示已就绪
ensure_xlsx() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  # 只在文件不存在时创建；已下载的半成品必须保留，否则每次重跑都从 0 开始
  [ -f "$out" ] || : > "$out"

  local guard=0
  while [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -lt "$XLSX_SIZE" ]; do
    guard=$((guard + 1))
    [ "$guard" -gt 200 ] && { warn "续传 200 轮仍未完成，放弃"; return 1; }
    # 关键：每轮先确认文件头是 gzip（1f8b）。CDN 限流时会返回 XML 错误体，
    # 若直接 -C - 续传会把错误字节拼在前面，造成"大小对但内容坏"。
    if [ -s "$out" ] && [ "$(xxd -l 2 -p "$out" 2>/dev/null)" != "1f8b" ]; then
      warn "文件头不是 gzip，删除后重下"
      rm -f "$out"
    fi
    printf '\r  xlsx 进度: %s / %s 字节' \
      "$(stat -c%s "$out" 2>/dev/null || echo 0)" "$XLSX_SIZE"
    curl -sS -C - --max-time 120 -o "$out" "$XLSX_URL" || true
  done
  printf '\n'

  local actual
  actual="$(sha512sum "$out" | cut -d' ' -f1 | xxd -r -p | base64 -w0)"
  if [ "$actual" != "$XLSX_SHA512_B64" ]; then
    warn "sha512 不匹配，文件可能损坏：$out"
    return 1
  fi
  gzip -t "$out" || { warn "gzip 校验失败"; return 1; }
  echo "xlsx 校验通过"
  return 0
}

do_install() {
  cd "$REPO_DIR"
  local cache="${HOME}/.cache/dsh-xlsx/xlsx-0.20.3.tgz"
  local lockfile="$REPO_DIR/pnpm-lock.yaml"
  local backup="$lockfile.dshbak"

  log "准备 xlsx（该包在 cdn.sheetjs.com，实测被限速到 ~3KB/s）"
  if ! ensure_xlsx "$cache"; then
    warn "xlsx 未就绪，install 可能长时间卡在 cdn.sheetjs.com；可重跑本脚本继续续传"
  fi

  # 关键（已踩过两次坑，别再改回去）：
  #  1) --frozen-lockfile 只比对 importer 的 `specifier` 与 package.json。
  #     若用全局 sed 把 5 处 URL 全换掉，specifier 会跟着变成 file:/http:，
  #     直接报 ERR_PNPM_OUTDATED_LOCKFILE（2026-11-07 实测）。
  #  2) 不带 frozen 则会重新解析 xlsx，pnpm 按 package.json 的 specifier
  #     回到 cdn.sheetjs.com，撞上 3KB/s 限速，表现为卡在 resolved 207。
  # 所以：只改 packages 里那一行的 `tarball:`，其余 4 处 URL 一个都不动。
  # 用本地 HTTP 服务而非 file:，是为了让 URL 形态与原来完全一致，pnpm 走
  # 标准 fetch 路径；integrity 仍是原 tarball 的 sha512，本地文件字节一致。
  local port=18888 fname srv_pid="" ready=0
  fname="$(basename "$cache")"
  if [ -f "$cache" ]; then
    python3 -m http.server "$port" --bind 127.0.0.1 \
      --directory "$(dirname "$cache")" >/dev/null 2>&1 &
    srv_pid=$!
    cp "$lockfile" "$backup"
    # 用双引号在定义时展开：local 变量在函数返回后不可见，EXIT trap 里取不到
    trap "kill '$srv_pid' 2>/dev/null || true; mv -f '$backup' '$lockfile' 2>/dev/null || true" EXIT

    # 环境可能设了全局代理，必须让 127.0.0.1 绕过，否则本地请求被转发出去
    export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
    export no_proxy="$NO_PROXY"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS -o /dev/null "http://127.0.0.1:${port}/${fname}"; then ready=1; break; fi
      sleep 1
    done
    [ "$ready" -eq 1 ] || die "本地 xlsx 服务未就绪（127.0.0.1:${port}）"

    sed -i "s|tarball: ${XLSX_URL}|tarball: http://127.0.0.1:${port}/${fname}|" "$lockfile"
    echo "lockfile 仅 tarball 一行指向本地服务；specifier 保持原样（退出时自动还原）"
  fi

  # 上次中断若留下残缺 node_modules（缺 .modules.yaml），续跑容易反复卡住
  if [ -d node_modules ] && [ ! -f node_modules/.modules.yaml ]; then
    warn "检测到上次中断留下的残缺 node_modules，重跑前建议先执行：rm -rf node_modules"
  fi

  log "安装依赖"
  # frozen 保证跳过解析；prefer-offline 优先复用 store 里已有的 1400+ 包，
  # 只联网补缺失的 optional 原生二进制（@esbuild/linux-x64、
  # @rollup/rollup-linux-x64-gnu 等）。纯 --offline 会把它们全部排除，
  # build 阶段会缺二进制。
  if ! pnpm install --frozen-lockfile --prefer-offline; then
    die "依赖安装失败。可重跑本脚本，已复用部分不会重下。"
  fi

  kill "$srv_pid" 2>/dev/null || true
  srv_pid=""
  if [ -f "$backup" ]; then
    mv -f "$backup" "$lockfile"
    trap - EXIT
    echo "lockfile 已还原，本地 xlsx 服务已停止"
  fi
}

do_build() {
  cd "$REPO_DIR"
  log "构建全仓（pnpm run build）"
  pnpm run build
  log "构建产物自检"
  # CLI 不走打包：package.json:211 的 dsh 就是 `node --import tsx/esm apps/cli/src/bin.ts`，
  # 没有 apps/cli/dist。原来 ls 这个路径必然报错，容易被误读成构建失败。
  [ -f apps/web/dist/index.html ] || die "Web 产物缺失：apps/web/dist/index.html"
  [ -f apps/cli/src/bin.ts ] || die "CLI 入口缺失：apps/cli/src/bin.ts"
  echo "Web 产物：apps/web/dist/index.html（$(find apps/web/dist/assets -type f | wc -l) 个 assets）"
  echo "CLI 入口：apps/cli/src/bin.ts（tsx 直跑源码，无 dist）"
}

do_web() {
  cd "$REPO_DIR"
  log "启动 Web UI（http://127.0.0.1:3080）"
  # --no-open 不会自动开浏览器，且服务带鉴权：直接访问根路径返回 401 属正常。
  # 必须复制下面启动时打印的 `dsh web:` 那行带 token 的 URL 到浏览器
  # （见 packages/bundle/web-app/README.zh.md:43）。该 URL 每次启动都重新生成。
  echo "请在浏览器打开启动时打印的「dsh web:」整行 URL；裸访问 127.0.0.1:3080 会返回 401（设计如此）"
  exec pnpm dsh web --no-open
}

ACTION="${1:-all}"
case "$ACTION" in
  --deps)  install_deps ;;
  --build) export PATH="$NODE_HOME/bin:$PATH"; do_build ;;
  --web)   export PATH="$NODE_HOME/bin:$PATH"; do_web ;;
  all)     install_deps; do_install; do_build; do_web ;;
  *)       die "未知参数：$ACTION（可用：--deps / --build / --web）" ;;
esac
