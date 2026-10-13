import Foundation
import NTFSMountCore

/// 主应用侧的 Finder 集成桥；在 App 启动时构造并 `start()`。
@MainActor
public final class FinderSyncBridge {

    public static let shared = FinderSyncBridge()

    /// 卷状态变化时的回调（供 UI 顺带刷新自己的列表）
    private var onStateChange: (@MainActor ([DiskEntry]) -> Void)?

    private let monitor: VolumeMonitor
    private var commandToken: ObservationToken?
    private var pollTimer: Timer?
    private var isRunning = false

    /// 执行命令时使用的上下文（当前正在处理的命令，用于抑制重复刷新）
    private var busyDevicePath: String?

    public init(monitor: VolumeMonitor = VolumeMonitor()) {
        self.monitor = monitor
    }

    deinit {
        // deinit 是 nonisolated；VolumeMonitor / ObservationToken 自身线程安全，
        // 直接调用其停止方法即可，不触碰 @MainActor 状态。
        monitor.stop()
    }

    // MARK: - 生命周期

    /// 启动观察。重复调用无副作用。
    public func start(onStateChange: (@MainActor ([DiskEntry]) -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        self.onStateChange = onStateChange

        guard FinderBridgeContainer.ensureDirectories() else {
            // 共享目录不可写（沙盒配置错误 / 权限问题）。
            // Finder 集成静默降级，主应用其余功能不受影响。
            NSLog("[NTFSMount] Finder 集成未启用：无法创建共享目录 %@",
                  FinderBridgeContainer.rootDirectory.path)
            return
        }

        // 回调来自 IOKit 通知线程（非主线程），而 scheduleSnapshotWrite 隔离在 MainActor，
        // 因此必须显式 hop 回去。
        monitor.start { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch change {
                case .refresh:
                    self.scheduleSnapshotWrite()
                case .detached:
                    self.scheduleSnapshotWrite()
                }
            }
        }

        commandToken = DarwinNotifier.observe(FinderBridgeNotification.commandPosted) { [weak self] in
            // Darwin 回调已 async 到主队列，这里可以直接用 MainActor
            MainActor.assumeIsolated {
                self?.drainCommand()
            }
        }

        // 兜底轮询：Darwin 通知在极少数情况下会丢（例如主应用刚启动时
        // 扩展已经发了通知）。5 秒一次，成本可忽略。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drainCommand()
                self?.writeSnapshotIfChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // 启动时立即写一次（让用户在启动主应用后马上在 Finder 看到徽标）
        writeSnapshot()
    }

    /// 停止观察。停止后扩展会保留最后一次快照。
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        commandToken?.cancel()
        commandToken = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 主应用即将退出：清空快照并通知扩展；应在 `willTerminateNotification` 里调用。
    public func prepareForTermination() {
        CommandQueue.removeIfExpired()
        DarwinNotifier.post(FinderBridgeNotification.appWillTerminate)
        SnapshotStore.clear()
    }

    // MARK: - 快照写入

    private var snapshotWriteTask: Task<Void, Never>?

    /// 合并短时间内的多次事件为一次写盘（挂载操作会触发一串事件）
    private func scheduleSnapshotWrite() {
        snapshotWriteTask?.cancel()
        snapshotWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot()
        }
    }

    /// 从 Core 读当前设备状态并写快照（只读状态，不执行特权操作）。
    @discardableResult
    public func writeSnapshot() -> VolumeSnapshot? {
        DiskInventory.invalidateCache()
        let devices = DiskInventory.enumerateNTFSPartitions()
        let snapshot = Self.makeSnapshot(from: devices)
        do {
            try SnapshotStore.write(snapshot)
            DarwinNotifier.post(FinderBridgeNotification.stateChanged)
        } catch {
            NSLog("[NTFSMount] 写入 Finder 快照失败: %@", error.localizedDescription)
            return nil
        }
        onStateChange?(devices)
        return snapshot
    }

    /// 仅当内容变化时才写盘 + 发通知，避免无谓写入与扩展侧全量重贴徽标。
    private var lastSnapshotDigest: Int?

    private func writeSnapshotIfChanged() {
        DiskInventory.invalidateCache()
        let devices = DiskInventory.enumerateNTFSPartitions()
        let snapshot = Self.makeSnapshot(from: devices)
        let digest = Self.digest(of: snapshot)
        guard digest != lastSnapshotDigest else { return }
        lastSnapshotDigest = digest
        do {
            try SnapshotStore.write(snapshot)
            DarwinNotifier.post(FinderBridgeNotification.stateChanged)
        } catch {
            NSLog("[NTFSMount] 写入 Finder 快照失败: %@", error.localizedDescription)
            return
        }
        onStateChange?(devices)
    }

    /// Core 的 `DiskEntry` → 扩展可读的 `VolumeSnapshot.Entry`；状态映射与 `DeviceService.refresh()` 一致：FUSE/ntfs-3g 挂载且非 ro = readWrite，系统 ro 挂载 = readOnly，无挂载点 = unmounted。
    public static func makeSnapshot(from entries: [DiskEntry]) -> VolumeSnapshot {
        let table = DiskInventory.mountTable()
        var snapshotEntries: [VolumeSnapshot.Entry] = []
        snapshotEntries.reserveCapacity(entries.count)

        for entry in entries where entry.isNTFS {
            let record = table.first { $0.devicePath == entry.devicePath }
            let fsType = record?.fsType.lowercased() ?? ""
            let isFUSEMount = fsType.contains("fuse") || fsType.contains("ntfs-3g")
            let isReadOnly = record?.options.contains("ro") ?? true
            let mountPoint = record?.mountPoint ?? ""

            let state: VolumeSnapshot.State
            if !entry.isInternal, mountPoint.isEmpty {
                state = .unmounted
            } else if isFUSEMount && !isReadOnly {
                state = .readWrite
            } else if !mountPoint.isEmpty {
                state = .readOnly
            } else {
                state = .unmounted
            }

            // 未挂载时 statfs 拿不到容量，退回 IOKit 的设备容量
            var total = record?.totalBytes ?? 0
            var free = record?.freeBytes ?? 0
            if total == 0, let cap = DiskInventory.deviceCapacity(path: entry.devicePath) {
                total = cap.total
                free = cap.available
            }

            snapshotEntries.append(VolumeSnapshot.Entry(
                mountPath: FinderPathNormalizer.normalize(mountPoint),
                devicePath: entry.devicePath,
                volumeName: entry.volumeName,
                volumeUuid: entry.volumeUUID,
                state: state,
                totalBytes: total,
                freeBytes: free
            ))
        }

        return VolumeSnapshot(entries: snapshotEntries)
    }

    /// 快照内容指纹（用于跳过无变化的写盘）
    private static func digest(of snapshot: VolumeSnapshot) -> Int {
        var hasher = Hasher()
        for e in snapshot.entries {
            hasher.combine(e.mountPath)
            hasher.combine(e.devicePath)
            hasher.combine(e.state)
            hasher.combine(e.totalBytes)
            hasher.combine(e.freeBytes)
        }
        return hasher.finalize()
    }

    // MARK: - 命令消费

    /// 取一条命令并执行；授权对话框是 async（等 Touch ID），故在 Task 里跑。
    private func drainCommand() {
        guard busyDevicePath == nil else { return }

        CommandQueue.removeIfExpired()
        guard let command = CommandQueue.take() else { return }

        busyDevicePath = command.devicePath
        ResultStore.write(MountCommandResult(requestID: command.requestID, status: .running))

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(command)
            self.busyDevicePath = nil
            // 执行完立刻同步快照，让扩展的徽标尽快更新
            self.writeSnapshot()
            CommandQueue.clearPending()
        }
    }

    /// 执行单条命令；提权全部经 `MountEngine` → `PrivilegedExecutor`。
    private func execute(_ command: MountCommand) async {
        let engine = MountEngine.shared
        let result: MountCommandResult

        do {
            guard let device = Self.device(for: command.devicePath) else {
                result = MountCommandResult(requestID: command.requestID,
                                             status: .failed,
                                             message: "找不到设备 \(command.devicePath)")
                ResultStore.write(result)
                return
            }

            switch command.kind {
            case .mount:
                try await engine.mountReadWrite(device: device)
            case .unmount:
                try await engine.unmount(device: device)
            case .restoreReadOnly:
                try await engine.restoreToReadOnly(device: device)
            case .eject:
                try await engine.eject(device: device)
            case .reset:
                try await engine.reset(device: device)
            }
            result = MountCommandResult(requestID: command.requestID, status: .succeeded)
        } catch let error as PrivilegeError {
            // 用户点了「取消」——这不是错误，不该弹错误提示
            let cancelled: Bool
            if case .cancelled = error { cancelled = true } else { cancelled = false }
            result = MountCommandResult(requestID: command.requestID,
                                         status: cancelled ? .cancelled : .failed,
                                         message: cancelled ? nil : error.errorDescription)
        } catch {
            result = MountCommandResult(requestID: command.requestID,
                                         status: .failed,
                                         message: error.localizedDescription)
        }

        ResultStore.write(result)
    }

    /// 按设备路径还原 `NTFSDevice`；devicePath 可能因 disk 号漂移而失效，故先用 volumeUuid 交叉匹配。
    private static func device(for devicePath: String) -> NTFSDevice? {
        DiskInventory.invalidateCache()
        let entries = DiskInventory.enumerateNTFSPartitions()
        let table = DiskInventory.mountTable()

        if let entry = entries.first(where: { $0.devicePath == devicePath }) {
            return makeDevice(from: entry, table: table)
        }

        // 路径已变（disk 号漂移）：若快照里记录了 volumeUuid 可交叉验证
        let snapshot = SnapshotStore.read()
        if let uuid = snapshot?.entries.first(where: { $0.devicePath == devicePath })?.volumeUuid,
           let entry = entries.first(where: { $0.volumeUUID == uuid }) {
            return makeDevice(from: entry, table: table)
        }

        return nil
    }

    private static func makeDevice(from entry: DiskEntry,
                                   table: [MountRecord]) -> NTFSDevice {
        let record = table.first { $0.devicePath == entry.devicePath }
        let fsType = record?.fsType.lowercased() ?? ""
        let isFUSEMount = fsType.contains("fuse") || fsType.contains("ntfs-3g")
        let isReadOnly = record?.options.contains("ro") ?? true
        let mountPoint = record?.mountPoint ?? ""

        var capacity: DeviceCapacity?
        if let cap = record?.capacity {
            capacity = DeviceCapacity(total: cap.total, used: cap.used, available: cap.available)
        } else if let cap = DiskInventory.deviceCapacity(path: entry.devicePath) {
            capacity = DeviceCapacity(total: cap.total, used: cap.used, available: cap.available)
        }

        return NTFSDevice(
            disk: entry.identifier,
            devicePath: entry.devicePath,
            volume: mountPoint,
            volumeName: entry.volumeName,
            volumeUuid: entry.volumeUUID,
            isReadOnly: isReadOnly,
            options: record?.options ?? "ro",
            isMounted: isFUSEMount && !isReadOnly,
            isUnmounted: mountPoint.isEmpty,
            capacity: capacity
        )
    }
}