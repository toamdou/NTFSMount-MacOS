import Foundation

public enum AppInfo {

    /// 版本号（CFBundleShortVersionString）
    public static var version: String {
        info("CFBundleShortVersionString") ?? "1.0.0"
    }

    /// 构建号（CFBundleVersion）
    public static var build: String {
        info("CFBundleVersion") ?? version
    }

    public static var name: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "NTFSMount"
    }

    /// 形如 `1.0.0 (1.0.0)`
    public static var versionWithBuild: String {
        build == version ? version : "\(version) (\(build))"
    }

    /// 运行环境描述，如 `macOS 26.0 · Apple Silicon`
    public static var environment: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion)"
        return "\(os) · \(HostArchitecture.description)"
    }

    /// 最低支持的系统版本（来自 LSMinimumSystemVersion）
    public static var minimumSystemVersion: String {
        info("LSMinimumSystemVersion") ?? "14.0"
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
