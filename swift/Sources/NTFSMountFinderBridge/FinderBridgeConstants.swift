import Foundation

// MARK: - 通知名

/// 跨进程通信用的 Darwin 通知名（无负载，接收方自行读文件）。
public enum FinderBridgeNotification {
    /// 卷状态快照已更新（主应用 → 扩展）
    public static let stateChanged = "com.ntfsmount.finder.stateChanged"

    /// 有新的挂载命令入队（扩展 → 主应用）
    public static let commandPosted = "com.ntfsmount.finder.commandPosted"

    /// 命令执行完成，结果已写盘（主应用 → 扩展）
    public static let commandFinished = "com.ntfsmount.finder.commandFinished"

    /// 主应用即将退出，扩展应清空「处理中」标记
    public static let appWillTerminate = "com.ntfsmount.finder.appWillTerminate"

    public static let all = [stateChanged, commandPosted, commandFinished, appWillTerminate]
}

// MARK: - App Group / 路径

/// 共享容器路径：优先 App Group，未配置时退化为 `~/Library/Application Support/NTFSMount`（扩展读不到，功能降级但不崩溃）。
public enum FinderBridgeContainer {

    /// App Group 标识符。必须同时写进主应用与扩展的 entitlements。
    public static let appGroupIdentifier = "group.com.ntfsmount.shared"

    /// 共享目录名（App Group 与退化路径都用它作为子目录名）
    public static let directoryName = "NTFSMount"

    public static let snapshotFileName = "finder-state.json"

    public static let pendingCommandFileName = "command.json"

    public static let commandResultFileName = "result.json"

    public static let commandLockFileName = "command.lock"

    public static let resultLockFileName = "result.lock"

    /// 待处理命令超过该时长视为过期并清理（秒）
    public static let commandTimeout: TimeInterval = 120

    /// 结果文件保留时长（秒），超过后清理，避免扩展长期运行堆积文件
    public static let resultRetention: TimeInterval = 600

    /// 共享根目录：App Group 可用时为 `<group>/NTFSMount`，否则为 `~/Library/Application Support/NTFSMount`。
    public static var rootDirectory: URL {
        if isAppGroupAvailable {
            let group = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
                ?? fallbackDirectory
            return group.appendingPathComponent(directoryName, isDirectory: true)
        }
        return fallbackDirectory
    }

    /// 无 App Group 时的退化目录
    private static var fallbackDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 是否真正可用 App Group 容器：必须实写探针文件判定 —— macOS 对无效 group id 也返回非 nil URL，不能靠 `containerURL(...) != nil`。
    public static let isAppGroupAvailable: Bool = probeAppGroupWritable()

    private static func probeAppGroupWritable() -> Bool {
        let fm = FileManager.default
        guard let group = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return false
        }
        let dir = group.appendingPathComponent(directoryName, isDirectory: true)
        let probe = group.appendingPathComponent(".ntfsmount-write-probe", isDirectory: false)
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data([0x6E]).write(to: probe)
            try? fm.removeItem(at: probe)
            return true
        } catch {
            try? fm.removeItem(at: probe)
            return false
        }
    }

    public static var snapshotURL: URL {
        rootDirectory.appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    public static var commandDirectory: URL {
        rootDirectory.appendingPathComponent("commands", isDirectory: true)
    }

    public static var pendingCommandURL: URL {
        commandDirectory.appendingPathComponent(pendingCommandFileName, isDirectory: false)
    }

    public static var resultDirectory: URL {
        rootDirectory.appendingPathComponent("results", isDirectory: true)
    }

    public static var commandLockURL: URL {
        commandDirectory.appendingPathComponent(commandLockFileName, isDirectory: false)
    }

    public static var resultLockURL: URL {
        resultDirectory.appendingPathComponent(resultLockFileName, isDirectory: false)
    }

    /// 创建所需目录。幂等。
    @discardableResult
    public static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for dir in [rootDirectory, commandDirectory, resultDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - 快照

/// Finder 可见的卷状态快照：主应用是唯一写入方，扩展只读。
public struct VolumeSnapshot: Codable, Sendable, Equatable {

    /// 单个卷的状态。`Codable` 用字符串原值，保证 JSON 可读且向后兼容。
    public enum State: String, Codable, Sendable {
        /// 已由 ntfs-3g(FUSE) 挂载为读写
        case readWrite
        /// 系统只读挂载（macOS 内置 NTFS 驱动）
        case readOnly
        /// 设备存在但当前没有挂载点
        case unmounted
        /// 设备消失 / 读取失败
        case unavailable

        /// 菜单项标题后缀（如「已以读写方式挂载」）
        public var localizedDescription: String {
            switch self {
            case .readWrite:  return FinderStrings.stateReadWrite
            case .readOnly:   return FinderStrings.stateReadOnly
            case .unmounted:  return FinderStrings.stateUnmounted
            case .unavailable: return FinderStrings.stateUnavailable
            }
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// 挂载点，如 `/Volumes/Backup`。扩展按此字段匹配 Finder URL。
        public var mountPath: String
        /// 设备路径，如 `/dev/disk4s1`
        public var devicePath: String
        /// 卷名（菜单展示用）
        public var volumeName: String
        /// 卷 UUID（稳定标识，disk 号会漂移）
        public var volumeUuid: String?
        public var state: State
        public var totalBytes: Int64
        public var freeBytes: Int64

        public init(mountPath: String,
                    devicePath: String,
                    volumeName: String,
                    volumeUuid: String?,
                    state: State,
                    totalBytes: Int64,
                    freeBytes: Int64) {
            self.mountPath = mountPath
            self.devicePath = devicePath
            self.volumeName = volumeName
            self.volumeUuid = volumeUuid
            self.state = state
            self.totalBytes = totalBytes
            self.freeBytes = freeBytes
        }
    }

    public var entries: [Entry]
    public var updatedAt: Date

    public init(entries: [Entry], updatedAt: Date = Date()) {
        self.entries = entries
        self.updatedAt = updatedAt
    }

    public static let empty = VolumeSnapshot(entries: [], updatedAt: .distantPast)

    /// 按挂载点索引。扩展每次请求 badge 都会调用，因此单独缓存。
    public func indexByMountPath() -> [String: Entry] {
        var map: [String: Entry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries where !entry.mountPath.isEmpty {
            map[FinderPathNormalizer.normalize(entry.mountPath)] = entry
        }
        return map
    }

    /// 由挂载点反查设备路径（未挂载的卷没有 mountPath，靠 volumeName 兜底）。
    public func devicePath(forMountPath path: String) -> String? {
        let key = FinderPathNormalizer.normalize(path)
        return entries.first { FinderPathNormalizer.normalize($0.mountPath) == key }?.devicePath
    }

    /// 未挂载的卷：按卷名找（`/Volumes/<name>` 形式的推测挂载点）。
    public func entry(forUnmountedVolumeNamed name: String) -> Entry? {
        entries.first { $0.mountPath.isEmpty && $0.volumeName == name }
    }
}

// MARK: - 路径归一化

/// 统一去掉尾斜杠（Finder 传来的路径可能带或不带 `/`），保证字典命中。
public enum FinderPathNormalizer {
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        // 只做字符串级归一化：URL(fileURLWithPath:) 在扩展里可能触发
        // 一次文件系统查询（符号链接解析），badge 回调里要避免。
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

// MARK: - 命令

/// 扩展 → 主应用的挂载命令请求：扩展只写意图，不执行任何特权操作。
public struct MountCommand: Codable, Sendable, Equatable, Identifiable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// 挂载为读写
        case mount
        case unmount
        /// 卸载并还原为系统只读挂载
        case restoreReadOnly
        case eject
        /// ntfsfix -d 修复
        case reset

        public var title: String {
            switch self {
            case .mount:           return FinderStrings.actionMountRW
            case .unmount:         return FinderStrings.actionUnmount
            case .restoreReadOnly: return FinderStrings.actionRestoreReadOnly
            case .eject:           return FinderStrings.actionEject
            case .reset:           return FinderStrings.actionReset
            }
        }

        public var symbolName: String {
            switch self {
            case .mount:           return "lock.open.display"
            case .unmount:         return "eject"
            case .restoreReadOnly: return "arrow.uturn.backward.circle"
            case .eject:           return "eject.circle"
            case .reset:           return "wrench.and.screwdriver"
            }
        }
    }

    public var kind: Kind
    public var devicePath: String
    public var requestedAt: Date
    public var requestID: UUID

    public var id: UUID { requestID }

    public init(kind: Kind,
                devicePath: String,
                requestedAt: Date = Date(),
                requestID: UUID = UUID()) {
        self.kind = kind
        self.devicePath = devicePath
        self.requestedAt = requestedAt
        self.requestID = requestID
    }

    /// 是否已过期（超过 `FinderBridgeContainer.commandTimeout`）
    public var isExpired: Bool {
        Date().timeIntervalSince(requestedAt) > FinderBridgeContainer.commandTimeout
    }
}

public struct MountCommandResult: Codable, Sendable, Equatable, Identifiable {

    public enum Status: String, Codable, Sendable {
        /// 主应用已接手，正在执行（含授权对话框等待）
        case running
        case succeeded
        /// 失败，message 为原因
        case failed
        case timedOut
        /// 用户拒绝授权
        case cancelled
    }

    public var requestID: UUID
    public var status: Status
    public var message: String?
    public var finishedAt: Date

    public var id: UUID { requestID }

    public init(requestID: UUID, status: Status, message: String? = nil, finishedAt: Date = Date()) {
        self.requestID = requestID
        self.status = status
        self.message = message
        self.finishedAt = finishedAt
    }

    public var isTerminal: Bool {
        switch status {
        case .running:   return false
        case .succeeded, .failed, .timedOut, .cancelled: return true
        }
    }
}

// MARK: - 文案

/// 扩展 bundle 里没有主应用的 locales，用 `NSLocalizedString` + 中文兜底，缺 .lproj 时不会显示 key 原文。
public enum FinderStrings {
    private static func s(_ key: String, _ zh: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: zh, comment: "")
    }

    public static var stateReadWrite: String   { s("finder.state.readWrite", "读写") }
    public static var stateReadOnly: String    { s("finder.state.readOnly", "只读") }
    public static var stateUnmounted: String   { s("finder.state.unmounted", "未挂载") }
    public static var stateUnavailable: String { s("finder.state.unavailable", "不可用") }

    public static var actionMountRW: String {
        s("finder.action.mountRW", "挂载为读写")
    }
    public static var actionUnmount: String {
        s("finder.action.unmount", "卸载")
    }
    public static var actionRestoreReadOnly: String {
        s("finder.action.restoreReadOnly", "恢复只读")
    }
    public static var actionEject: String {
        s("finder.action.eject", "弹出")
    }
    public static var actionReset: String {
        s("finder.action.reset", "重置卷（ntfsfix）")
    }
    public static var actionRevealInApp: String {
        s("finder.action.revealInApp", "在 NTFSMount 中显示")
    }
    public static var actionOpenApp: String {
        s("finder.action.openApp", "打开 NTFSMount")
    }
    public static var actionProcessing: String {
        s("finder.action.processing", "正在处理…")
    }

    public static var toolbarName: String {
        s("finder.toolbar.name", "NTFSMount")
    }
    public static var toolbarToolTip: String {
        s("finder.toolbar.tooltip", "把选中的 NTFS 卷挂载为读写")
    }

    public static var badgeLabelReadWrite: String {
        s("finder.badge.readWrite", "读写")
    }
    public static var badgeLabelReadOnly: String {
        s("finder.badge.readOnly", "只读")
    }
    public static var badgeLabelUnmounted: String {
        s("finder.badge.unmounted", "未挂载")
    }

    public static var menuSectionTitle: String {
        s("finder.menu.section", "NTFS 读写")
    }

    /// 无可操作卷时的提示
    public static var noActionableVolume: String {
        s("finder.menu.empty", "没有可操作的 NTFS 卷")
    }
}