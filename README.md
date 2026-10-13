# NTFSMount

**[简体中文](#简体中文) · [English](README_EN.md)**

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
