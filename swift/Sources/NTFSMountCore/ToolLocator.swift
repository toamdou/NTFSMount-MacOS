import Foundation

public enum ToolLocator {

    // MARK: - 已知前缀目录

    /// 候选查找前缀，顺序即优先级。
    public static let searchPrefixes: [String] = [
        "/opt/homebrew",
        "/usr/local",
        "/opt/local",
        "/usr",
        "/bin",
        "/sbin",
    ]

    private static func candidateDirs(for tool: String) -> [String] {
        var dirs: [String] = []
        for prefix in searchPrefixes {
            dirs.append("\(prefix)/bin")
            dirs.append("\(prefix)/sbin")
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let dir = String(entry)
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs
    }

    /// macOS 11+ 的 /usr/local 等是 firmlink，实际落在 /System/Volumes/Data 下；fileExists 会回退，这里显式处理以便返回可直接执行的绝对路径。
    private static func resolveFirmlink(_ path: String) -> String {
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        let dataVolumePath = "/System/Volumes/Data" + path
        if FileManager.default.isExecutableFile(atPath: dataVolumePath) { return dataVolumePath }
        return path
    }

    // MARK: - 查找 API

    /// 未找到返回 nil；纯同步文件系统调用，无子进程开销，可安全在高频路径调用。
    public static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in candidateDirs(for: tool) {
            let candidate = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
            let resolved = resolveFirmlink(candidate)
            if resolved != candidate, fm.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }

    public static func locateDirectory(containingRelativePath relative: String) -> String? {
        let fm = FileManager.default
        for prefix in searchPrefixes {
            let candidate = "\(prefix)/\(relative)"
            if fm.fileExists(atPath: candidate) { return candidate }
            let resolved = "/System/Volumes/Data" + candidate
            if fm.fileExists(atPath: resolved) { return resolved }
        }
        return nil
    }

    public static func locateFile(relativePath: String) -> String? {
        locateDirectory(containingRelativePath: relativePath)
    }

    public static func detectPackageManagers() -> PackageManagerPresence {
        PackageManagerPresence(
            homebrew: HomebrewDetector.detect(),
            macPorts: MacPortsDetector.detect()
        )
    }
}

// MARK: - Homebrew

public struct HomebrewDetection: Sendable {
    public var binaryPath: String?
    /// Intel 前缀 (/usr/local) 或 Apple Silicon 前缀 (/opt/homebrew)
    public var prefix: String?

    public var isPresent: Bool { binaryPath != nil }

    /// Intel Mac 的 Homebrew 前缀；Apple Silicon 为 nil
    public static var intelPrefix: String? { "/usr/local".isEmpty ? nil : "/usr/local" }
}

public enum HomebrewDetector {
    /// 探测 Homebrew 是否存在。
    /// 结果不参与依赖满足性判定（`DependencyStatus.coreInstalled`）。
    public static func detect() -> HomebrewDetection {
        if let p = ToolLocator.locate("brew") {
            let prefix = p.hasPrefix("/opt/homebrew") ? "/opt/homebrew" : "/usr/local"
            return HomebrewDetection(binaryPath: p, prefix: prefix)
        }
        return HomebrewDetection(binaryPath: nil, prefix: nil)
    }
}

// MARK: - MacPorts

public struct MacPortsDetection: Sendable {
    public var binaryPath: String?
    public var portPath: String?
    /// MacPorts 固定前缀
    public let prefix = "/opt/local"

    public var isPresent: Bool { portPath != nil }
}

public enum MacPortsDetector {
    /// 探测 MacPorts 是否存在。
    public static func detect() -> MacPortsDetection {
        let fm = FileManager.default
        let portPath = fm.isExecutableFile(atPath: "/opt/local/bin/port") ? "/opt/local/bin/port" : nil
        let binary = ToolLocator.locate("port")
        return MacPortsDetection(binaryPath: binary, portPath: portPath)
    }
}

public struct PackageManagerPresence: Sendable {
    public var homebrew: HomebrewDetection
    public var macPorts: MacPortsDetection

    public var hasAny: Bool { homebrew.isPresent || macPorts.isPresent }

    public var preferMacPorts: Bool { macPorts.isPresent && !homebrew.isPresent }
}
