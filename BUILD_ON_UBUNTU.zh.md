# deepseek-harness 在 Ubuntu 上编译运行 —— 实测结论

> 实测日期：2026-11-06 ~ 11-07　机器：Ubuntu 24.04.5 LTS / x86_64 / glibc 2.39 / 内核 7.0.0
> 11-07 在真实终端跑通完整链路：`装依赖 → 构建 → Web UI 监听 3080`。

## 一、结论先行

| 交付形态 | Ubuntu 能否产出 | 11-07 实测 | 依据 |
|---|---|---|---|
| CLI（`dsh`） | ✅ 能 | ✅ `--help` rc=0 | `package.json:211`，tsx 直跑 `apps/cli/src/bin.ts` |
| Web UI（`dsh web`） | ✅ 能 | ✅ 127.0.0.1:3080 LISTEN | `apps/web/dist/index.html` + 147 个 assets |
| Python SDK | ✅ 能 | 未跑 | 纯 Python，`python/sdk/pyproject.toml` |
| 桌面安装包（AppImage / deb） | ❌ 需移植发布链路 | 未打 | 三目标白名单 + 单测显式断言 Linux 应被拒绝（见第七节） |

**一句话**：源码在 Ubuntu 上能编译运行（Web + CLI）；**官方 Electron 桌面端没有 Linux 发布目标，要出 AppImage/deb 是新增平台的移植工作，不是改几行白名单**（详见第七节）。11-07 复核：官方 CDN 实测无 Linux 包（4 个命名全 404），但存在第三方社区版 Linux deb（225.8 MB，非官方、未验安装），见第九节。

CI 主构建全跑 Ubuntu 24.04（`.github/workflows/ci.yml:43-48`），`native/system/docs/support-matrix.md:5` 标注 linux-x64 builder = ubuntu-24.04，与本机一致。

## 二、11-07 全链路实测记录

```text
pnpm install --frozen-lockfile --prefer-offline   → Done in 24s using pnpm v11.28.5
lockfile 已还原，本地 xlsx 服务已停止
pnpm run build → run-gates: 10 gate(s) / 10 worker(s)
  PASS native addon (1.11s) / Host Typert (8.79s) / host compiler (62.91s)
  PASS Host bundle (7.72s) / Desktop bundle (2.34s) / ...
pnpm dsh web --no-open → 127.0.0.1:3080 LISTEN
```

复核证据（本机命令输出，非推测）：

| 检查项 | 结果 |
|---|---|
| `git status --porcelain` | 仅 3 个未跟踪项（脚本 / 本文 / `.workbuddy/`），lockfile 无改动 |
| `grep -n cdn.sheetjs.com pnpm-lock.yaml` | 5 处 URL 全部在原位（6382/6383/26318/26319/34337） |
| `apps/web/dist` | 11-07 14:00 生成，`index.html` 1008 B，`assets/` 147 个文件 |
| `ss -ltnp \| grep 3080` | `LISTEN 127.0.0.1:3080` |
| `ps -eo args \| grep tsx scripts/build` | 无残留 → 构建进程已正常退出 |
| `node --import tsx/esm apps/cli/src/bin.ts --help` | rc=0，输出完整 Usage |
| 带启动 token 请求 `/?token=...` | `303 See Other` + `location: ./` + `Set-Cookie: dsh-auth-...`（签名会话，`Max-Age=2592000`，`HttpOnly; SameSite=Strict`） |
| 带该 cookie 请求 `/` | **200，40478 B**，运行时组装的 HTML，含完整插件清单（`dsh-client-ui-*` / `dsh-api-*` 等）、favicon、manifest |
| 不带 cookie 请求 `/`（对照） | 401 + `dsh web authentication required; reopen the URL printed by dsh web.` |
| 同一个启动 token 连续交换 2 次 | 两次都是 303 → token 可重复换取 cookie，不会被消费掉 |

> 至此 Web UI 从「端口在听」升级为**页面级实证**：能换会话、能返回完整前端页面。

> 构建 10 个 gate 全 PASS 是**推断**：日志片段停在 `start client compiler`，但 14:08 补到的终端输出已出现 `==> 构建产物自检` / `==> 启动 Web UI`，配合脚本 `set -euo pipefail`（构建非 0 就不会往下走）与 3080 监听，可确认 `pnpm run build` 正常返回。未直接看到后半段 PASS 行。
> 另注：那次自检只打印 `apps/web/dist`，是**改前的旧脚本**——原写法 `ls -d apps/web/dist apps/cli/dist 2>/dev/null || true` 把不存在的 `apps/cli/dist` 报错吞了，看着像只构建了一半。现已改为明确校验并打印两行，下次跑 `--build` 生效，不影响本次结果。

原生组件（`native/system`）另已单独编译加载成功，参数取自 `native/system/scripts/build.ts:52-60`，`-Werror` 零告警：`musl-gcc -static` 产出 `landlock-run`（静态 ELF）、`gcc -shared -fPIC` 产出 `system.node`，`node -e "Object.keys(require('./system.node'))"` → `[ 'tryLock' ]`。`node_api.h` 取自 `process.execPath` 解析的 Node 安装目录（`build.ts:42`）。

## 三、两个真实门槛

### 门槛 1：Node 版本

`package.json:7-9` 要求 `"node": ">=24.9.0"`，Ubuntu 24.04 源里是 18/20，**必须显式装 Node 24**。CI 主版本 pin 在 24（`.github/workflows/ci.yml:9`），兼容腿测 24.9（`scripts/run-gates.ts:100`）。本机装在 `/opt/node-v24.9.0-linux-x64/bin/node`。

### 门槛 2：`cdn.sheetjs.com` 限速（最容易卡死的一步）

唯一依赖 xlsx 的地方是 `packages/client/ui-sidebar-documentpreview/package.json:89` 的 devDependency：

```
"xlsx": "https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz"
```

实测 CDN 限速 **300 B/s ~ 3 KB/s**（2.4 MB 要 1~2 小时），且该包已从公共 registry 撤下（npmmirror `NoSuchKey`），**没有镜像可用**。校验值：size `2409319`，magic `1f8b`，sha512 `oLDq3jw7AcLqKWH2AhCpVTZl8mf6X2YReP+Neh0SJUzV/BdZYjth94tG5toiMB1PPrYtxOCfaoUCkvtuH+3AJA==`。

**最终解法（已实证闭环）**：断点续传拿到原包 → 本地 `python3 -m http.server 18888` 提供 → **只改 lockfile 第 26319 行的 `tarball:` 为 `http://127.0.0.1:18888/xlsx-0.20.3.tgz`** → `pnpm install --frozen-lockfile --prefer-offline` → trap 还原 lockfile、停服务。

> ⚠️ **踩过两次的坑，别改回去**：
> 1. xlsx 在 lockfile 里共 5 处 URL。第 `6382` 行是 importer 的 `specifier`，`--frozen-lockfile` 拿它和 package.json 比对；第 `26319` 行的 `tarball` 才是实际取包地址。**全局 sed 替换 5 处会改掉 specifier → `ERR_PNPM_OUTDATED_LOCKFILE`**。
> 2. 去掉 frozen 兜底会让 pnpm 按原始 specifier 重新解析，回到 3KB/s CDN，表现为**卡在 `resolved 207`**。
> 3. 用本地 HTTP 而非 `file:`：URL 形态与原值一致，pnpm 走标准 fetch，integrity 仍是原 sha512（本地文件字节相同）。同时必须 `export NO_PROXY=127.0.0.1,localhost`，否则本地请求被全局代理转走。
> 4. 断点续传陷阱：`curl -C -` 遇到限流返回的 XML 错误体会把错误字节拼到文件头，结果**大小对、sha512 不对、`gzip -t` 失败**。每轮续传前必须检查文件头是 `1f8b`，不是就删掉重下；已下载的半成品要保留。

只改 tarball 后 pnpm 输出 `Lockfile is up to date, resolution step is skipped` + `resolved 1432`，完全不碰 CDN。安装 24 秒完成。

## 四、完整步骤（正常 Ubuntu 机器）

```bash
cd ~/deepseek-harness
git checkout pnpm-lock.yaml     # 确保 lockfile 干净
rm -rf node_modules            # 上次中断的残缺目录不要续用
./build-on-ubuntu.sh           # 装依赖 → 构建 → 起 Web UI
```

脚本支持 `--deps` / `--build` / `--web` 分段执行。手动等价步骤：装 `build-essential musl-tools python3` → 装 Node 24 并 `export PATH=/opt/node-v24.9.0-linux-x64/bin:$PATH` → `npm i -g pnpm@11.28.5` → `pnpm install --frozen-lockfile`（卡 CDN 见第三节）→ `pnpm run build` → `pnpm dsh web`。

**访问 Web UI 的关键点**：脚本用 `--no-open`，服务带鉴权，直接 `curl http://127.0.0.1:3080/` 返回 **401 是设计行为，不是失败**（提示文本来自 `packages/client/connection/src/browser-auth.ts:392`）。启动时终端打印 `dsh web: http://127.0.0.1:3080/?token=<启动 token>`（生成处 `packages/bundle/web-app/src/index.ts:231`），**必须复制整行到浏览器**：

```text
浏览器 GET /?token=...  → 303 → location: ./ + Set-Cookie（签名会话）
浏览器 GET /（带 cookie）→ 200，完整前端页面
```

依据 `packages/bundle/web-app/README.zh.md:43,67`。会话 cookie `Max-Age=2592000`（30 天），绑定 authority `127.0.0.1:3080`；**启动 token 每次重启重新生成、可重复换取 cookie，不会被一次性消费**。URL 找不到了就重跑 `./build-on-ubuntu.sh --web` 再打印。注意别把带 token 的 URL 贴到公开场合，它等同于本机会话凭据。

安装时若看到 `[WARN] Request took ... registry.npmmirror.com` 是在补 optional 原生二进制元数据（`@esbuild/linux-x64`、`@rollup/rollup-linux-x64-gnu`），不是卡死；纯 `--offline` 反而会把这些二进制排除，导致 build 阶段缺文件。

## 五、沙箱环境限制（历史背景，正常机器不会遇到）

11-06 首次尝试在受控沙箱内跑，文件创建 syscall 被统一拦截，单文件约 **0.15 s**：200 个文件在 nvme 30.1s、`/dev/shm` 36.4s、`mountDisk` 37.8s，而 `dd` 200MB 仅 0.1s（2.1 GB/s）。连 tmpfs 都慢，说明瓶颈不在磁盘。加上长任务被看门狗 SIGTERM、安全删除 shim 需 `GENIE_TRASH_DIR`、`HOME` 未设导致 pnpm 读 `/root/.npmrc` EACCES，当时未能在本环境跑完构建。

**11-07 由真实终端执行已完成验证**，上述限制不影响结论。另记：本机 `pnpm`/`git` 按 passwd 家目录找 `/root`，跑 Node 相关命令时显式 `export HOME=/home/qianqianjie`。

## 六、现场状态

- `pnpm-lock.yaml` 与 HEAD 一致（`git diff` 空），源码零修改；新增仅 `build-on-ubuntu.sh`、`BUILD_ON_UBUNTU.zh.md` 与 `.workbuddy/`（均未跟踪）。
- xlsx 缓存保留在 `~/.cache/dsh-xlsx/xlsx-0.20.3.tgz`，重跑脚本直接复用，不会再连 CDN。
- Python SDK 未在本轮跑测试，属于未验证项。

## 七、Linux 桌面包（AppImage / deb）复核 —— 两次结论修正

**第一次（11-06）**：「❌ 不能，除非改代码」，依据只有 `package-target.ts:53` 的三个目标。
**第二次（11-07 14:12）**：发现 `electron-builder.config.mjs:257` 已有 `linux: { target: ['AppImage'] }`，据此判断「补 3 个文件、10 行即可出包」——**这个判断是错的，现予撤回**。config 里留了 linux 段，不代表发布链路支持 Linux。

### 决定性反证：不支持 Linux 是显式设计，且有单测守着

| 测试 | 断言 |
|---|---|
| `apps/desktop/tests/package-target.spec.ts:29` | `resolveDesktopPackageTarget('linux-x64', 'linux', 'x64')` **应抛** `/unsupported target/` |
| `apps/desktop/tests/desktop-build-paths.spec.ts:82` | `desktopTargetPlatform('linux-x64')` **应抛** `/unsupported target/` |
| `apps/desktop/tests/desktop-build-paths.spec.ts:91-92` | `resolveDesktopBuildTarget({}, 'linux', 'x64')`、`desktopTargetBuildPaths('linux-x64')` **应抛** |
| `apps/desktop/tests/desktop-auto-update-environment.spec.ts:111-112` | `resolveDesktopAutoUpdateTarget('linux','x64')`、`desktopBuildRecordFilename('linux-x64')` **应抛** |

放行白名单而不改这些测试，CI 必挂；改了测试，等于擅自变更项目的发布平台契约。

### 发布链路里的 mac/win 硬假设（远不止白名单）

| 位置 | 问题 |
|---|---|
| `apps/desktop/scripts/prepare-runtime.ts:30` | Electron 可执行文件只有 `electron.exe` / `Electron.app/...`，Linux 应为 `electron` |
| `apps/desktop/scripts/prepare-cli.ts:11` | `platform: 'darwin' \| 'win32'`，`chmod` 只在 darwin 做 |
| `apps/desktop/scripts/desktop-package-environment.mjs:61,68,125` | 读 `.env.macos` 或 `.env.windows`；非 darwin 一律走 `resolveWindowsPackageSettings()` |
| `apps/desktop/scripts/desktop-toolchain-preflight.ts:78,95` | 类型只有 `'darwin' \| 'win32'` |
| `apps/desktop/scripts/desktop-build-paths.mjs:78-84` | `desktopTargetPlatform()` 映射表只有 mac/win 两条 |
| `upload-target.ts:15`、`desktop-publish-targets.ts:11`、`desktop-publish-route.ts:16,31`、`retain-desktop-ci.ts:56`、`smoke-packaged-runtime.ts:13`、`desktop-publication-summary.ts:40`、`desktop-website-installer.ts:43` | 上传 / 发布路由 / CI 保留 / 冒烟 / 安装页全部按三目标硬编码 |

自动更新体系本身不支持 Linux（`desktop-auto-update-environment.spec.ts:111`）。**复用官方发布链路出 AppImage/deb ≈ 新增一个发布平台**，涉及 15+ 文件与一批单测契约，不是"放行白名单"。

### 本机验证条件也不具备

- `apps/desktop/node_modules/electron/dist/electron` 不存在，`~/.cache/electron` 也没有 → 本机**没有 Electron Linux 二进制**。
- electron-builder 需拉 ~100 MB Electron release + appimagetool；本机 HTTPS 直连 github.com:443 不通（SSH 通），要挂 `ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/`，能否拿全未验。
- 体积：`files` 会把 `buildPaths.dsh` 整棵运行时树（含 2.1 GB `node_modules`）装进 asar；`apps/web/dist` 单独只有 22 MB。

**最终结论**：`apps/web/dist` + CLI 这条已跑通的链路可以打包分发；**官方 Electron 桌面端的 Linux 安装包需要真正的平台移植工作，且本机无法验证出包**。因此本轮**不改动任何现有源码与测试**（保持 `git diff` 干净、现有单测契约不变）。零回归的可行路径是另写独立打包配置，不 import 那套 mac/win 发布编排。

## 八、Web 服务 deb（方案 2，11-07 已实测）

不改任何现有源码，新增 `packaging/deb/`，把已跑通的 Web UI + CLI 打成自包含 `.deb`。

```bash
bash packaging/deb/build-deb.sh              # 产物在 dist-linux/
sudo dpkg -i dist-linux/deepseek-harness-web_0.2.2-rc.1_amd64.deb

# 方式 A（推荐）：应用菜单搜 "DeepSeek Harness"，点图标自动起服务并开浏览器
#                右键图标 → Stop Web Service 停掉常驻服务
# 方式 B（命令行）：
dsh-web start        # 后台启动，监听 127.0.0.1:3080
dsh-web url          # 打印带 token 的 URL，复制整行到浏览器
dsh-web stop         # 停止；status / foreground 亦可用
dsh --help           # CLI
```

> 已装旧包、只是缺图标的机器，不必重下 328 MiB：`sudo bash packaging/deb/install-desktop-entry.sh`（详见第十一节）。

| 包内路径 | 内容 |
|---|---|
| `/opt/deepseek-harness/` | 整个运行时树（源码、`node_modules`、`apps/web/dist`） |
| `/opt/deepseek-harness/node24/` | 内置 Node 24.9.0，不依赖系统 Node |
| `/usr/bin/dsh` | CLI 启动器（`DSH_ROOT` / `DSH_NODE` 可覆盖，便于源码直跑） |
| `/usr/bin/dsh-web` | 启停 / 取 URL；日志与 pid 在 `$DSH_HOME`（默认 `~/.dsh`） |
| `/usr/bin/dsh-launch` | 桌面图标入口：起服务 + 打开带 token 的 URL（11-07 16:00 补，见第十一节） |
| `/usr/share/applications/deepseek-harness.desktop` | 桌面入口，`Development` 分类，含 Stop Action |
| `/usr/share/icons/hicolor/{512x512,scalable}/apps/` | 鲸鱼 logo（PNG 512 + SVG），取自仓库自带资源 |
| `DEBIAN/` | `control` + `postinst` / `prerm` / `postrm`（卸载保留 `~/.dsh` 用户数据） |

**四个设计要点**：

1. **流式组装**：仓库 `node_modules` 有 9 万文件，落地到 dpkg staging 树在本机需数小时。改为 GNU tar `--transform` 直接从源树生成 `data.tar`，再手工组装标准 ar 三成员（`debian-binary` / `control.tar.gz` / `data.tar.xz`；现行版已由 gzip -1 换成 xz，见第十节）。`--owner=0 --group=0 --numeric-owner` 必需，否则 dpkg 解 control 时 chown 到 nobody 会失败。
2. **保留 pnpm 相对符号链接**：`--transform` 只改成员名、不改链接目标，解包到 `/opt` 后 `node_modules/tsx -> .pnpm/tsx@.../node_modules/tsx` 依然有效。
3. **绝对路径 tsx loader**：`/usr/bin/dsh` 用 `--import "$DSH_ROOT/node_modules/tsx/dist/esm/index.mjs"`，而非 `package.json:211` 的裸 `--import tsx/esm`（后者按 cwd 解析，换个目录就 `ERR_MODULE_NOT_FOUND`）。这样用户的工作目录不被改变。
4. **`umask 077`**：项目会因 `~/.dsh/.credentials.yaml` 组/其他可读而拒绝启动（实测 `credentials-local` 报错），默认 umask 022 会创建 644。包内服务已收紧，实测生成 600。

**实测结果**：

| 检查 | 结果 |
|---|---|
| `dpkg-deb --info` | 正确解析 control（Package / Version / Depends / Installed-Size） |
| `dpkg-deb --fsys-tarfile` | 154982 条；`/usr/bin/dsh`、`dsh-web`、`apps/web/dist/index.html`、`node24/bin/node`、pnpm 符号链接及其 `.pnpm` 目标文件齐全 |
| `dsh --help` | rc=0，Usage 完整 |
| `dsh-web start` | 打印带 token 的启动 URL |
| `dsh-web url` | 正确从日志提取 URL |
| `GET /?token=...` | `303 See Other` + `Set-Cookie` |
| 带 cookie `GET /` | **200 / 40590 B**（完整前端页） |
| 不带 cookie `GET /` | 401（对照，设计行为） |
| `dsh-web stop` / `status` | 正常停止 |
| `.credentials.yaml` | mode 600 |
| 包内 `/usr/bin/dsh*` 权限 | 755（初版用 `tar --mode` 强制；构建分区忽略 chmod，否则会装成 777。现行版改由 ext4 staging 决定，详见第十一节） |

**验证边界（如实说明）**：上述启停与 HTTP 验证是用包内**同一份脚本**、通过 `DSH_ROOT` / `DSH_NODE` / `DSH_BIN` 覆盖指向源码目录实跑的，没有执行 `sudo dpkg -i` 全量安装——本机沙箱创建单文件约 0.15 s，15.5 万个文件不现实。包本身的结构、控制信息、文件清单已直接对 `.deb` 验证。真实终端安装一步未验成。

**已知限制（初版，已被第十节瘦身取代）**：初版包约 848 MiB（gzip -1），装完 2.71 GiB（`Installed-Size: 2843876` KB，构成见第九节）；**现行版本为 328 MiB / 1.79 GiB**。架构仅 amd64；`dsh plugin` 子命令需要 pnpm（包内有 `corepack`，首次调用会按需下载），但 `dsh web` 不依赖 pnpm；服务只监听 loopback。

**沙箱特有的两个坑（真实终端不会遇到）**：`node-safe-delete-shim` 写 `/tmp` 报 `SAFE_DELETE_BULK_GUARD_ERROR ENOSPC`（需 `TMPDIR` 指到大分区 + `CODEBUDDY_SAFE_DELETE_ENABLED=0`）；`mountSysdisk` 挂载强制文件 777，导致凭据文件被拒（改用普通 ext4 家目录）。

## 九、11-07 15:00 复核：2.8 GB 的构成，以及与 Windows 的对比

### 数字（前两行是实测，不是估算）

| 项目 | 安装包 | 安装后 | 证据 |
|---|---|---|---|
| 本仓自打 Web deb | 848 MB | **2.71 GiB（2.8 GB）** | `dpkg-deb --info` → `Installed-Size: 2843876 KB` |
| 官方 Windows NSIS | **293,425,336 B = 280 MiB（293 MB）** | 未公开 | `curl -I https://download.deepseek.com/desktop/dsh-latest-windows-x64.exe` → `content-length`，`Last-Modified: 2026-11-05` |
| 官方 Linux 安装包 | **不存在** | — | 同 CDN 试 `dsh-latest-linux-{x64,amd64,debian-x64,arm64}.deb` 全 404；`dsh-latest-macos-arm64.dmg` 返回 200 作对照 |
| 第三方社区 Linux deb | 225.8 MB（amd64）/ 220.4 MB（arm64） | 未验 | `citrusli2026/dsh-desktop` v0.2.2-alpha.3.shell.0，下载页数据，**非官方** |

**官方 Windows 装完占多少**：官方未公开。按本机实测压缩比 848 MB / 2.71 GiB ≈ 0.31 外推，NSIS 用 LZMA 压缩更强，估 0.8–1.3 GB。**这是推断，不是实测**；`apps/desktop/packaging/README.md:295` 明确要求区分 installer size 与 filesystem size，两者不等价。

### 2.8 GB 拆开看

| 组成 | 大小 | 占比 |
|---|---|---|
| `node_modules/.pnpm`（1434 个包，完整开发依赖树） | 2.1 GB | 77% |
| `packages/`（全仓 TS 源码与构建产物） | 330 MB | 12% |
| 内置 Node 24 | 211 MB | 8% |
| `apps/`（其中真正要用的 `apps/web/dist` 仅 22 MB） | 44 MB | 1.6% |
| `docs/`、`snapshots/`、`scripts/` 等 | 46 MB | 1.7% |

其中：带 `*linux-x64*` 的平台专用二进制合计 **812 MB**（`@openai/codex` 320 MB、`@anthropic-ai/claude-agent-sdk` 206 MB、`@napi-rs/canvas` 33 MB、`sherpa-onnx` 32 MB、`@rolldown/binding` 27 MB 等）；devDependencies（vitest / playwright / typescript / oxlint / @types）约 167 MB；各包 `tests` 目录约 38 MB。

### 技术结论：差距在打包方式，不在软件本身

官方桌面包走两道裁剪，本包一道都没做：

1. `apps/desktop/scripts/prepare-dsh.ts:140` — `pnpm install --prod --frozen-lockfile --trust-lockfile`，只装**生产依赖闭包**；本包直接把含 devDependencies 的完整 `node_modules` 打进 `data.tar`。
2. `desktopRuntimeFileExclusion(relative(modules, source), target, officeEngine)`（`prepare-dsh.ts:148-152`）— 按目标平台剔除用不到的二进制与 LibreOffice 引擎；`apps/desktop/packaging/README.md:289` 说明只打首方生产闭包。本包全平台变体照单全收。

因此 848 MB / 2.8 GB 是「把整个开发仓库塞进 deb」的结果，不是 Web UI 运行时的体量（`apps/web/dist` 22 MB）。要对齐官方 280 MB 量级，需先生成干净的生产运行时树再打包，`build-deb.sh` 的 tar 范围要跟着改；**本轮未做，未实测瘦身后的数字**。

### 第三方社区版（附注，非推荐默认项）

`github.com/citrusli2026/dsh-desktop` v0.2.2-alpha.3.shell.0（2026-11-04）提供 Linux amd64/arm64 deb，内置官方内核 `@deepseek-ai/dsh` 0.2.2-alpha.3，附 `.sha256` 与 GitHub Actions 来源证明（release body 建议 `gh attestation verify`）。**不是 DeepSeek 官方产物**：官方仓库 `deepseek-ai/deepseek-harness` 的 releases assets 全为空，官方 CDN 也无 Linux 包。本机 HEAD 其 GitHub release 直链超时（curl rc=28），**下载与安装均未验成**。

## 十、11-07 15:40 瘦身实施（方案 1，已实跑）

目标：把 848 MiB / 2.71 GiB 压到官方量级，不改任何现有源码与测试。

### 两根杠杆

| 杠杆 | 做法 | 依据 |
|---|---|---|
| 生产依赖闭包 | `pnpm list --prod --depth=Infinity --json` 算闭包，只把 508 个 `.pnpm` 目录追加进 `data.tar`，裁掉 925 个 | `packaging/deb/build-deb.sh`；闭包由 pnpm 自己算，等价于 `pnpm install --prod` 的语义 |
| xz 压缩 | `data.tar.xz`（`xz -6 -T0`）替代 `data.tar.gz`（gzip -1） | 官方 NSIS/electron-builder 走 LZMA 类压缩；dpkg 原生支持 xz，已用原型验证 `--fsys-tarfile` 可读 |

另排除 `docs/` `snapshots/` `benchmarks/` `website/`（约 35 MiB）、`*.map`、`*.tsbuildinfo`。

### 结果（统一 MiB / GiB 口径）

| 指标 | 瘦身前 | 瘦身后 | 变化 |
|---|---|---|---|
| 安装包 | 848 MiB | **328 MiB**（343,571,730 B） | **−61.3%** |
| 装完（`Installed-Size`） | 2.71 GiB | **1.79 GiB**（1,872,420 KB，近似） | −34.2% |
| `data.tar` 条目 | 154982 | 88822 | −66160 |
| `.pnpm` 包目录 | 1434 | 508 | −925 |
| 对照官方 Windows 安装包 | — | 280 MiB | 新包大 **17.1%** |

### 四个关键实现点

1. **不能直接 `pnpm install --prod`**：根 `package.json` 的 83 个依赖**全是 devDependencies**（`dependencies: 0`），直接 `--prod` 会把整棵树砍空。改为用 `pnpm list --prod` 按 394 个 workspace importer 各自的 `dependencies` 算闭包。`tsx@4.23.13` 恰好在闭包内，CLI 启动器 `node --import tsx/esm apps/cli/src/bin.ts` 保住。
2. **`.pnpm/node_modules`（hoisted 目录）必须保留**：第一轮 park 冒烟误把它裁掉后，`node-addon-require-builtin` 的原生 `.node` 加载失败、`dsh web` 起不来；补回后全绿。该目录只有 2.6 MiB，但承担原生 loader 解析。
3. **流式追加而非 925 条 exclude**：主 tar 用 `--exclude='./node_modules/.pnpm'` 跳过整棵树，再用 `tar -r -T keep-dirs.txt` 追加闭包，避免逐文件匹配 925 条规则。
4. **`xz -f` 在构建分区会失败**：挂载强制 0777，xz 替换输出文件时尝试 `fchown` 报 `Cannot set the file owner: Invalid argument`；改成 `xz -c ... > data.tar.xz` 管道输出。

`DSH_FULL_DEPS=1 bash packaging/deb/build-deb.sh` 可回退到全量依赖树。

### 验证

| 检查 | 结果 |
|---|---|
| **裁剪态真跑**（park 926 个目录、只留 509） | `dsh --help` rc=0；`start` → URL → `303`+`Set-Cookie` → **200 / 40590 B** → 裸访问 401 → `stop` 正常；依赖树已恢复 1434 |
| 端到端打包 | `bash -n` / `sh -n` 通过，脚本两次跑完，全部断言绿 |
| 包内结构 | 88822 条；`/usr/bin/dsh*`、`postinst`/`prerm`/`postrm` 均 755；hoisted 树、`tsx` esm loader、`node24/bin/node`、`apps/web/dist/index.html` 齐全；dev-only 包 `.pnpm/electron-winstaller@*` 不在包内 |
| 源码 | `git diff` 空，`git status` 仍只有 5 个未跟踪项 |

### 验证边界（如实）

- **未执行 `sudo dpkg -i` 全量安装**：沙箱创建单文件约 0.15 s，8.9 万个文件不现实。包的结构、控制信息、文件清单是对 `.deb` 直接验的；真机安装留待真实终端。
- 附加排除（`docs/` `*.map` 等）**未单独在裁剪态跑冒烟**；这些是静态文档与调试文件，不参与 Node 模块解析。
- 闭包来自**静态依赖图**。插件运行时按名字动态加载，若某个插件把运行时依赖误声明为 `devDependency`，可能漏包。回退开关 `DSH_FULL_DEPS=1`；真机装完建议跑一次 `dsh plugin` 与常用插件路径。
- `Installed-Size: 1872420` KB 是近似值（未扣 source map 等小项）。
- 打包脚本现在**需要 `pnpm` 命令**（仅开发机打包时；装好的包不需要）。

---

## 十一、11-07 16:00 补桌面图标（装完没图标的根因与修复）

**反馈**：`sudo dpkg -i *.deb` 装完，应用菜单里没有图标。

**根因（不是装坏了）**：初版 `build-deb.sh` 只往 `/usr/` 放了 `dsh` 和 `dsh-web` 两个命令。`dpkg-deb --contents` 实证 `/usr/` 下仅 3 个条目（`usr/`、`usr/bin/` 加两个文件），没有 `.desktop`、没有图标、没有 GUI 启动器。这个包定位是 **Web 服务 deb**，设计上靠 `dsh-web start` + 浏览器访问 3080，不是 Electron 桌面应用。

**修复清单**：

| 文件 | 作用 |
|---|---|
| `packaging/deb/assets/dsh-launch` | 图标入口：幂等 `dsh-web start` → 取 token URL → `xdg-open`（`gio` 兜底）→ `notify-send` 提示；另存 `~/.dsh/last-url.txt`（600）便于手工兜底。`--stop` / `--status` / `--url` 供桌面 Action 复用 |
| `packaging/deb/assets/deepseek-harness.desktop` | `Development` 分类，中英文 Name/Comment，`TryExec`，`StartupNotify`，`Actions=Stop`（右键停掉常驻服务） |
| 图标 | `apps/web/dist/icon-512.png` → `hicolor/512x512/apps/`；`apps/desktop/resources/icon.svg` → `hicolor/scalable/apps/`。仓库自带鲸鱼 logo，零生成、可复现 |
| `packaging/deb/install-desktop-entry.sh` | **现场补丁**：已装旧包的机器 `sudo bash` 一次即补图标，不用重下 328 MiB |
| `assets/dsh-web` | `start` 改用 `setsid nohup ... </dev/null`：GNOME/KDE 在自己的 session/cgroup 里跑 `.desktop`，纯 `nohup &` 子进程可能随 launcher 退出被回收 |
| `assets/control` / `postinst` | `Recommends: xdg-utils, libnotify-bin`；`postinst` 刷新 desktop 数据库与图标缓存并提示图标用法 |
| `build-deb.sh` | 把上述 4 类文件打进 `/usr`，新增 4 条文件断言 + 3 条 `check_mode` 权限断言 |

**验证（16:00 实跑）**：

| 检查 | 结果 |
|---|---|
| 模拟点击图标（`dsh-launch`，假 `xdg-open` 截获 URL） | 传给浏览器的 URL 与 `dsh-web url` **完全一致**；`303`+cookie → **200 / 40590 B** |
| launcher 退出后 `dsh-launch --status` | `running (pid 142415)` —— `setsid` 生效、`$!` 指向正确进程 |
| `--stop` / `last-url.txt` | 正常停止；备份文件 mode 600 |
| `desktop-file-validate` | 通过（`Categories` 曾有两个主分类的 hint，已改为仅 `Development`） |
| 现场补丁等价干跑（目标重定向到临时根） | 4 个文件落位正确、内容 `cmp` 一致、权限 755/644 |
| **包内权限** | 初版整棵 `/usr` 被 `tar --mode` 压成 755（数据文件带执行位）→ 把小文件 staging 挪到 ext4 分区，脚本 755、desktop/图标 644；又发现本机 umask 002 会把目录装成 0775，补 `find -type d -exec chmod 755` 并加 `check_mode` 断言（含目录）守住 |

**验证边界（如实）**：本沙箱看不到已安装的系统（`/usr/bin/dsh`、`/opt/deepseek-harness` 均不存在，`sudo` 因 `/etc/sudo.conf` 属主异常不可用），所以**没在真实桌面会话里点过图标**，也没执行 `sudo dpkg -i`。图标点击链路是用包内同一份脚本 + 假浏览器完整跑通的；现场补丁是重定向到临时根的等价干跑。真实机器上菜单刷新、图标缓存、GNOME 的 cgroup 行为留待实机确认。

**用法**：新包装完直接在应用菜单搜 `DeepSeek Harness`；旧包已装的机器跑 `sudo bash packaging/deb/install-desktop-entry.sh`。菜单没立刻出现就注销重登一次。

---

## 十二、11-07 16:40 实机反馈「启动失败」：补丁漏更新命令

> **⚠️ 本节的根因推断已被 16:42 实机日志推翻，见第十三节。** 补丁漏更新 `dsh-web` 是真实缺陷（已修），但**不是本次启动失败的原因**：真实报错发生在 `dsh` 第一道自检，服务根本没启动。以下保留原始判断以便追溯。

**现象**：领导在真机 `sudo dpkg -i` 后点图标，报启动失败。

**先排除的硬伤**（直接从 `.deb` 索引核对，非推测）：

| 路径 | 包内形态 |
|---|---|
| `opt/deepseek-harness/node24/bin/node` | `-rwxr-xr-x`，129,379,880 B ELF |
| `.../node_modules/tsx` | 符号链接 → `.pnpm/tsx@4.23.13/node_modules/tsx`，目标 `dist/esm/index.mjs` 在包内 |
| `.../apps/cli/src/bin.ts`、`apps/web/dist/index.html` | 均在 |
| `.../node_modules/.pnpm/node_modules/`（hoisted） | 在 |

故「包缺文件 / bundled Node 跑不起来」不是本次原因；bundled Node 与开发机 `/opt/node-v24.9.0-linux-x64/bin/node` 是同一份二进制。

**根因判断（高置信，待实机日志确认）**：上一版 `install-desktop-entry.sh` 只装 `dsh-launch` + `.desktop` + 图标，**没有覆盖 `/usr/bin/dsh-web`**。领导装的是补图标之前的包，其 `dsh-web` 仍是 `nohup ... &`（无 `setsid`）；而 `setsid` 是第十一节才加的。新 launcher 调旧 `dsh-web`，GNOME/KDE 在 `.desktop` 会话退出时回收子进程 → `start` 期间拿到 token、随后服务消失 → 浏览器打不开 = 「启动失败」。

**已修**（`packaging/deb/` 下 3 个文件）：

| 文件 | 改动 |
|---|---|
| `install-desktop-entry.sh` | 循环覆盖安装 `dsh` / `dsh-web` / `dsh-launch` 到 `/usr/bin`（幂等），并提示诊断命令；旧系统跑一次即升级，无需重下 328 MiB |
| `assets/dsh-web` | `start` 不再 `: > web.log` 清空现场，改为轮转 `web.log.1`；进程早退或 120 s 无 token 时把 `tail -30` 写入 `~/.dsh/last-error.txt`；`EADDRINUSE` 翻译成「端口 3080 被占用」；超时独立报错 |
| `assets/dsh-launch` | `Terminal=false` 会丢掉 stderr，`die()` 现在把关键错误行塞进桌面通知，并写 `~/.dsh/launch-error.txt` |

**验证（16:36 实跑）**：`bash -n` / `sh -n` / `desktop-file-validate` 全过；模拟点击图标全链路 URL 一致 → `303` → **200 / 40590 B** → `--status running` → `--stop`；`web.log` 与 `web.log.1` 均为 600，轮转生效。补丁等价干跑：三个命令都落位 `/usr/bin`、755、`cmp` 与 assets 一致，`setsid` 确实在补丁后的 `dsh-web` 里。

**给实机的三步**：

```bash
sudo bash ~/deepseek-harness/packaging/deb/install-desktop-entry.sh   # 覆盖更新 3 个命令 + 图标
dsh-web status
/usr/bin/dsh-web foreground    # 前台直跑，报错直接可见；Ctrl+C 退出
```

若仍失败，把下面输出贴回来定位：

```bash
ss -ltnp | grep 3080 || echo "3080 空闲"
tail -n 40 ~/.dsh/web.log; tail -n 40 ~/.dsh/web.log.1
cat ~/.dsh/last-error.txt ~/.dsh/launch-error.txt 2>/dev/null
```

**验证边界**：沙箱看不到领导装好的系统（`/usr/bin/dsh`、`/opt/deepseek-harness` 均不存在，`sudo` 不可用），根因是**基于版本差异的推断，不是实机日志实证**；上述修复与全链路复验均在本机完成。

---

## 十三、11-07 16:42 实机日志：真因是 deb payload 未落地（推翻第十二节推断）

**实机证据（领导在真机终端跑出的原文）**：

```
dsh: bundled Node not found: /opt/deepseek-harness/node24/bin/node
3080 空闲
==> /home/qianqianjie/.dsh/web.log <==
dsh: bundled Node not found: /opt/deepseek-harness/node24/bin/node
```

桌面通知同时显示「服务启动失败，详见 ~/.dsh/web.log | dsh: bundled Node not found: …」。

**结论**：报错来自 `assets/dsh` 的第一道自检 `[ -x "$NODE" ]`，进程在启动服务**之前**就退出 → 端口 3080 当然空闲 → **第十二节推断的 setsid 新旧混跑根本没机会发生**。

**包本体无罪（本地实证，非推测）**：

| 检查 | 结果 |
|---|---|
| `.deb` 索引 | `node24/bin/node` 精确匹配 **1 条**，node24 下 6199 条，总 88833 条 |
| 从 `.deb` 实际解出该文件 | `-rwxr-xr-x`，129,379,880 B，ELF 64-bit dynamically linked |
| 解出的二进制实跑 | `v24.9.0` ✅ |
| 与开发机 `/opt/node-v24.9.0-linux-x64/bin/node` | 同一份（大小 / mtime / version 一致） |

所以问题在**安装侧没落地**：`/usr/bin/dsh*` 由 `install-desktop-entry.sh` 单独装上，而 `/opt/deepseek-harness` 的 payload 不完整，形成「命令在、运行时不在」的组合。

> **⚠️ 本节两处推断已被 17:04 实机证据推翻，见第十四节**：①「磁盘满」排除（`/opt` 余量 43G）；②「沙箱看不到真机 `/opt`」是错的，本机可直接读 `/opt`、`/var/log/dpkg.log`、`~/.dsh`。真因实锤是 dpkg 日志中 15:44:48 的 `install → half-installed → not-installed`——**首次安装失败回滚，包从未登记**。

**修复（4 个文件）**：

| 文件 | 改动 |
|---|---|
| `assets/dsh` | 自检一次列全 4 个必需路径（Node / tsx loader / CLI 入口 / Web 前端），打印 `INCOMPLETE` + 两条修复命令 + `df -h /opt`，不再只报 "not found" |
| `assets/dsh-launch` | 通知 hint 优先抓 `INCOMPLETE` 行 |
| `install-desktop-entry.sh` | 提示语改正：明示本脚本**只装 `/usr/bin` 与图标、不装 payload**；给出只补解 payload 的命令 |
| `assets/dsh-web` / `dsh-launch`（第十二节） | 日志轮转、last-error、setsid 等修复是真实缺陷，保留 |

**给真机的一步修复**（任选，推荐 A）：

```bash
cd ~/deepseek-harness/dist-linux
df -h /opt
# A 最干净：重装
sudo dpkg -i --force-overwrite *.deb
# B 只补 payload，跳过控制脚本，快得多
dpkg-deb --fsys-tarfile *.deb | sudo tar -x -C / ./opt/deepseek-harness

/opt/deepseek-harness/node24/bin/node --version   # 应输出 v24.9.0
dsh-web foreground                                # 前台验证，Ctrl+C 退出
```

**验证（16:45 本机实跑）**：语法全过；模拟 `DSH_ROOT=/nonexistent/dsh-root` 时新报错完整列出 4 个缺失路径 + 两条修复命令 + 磁盘行；正常路径 `dsh --help` rc=0；通知 hint 抓到 `INCOMPLETE` 行。

**验证边界（当时记录，17:04 后已不成立）**：当时称「沙箱看不到真机 `/opt`」——实为同一文件系统，本机可直接读 `/opt`、`/var/log/dpkg.log`、`~/.dsh`；「没在真机补解 / 重装」由领导在 17:04 执行完成。

---

## 十四、11-07 17:04 终局：修复成功 + 真因实锤（推翻「磁盘满」推断）

**结论：Web 服务已在本机跑通，后台启动 + 鉴权链路全绿，启动失败闭环。**

**领导真机执行结果（原文）**：

| 命令 | 输出 |
|---|---|
| `df -h /opt` | `228G / 174G used / 43G avail / 81%` → **磁盘满排除** |
| `dpkg-deb --fsys-tarfile *.deb \| sudo tar -x -C / ./opt/deepseek-harness` | 无报错 |
| `node24/bin/node --version` | `v24.9.0` ✅ |
| `dsh-web foreground` | `dsh web: http://127.0.0.1:3080/?token=…` ✅ |

### 真因：dpkg 日志实锤，非推断

| 时间 | `/var/log/dpkg.log` 原文 | 含义 |
|---|---|---|
| 15:44:48 | `install … <none> 0.2.2-rc.1` → `status half-installed` → **`status not-installed … <none>`** | **首次 `dpkg -i` 失败并回滚，包从未登记**；`/opt` 自然没有完整 payload |
| 15:44–17:04 | `install-desktop-entry.sh` 单独写入 `/usr/bin/dsh*`、`dsh-launch`、图标、desktop | 形成「命令在、运行时不在」 |
| 17:04:51 | `install` → `unpacked`(17:05:03) → `configure` → `installed`(17:05:04) | 重装成功 |
| 17:05 | 补解 payload | `node24/bin/node` 129,379,880 B 落地 |

**主动纠正上一轮两处误判**：①「磁盘满」排除（43G 可用）；②「沙箱视图隔离」是错的。首次 `dpkg -i` 失败的**具体 stderr 未留档**，原因不下定论。

### 本机复核（17:2x 实跑）

| 检查 | 结果 |
|---|---|
| `dpkg -l` / `dpkg -s` | `ii … install ok installed`；三个 `/usr/bin/dsh*` 均归属该包 |
| `/usr/bin/dsh --help` | rc=0，Usage 正常 |
| `/usr/bin/dsh-web start` | rc=0，pid 184457 后台常驻；`status` = running |
| HTTP 鉴权三段 | 裸访问 `/` = **401**；带 token = **303** + `Set-Cookie`(HttpOnly, SameSite=Strict, 30d)；带 cookie 访问 `/` = **200** |
| `dpkg -V` 报 830 条 missing | 全为 `Permission denied`，源头只有 1 个 `drwx------ root` 的 `packages/experimental/inspector/lib/devtools` 目录；**不是文件缺失**，属权限噪声 |

### 遗留噪声（不影响运行，会误导下次排障）

`~/.dsh/web.log`、`web.log.1`、`last-error.txt`、`launch-error.txt` 停在 17:04–17:05 的两次失败：先 `bundled Node not found`，后是补解中间态的 `SyntaxError: … cordis … FiberState`。`foreground` 输出直连终端、不写日志，故日志里翻不到成功 token 属正常；当前 `dsh --help` rc=0 与 401/303/200 证明中间态已消失。清理与否由使用者决定（4 个明确路径，不自动删）：

```bash
rm -f ~/.dsh/web.log ~/.dsh/web.log.1 ~/.dsh/last-error.txt ~/.dsh/launch-error.txt
```

### 防复发（本轮 3 处改动）

| 文件 | 改动 |
|---|---|
| `assets/postinst` | 安装后自检 4 个必需路径（Node / tsx loader / CLI 入口 / Web 前端），缺失即打 `*** WARNING: … INCOMPLETE ***` + 缺哪个 + 补解命令；**故意不 `exit 1`**，避免 half-configured 状态比警告更难收拾 |
| `install-desktop-entry.sh` | 提示语改掉「磁盘满」首选归因；要求先 `dpkg -l \| grep` 确认状态为 `ii`，否则只补解 payload 会让 dpkg 仍停在 not-installed（卸载/升级踩坑），应先 `sudo dpkg -i *.deb` |
| 本文档 | 第十三节两处误判标注 + 本节实锤 |

**验证**：`sh -n` 通过；`DSH_ROOT=/nonexistent/dsh-root` 触发完整警告且 rc=0；假根放齐 4 个文件走正常用法输出且 rc=0；`dsh-web start` + 401/303/200 全绿。

> **状态边界**：`dist-linux/*.deb` 仍是 16:51 构建版，包内 `postinst` 为 927 B 旧版（可对照 `/var/lib/dpkg/info/deepseek-harness-web.postinst`）。**本轮源码改动尚未进包**，需重建才生效；当前已装环境无需任何操作。

### 17:28 终局：桌面图标闭环 ✅

领导在真机桌面点图标 → 服务就绪、浏览器打开，回复「OK 了」，**「图标 → 服务 → 浏览器」全链路闭环**。本机文件系统证据：`~/.dsh/last-url.txt` 17:27:46 写入且含 token URL；`web.log` 17:28:04 刷新且含 token 行；`launch-error.txt` / `last-error.txt` 仍停在 17:05，**无新增失败**；3080 持续监听。

> **沙箱边界（不作为故障）**：文件系统视图是通的，但**进程视图不通**——沙箱内 `ps` 看不到任何 dsh 进程、`dsh-web status` 因 `kill -0` 失败误报 stopped，而 3080 实际在监听。故进程类判断一律以真机为准；真机自查用 `dsh-web status` 与 `ss -lntp | grep 3080` 对照。
