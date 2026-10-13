import Foundation

public struct DependencyStatus: Sendable {
    public var macOS: Bool = false
    public var macOSVersionString: String = "未知"
    /// Xcode Command Line Tools（运行期非必需，用于诊断与「重置设备」时定位 ntfsfix）
    public var commandLineTools: Bool = false
    public var macFUSE: Bool = false
    public var ntfs3g: Bool = false
    public var ntfs3gPath: String?
    public var ntfsfixPath: String?

    public var homebrew: HomebrewDetection = HomebrewDetection()
    public var macPorts: MacPortsDetection = MacPortsDetection()

    /// 核心依赖是否齐备 —— 不含 Homebrew
    public var coreInstalled: Bool {
        macOS && macFUSE && ntfs3g
    }

    public init() {}
}

// MARK: - 检测器

public struct DependencyDetector {

    public init() {}

    public func detect() -> DependencyStatus {
        var status = DependencyStatus()

        let osVersion = OperatingSystem.versionString
        status.macOSVersionString = osVersion.string
        status.macOS = osVersion.isSupported

        status.commandLineTools = (ToolLocator.locate("xcrun") != nil)

        status.homebrew = HomebrewDetector.detect()
        status.macPorts = MacPortsDetector.detect()

        status.macFUSE = MacFUSEDetector.isInstalled()
        status.ntfs3gPath = ToolLocator.locate("ntfs-3g")
        status.ntfs3g = status.ntfs3gPath != nil
        status.ntfsfixPath = ToolLocator.locate("ntfsfix")

        return status
    }
}

// MARK: - macOS 版本

public struct OSVersionInfo {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let string: String

    /// 应用要求 macOS 14 (Sonoma) 及以上。
    public static let minimumMajor = 14

    public var isSupported: Bool { major >= Self.minimumMajor }
}

public enum OperatingSystem {
    public static var versionString: OSVersionInfo {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let s = "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
        return OSVersionInfo(major: info.majorVersion,
                            minor: info.minorVersion,
                            patch: info.patchVersion,
                            string: s)
    }

    /// FSKit 需要 macOS 15.4+。此常量用于未来分流与提示。
    public static let fskitMinimumMajor = 15
    public static let fskitMinimumMinor = 4

    public static var supportsFSKit: Bool {
        let v = versionString
        return v.major > fskitMinimumMajor ||
               (v.major == fskitMinimumMajor && v.minor >= fskitMinimumMinor)
    }
}

// MARK: - MacFUSE 检测

public enum MacFUSEDetector {

    /// MacFUSE 安装后固定在 `/Library/Filesystems/macfuse.fs` 留下 bundle，与安装方式无关。
    public static let bundlePath = "/Library/Filesystems/macfuse.fs"

    /// libfuse 动态库位置（Intel Homebrew / MacPorts / Apple Silicon Homebrew）
    private static let libraryRelativePaths = [
        "lib/libfuse.dylib",
        "lib/libfuse.2.dylib",
        "lib/libfuse.3.dylib",
        "lib/libosxfuse.dylib",
        "lib/libosxfuse.2.dylib",
    ]

    public static func isInstalled() -> Bool {
        let fm = FileManager.default

        if fm.fileExists(atPath: bundlePath) { return true }
        if fm.fileExists(atPath: "/System/Volumes/Data" + bundlePath) { return true }

        if fm.fileExists(atPath: bundlePath + "/Contents/Resources/mount_macfuse") { return true }

        for relative in libraryRelativePaths {
            if ToolLocator.locateFile(relativePath: relative) != nil { return true }
        }

        return false
    }

    /// 读取安装版本（读取 bundle 的 Info.plist），用于版本下限提示。
    public static func installedVersion() -> String? {
        let plist = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    /// 是否加载了内核扩展 / 系统扩展（需要 SIP 放行）。
    public static func kextOrSystemExtensionPresent() -> Bool {
        let candidates = [
            "/Library/Extensions/macfuse.kext",
            "/Library/Extensions/macfuse.systemextension",
            "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.kext",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - ntfs-3g 版本要求

public enum NTFS3GRequirement {
    /// 建议的 ntfs-3g 版本下限（2026.9.28 修复了 2026.9.18 引入的文件创建回归）。
    public static let recommended = "2026.9.28"

    /// 已知有严重回归、**不应安装**的版本（2026.9.18：新建文件/目录返回 EINVAL）。
    public static let knownBadVersions: Set<String> = ["2026.9.18"]

    /// 低于此版本只提示「建议升级」，不再声称有安全风险。
    public static let upgradeFloor = "2026.2.25"

    public enum Severity {
        /// 版本达到推荐值，或无法解析。
        case ok
        /// 版本低于推荐值，建议升级。
        case upgradeRecommended
        /// 已知有严重回归，不应安装。
        case brokenVersion
    }

    /// 比较 `ntfs-3g --version` 输出。
    public static func evaluate(version: String) -> Severity {
        let normalized = normalize(version)
        guard !normalized.isEmpty else { return .ok }

        // 已知坏版本优先判定：即便它高于 upgradeFloor 也要拦下。
        if knownBadVersions.contains(normalized) { return .brokenVersion }

        guard let current = parse(normalized) else { return .ok }
        if compare(current, parse(normalize(recommended))!) < 0 {
            return .upgradeRecommended
        }
        return .ok
    }

    /// 归一化：把 `2026.9.28` / `2026.09.28` / `v2026.9.28` 统一为 `2026.9.28`
    public static func normalize(_ s: String) -> String {
        var out = ""
        var sawDigit = false
        for ch in s {
            if ch.isNumber {
                if ch == "0" && out.hasSuffix(".") { continue } // 去掉前导零
                out.append(ch)
                sawDigit = true
            } else if ch == "." && sawDigit && !out.hasSuffix(".") {
                out.append(ch)
            } else if sawDigit {
                break
            }
        }
        while out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// 归一化后的版本字符串 → 可比较数组（缺失位补 0）
    private static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var v = parts
        while v.count < 3 { v.append(0) }
        return v
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
