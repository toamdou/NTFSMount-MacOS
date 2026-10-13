import Foundation

// MARK: - NTFS 设备

public struct DeviceCapacity: Sendable, Equatable {
    public var total: Int64
    public var used: Int64
    public var available: Int64

    public init(total: Int64, used: Int64, available: Int64) {
        self.total = total
        self.used = used
        self.available = available
    }

    public var usageFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

public struct NTFSDevice: Identifiable, Sendable, Equatable {
    public var disk: String            // disk4s1
    public var devicePath: String      // /dev/disk4s1
    public var volume: String          // 挂载点 /Volumes/XXX（未挂载为空）
    public var volumeName: String
    public var volumeUuid: String?
    public var isReadOnly: Bool
    public var options: String
    public var isMounted: Bool         // 是否已由 ntfs-3g(FUSE) 挂载为读写
    public var isUnmounted: Bool       // 用户主动卸载后仍保留在列表
    public var capacity: DeviceCapacity?

    public init(disk: String, devicePath: String, volume: String, volumeName: String,
                volumeUuid: String?, isReadOnly: Bool, options: String,
                isMounted: Bool, isUnmounted: Bool, capacity: DeviceCapacity?) {
        self.disk = disk
        self.devicePath = devicePath
        self.volume = volume
        self.volumeName = volumeName
        self.volumeUuid = volumeUuid
        self.isReadOnly = isReadOnly
        self.options = options
        self.isMounted = isMounted
        self.isUnmounted = isUnmounted
        self.capacity = capacity
    }

    /// SwiftUI List 标识
    public var id: String { disk }

    /// 稳定标识：优先 volumeUuid，回退 disk（避免 disk 号漂移导致设置丢失）。
    public var stableId: String { volumeUuid ?? disk }

    public var isReadWrite: Bool { isMounted && !isReadOnly }
}

// MARK: - 日志

public enum LogType: String, Sendable, CaseIterable, Codable {
    case info, success, error, warning

    public var symbolName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

public struct LogEntry: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID = UUID()
    public var time: Date
    public var message: String
    public var type: LogType

    public init(time: Date = Date(), message: String, type: LogType) {
        self.time = time
        self.message = message
        self.type = type
    }

    public var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: time)
    }
}

// MARK: - 设置

public enum AppTab: String, CaseIterable, Identifiable, Sendable, Codable {
    case dependencies, devices, logs, help

    public var id: String { rawValue }

    public var titleKey: String { "tabs.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .dependencies: return "square.grid.2x2"
        case .devices:      return "externaldrive"
        case .logs:         return "list.bullet.rectangle"
        case .help:         return "book"
        }
    }

    /// 未知取值回退到 `.dependencies`（`AppSettings` 整体解码，解不出会重置整份配置）。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppTab(rawValue: raw) ?? .dependencies
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable, Codable {
    case system, zhCN = "zh-CN", zhTW = "zh-TW", ja, en, de

    public var id: String { rawValue }

    /// 语言在界面上的显示名。具体语言用其自称（endonym），「跟随系统」附带解析结果。
    public var displayName: String {
        switch self {
        case .system:
            let resolved = Localization.resolvedSystemCode()
            return Localization.shared.t("language.system") + " · " + Self.selfName(forCode: resolved)
        case .zhCN: return "简体中文"
        case .zhTW: return "繁體中文"
        case .ja:   return "日本語"
        case .en:   return "English"
        case .de:   return "Deutsch"
        }
    }

    /// 语言代码对应的自称。未知代码原样返回，便于发现映射缺口。
    public static func selfName(forCode code: String) -> String {
        switch code {
        case "zh-CN": return "简体中文"
        case "zh-TW": return "繁體中文"
        case "ja":    return "日本語"
        case "en":    return "English"
        case "de":    return "Deutsch"
        default:      return code
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var savePassword: Bool = false
    public var autoMount: Bool = false
    public var startupTab: AppTab = .dependencies
    public var enableLogs: Bool = false
    public var language: AppLanguage = .system
    public var windowWidth: Double = 900
    public var windowHeight: Double = 680
    public var trayMode: Bool = false
    public var preventSleep: Bool = false
    public var launchAtLogin: Bool = false
    public var silentLaunch: Bool = false
    public var mountOnLaunch: Bool = false
    public var ioBlockSize: IOBlockSize = .oneMiB
    public var manuallyReadOnlyDevices: [String] = []

    public init() {}

    /// 手写解码：每字段用 `decodeIfPresent` 给默认值；新增字段必须同步加进这里，否则老配置整份重置。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        savePassword   = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        autoMount      = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? false
        startupTab     = try c.decodeIfPresent(AppTab.self, forKey: .startupTab) ?? .dependencies
        enableLogs     = try c.decodeIfPresent(Bool.self, forKey: .enableLogs) ?? false
        language       = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        windowWidth    = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? 900
        windowHeight   = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 680
        trayMode       = try c.decodeIfPresent(Bool.self, forKey: .trayMode) ?? false
        preventSleep   = try c.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? false
        launchAtLogin  = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        silentLaunch   = try c.decodeIfPresent(Bool.self, forKey: .silentLaunch) ?? false
        mountOnLaunch  = try c.decodeIfPresent(Bool.self, forKey: .mountOnLaunch) ?? false
        ioBlockSize    = try c.decodeIfPresent(IOBlockSize.self, forKey: .ioBlockSize) ?? .oneMiB
        manuallyReadOnlyDevices =
            try c.decodeIfPresent([String].self, forKey: .manuallyReadOnlyDevices) ?? []
    }
}

// MARK: - I/O 块大小

/// macFUSE 的 `iosize` 档位。块大小最优值与负载相关，`.automatic` 是「不传该参数」的安全回退。
public enum IOBlockSize: String, Sendable, CaseIterable, Identifiable, Codable {
    /// 不传 `iosize`，由 macFUSE 取自身默认值（64 KiB）。
    case automatic
    /// 1 MiB —— 默认值。
    case oneMiB
    /// 4 MiB —— 面向超大文件（视频素材、磁盘映像）的顺序读写。
    case fourMiB

    public var id: String { rawValue }

    /// 传给 macFUSE 的字节数，须为 2 的幂；`.automatic` 返回 nil 表示不追加该参数。
    public var bytes: Int? {
        switch self {
        case .automatic: return nil
        case .oneMiB:    return 1_048_576
        case .fourMiB:   return 4_194_304
        }
    }

    public var titleKey: String { "settings.ioSize.\(rawValue)" }
}
