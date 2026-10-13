# NTFSMount

**[简体中文](#简体中文) · [English](#english)**

macOS 上的 NTFS 读写工具，原生 Swift + SwiftUI 实现。起因是上游 [Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac) 新版不再支持 Intel Mac —— 详见[为什么会有这个项目](#为什么会有这个项目)。

macOS 自带只读的 NTFS 支持。本工具调用 **ntfs-3g + macFUSE**，把 NTFS 卷重新挂载为可读可写，
并在菜单栏与访达中提供快速操作。

![NTFS 设备](docs/images/devices.png)

---

# 简体中文

## 为什么会有这个项目

我一直用 **[Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac)**（原名
Free-NTFS-for-Mac，GitHub 仓库地址沿用至今）在 macOS 上读写 NTFS 移动盘 —— 好用、免费、
界面清楚，在此先致谢。

唯一的问题是：最新版 v1.5.4 已只发布 Apple Silicon（arm64）构建 —— Intel Mac 被官方建议
留在 1.4.5；发布说明也写明后续版本不再支持 Intel，理由是 macOS 27 已不再支持 Intel Mac。
我 clone 到的是旧版，于是决定自己动手，用原生 Swift 重写一个
**Intel 与 Apple Silicon 一起持续维护**的版本。

重写过程用了 AI 辅助（vibe coding），但它不是界面套壳：设备检测、挂载参数、依赖判定、
访达集成这些最容易静默出错的地方都逐项重新做过取舍。

## 特点与优势

### Intel 与 Apple Silicon 同步发布

两个架构各出一份 DMG，版本号同步推进，**不把 Intel 用户留在旧版本上**。

这在当下并非多余：Homebrew 7.0.0（2026-09-13）已把 macOS Intel 移到 **Tier 3** ——
不再构建二进制包（bottles），官方建议 Intel 用户迁移到 MacPorts，官方 `.pkg` 安装器也只提供
Apple Silicon 版本。也就是说，Intel Mac 的软件供给正在持续收窄，一个还在双架构发版的小工具
是有意义的。

### 原生应用，不是 Electron 套壳

| | NTFSMount | Nigate 1.5.4 |
|---|---|---|
| 安装包体积 | **约 2 MB** | 约 98 MB |
| 运行时 | 原生 Swift / SwiftUI | Electron（内嵌 Chromium + Node） |
| 内存占用 | 约 40 MB | — |

不内嵌浏览器内核，不带 Node 运行时。

### 不装驱动也能看见磁盘

设备检测走 IOKit 与 DiskArbitration 系统 API，**不依赖 macFUSE / ntfs-3g**。
驱动还没装的时候，应用照样能列出所有分区、判定文件系统类型、显示容量条 ——
只有「挂载为读写」这一步才需要驱动。

### 零常驻子进程、零轮询定时器

设备变化来自 IOKit 匹配/终止通知端口与 NSWorkspace 挂载事件，空闲时 CPU 为 0。

单轮全量刷新约 **3~5 ms**（`statfs` 加一次 IOKit 遍历，全程不 fork 任何进程）。

### 依赖判定不把 Homebrew 当必要条件

`核心依赖 = macOS 版本 × macFUSE × ntfs-3g`，**不含 Homebrew**。
MacPorts、Homebrew、手动安装三种方式在检测上完全等价 —— 没有 Homebrew 的机器不会被误判成
「缺少依赖」。考虑到上面提到的 Intel 现状，这一点对 Intel 用户尤其重要。

### 挂载参数是逐项复核过的，不是照抄

其中一条值得单独说：**刻意不加 `-oauto_xattr`**。该选项会让内核一律用 `._` 边车文件存扩展
属性，而 ntfs-3g 原生支持扩展属性 —— 加上它等于每个带标签的文件旁边多一个 Windows 里看不见的
垃圾文件，同时丢弃 NTFS 的原生扩展属性通道。

`iosize` 默认提到 1 MiB（macFUSE 默认 64 KiB）。完整参数列表与逐项依据见后文「挂载参数」一节。

### 不安装特权 helper

走系统原生授权对话框，支持 Touch ID / Apple Watch，凭据不经过应用进程。
**不安装任何特权守护进程**，卸载时无残留。

### 界面与系统集成

- 菜单栏常驻：左键弹快捷面板，右键弹菜单；关闭主窗口不退出
- 访达集成：卷状态徽标 + 右键菜单（挂载 / 卸载、切换读写、推出、ntfsfix）
- 静默自启：开机只留菜单栏图标，不弹主窗口
- 开机自动挂载读写
- 界面五语言（简中 / 繁中 / 英语 / 日语 / 德语），运行时随时切换
- 16 章使用手册内置于应用，离线可查
- 管理员密码可选存入钥匙串，免去每次挂载弹窗

### 不联网、不上传

应用全程不发起网络请求，不收集、不上传任何信息。

## 功能一览

| | |
|---|---|
| 读写挂载 | 调用 ntfs-3g + macFUSE，把 NTFS 卷挂载为可读可写 |
| 设备识别 | 走 IOKit / DiskArbitration 系统 API，**不依赖任何第三方驱动** —— 驱动还没装也能看到磁盘 |
| 刷新方式 | 事件驱动（IOKit 匹配/终止通知 + NSWorkspace 挂载事件），无轮询定时器 |
| 常驻子进程 | 0 个 |
| 内存占用 | 约 40 MB（活动监视器「内存」列，即 `phys_footprint`） |
| 菜单栏驻留 | 左键点图标弹快捷面板，右键弹菜单；关闭主窗口不退出 |
| 访达集成 | 卷状态徽标 + 右键菜单（挂载 / 卸载、切换读写、推出、ntfsfix） |
| 界面语言 | 简体中文 / 繁体中文 / 英语 / 日语 / 德语，可在设置里随时切换 |
| 架构 | Apple Silicon (arm64) 与 Intel (x86_64) 分别出包 |
| 最低系统 | macOS 14 |

## 应用截图

| 系统依赖 | NTFS 设备 |
|---|---|
| ![系统依赖](docs/images/dependencies.png) | ![NTFS 设备](docs/images/devices.png) |

| 菜单栏快捷面板（左键点图标） | 设置 |
|---|---|
| ![菜单栏快捷面板](docs/images/tray-panel.png) | ![设置](docs/images/settings.png) |

使用手册（16 章）内置于应用，不联网即可查看：

![使用手册](docs/images/manual.png)

## 它能做什么，不能做什么

**能做**：把已存在的 NTFS 卷挂载为可读写；挂载 / 卸载 / 还原只读；`ntfsfix` 清除「脏分区」标记。

**不做**：不格式化、不分区、不转换文件系统；不修改分区表与引导记录；不碰 Windows 的访问控制列表；
不恢复数据；不在后台常驻第三方进程、不联网、不上传任何信息。

> **写 NTFS 有风险，与用哪种工具无关。** 第一次对某块盘写操作之前，请把里面的重要文件另备份一份。
> 「重置」功能里的 `ntfsfix` 只清除「脏分区」标记，它不修复文件内容。

## 安装

### 1. 安装应用

下载对应架构的 DMG，双击挂载后把 `NTFSMount.app` 拖进「应用程序」。

- Apple Silicon（M 系列）：`NTFSMount-1.0.0-arm64.dmg`
- Intel：`NTFSMount-1.0.0-x86_64.dmg`

发布包使用 ad-hoc 签名，首次打开若提示「无法验证开发者」，右键点 App → 选「打开」即可。

### 2. 安装依赖

读写能力来自 macFUSE + NTFS-3G，需要单独安装。应用内「系统依赖」页会检测并给出对应命令。

**MacPorts**

```bash
sudo port install macfuse      # 安装后需在「系统设置 → 通用 → 登录项与扩展」中允许
sudo port install ntfs-3g
```

**Homebrew**

```bash
brew install --cask macfuse
brew tap gromgit/homebrew-fuse
brew install ntfs-3g-mac
```

**手动安装**：从 [macFUSE](https://macfuse.github.io/) 与
[NTFS-3G](https://tuxera.com/opensource/ntfs-3g_ntfsprogs/) 下载，把 `ntfs-3g` 放进 PATH 中的
任意目录（如 `/usr/local/bin`）即可。

应用按路径直接查找二进制，**与用哪种包管理器无关**。

## 使用

### 挂载为读写

在主界面「NTFS 设备」页点某台设备的「读写」，或左键点菜单栏图标在快捷面板里操作。
挂载需要管理员权限，会弹出系统授权对话框。

### 设置项

| 设置 | 作用 |
|---|---|
| 自动读写 | 新接入的 NTFS 设备自动挂载为读写 |
| 系统自启 | 登录时自动启动应用 |
| 静默自启 | 开机只驻留菜单栏图标，不打开主窗口 |
| 开机自动挂载读写 | 启动时把已经连着的 NTFS 设备挂载为读写 |
| 保存管理员密码 | 把管理员密码存入 macOS 钥匙串，挂载时不再弹授权对话框 |
| I/O 块大小 | 传给 macFUSE 的 `iosize`，影响大文件吞吐；默认 1 MiB |
| 启用操作日志 | 记录全部操作日志，默认最长保留 30 天 |

> **保存管理员密码**是便利性与安全性的取舍：密码由本应用代为提交给系统提权接口，
> 存在登录钥匙串里（`kSecAttrAccessibleWhenUnlocked`，锁屏状态下不可读）。
> 如果密码被改动，应用会自动丢弃旧密码并退回系统授权对话框。不想要就关掉。

## 构建

需要 Xcode Command Line Tools 与 [Bazelisk](https://github.com/bazelbuild/bazelisk)。

```bash
# Apple Silicon
bazelisk build //swift:NTFSMount --config=arm64

# Intel x86_64
bazelisk build //swift:NTFSMount --config=intel
```

> **交叉编译注意**：`.bazelrc` 里的 `--platforms` 必须直接写
> `@apple_support//platforms:darwin_x86_64` 这样的原始 label。
> 用本地 alias 不会被解引用，rules_apple 的平台→架构映射会静默 miss 并回退宿主 CPU。

## 打包

### 发布形态：Intel 与 Apple Silicon 各一份 DMG

```bash
scripts/package.sh --arch x86_64 --sign --dmg   # → dist/NTFSMount-1.0.0-x86_64.dmg
scripts/package.sh --arch arm64  --sign --dmg   # → dist/NTFSMount-1.0.0-arm64.dmg
```

DMG 内是 `NTFSMount.app` + `Applications` 软链接，双击挂载后把 app 拖进去即完成安装。

> **两次构建必须串行**。SwiftPM 的 `.build/out/Products/Release/` 不按架构分目录，
> 后一次构建会覆盖前一次；脚本靠「构建完立刻拷走」规避，但并行执行仍会互相踩。
> 同理，`.pkg` / `.dmg` 的文件名必须带架构后缀 —— 否则第二次打包会**静默覆盖**
> 第一次的安装包，只剩一份、且是后打的那份。

### 其他形态

```bash
scripts/package.sh --universal --sign --pkg --dmg   # Universal 2 + .pkg + .dmg
scripts/package.sh --app-only                       # 只要 .app，宿主架构
scripts/package.sh --arch x86_64 --sign --pkg       # 单架构 .app + .pkg
```

产物在 `dist/`，完整参数见 `scripts/package.sh --help`。

### 签名

当前发布包使用 **ad-hoc 签名**。自己的机器双击直接运行；别人的机器首次打开会提示
「无法验证开发者」，这是 Gatekeeper 的正常行为。若要让所有用户完全无提示，需要
Apple **Developer ID** 证书签名并公证：

```bash
scripts/package.sh --universal --sign \
    --identity "Developer ID Application: Your Name (TEAMID)" \
    --pkg --dmg
```

### 沙盒与权限

主应用**不开启** App Sandbox，且不能开启 —— 沙盒进程打不开 `/dev/rdisk*`、
子进程会继承沙盒（提权后的 `ntfs-3g` 照样读不到设备节点）、读不到 `/opt/homebrew`。
只有访达扩展（`.appex`）必须开启沙盒，否则会被 `pkd` 拒绝加载。
两者通过 App Group `group.com.ntfsmount.shared` 共享状态快照。

## 架构

```
swift/Sources/
├── NTFSMountCore/            纯逻辑，无 UI 依赖
│   ├── MountContract.swift     挂载参数的单一事实来源
│   ├── MountEngine.swift       挂载 / 卸载 / 读写切换
│   ├── DeviceService.swift     设备列表 + 事件驱动刷新
│   ├── VolumeMonitor.swift     IOKit + NSWorkspace 事件源
│   ├── DependencyDetector.swift 依赖检测与版本评估
│   ├── KeychainStore.swift     管理员密码钥匙串存取
│   └── Shell.swift             子进程执行
├── NTFSMountUI/              SwiftUI 界面
├── NTFSMountFinderBridge/    主应用侧：App Group 快照 IPC
├── NTFSMountFinderSync/      访达扩展：徽标 + 右键菜单
├── NTFSMountSmoke/           回归测试
└── NTFSMount/                应用入口
```

### 挂载参数

全部集中在 `MountContract.swift`，每一项的取舍依据写在代码注释里：

| 参数 | 作用 |
|---|---|
| `-olocal` | 让卷被当作本地卷，影响访达侧边栏与空闲自动卸载 |
| `-oallow_other` | 允许其他用户访问挂载点 |
| `-oremove_hiberfile` | 删除休眠文件，腾出空间 |
| `-onoatime` | 不更新访问时间，减少写入 |
| `-oiosize=` | macFUSE I/O 块大小，默认 1 MiB（可选 4 MiB / 交给 macFUSE 默认 64 KiB） |

**刻意不加** `-oauto_xattr`：macFUSE 文档明确说明该选项会让内核**始终**使用 `._` 边车文件存
xattr，而 NTFS-3G 原生支持 xattr，加上反而是负优化。

`big_writes` 归入实验开关、默认关闭 —— macFUSE 的 `max_write` 默认约 32 KiB，
而写请求本来就小于 128 KiB，收益未经实测。

## 访达集成

安装后访达会显示卷状态徽标，并提供右键菜单：挂载 / 卸载、切换读写、打开 NTFSMount。

实现方式是 FIFinderSync 扩展 + App Group 共享目录：主应用把卷状态写成 JSON 快照，
扩展读快照渲染徽标，用户操作经命令队列投递回主应用执行（扩展本身无提权能力）。

轮询（5 秒）是最终一致性的主通道，Darwin 通知只作加速信号 —— 通知在极少数情况下会丢。

## 许可

[GNU General Public License v3.0](LICENSE)（GPL-3.0）。

## 致谢

本工具的读写能力建立在下面两个开源项目之上：

- **[macFUSE](https://macfuse.github.io/)** —— 用户态文件系统框架，提供本工具挂载 NTFS 的内核通道
- **[NTFS-3G](https://github.com/tuxera/ntfs-3g)**（Tuxera）—— NTFS 读写驱动本体

界面与交互的设计思路受 [Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac)
启发，在此致谢。

---

# English

A native NTFS read/write utility for macOS, written in Swift + SwiftUI.

macOS ships read-only NTFS support. NTFSMount calls **ntfs-3g + macFUSE** to remount an
NTFS volume as read/write, and exposes quick actions in the menu bar and in Finder.

## Why this project exists

I have long used **[Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac)** (formerly
Free-NTFS-for-Mac; the GitHub repository still carries the old name) to read and write NTFS
drives on macOS — it works well, it is free, and its interface is clear. Credit where it is due.

The one problem: the latest release, **v1.5.4, ships Apple Silicon (arm64) builds only** —
Intel Macs are officially told to stay on 1.4.5, and the release notes state that future
versions will no longer support Intel, citing macOS 27 dropping Intel Macs. I had cloned the
older version, so the decision was to build a native Swift rewrite that **keeps Intel and
Apple Silicon on the same release train**.

The rewrite was AI-assisted (vibe coding), but it is not a reskin: device detection, mount
arguments, dependency checks and Finder integration — the parts that fail *silently* — were
all re-evaluated from scratch.

## Features and advantages

### Apple Silicon and Intel ship together

One DMG per architecture, versions kept in lockstep. **Intel users are not left behind on an
old build.**

That matters right now: Homebrew 7.0.0 (2026-09-13) moved macOS Intel to **Tier 3** — no more
binary bottles, with the project recommending Intel users migrate to MacPorts, and its
official `.pkg` installer now Apple Silicon only. Software supply for Intel Macs is narrowing,
so a small utility that still ships both architectures has real value.

### A native app, not an Electron wrapper

| | NTFSMount | Nigate 1.5.4 |
|---|---|---|
| Installer size | **~2 MB** | ~98 MB |
| Runtime | native Swift / SwiftUI | Electron (bundled Chromium + Node) |
| Memory footprint | ~40 MB | — |

No bundled browser engine, no Node runtime.

### Drives show up even with no driver installed

Device detection runs on IOKit and DiskArbitration system APIs and **does not depend on
macFUSE / ntfs-3g**. Before either is installed, the app still lists every partition,
identifies the filesystem type and shows capacity bars — only the "mount read/write" step
needs the driver.

### Zero resident child processes, zero polling timers

Device changes come from IOKit match/terminate notification ports and NSWorkspace mount
events; idle CPU usage is 0.

A full refresh pass takes about **3–5 ms** (`statfs` plus one IOKit sweep, with no process
forks at all).

### Homebrew is not required

`core dependencies = macOS version × macFUSE × ntfs-3g`, with **no Homebrew term**.
MacPorts, Homebrew and manual installs are treated identically — a machine without Homebrew
is never misreported as "missing dependencies". Given the Intel situation above, that matters
most for exactly those users.

### Mount arguments were reviewed item by item, not copied

One is worth calling out: **`-oauto_xattr` is deliberately omitted.** It forces the kernel to
*always* store extended attributes in `._` sidecar files, whereas ntfs-3g supports xattrs
natively — adding it litters every tagged file with a sidecar that Windows cannot even see,
while abandoning NTFS's native extended-attribute channel.

`iosize` defaults to 1 MiB (macFUSE's own default is 64 KiB). The full argument list and the
reasoning behind each entry appear under "Mount arguments" below.

### No privileged helper is installed

Privilege escalation uses the native system authorization dialog, with Touch ID / Apple Watch
support, so credentials never pass through the app process. **No privileged daemon is
installed**, and uninstalling leaves nothing behind.

### Interface and system integration

- Menu bar resident: left-click opens a quick panel, right-click opens a menu; closing the
  main window does not quit
- Finder integration: volume status badges + context menu (mount / unmount, toggle
  read-write, eject, ntfsfix)
- Silent launch: on login, only the menu bar icon appears — no main window
- Auto-mount read/write at launch
- Five UI languages (Simplified Chinese, Traditional Chinese, English, Japanese, German),
  switchable at runtime
- A 16-chapter manual built into the app, readable offline
- Optional keychain storage for the administrator password, so mounting stops prompting

### No network, no telemetry

The app makes no network requests and collects or uploads nothing.

## Features

| | |
|---|---|
| Read/write mount | Uses ntfs-3g + macFUSE to mount NTFS volumes as read/write |
| Device detection | Built on IOKit / DiskArbitration system APIs — **no third-party driver required**. Drives show up even before macFUSE / ntfs-3g are installed |
| Refresh strategy | Event-driven (IOKit match/terminate notifications + NSWorkspace mount events); no polling timers |
| Resident child processes | None |
| Memory footprint | ~40 MB (Activity Monitor's "Memory" column, i.e. `phys_footprint`) |
| Menu bar | Left-click opens a quick panel, right-click opens a menu; closing the main window does not quit |
| Finder integration | Volume status badges + context menu (mount / unmount, toggle read-write, eject, ntfsfix) |
| UI languages | Simplified Chinese, Traditional Chinese, English, Japanese, German — switchable at runtime |
| Architectures | Separate builds for Apple Silicon (arm64) and Intel (x86_64) |
| Minimum OS | macOS 14 |

## Screenshots

| System Dependencies | NTFS Devices |
|---|---|
| ![System Dependencies](docs/images/dependencies.png) | ![NTFS Devices](docs/images/devices.png) |

| Menu bar quick panel (left-click) | Settings |
|---|---|
| ![Menu bar quick panel](docs/images/tray-panel.png) | ![Settings](docs/images/settings.png) |

The built-in manual has 16 chapters and works entirely offline:

![Manual](docs/images/manual.png)

## What it does — and does not do

**Does**: mount existing NTFS volumes read/write; mount, unmount and restore read-only;
clear the "dirty volume" flag with `ntfsfix`.

**Does not**: format, partition or convert filesystems; modify partition tables or boot records;
touch Windows ACLs; recover data; keep third-party processes resident, connect to the network,
or upload anything.

> **Writing to NTFS carries risk regardless of which tool you use.** Back up anything important
> on the volume before the first write. The `ntfsfix` action only clears the dirty-volume flag —
> it does not repair file contents.

## Installation

### 1. Install the app

Download the DMG matching your architecture, mount it, and drag `NTFSMount.app` into
Applications.

- Apple Silicon (M-series): `NTFSMount-1.0.0-arm64.dmg`
- Intel: `NTFSMount-1.0.0-x86_64.dmg`

Release builds are ad-hoc signed. If macOS shows "cannot verify the developer" on first
launch, right-click the app and choose Open.

### 2. Install the dependencies

Read/write support comes from macFUSE + NTFS-3G, which must be installed separately. The
in-app "System Dependencies" page detects them and shows the exact commands.

**MacPorts**

```bash
sudo port install macfuse      # then allow it in System Settings → General → Login Items & Extensions
sudo port install ntfs-3g
```

**Homebrew**

```bash
brew install --cask macfuse
brew tap gromgit/homebrew-fuse
brew install ntfs-3g-mac
```

**Manual**: download from [macFUSE](https://macfuse.github.io/) and
[NTFS-3G](https://tuxera.com/opensource/ntfs-3g_ntfsprogs/), then put `ntfs-3g` anywhere on
your PATH (e.g. `/usr/local/bin`).

The app looks up binaries by path, so **it does not matter which package manager you used**.

## Usage

### Mount as read/write

Click "Read/Write" for a device on the NTFS Devices page, or left-click the menu bar icon and
use the quick panel. Mounting requires administrator privileges and shows the system
authorization dialog.

### Settings

| Setting | Effect |
|---|---|
| Auto read/write | Automatically mount newly attached NTFS devices as read/write |
| Launch at login | Start the app when you log in |
| Silent launch | On login, stay in the menu bar only — no main window |
| Mount at launch | Mount already-connected NTFS devices as read/write on startup |
| Save admin password | Store the administrator password in the macOS keychain so mounting never prompts again |
| I/O block size | `iosize` passed to macFUSE; affects large-file throughput. Default 1 MiB |
| Enable operation log | Record all operations, retained for up to 30 days |

> **Save admin password** trades convenience for security: the password is submitted to the
> system privilege-escalation mechanism on your behalf and stored in the login keychain
> (`kSecAttrAccessibleWhenUnlocked`, unreadable while locked). If the password is later
> changed, the app discards it automatically and falls back to the system dialog. Turn it off
> if you would rather not store it.

## Building

Requires Xcode Command Line Tools and [Bazelisk](https://github.com/bazelbuild/bazelisk).

```bash
# Apple Silicon
bazelisk build //swift:NTFSMount --config=arm64

# Intel x86_64
bazelisk build //swift:NTFSMount --config=intel
```

> **Cross-compilation note**: `--platforms` in `.bazelrc` must use the raw label
> (e.g. `@apple_support//platforms:darwin_x86_64`). A local alias is not dereferenced,
> so rules_apple's platform→architecture mapping silently misses and falls back to the host CPU.

## Packaging

### Release shape: one DMG per architecture

```bash
scripts/package.sh --arch x86_64 --sign --dmg   # → dist/NTFSMount-1.0.0-x86_64.dmg
scripts/package.sh --arch arm64  --sign --dmg   # → dist/NTFSMount-1.0.0-arm64.dmg
```

Each DMG contains `NTFSMount.app` plus an `Applications` symlink: mount it, drag the app in,
and you are done.

> **The two builds must run sequentially.** SwiftPM's `.build/out/Products/Release/` is not
> split per architecture, so the second build overwrites the first. The script copies artifacts
> out immediately after each build, but parallel runs still collide. For the same reason
> `.pkg` / `.dmg` filenames must carry the architecture suffix — otherwise the second packaging
> run **silently overwrites** the first, leaving a single artifact.

### Other shapes

```bash
scripts/package.sh --universal --sign --pkg --dmg   # Universal 2 + .pkg + .dmg
scripts/package.sh --app-only                       # .app only, host architecture
scripts/package.sh --arch x86_64 --sign --pkg       # single-arch .app + .pkg
```

Artifacts land in `dist/`. Run `scripts/package.sh --help` for all options.

### Signing

Release builds use **ad-hoc signing**. On your own machine they run directly; on someone
else's, the first launch shows "cannot verify the developer", which is normal Gatekeeper
behaviour. To make installation fully silent for all users, sign and notarize with an Apple
**Developer ID** certificate:

```bash
scripts/package.sh --universal --sign \
    --identity "Developer ID Application: Your Name (TEAMID)" \
    --pkg --dmg
```

### Sandbox and entitlements

The main app is **not** sandboxed, and must not be — a sandboxed process cannot open
`/dev/rdisk*`, child processes inherit the sandbox (so an elevated `ntfs-3g` still cannot
reach the device node), and `/opt/homebrew` becomes unreadable. Only the Finder extension
(`.appex`) must be sandboxed, otherwise `pkd` refuses to load it. The two share state through
the App Group `group.com.ntfsmount.shared`.

## Architecture

```
swift/Sources/
├── NTFSMountCore/            Pure logic, no UI dependency
│   ├── MountContract.swift     Single source of truth for mount arguments
│   ├── MountEngine.swift       Mount / unmount / read-write switching
│   ├── DeviceService.swift     Device list + event-driven refresh
│   ├── VolumeMonitor.swift     IOKit + NSWorkspace event source
│   ├── DependencyDetector.swift Dependency detection and version checks
│   ├── KeychainStore.swift     Administrator password storage
│   └── Shell.swift             Subprocess execution
├── NTFSMountUI/             SwiftUI interface
├── NTFSMountFinderBridge/   App side: App Group snapshot IPC
├── NTFSMountFinderSync/     Finder extension: badges + context menu
├── NTFSMountSmoke/          Regression tests
└── NTFSMount/               App entry point
```

### Mount arguments

All of them live in `MountContract.swift`, with the reasoning in the source comments:

| Argument | Purpose |
|---|---|
| `-olocal` | Treat the volume as local; affects the Finder sidebar and idle unmounting |
| `-oallow_other` | Let other users access the mount point |
| `-oremove_hiberfile` | Remove the hibernation file to reclaim space |
| `-onoatime` | Do not update access times; fewer writes |
| `-oiosize=` | macFUSE I/O block size. Default 1 MiB (4 MiB, or macFUSE's own 64 KiB default) |

`-oauto_xattr` is **deliberately omitted**: the macFUSE documentation states that it makes the
kernel *always* use `._` sidecar files for xattrs, while NTFS-3G supports xattrs natively — so
adding it would be a pessimisation.

`big_writes` is treated as an experimental flag and off by default — macFUSE's `max_write`
defaults to roughly 32 KiB while write requests are already below 128 KiB, so the benefit is
unmeasured.

## Finder integration

Once installed, Finder shows volume status badges and a context menu: mount / unmount, toggle
read-write, open NTFSMount.

It is implemented as a FIFinderSync extension plus a shared App Group directory: the main app
writes volume state as a JSON snapshot, the extension reads it to render badges, and user
actions are posted back to the main app through a command queue (the extension itself has no
privilege escalation).

Polling (5 s) is the primary consistency channel; Darwin notifications are only an accelerator,
because they can occasionally be dropped.

## License

[GNU General Public License v3.0](LICENSE) (GPL-3.0).

## Acknowledgements

Read/write support rests on two open-source projects:

- **[macFUSE](https://macfuse.github.io/)** — userspace filesystem framework providing the kernel channel used to mount NTFS
- **[NTFS-3G](https://github.com/tuxera/ntfs-3g)** (Tuxera) — the NTFS read/write driver itself

The UI and interaction design was inspired by
[Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac).
With thanks to its author.
