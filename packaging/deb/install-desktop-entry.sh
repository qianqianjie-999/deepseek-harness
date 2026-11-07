#!/usr/bin/env bash
# Add the desktop icon to an ALREADY INSTALLED deepseek-harness-web .deb.
#
#   sudo bash packaging/deb/install-desktop-entry.sh
#
# This avoids re-installing the ~328 MiB package just to get a launcher.
# It installs three things into the system:
#   /usr/bin/dsh-launch
#   /usr/share/applications/deepseek-harness.desktop
#   /usr/share/icons/hicolor/{512x512,scalable}/apps/deepseek-harness.{png,svg}
# Icon sources are taken from the installed payload at /opt/deepseek-harness
# (falling back to a local checkout), so no download is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/assets"
die() { printf '[fail] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root：sudo bash $0"
for b in dsh dsh-web dsh-launch; do
  [ -f "$ASSETS/$b" ] || die "缺少 $ASSETS/$b"
done
[ -f "$ASSETS/deepseek-harness.desktop" ] || die "缺少 $ASSETS/deepseek-harness.desktop"

if [ -f /opt/deepseek-harness/apps/web/dist/icon-512.png ]; then
  SRC=/opt/deepseek-harness
elif [ -f "$HERE/../../apps/web/dist/icon-512.png" ]; then
  SRC="$(cd "$HERE/../.." && pwd)"
else
  die "找不到图标源（/opt/deepseek-harness 或本地仓库）"
fi

# Overwrite ALL three commands, not just the launcher. Earlier .deb builds
# shipped a dsh-web that used plain `nohup &`; desktop sessions reap that child
# when the launcher exits, so the icon appeared to fail. Re-running this script
# upgrades an already-installed system without re-downloading the 328 MiB deb.
for b in dsh dsh-web dsh-launch; do
  install -Dm755 "$ASSETS/$b" "/usr/bin/$b"
done
install -Dm644 "$ASSETS/deepseek-harness.desktop" \
  /usr/share/applications/deepseek-harness.desktop
install -Dm644 "$SRC/apps/web/dist/icon-512.png" \
  /usr/share/icons/hicolor/512x512/apps/deepseek-harness.png
install -Dm644 "$SRC/apps/desktop/resources/icon.svg" \
  /usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate /usr/share/applications/deepseek-harness.desktop || true
fi
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true

cat <<'EOF'
桌面入口已安装，并已覆盖更新 /usr/bin/dsh、dsh-web、dsh-launch
（旧版 dsh-web 用 nohup 起服务，桌面会话可能回收子进程；已统一为 setsid）。
注意：本脚本只更新 /usr/bin 下的命令与图标，不安装 /opt/deepseek-harness 的运行时。

  点击图标  = 启动本地服务并打开浏览器（首次约 30–60 秒）
  右键图标  = Stop Web Service（停止常驻服务）
  命令行    = dsh-launch --status / --url / --stop

若报 "bundled Node not found" / "INCOMPLETE"，说明 /opt 下的运行时没落地。
先确认包是否真的登记成功：首次 dpkg -i 可能失败回滚，此时只补解 payload 不够
（服务能起，但 dpkg 数据库里仍是 not-installed，后续卸载/升级会踩坑）：
  dpkg -l | grep deepseek-harness-web     # 要看到 "ii"，不是 "un" 或无输出
  grep deepseek /var/log/dpkg.log         # 看有无 install → not-installed 回滚
状态为 ii 时，只补解 payload 即可，无需重装：
  cd ~/deepseek-harness/dist-linux
  dpkg-deb --fsys-tarfile *.deb | sudo tar -x -C / ./opt/deepseek-harness
状态不是 ii 时，先完整重装让 dpkg 登记：
  sudo dpkg -i *.deb

若仍失败，先把服务报错直接打在终端里看：
  /usr/bin/dsh-web foreground        # Ctrl+C 退出
  tail -n 40 ~/.dsh/web.log
  cat ~/.dsh/last-error.txt

若菜单里没立刻出现，注销重登一次，或运行：
  update-desktop-database ~/.local/share/applications
EOF
