import Foundation
import IOKit
import IOKit.storage
import NTFSMountCore

func w(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Swift 6 严格并发下顶层全局变量默认 MainActor 隔离，
/// 这里用显式累加器封装避免并发标注问题。
final class FailCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

let failures = FailCounter()

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "✓" : "✗"
    if !condition { failures.increment() }
    w("  \(mark) \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
}

func rssMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : 0
}

// MARK: - 1. ToolLocator：按路径查找，与包管理器解耦

w("=== 1. 工具查找只按路径 stat ===")
w("  ToolLocator.locate() 直接按已知前缀查可执行文件，")
w("  因此手动安装 / MacPorts 安装 / Homebrew 安装在检测上没有差别。")

let prefixes = ToolLocator.searchPrefixes
check("覆盖 Apple Silicon Homebrew (/opt/homebrew)", prefixes.contains("/opt/homebrew"))
check("覆盖 Intel Homebrew / 手动安装 (/usr/local)", prefixes.contains("/usr/local"))
check("覆盖 MacPorts (/opt/local)", prefixes.contains("/opt/local"),
      "Intel Mac 用户的主要安装途径")
check("覆盖系统路径 (/usr, /bin, /sbin)",
      prefixes.contains("/usr") && prefixes.contains("/bin") && prefixes.contains("/sbin"))

let deps = DependencyDetector().detect()
w("")
w("  当前环境实测：")
w("    brew 存在    : \(deps.homebrew.isPresent)")
w("    MacPorts 存在: \(deps.macPorts.isPresent)")
w("    macFUSE      : \(deps.macFUSE)")
w("    ntfs-3g      : \(deps.ntfs3g)")
w("    CLT          : \(deps.commandLineTools)")

let bogus = ToolLocator.locate("ntfsmount-definitely-not-installed-xyz")
check("不存在的工具定位返回 nil", bogus == nil)

let sh = ToolLocator.locate("sh")
check("/bin/sh 可被定位（证明查找不依赖 brew/MacPorts）", sh != nil,
      "→ \(sh ?? "nil")  brew=\(deps.homebrew.isPresent) macPorts=\(deps.macPorts.isPresent)")

// MARK: - 2. Homebrew 移除后的依赖判定

w("")
w("=== 2. Homebrew 检测移除验证 ===")
check("coreInstalled = macOS && macFUSE && ntfs3g（不含 brew）",
      deps.coreInstalled == (deps.macOS && deps.macFUSE && deps.ntfs3g),
      "coreInstalled=\(deps.coreInstalled)  brew=\(deps.homebrew.isPresent)")

// CLT 不得影响 coreInstalled（「缺失时不制造假阻塞」）：要断言的是它不参与
// 判定，而不是「列表里不含 CLT」——CLT 作为诊断项展示是合理的。
check("CLT 缺失不影响 coreInstalled",
      deps.coreInstalled == (deps.macOS && deps.macFUSE && deps.ntfs3g),
      "CLT=\(deps.commandLineTools) 未参与判定")

var probe = deps
probe.commandLineTools = false
check("强制 CLT=false 后 coreInstalled 不变",
      probe.coreInstalled == deps.coreInstalled,
      "before=\(deps.coreInstalled) after=\(probe.coreInstalled)")

var noFUSE = deps
noFUSE.macFUSE = false
check("仅缺 macFUSE 时 coreInstalled 为 false",
      noFUSE.coreInstalled == false,
      "coreInstalled=\(noFUSE.coreInstalled) brew=\(noFUSE.homebrew.isPresent)")

var noNtfs = deps
noNtfs.ntfs3g = false
check("仅缺 ntfs-3g 时 coreInstalled 为 false",
      noNtfs.coreInstalled == false,
      "coreInstalled=\(noNtfs.coreInstalled) brew=\(noNtfs.homebrew.isPresent)")

var allPresent = deps
allPresent.macOS = true
allPresent.macFUSE = true
allPresent.ntfs3g = true
check("三项齐备时 coreInstalled 为 true（与 brew 无关）",
      allPresent.coreInstalled == true,
      "brew 存在与否均不影响：\(allPresent.homebrew.isPresent)")

let entries = InstallGuideBuilder.entries(for: deps)
check("依赖列表不含 Homebrew 条目",
      !entries.contains { $0.name.localizedCaseInsensitiveContains("homebrew") },
      "共 \(entries.count) 项: \(entries.map { $0.key.rawValue }.joined(separator: ", "))")
check("依赖列表不含 fswatch 条目（已彻底移除）",
      !entries.contains { $0.key.rawValue.lowercased().contains("fswatch") })

let macFUSEEntry = entries.first { $0.key == .macFUSE }
let ntfsEntry = entries.first { $0.key == .ntfs3g }
check("MacFUSE 指引含 MacPorts 命令",
      macFUSEEntry?.commands.contains {
          $0.method == .macPorts && $0.command.contains("port install") } == true,
      macFUSEEntry?.commands.map(\.command).joined(separator: "  |  ") ?? "-")
check("ntfs-3g 指引含 MacPorts 命令",
      ntfsEntry?.commands.contains {
          $0.method == .macPorts && $0.command == "sudo port install ntfs-3g" } == true,
      ntfsEntry?.commands.map(\.command).joined(separator: "  |  ") ?? "-")

let firstMethod = ntfsEntry?.commands.first?.method
if !deps.homebrew.isPresent && !HostArchitecture.isAppleSilicon {
    check("无 Homebrew 的 Intel Mac 优先展示 MacPorts",
          firstMethod == .macPorts, "实际: \(firstMethod?.rawValue ?? "-")")
} else {
    w("  · 当前环境 Homebrew=\(deps.homebrew.isPresent) ARM=\(HostArchitecture.isAppleSilicon)"
      + "，首个安装方式: \(firstMethod?.rawValue ?? "-")")
}

// MARK: - 3. fswatch 已移除：事件走 IOKit

w("")
w("=== 3. fswatch 移除验证（事件驱动替代轮询）===")
check("DependencyKey 中无 fswatch",
      !DependencyKey.allCases.contains { $0.rawValue.lowercased().contains("fswatch") },
      "实际: \(DependencyKey.allCases.map(\.rawValue).joined(separator: ", "))")

let monitorStart = Date()
let monitor = VolumeMonitor()
let monitorStartMs = Date().timeIntervalSince(monitorStart) * 1000
monitor.stop()
check("VolumeMonitor 构造 < 200 ms（不 spawn 子进程）",
      monitorStartMs < 200, String(format: "%.2f ms", monitorStartMs))

// 只匹配调用形态，不能整词匹配 —— 注释里的设计说明不属于依赖。
let coreSourceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // NTFSMountSmoke
    .deletingLastPathComponent()   // Sources
    .appendingPathComponent("NTFSMountCore")
let swiftFiles: [URL] = (try? FileManager.default
    .contentsOfDirectory(at: coreSourceRoot, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "swift" } ?? []

/// 剥离注释，只留可执行代码，避免把设计说明误判成依赖残留。
func strippingComments(_ source: String) -> String {
    var out = ""
    var inLine = false
    var blockDepth = 0
    var inString = false
    var escaped = false

    var chars = Array(source)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        let next = i + 1 < chars.count ? chars[i + 1] : "\0"

        if inString {
            out.append(c)
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString = false }
            i += 1
            continue
        }
        if inLine {
            if c == "\n" { inLine = false; out.append(c) }
            i += 1
            continue
        }
        if blockDepth > 0 {
            if c == "*" && next == "/" { blockDepth -= 1; i += 2; continue }
            if c == "/" && next == "*" { blockDepth += 1; i += 2; continue }
            i += 1
            continue
        }
        if c == "/" && next == "/" { inLine = true; i += 2; continue }
        if c == "/" && next == "*" { blockDepth = 1; i += 2; continue }
        if c == "\"" { inString = true; out.append(c); i += 1; continue }
        out.append(c)
        i += 1
    }
    chars.removeAll()
    return out
}

let fswatchHits = swiftFiles.compactMap { url -> String? in
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let code = strippingComments(text)
    return code.range(of: "fswatch", options: .caseInsensitive) == nil
        ? nil : url.lastPathComponent
}
check("NTFSMountCore 代码中零 fswatch 引用（已剥离注释）",
      fswatchHits.isEmpty,
      fswatchHits.isEmpty
        ? "扫描 \(swiftFiles.count) 个源文件的可执行部分"
        : fswatchHits.joined(separator: ", "))

// MARK: - 3. ntfs-3g 版本护栏

w("")
w("=== 3. ntfs-3g 版本提示 ===")
w("  badVersion 判断仅基于上游 issue 原文（tuxera/ntfs-3g #217，2026-09-27）。")
w("  不做「某版本修了 N 个 CVE」这类无一手依据的断言。")
check("2026.9.28（推荐）→ 无提示", NTFS3GRequirement.evaluate(version: "2026.9.28") == .ok)
check("2026.9.18 → 拦下（新建文件 EINVAL 回归，上游 #217/#218）",
      NTFS3GRequirement.evaluate(version: "2026.9.18") == .brokenVersion)
check("2026.7.7（回归前的好版本）→ 仅建议升级",
      NTFS3GRequirement.evaluate(version: "2026.7.7") == .upgradeRecommended)
check("2024.11.13（远低于推荐）→ 仅建议升级，不谎报安全风险",
      NTFS3GRequirement.evaluate(version: "2024.11.13") == .upgradeRecommended)
check("无法解析的版本字符串 → 不误报", NTFS3GRequirement.evaluate(version: "unknown") == .ok)
check("已知坏版本集合仅收录有上游 issue 佐证的版本",
      NTFS3GRequirement.knownBadVersions == ["2026.9.18"],
      "已收录: \(NTFS3GRequirement.knownBadVersions.sorted().joined(separator: ", "))")
check("版本归一化", NTFS3GRequirement.normalize("2026.09.08") == "2026.9.8",
      "normalize(\"2026.09.08\") = \(NTFS3GRequirement.normalize("2026.09.08"))")

// MARK: - 4. 挂载参数

w("")
w("=== 4. ntfs-3g 挂载参数 ===")
w("  参数由 MountContract 定义，每项取舍见源码注释。")
check("默认参数集 == 期望值（顺序稳定，可复现）",
      MountContract.flags == MountContract.expectedFlags,
      MountContract.flags.joined(separator: " "))

for flag in ["-olocal", "-oallow_other", "-oremove_hiberfile", "-onoatime"] {
    check("必需参数 \(flag)", MountContract.flags.contains(flag))
}

check("已移除 -oauto_xattr（否则强制用 ._ 边车文件存 xattr）",
      !MountContract.flags.contains("-oauto_xattr"),
      MountContract.removedFlagsReason)

check("big_writes 默认不启用（收益未经实机 fio/dd 对比）",
      !MountContract.flags.contains(MountContract.bigWrites),
      "需实机 fio/dd 对比后再决定")

let savedExperimental = MountContract.experimentalEnabled
MountContract.experimentalEnabled = true
check("开启实验开关后 big_writes 进入参数集",
      MountContract.flags.contains(MountContract.bigWrites),
      MountContract.flags.joined(separator: " "))
MountContract.experimentalEnabled = savedExperimental
check("关闭实验开关后参数集复原",
      MountContract.flags == MountContract.expectedFlags)

// MARK: - 4a. macFUSE iosize

w("")
w("=== 4a. macFUSE I/O 块大小 ===")
w("  官方文档：默认 64 KiB，必须是 2 的幂，最大 32 MiB；")
w("  本地磁盘取大值「can result in a significantly higher performance」。")

check("默认档位为 1 MiB",
      MountContract.ioBlockSize == .oneMiB,
      "-oiosize=\(MountContract.ioBlockSize.bytes.map(String.init) ?? "未传")")

check("默认参数集含 -oiosize=1048576",
      MountContract.flags.contains("-oiosize=1048576"),
      MountContract.flags.joined(separator: " "))

// 三个档位都必须能被正确翻译成挂载参数 —— 这是「设置改了但没生效」这类
// 缺陷唯一能被拦住的地方（UI 侧无法在本环境 typecheck）。
let savedIOSize = MountContract.ioBlockSize
var ioFailures: [String] = []
for (size, expected) in [(IOBlockSize.automatic, [String]()),
                         (IOBlockSize.oneMiB,    ["-oiosize=1048576"]),
                         (IOBlockSize.fourMiB,   ["-oiosize=4194304"])] {
    MountContract.ioBlockSize = size
    let got = MountContract.macFUSEFlags
    if got != expected {
        ioFailures.append("\(size.rawValue)→\(got.joined(separator: " "))")
    }
}
MountContract.ioBlockSize = savedIOSize
check("三档 iosize 均生成正确的挂载参数",
      ioFailures.isEmpty,
      ioFailures.isEmpty ? "automatic / 1 MiB / 4 MiB" : ioFailures.joined(separator: ", "))

MountContract.ioBlockSize = .fourMiB
let fourM = MountContract.flags
MountContract.ioBlockSize = .automatic
let autoFlags = MountContract.flags
MountContract.ioBlockSize = savedIOSize
check("automatic 档不产生 iosize 参数（退回 macFUSE 默认 64 KiB）",
      !autoFlags.contains { $0.hasPrefix("-oiosize") },
      autoFlags.joined(separator: " "))
check("档位切换后参数集回到默认",
      MountContract.flags == MountContract.expectedFlags,
      fourM.joined(separator: " ") + "  →  " + MountContract.flags.joined(separator: " "))

// MARK: - 4b. 设置解码的向前兼容

w("")
w("=== 4b. 设置解码兼容性 ===")
// ★ Swift 合成的 init(from:) 对非可选属性键缺失即抛 keyNotFound，而
//   SettingsStore.load 用 try? ——「老配置 + 新版本」会静默把整份配置退回默认值。
let legacyJSON = """
{
  "savePassword": true,
  "autoMount": true,
  "startupTab": "devices",
  "enableLogs": true,
  "language": "ja",
  "windowWidth": 1280,
  "windowHeight": 800,
  "trayMode": false,
  "preventSleep": true,
  "launchAtLogin": true,
  "manuallyReadOnlyDevices": ["UUID-A", "UUID-B"]
}
""".data(using: .utf8)!

if let legacy = try? JSONDecoder().decode(AppSettings.self, from: legacyJSON) {
    let preserved = legacy.language == .ja
        && legacy.windowWidth == 1280
        && legacy.windowHeight == 800
        && legacy.startupTab == .devices
        && legacy.enableLogs
        && legacy.preventSleep
        && legacy.launchAtLogin
        && legacy.savePassword
        && legacy.autoMount
        && legacy.manuallyReadOnlyDevices == ["UUID-A", "UUID-B"]
    check("旧配置文件的既有字段全部保留（不被重置）",
          preserved,
          "语言 \(legacy.language.rawValue) · 窗口 \(Int(legacy.windowWidth))×\(Int(legacy.windowHeight))"
          + " · 只读清单 \(legacy.manuallyReadOnlyDevices.count) 项")

    let defaultsApplied = legacy.silentLaunch == false
        && legacy.mountOnLaunch == false
        && legacy.ioBlockSize == .oneMiB
    check("缺失的新字段取默认值（而不是让整份配置解码失败）",
          defaultsApplied,
          "silentLaunch=\(legacy.silentLaunch) · mountOnLaunch=\(legacy.mountOnLaunch)"
          + " · ioBlockSize=\(legacy.ioBlockSize.rawValue)")
} else {
    check("旧配置文件的既有字段全部保留（不被重置）", false,
          "解码抛错了 —— 老用户的语言与窗口尺寸会被全部清空")
    check("缺失的新字段取默认值（而不是让整份配置解码失败）", false, "同上")
}

let emptyOK = (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) != nil
check("空配置 {} 可解码为全默认值", emptyOK)

// 往返：编码 → 解码必须完全等价，否则 persist() 每次落盘都在改用户设置
let roundTrip = AppSettings()
var mutated = roundTrip
mutated.silentLaunch = true
mutated.mountOnLaunch = true
mutated.ioBlockSize = .fourMiB
let encoded = try? JSONEncoder().encode(mutated)
let decoded = encoded.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
check("设置编解码往返等价", decoded == mutated,
      decoded == nil ? "往返失败" : "ioBlockSize=\(decoded!.ioBlockSize.rawValue)")

// MARK: - 4c. 钥匙串往返

w("")
w("=== 4c. 管理员密码钥匙串 ===")
// 用**独立的 service** 测试，绝不碰真实条目 ——
// 测试若中途失败留下一条错误密码，会直接破坏用户的挂载功能。
let kcProbeService = "com.ntfsmount.NTFSMount.smokeTest"
let kcProbe = KeychainStore(service: kcProbeService)
_ = kcProbe.delete()

check("初始状态无条目", kcProbe.hasPassword == false && kcProbe.loadPassword() == nil)

do {
    try kcProbe.save("correct-horse-battery-staple")
    check("写入后读回一致",
          kcProbe.loadPassword() == "correct-horse-battery-staple",
          "hasPassword=\(kcProbe.hasPassword)")
} catch {
    check("写入后读回一致", false, "写入抛错：\(error.localizedDescription)")
}

do {
    try kcProbe.save("second-value")
    let matches = kcProbe.loadPassword() == "second-value"
    check("覆盖写入后取到新值（不残留旧条目）", matches,
          "取回：\(kcProbe.loadPassword() ?? "nil")")
} catch {
    check("覆盖写入后取到新值（不残留旧条目）", false, error.localizedDescription)
}

// 空密码必须被拒绝 —— 否则 sudo 会拿着空串去试，且留下一个无效条目
do {
    try kcProbe.save("")
    check("空密码被拒绝", false, "空串竟然写进去了")
} catch {
    check("空密码被拒绝", true, error.localizedDescription)
}

// 密码里的空格是密码的一部分，不能被「顺手 trim」掉
do {
    try kcProbe.save("  spaced password  ")
    check("首尾空格原样保留（不 trim）",
          kcProbe.loadPassword() == "  spaced password  ",
          "「\(kcProbe.loadPassword() ?? "nil")」")
} catch {
    check("首尾空格原样保留（不 trim）", false, error.localizedDescription)
}

_ = kcProbe.delete()
check("删除后条目消失（幂等）",
      kcProbe.hasPassword == false && kcProbe.delete() == true)

// MARK: - 5. 性能

w("")

w("=== 5. 语言包完整性 ===")

// 符号链接构建目录（.build/debug -> out/Products/Debug）会让 contentsOfDirectory(at:)
// 抛 ENOTDIR 并被 try? 吞掉，导致下面十几条集体失败 —— 单独钉一条指向根因。
do {
    let bundles = ResourceLocator.candidateBundles()
    let discovery = bundles.first { $0.bundlePath.contains("NTFSMountCore") }
    let searched = [Bundle.main.bundleURL,
                    Bundle.main.resourceURL,
                    Bundle.main.executableURL?.deletingLastPathComponent()]
        .compactMap { $0?.resolvingSymlinksInPath().path }
    check("资源包发现成功（候选 bundle 命中 *NTFSMountCore.bundle）",
          discovery != nil,
          discovery.map { "命中 \($0.bundlePath)" }
            ?? "候选 \(bundles.count) 个，均非资源包；已搜索：\(Set(searched).sorted().joined(separator: ", "))")
}

// 语言包曾有三类静默故障：繁中条目未翻译、带点号的 key（"quickStart.1"）靠
// 父节点恰为 String 侥幸命中、标题被同名前缀条目覆盖 —— 都只在界面显示裸 key。
let localized = Localization.shared
var cnTitle = "", twTitle = "", enTitle = ""
for lang in AppLanguage.allCases {
    localized.load(language: lang)
    let probes = [
        ("tabs.devices",      "导航标签"),
        ("help.quickStart.1", "帮助条目"),
        ("install.method.macPorts", "安装方式"),
        ("mount.error.timeout",     "错误提示"),
        ("settings.language",       "设置项"),
    ]
    var rawKeys: [String] = []
    for (key, label) in probes {
        let v = localized.t(key)
        if v == key { rawKeys.append("\(label)(\(key))") }
    }
    check("\(lang.displayName) 文案可查（无裸 key 泄漏）",
          rawKeys.isEmpty,
          rawKeys.isEmpty ? "\(probes.count) 项抽查全部命中"
                          : "泄漏: " + rawKeys.joined(separator: ", "))

    let title = localized.title("help.quickStart")
    check("\(lang.displayName) 分组标题可查", title != "help.quickStart", "「\(title)」")

    // 记录三语的实际文案。简繁必须不同 —— 之前显式选简中却显示繁体，
    // 根因是 load() 里系统语言在用户选择之后合并、覆盖了前者。
    if lang == .zhCN { cnTitle = title }
    if lang == .zhTW { twTitle = title }
    if lang == .en   { enTitle = title }
}
localized.load(language: .system)

// MARK: - 5a. 系统语言解析

w("")
w("=== 5a. 系统语言解析（简繁判定） ===")
// 「系统明明是简体却全变繁体」的根因：判定曾「先看地区、后看脚本」，
// zh-Hans-HK 同时含 Hans 与 -HK，地区先命中被归成 zh-TW。正确顺序是脚本优先。
w("  本机首选语言：\(Locale.preferredLanguages.first ?? "(空)")"
  + "  →  解析为 \(Localization.resolvedSystemCode())")

let languageCases: [(String, String)] = [
    ("zh-Hans-HK", "zh-CN"),   // ← 触发线上问题的那个标签
    ("zh-Hant-HK", "zh-TW"),
    ("zh-Hans-TW", "zh-CN"),
    ("zh-Hant-CN", "zh-TW"),
    ("zh-Hans", "zh-CN"),
    ("zh-Hans-CN", "zh-CN"),
    ("zh-Hant", "zh-TW"),
    ("zh-Hant-TW", "zh-TW"),
    ("zh-TW", "zh-TW"),
    ("zh-HK", "zh-TW"),
    ("zh-MO", "zh-TW"),
    ("zh-CN", "zh-CN"),
    ("zh", "zh-CN"),
    ("en-US", "en"),
    ("en", "en"),
    ("ja-JP", "ja"),
    ("de-DE", "de"),
    ("fr-FR", "en"),
    ("ko-KR", "en"),
]
var languageFailures: [String] = []
for (raw, expected) in languageCases {
    let got = Localization.resolve(preferredLanguage: raw)
    if got != expected { languageFailures.append("\(raw)→\(got)(应为 \(expected))") }
}
check("\(languageCases.count) 个语言标签解析正确",
      languageFailures.isEmpty,
      languageFailures.isEmpty ? "含简繁混搭与未支持语言的回退"
                               : languageFailures.joined(separator: ", "))

check("简中显示简体", cnTitle == "快速开始", "「\(cnTitle)」")
check("繁中显示繁体", twTitle == "快速開始", "「\(twTitle)」")
check("英文显示英文", enTitle == "Quick Start", "「\(enTitle)」")
check("简繁文案不同", cnTitle != twTitle, "简=「\(cnTitle)」 繁=「\(twTitle)」")

// 查的是「磁盘上有哪些语言包」而不是 diagnostics.loadedFrom（后者只记录
// 最近一次 load 命中）；零语言包不会报错，只会让界面成片显示裸 key。
let availableLocales = ResourceLocator.availableLanguageCodes(Localization.supportedCodes)
check("语言包资源完整（5 种语言均在产物中）",
      availableLocales.count == Localization.supportedCodes.count,
      availableLocales.isEmpty
        ? "一个语言包都没找到 —— 产物缺资源，界面会全面退化成裸 key"
        : "找到 \(availableLocales.count) 份：" + availableLocales.joined(separator: ", "))

let availableManuals = Localization.supportedCodes.filter {
    ResourceLocator.locate("help.\($0).md") != nil
}
check("手册资源完整（5 种语言均在产物中）",
      availableManuals.count == Localization.supportedCodes.count,
      availableManuals.isEmpty
        ? "一份手册都没找到 —— 手册页会退化成兜底提示"
        : "找到 \(availableManuals.count) 份：" + availableManuals.joined(separator: ", "))

w("")
w("=== 5b. 使用手册 ===")
// 手册缺文件只会显示兜底提示、不会报错，故逐语言确认真的解析出了章节。
for lang in AppLanguage.allCases {
    let doc = Manual.load(language: lang)
    let chapterText = doc.chapters.map(\.title).joined(separator: " / ")
    check("\(lang.displayName) 手册可解析",
          !doc.isFallback && doc.chapters.count >= 10,
          doc.isFallback
            ? "回退到内置兜底文档 —— 手册文件缺失"
            : "\(doc.chapters.count) 章：\(chapterText.prefix(60))…")
}

if let zhDoc = Optional(Manual.load(language: .zhCN)), !zhDoc.isFallback {
    let allBlocks = zhDoc.chapters.flatMap(\.blocks)
    var headings = 0, bullets = 0, codes = 0, tables = 0, callouts = 0, paragraphs = 0
    for block in allBlocks {
        switch block {
        case .heading:   headings += 1
        case .bullet:    bullets += 1
        case .code:      codes += 1
        case .table:     tables += 1
        case .callout:   callouts += 1
        case .paragraph: paragraphs += 1
        case .ordered, .divider: break
        }
    }
    check("Markdown 块级解析完整",
          headings > 0 && bullets > 0 && codes > 0 && tables > 0 && callouts > 0,
          "标题 \(headings) · 列表 \(bullets) · 命令块 \(codes) · 表格 \(tables) · 提示框 \(callouts) · 段落 \(paragraphs)")

    let spans = InlineMarkdown.parse("**粗体** 与 `代码` 与 [链接](https://example.com)")
    let kinds = Set(spans.map { span -> String in
        switch span {
        case .text:   return "text"
        case .bold:   return "bold"
        case .italic: return "italic"
        case .code:   return "code"
        case .link:   return "link"
        }
    })
    check("行内标记解析完整",
          kinds.isSuperset(of: ["bold", "code", "link"]),
          "识别到 " + kinds.sorted().joined(separator: ", "))
}
localized.load(language: .system)

w("")
w("=== 6. 性能实测 ===")
// 注意这是**跑完前面所有小节之后**的常驻内存，不是进程冷启动那一刻的值 ——
// 标成「启动 RSS」会让人以为应用一启动就占这么多。
w(String(format: "  RSS（本节开始时）   : %.1f MB", rssMB()))

let t0 = Date(); _ = DependencyDetector().detect()
let depsMs = Date().timeIntervalSince(t0) * 1000
let t1 = Date(); _ = DiskInventory.mountTable()
let mountMs = Date().timeIntervalSince(t1) * 1000
let t2 = Date(); _ = DiskInventory.enumerateNTFSPartitions()
let enumMs = Date().timeIntervalSince(t2) * 1000

let t3 = Date()
for _ in 0..<200 { _ = DiskInventory.mountTable(); _ = DiskInventory.enumerateNTFSPartitions() }
let loopMs = Date().timeIntervalSince(t3) * 1000

w(String(format: "  依赖检测            : %6.2f ms    纯 stat，无子进程", depsMs))
w(String(format: "  挂载表 (statfs)     : %6.2f ms    遍历 /Volumes + statfs", mountMs))
w(String(format: "  NTFS 枚举 (IOKit)   : %6.2f ms    IOServiceGetMatchingServices", enumMs))
w(String(format: "  200 轮全量刷新      : %6.2f ms    平均 %6.3f ms/轮", loopMs, loopMs / 200))
w(String(format: "  刷新后 RSS          : %.1f MB", rssMB()))
w("")
w("  常驻资源：0 子进程、0 轮询定时器。刷新耗时随挂载的分区数量线性变化。")
w("  事件来源：IOKit kIOMatched/kIOTerminated 通知端口 + NSWorkspace didMount/didUnmount。")

// 这条断言守的是「热路径里不许有 fork/exec」，不是给 IOKit 遍历做微基准 ——
// 后者随挂载分区数线性变化，阈值卡太紧会变成随机器状态偶发飘红的假警报。
check("单轮刷新 < 20 ms", loopMs / 200 < 20.0, String(format: "%.3f ms/轮", loopMs / 200))
check("依赖检测 < 50 ms（无子进程）", depsMs < 50.0, String(format: "%.2f ms", depsMs))

// MARK: - 结果

w("")
let n = failures.value
w(n == 0 ? "✅ 全部检查通过" : "❌ \(n) 项检查失败")
exit(failures.value == 0 ? 0 : 1)


