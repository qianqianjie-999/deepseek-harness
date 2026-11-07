#!/usr/bin/env bash
# Build a self-contained .deb for the DeepSeek Harness Web UI + CLI.
#
#   bash packaging/deb/build-deb.sh
#   WORK=/big/disk OUT=/big/disk/pkg.deb bash packaging/deb/build-deb.sh
#   DSH_FULL_DEPS=1 bash packaging/deb/build-deb.sh   # disable closure pruning
#
# The repository has ~90k files under node_modules. Copying them into a dpkg
# staging tree is prohibitively slow on this host (file-create interception),
# so data.tar is streamed straight from the source tree with GNU tar's
# --transform, and the .deb is assembled from the three standard ar members.
# pnpm's node_modules symlinks are relative; --transform rewrites member names
# only, leaving link targets untouched, so the tree stays valid after install.
#
# Size control (two independent levers):
#   1. Production dependency closure. `pnpm list --prod --depth=Infinity --json`
#      gives every package reachable from a non-dev dependency. Only those
#      .pnpm directories are appended; the rest (build tools, test frameworks,
#      other-platform binaries) never enter the archive. The hoisted
#      .pnpm/node_modules directory is ALWAYS kept: native loaders resolve
#      through it and the service fails at boot without it.
#   2. xz instead of gzip -1. NSIS/electron-builder ship LZMA-compressed
#      payloads; xz gives a comparable ratio. dpkg reads data.tar.xz natively.
#
# Verified on 2026-11-07: with only the production closure present, `dsh web`
# still boots (token -> 303 -> cookie -> 200) and `dsh --help` works.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSETS="$REPO/packaging/deb/assets"
NODE_HOME="${NODE_HOME:-/opt/node-v24.9.0-linux-x64}"
WORK="${WORK:-/home/qianqianjie/mountSysdisk/dsh-deb-build}"
OUT_DIR="${OUT_DIR:-$REPO/dist-linux}"
VERSION="$("$NODE_HOME/bin/node" -p "require('$REPO/package.json').version")"
OUT="${OUT:-$OUT_DIR/deepseek-harness-web_${VERSION}_amd64.deb}"
FULL_DEPS="${DSH_FULL_DEPS:-0}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[fail] %s\033[0m\n' "$*" >&2; exit 1; }

[ -x "$NODE_HOME/bin/node" ] || die "bundled Node not found: $NODE_HOME/bin/node"
[ -f "$REPO/apps/web/dist/index.html" ] || die "Web frontend not built: run pnpm run build first"
[ -f "$REPO/node_modules/tsx/dist/esm/index.mjs" ] || die "tsx loader missing: run pnpm install first"
[ -f "$REPO/apps/web/dist/icon-512.png" ] || die "desktop icon missing: apps/web/dist/icon-512.png (run pnpm run build)"
[ -f "$REPO/apps/desktop/resources/icon.svg" ] || die "scalable icon missing: apps/desktop/resources/icon.svg"
command -v ar >/dev/null || die "binutils 'ar' is required"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required"
command -v xz >/dev/null || die "xz is required"
PNPM="$(command -v pnpm || true)"
[ -n "$PNPM" ] || die "pnpm is required to compute the production dependency closure"

mkdir -p "$WORK/DEBIAN" "$OUT_DIR"
# Small-file staging lives on a normal ext4 filesystem: the big WORK mount
# ignores chmod, which would force every /usr member into the same mode.
STAGE="${STAGE:-${HOME:-/home/qianqianjie}/.dsh-deb-stage}"
mkdir -p "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/512x512/apps" \
  "$STAGE/usr/share/icons/hicolor/scalable/apps"
rm -f "$WORK/data.tar" "$WORK/data.tar.gz" "$WORK/data.tar.xz" \
  "$WORK/control.tar.gz" "$WORK/debian-binary" "$OUT" \
  "$WORK/contents.txt" "$WORK/keep-dirs.txt" "$WORK/drop-dirs.txt" \
  "$WORK/prod-tree.json" "$WORK/excludes.txt"

# ---- production dependency closure -----------------------------------------
DROP_KB=0
if [ "$FULL_DEPS" = "1" ]; then
  log "DSH_FULL_DEPS=1: skipping dependency pruning (full dev tree goes in)"
else
  log "computing production dependency closure (pnpm list --prod)"
  (cd "$REPO" && "$PNPM" list --prod --depth=Infinity --json > "$WORK/prod-tree.json" 2>/dev/null) \
    || die "pnpm list --prod failed; run pnpm install first"
  "$NODE_HOME/bin/node" - "$WORK/prod-tree.json" "$REPO/node_modules/.pnpm" \
    "$WORK/keep-dirs.txt" "$WORK/drop-dirs.txt" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const [, , treeFile, pnpmDir, keepFile, dropFile] = process.argv
const tree = JSON.parse(fs.readFileSync(treeFile, 'utf8'))
const keep = new Set()
function walk (node) {
  if (!node || typeof node !== 'object') return
  if (!node.dependencies) return
  for (const dep of Object.values(node.dependencies)) {
    if (!dep || typeof dep !== 'object') continue
    if (typeof dep.path === 'string') {
      const m = dep.path.match(/node_modules\/\.pnpm\/([^/]+)/)
      if (m) keep.add(m[1])
    }
    walk(dep)
  }
}
for (const importer of tree) walk(importer)
const entries = fs.readdirSync(pnpmDir, { withFileTypes: true })
  .filter(e => e.isDirectory() || e.isSymbolicLink())
  .map(e => e.name)
  .filter(n => n !== 'node_modules')
const realKeep = [...keep].filter(n => entries.includes(n))
// pnpm's hoisted directory is not a package but native loaders resolve through it.
realKeep.push('node_modules')
const keepSet = new Set(realKeep)
const drop = entries.filter(n => !keepSet.has(n))
fs.writeFileSync(keepFile, realKeep.map(n => './.pnpm/' + n).join('\n') + '\n')
fs.writeFileSync(dropFile, drop.join('\n') + '\n')
console.log(`  importers=${tree.length} keep=${realKeep.length} drop=${drop.length} total=${entries.length + 1}`)
NODE
  DROP_KB="$(cd "$REPO/node_modules/.pnpm" && xargs -a "$WORK/drop-dirs.txt" -n 100 du -sk 2>/dev/null | awk '{s+=$1} END {print int(s)+0}')"
  log "pruning $(wc -l < "$WORK/drop-dirs.txt") non-production package dirs (~${DROP_KB} KB)"
fi

# ---- control archive -------------------------------------------------------
BASE_KB="$(du -sk \
  --exclude='.git' --exclude='dist-linux' --exclude='packaging' \
  --exclude='.workbuddy' --exclude='docs' --exclude='snapshots' \
  --exclude='benchmarks' --exclude='website' "$REPO" | cut -f1)"
NODE_KB="$(du -sk "$NODE_HOME" | cut -f1)"
SIZE_KB=$((BASE_KB + NODE_KB - DROP_KB))
sed -e "s|__VERSION__|$VERSION|" -e "s|__SIZE_KB__|$SIZE_KB|" "$ASSETS/control" > "$WORK/DEBIAN/control"
for script in postinst prerm postrm; do
  cp "$ASSETS/$script" "$WORK/DEBIAN/$script"
  chmod 755 "$WORK/DEBIAN/$script"
done
for bin in dsh dsh-web dsh-launch; do
  cp "$ASSETS/$bin" "$STAGE/usr/bin/$bin"
  chmod 755 "$STAGE/usr/bin/$bin"
done
# Desktop entry + hicolor icons. Icons come from the repo's own artwork, so
# the package carries no generated binaries and stays reproducible.
# Data files are 0644 (not executable); only the launchers are 0755.
cp "$ASSETS/deepseek-harness.desktop" "$STAGE/usr/share/applications/"
cp "$REPO/apps/web/dist/icon-512.png" \
  "$STAGE/usr/share/icons/hicolor/512x512/apps/deepseek-harness.png"
cp "$REPO/apps/desktop/resources/icon.svg" \
  "$STAGE/usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg"
chmod 644 "$STAGE/usr/share/applications/deepseek-harness.desktop" \
  "$STAGE/usr/share/icons/hicolor/512x512/apps/deepseek-harness.png" \
  "$STAGE/usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg"
# Some hosts use umask 002, which would make /usr/bin group-writable (0775).
find "$STAGE/usr" -type d -exec chmod 755 {} +
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$ASSETS/deepseek-harness.desktop" || \
    die "desktop entry failed validation"
fi
log "control: version=$VERSION installed-size=${SIZE_KB}KB (approx)"

# ---- data archive ----------------------------------------------------------
# Owner/group forced to 0: dpkg tries to chown to whatever uid tar recorded,
# and this host's sandbox rejects chown to nobody (65534).
TAR_COMMON=(--owner=0 --group=0 --numeric-owner --warning=no-file-changed)

# With pruning, exclude the whole .pnpm tree here and append only the closure
# below. Without pruning, keep everything.
PRUNE_EXCLUDE=()
if [ "$FULL_DEPS" != "1" ]; then
  PRUNE_EXCLUDE=(--exclude='./node_modules/.pnpm')
fi

log "streaming repository tree -> ./opt/deepseek-harness"
tar "${TAR_COMMON[@]}" \
  --transform='s,^\./,./opt/deepseek-harness/,' \
  --exclude='./.git' \
  --exclude='./packaging' \
  --exclude='./.workbuddy' \
  --exclude='./dist-linux' \
  --exclude='./docs' \
  --exclude='./snapshots' \
  --exclude='./benchmarks' \
  --exclude='./website' \
  --exclude='./node_modules.broken_partial' \
  --exclude='./node_modules/.dsh-parked' \
  --exclude='./apps/desktop/.desktop-build' \
  --exclude='./node_modules/.cache' \
  --exclude='*.map' \
  --exclude='*.tsbuildinfo' \
  --exclude='*.dshbak' \
  --exclude='*.log' \
  "${PRUNE_EXCLUDE[@]}" \
  -cf "$WORK/data.tar" -C "$REPO" .

if [ "$FULL_DEPS" != "1" ]; then
  log "appending production .pnpm closure ($(wc -l < "$WORK/keep-dirs.txt") dirs)"
  tar "${TAR_COMMON[@]}" \
    --transform='s,^\./,./opt/deepseek-harness/node_modules/,' \
    -rf "$WORK/data.tar" -C "$REPO/node_modules" -T "$WORK/keep-dirs.txt"
fi

log "streaming Node 24 -> ./opt/deepseek-harness/node24 (about 211 MB)"
tar "${TAR_COMMON[@]}" \
  --transform='s,^\./,./opt/deepseek-harness/node24/,' \
  -rf "$WORK/data.tar" -C "$NODE_HOME" .

log "appending /usr (launchers, desktop entry, icons)"
# Staged on ext4, so real permissions survive: 0755 for executables and
# directories, 0644 for the desktop entry and icons.
tar "${TAR_COMMON[@]}" -rf "$WORK/data.tar" -C "$STAGE" ./usr

log "compressing data.tar with xz -6 -T0 (LZMA-class ratio; may take minutes)"
# Pipe through stdout: `xz -f` tries to fchown the output to the input's owner,
# which this build partition (always 0777/nobody) rejects with EINVAL.
xz -6 -T0 -c "$WORK/data.tar" > "$WORK/data.tar.xz"

tar "${TAR_COMMON[@]}" --mode='u=rwx,go=rx' -czf "$WORK/control.tar.gz" \
  -C "$WORK/DEBIAN" control postinst prerm postrm
printf '2.0\n' > "$WORK/debian-binary"

log "assembling $OUT"
(cd "$WORK" && ar r "$OUT" debian-binary control.tar.gz data.tar.xz >/dev/null 2>&1)

# ---- verification ----------------------------------------------------------
log "verifying package"
dpkg-deb --info "$OUT" | head -20
# Walk the data archive ONCE; re-decompressing per check is wasteful.
dpkg-deb --fsys-tarfile "$OUT" | tar -tf - > "$WORK/contents.txt"
ENTRIES="$(wc -l < "$WORK/contents.txt")"
echo "data.tar entries: $ENTRIES"
# Check packaged modes, not staging modes: the build mount ignores chmod, so
# the archive index is the only authority on what dpkg will actually install.
dpkg-deb --contents "$OUT" > "$WORK/contents-full.txt"
check_mode() {
  got="$(awk -v p="$1" '$NF == p {print $1; exit}' "$WORK/contents-full.txt")"
  [ "$got" = "$2" ] || die "$1 packaged as '$got', expected '$2'"
  echo "  ok  $1 ($got)"
}
check_mode './usr/bin/' 'drwxr-xr-x'
check_mode './usr/bin/dsh-launch' '-rwxr-xr-x'
check_mode './usr/share/applications/deepseek-harness.desktop' '-rw-r--r--'
check_mode './usr/share/icons/hicolor/512x512/apps/deepseek-harness.png' '-rw-r--r--'
for expected in \
  './usr/bin/dsh' \
  './usr/bin/dsh-web' \
  './usr/bin/dsh-launch' \
  './usr/share/applications/deepseek-harness.desktop' \
  './usr/share/icons/hicolor/512x512/apps/deepseek-harness.png' \
  './usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg' \
  './opt/deepseek-harness/apps/web/dist/index.html' \
  './opt/deepseek-harness/apps/cli/src/bin.ts' \
  './opt/deepseek-harness/node24/bin/node' \
  './opt/deepseek-harness/node_modules/tsx'; do
  if grep -Fxq "$expected" "$WORK/contents.txt"; then
    echo "  ok  $expected"
  else
    die "missing from package: $expected"
  fi
done
# tar records directories with a trailing slash; match by prefix instead.
# This hoisted tree is essential: native loaders resolve through it.
if grep -q '^\./opt/deepseek-harness/node_modules/\.pnpm/node_modules/' "$WORK/contents.txt"; then
  echo "  ok  .pnpm/node_modules/ (hoisted tree)"
else
  die "missing from package: hoisted .pnpm/node_modules tree"
fi
# node_modules/tsx is a pnpm symlink, so the real loader lives under .pnpm/.
if grep -Eq '^\./opt/deepseek-harness/node_modules/\.pnpm/tsx@[^/]+/node_modules/tsx/dist/esm/index\.mjs$' "$WORK/contents.txt"; then
  echo "  ok  .pnpm/tsx@*/node_modules/tsx/dist/esm/index.mjs (symlink target)"
else
  die "missing from package: tsx esm loader under .pnpm"
fi
if [ "$FULL_DEPS" != "1" ]; then
  # A dangling hoisted symlink may still carry the name; check the real .pnpm dir.
  if grep -q '/\.pnpm/electron-winstaller@' "$WORK/contents.txt"; then
    die "dependency pruning did not take effect (electron-winstaller still present)"
  fi
  echo "  ok  dev-only packages absent (.pnpm/electron-winstaller@*)"
  echo "  pruned package dirs: $(wc -l < "$WORK/drop-dirs.txt")"
fi
echo
echo "package: $OUT ($(du -h "$OUT" | cut -f1), xz data archive)"
echo "install: sudo dpkg -i $OUT"
echo "run:     click 'DeepSeek Harness' in the app menu"
echo "         or: dsh-web start && dsh-web url"
