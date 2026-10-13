import Foundation

public enum InstallMethod: String, CaseIterable, Sendable {
    case macPorts
    case homebrew
    /// 与包管理器无关的系统命令（如 `xcode-select --install`）。不出现在界面
    /// 「安装方式」选择器里 —— 用户无从「选择」一条系统命令。
    case direct

    /// 「安装方式」选择器的选项，只保留两个包管理器；`allCases` 仍含 `direct`（命令生成要用）。
    public static var selectableCases: [InstallMethod] { [.macPorts, .homebrew] }

    public var displayName: String {
        switch self {
        case .macPorts: return Localization.shared.t("install.method.macPorts")
        case .homebrew: return Localization.shared.t("install.method.homebrew")
        case .direct:   return Localization.shared.t("install.method.direct")
        }
    }
}

public struct InstallCommand {
    public let method: InstallMethod
    public let command: String
    public let note: String?

    public init(method: InstallMethod, command: String, note: String? = nil) {
        self.method = method
        self.command = command
        self.note = note
    }
}

public enum DependencyKey: String, CaseIterable, Sendable {
    case macOS
    case commandLineTools
    case macFUSE
    case ntfs3g
}

public struct DependencyEntry {
    public let key: DependencyKey
    public let name: String
    public let description: String
    public let isSatisfied: Bool
    public let isOptional: Bool
    public let commands: [InstallCommand]
    public let guide: String
    /// 额外提示（例如 ntfs-3g 版本风险）
    public var warning: String? = nil
}

public enum InstallGuideBuilder {

    public static func entries(for status: DependencyStatus) -> [DependencyEntry] {
        DependencyKey.allCases.map { key in
            entry(for: key, status: status)
        }
    }

    private static func entry(for key: DependencyKey, status: DependencyStatus) -> DependencyEntry {
        switch key {
        case .macOS:
            return DependencyEntry(
                key: key,
                name: Localization.shared.t("dependencies.macosVersion.name",
                                             ["version": status.macOSVersionString]),
                description: Localization.shared.t("dependencies.macosVersion.description"),
                isSatisfied: status.macOS,
                isOptional: false,
                commands: [],
                guide: Localization.shared.t("dependencies.macosVersion.installGuide")
            )

        case .commandLineTools:
            return DependencyEntry(
                key: key,
                name: Localization.shared.t("dependencies.swift.name"),
                description: Localization.shared.t("dependencies.swift.description"),
                isSatisfied: status.commandLineTools,
                isOptional: false,
                commands: [InstallCommand(method: .direct,
                                          command: "xcode-select --install",
                                          note: Localization.shared.t("dependencies.swift.installGuide"))],
                guide: Localization.shared.t("dependencies.swift.installGuide")
            )

        case .macFUSE:
            return DependencyEntry(
                key: key,
                name: Localization.shared.t("dependencies.macfuse.name"),
                description: Localization.shared.t("dependencies.macfuse.description"),
                isSatisfied: status.macFUSE,
                isOptional: false,
                commands: macFUSECommands(status: status),
                guide: Localization.shared.t("dependencies.macfuse.installGuide")
            )

        case .ntfs3g:
            var entry = DependencyEntry(
                key: key,
                name: Localization.shared.t("dependencies.ntfs3g.name"),
                description: Localization.shared.t("dependencies.ntfs3g.description"),
                isSatisfied: status.ntfs3g,
                isOptional: false,
                commands: ntfs3gCommands(status: status),
                guide: Localization.shared.t("dependencies.ntfs3g.installGuide")
            )
            if let path = status.ntfs3gPath {
                if let version = NTFS3GVersionProbe.readVersion(at: path) {
                    entry.warning = NTFS3GRequirement.warningText(
                        for: NTFS3GRequirement.evaluate(version: version), version: version
                    )
                }
            } else {
                entry.warning = Localization.shared.t("dependencies.ntfs3g.notFoundWarning")
            }
            return entry

        }
    }

    // MARK: - 命令生成

    private static func orderedMethods(_ status: DependencyStatus) -> [InstallMethod] {
        if status.macPorts.isPresent && !status.homebrew.isPresent {
            return [.macPorts, .homebrew]
        }
        if status.homebrew.isPresent {
            return [.homebrew, .macPorts]
        }
        // 两者都没有：Intel Mac 优先推荐 MacPorts
        if !HostArchitecture.isAppleSilicon {
            return [.macPorts, .homebrew]
        }
        return [.homebrew, .macPorts]
    }

    private static func macFUSECommands(status: DependencyStatus) -> [InstallCommand] {
        orderedMethods(status).map { method in
            switch method {
            case .macPorts:
                return InstallCommand(
                    method: .macPorts,
                    command: "sudo port install macfuse",
                    note: Localization.shared.t("install.macPorts.note")
                )
            case .homebrew:
                return InstallCommand(
                    method: .homebrew,
                    command: "brew install --cask macfuse"
                )
            case .direct:
                return InstallCommand(method: .direct, command: "")
            }
        }
    }

    private static func ntfs3gCommands(status: DependencyStatus) -> [InstallCommand] {
        orderedMethods(status).map { method in
            switch method {
            case .macPorts:
                // MacPorts 的 ntfs-3g port 会自动依赖 macfuse
                return InstallCommand(
                    method: .macPorts,
                    command: "sudo port install ntfs-3g",
                    note: Localization.shared.t("install.ntfs3g.macPortsNote")
                )
            case .homebrew:
                return InstallCommand(
                    method: .homebrew,
                    command: "brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"
                )
            case .direct:
                return InstallCommand(method: .direct, command: "")
            }
        }
    }

}

// MARK: - ntfs-3g 版本读取

public enum NTFS3GVersionProbe {
    /// 执行 `ntfs-3g --version` 读取版本；仅在依赖面板展开时调用（懒执行），不进入常驻路径。
    public static func readVersion(at path: String) -> String? {
        guard let result = try? Shell.run(path, ["--version"], timeout: 3),
              result.exitCode == 0
        else { return nil }

        // 输出形如 `ntfs-3g 2026.9.28 ...` 或 `ntfs-3g_ntfsprogs-2026.9.28`
        let text = (result.stdout + " " + result.stderr)
        guard let range = text.range(of: #"\d{4}\.\d{1,2}\.\d{1,2}"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}

public extension NTFS3GRequirement {
    static func warningText(for severity: Severity, version: String) -> String? {
        switch severity {
        case .ok:
            return nil
        case .upgradeRecommended:
            return Localization.shared.t("dependencies.ntfs3g.outdatedWarning",
                                          ["version": version, "recommended": recommended])
        case .brokenVersion:
            return Localization.shared.t("dependencies.ntfs3g.brokenWarning",
                                          ["version": version, "recommended": recommended])
        }
    }
}

// MARK: - 主机架构

public enum HostArchitecture {
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var description: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
}
