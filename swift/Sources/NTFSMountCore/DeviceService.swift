import Foundation
import Combine

@MainActor
public final class DeviceService: ObservableObject {

    @Published public private(set) var devices: [NTFSDevice] = []

    /// 用户主动卸载后仍保留在列表中的设备
    private var retainedUnmounted: [String: NTFSDevice] = [:]

    /// 用户手动标记为「保持只读」的设备（稳定 ID = volumeUUID ?? disk）
    private var manuallyReadOnly: Set<String> = []

    private let monitor = VolumeMonitor()
    private var cancellables = Set<AnyCancellable>()

    /// 挂载操作进行中，用于抑制事件触发的重复刷新
    private var isMutating = false
    /// 合并短时间内的多个事件为一次刷新
    private var pendingRefreshTask: Task<Void, Never>?

    public init() {
        startMonitoring()
    }

    deinit {
        // deinit 是 nonisolated 的，不能访问 MainActor 状态；VolumeMonitor 自身线程安全，
        // 直接调用其停止方法即可。
        monitor.stop()
    }

    // MARK: - 刷新

    public func refresh() {
        DiskInventory.invalidateCache()
        // 挂载表随扫描结果一并带出，无需再单独调一次 mountTable()
        let scan = DiskInventory.scanNTFSPartitions()
        let table = scan.mountTable

        var result: [NTFSDevice] = []
        result.reserveCapacity(scan.entries.count)

        for entry in scan.entries {
            let record = table.first { $0.devicePath == entry.devicePath }

            // 只读与否直接取枚举阶段算好的结果，避免两处规则分叉。
            let isFUSEMount = record?.isFUSEMount ?? entry.isFUSE
            let isReadOnly = entry.isReadOnly

            let stableId = entry.volumeUUID ?? entry.identifier

            var device = NTFSDevice(
                disk: entry.identifier,
                devicePath: entry.devicePath,
                volume: record?.mountPoint ?? "",
                volumeName: entry.volumeName,
                volumeUuid: entry.volumeUUID,
                isReadOnly: isReadOnly,
                options: record?.options ?? "ro",
                isMounted: isFUSEMount && !isReadOnly,
                isUnmounted: false,
                capacity: nil
            )

            // 容量：已挂载取 statfs 结果，未挂载取 IOMedia 的 Size
            if let cap = record?.capacity {
                device.capacity = DeviceCapacity(total: cap.total, used: cap.used, available: cap.available)
            } else {
                device.capacity = DiskInventory.deviceCapacity(path: entry.devicePath)
                    .map { DeviceCapacity(total: $0.total, used: $0.used, available: $0.available) }
            }

            // 手动只读标记覆盖自动判定
            if manuallyReadOnly.contains(stableId) {
                device = NTFSDevice(
                    disk: device.disk,
                    devicePath: device.devicePath,
                    volume: device.volume,
                    volumeName: device.volumeName,
                    volumeUuid: device.volumeUuid,
                    isReadOnly: true,
                    options: "ro",
                    isMounted: false,
                    isUnmounted: device.volume.isEmpty,
                    capacity: device.capacity
                )
            }

            result.append(device)
        }

        for (key, device) in retainedUnmounted where !result.contains(where: { $0.disk == key }) {
            result.append(device)
        }

        result.sort { lhs, rhs in
            if lhs.isUnmounted != rhs.isUnmounted { return lhs.isUnmounted }
            return lhs.volumeName.localizedStandardCompare(rhs.volumeName) == .orderedAscending
        }

        devices = result
        scheduleProbeRetryIfNeeded(scan.hasPendingProbe)
    }

    // MARK: - DiskArbitration 探测重试

    /// 刚插入的 GPT 盘文件系统尚未探测完时先跳过并延迟重扫；
    /// 必须有次数上限，否则未格式化的空闲分区会导致无限轮询。
    private static let probeRetryLimit = 4
    private static let probeRetryDelay = Duration.milliseconds(700)

    private var probeRetryCount = 0
    private var probeRetryTask: Task<Void, Never>?

    private func scheduleProbeRetryIfNeeded(_ pending: Bool) {
        guard pending else {
            // 探测已全部收敛，计数归零，为下一次插盘做准备
            probeRetryCount = 0
            probeRetryTask?.cancel()
            probeRetryTask = nil
            return
        }
        guard probeRetryTask == nil, probeRetryCount < Self.probeRetryLimit else { return }

        probeRetryCount += 1
        probeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.probeRetryDelay)
            guard let self else { return }
            self.probeRetryTask = nil
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    // MARK: - 事件驱动

    private func startMonitoring() {
        // 回调被标了 @Sendable，会从 IOKit 通知线程 / 主队列两条路径投递，
        // 而 isMutating / pendingRefreshTask 是 MainActor 状态，必须显式 hop 回主线程。
        monitor.start { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch change {
                case .refresh, .detached:
                    // 挂载操作本身也会触发事件，用标志位抑制多余刷新
                    guard !self.isMutating else { return }
                    // 事件到达后留极短延迟，等待内核完成挂载表更新
                    // （mount/unmount 表项的可见性略滞后于 DA 通知）
                    self.pendingRefreshTask?.cancel()
                    self.pendingRefreshTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        self.refresh()
                    }
                }
            }
        }
    }

    // MARK: - 操作（统一在此处维护状态一致性）

    public func withMutation<T>(_ body: @escaping () async throws -> T) async rethrows -> T {
        isMutating = true
        defer {
            isMutating = false
            refresh()
        }
        return try await body()
    }

    public func setManuallyReadOnly(_ readOnly: Bool, for device: NTFSDevice) {
        let id = device.stableId
        if readOnly {
            manuallyReadOnly.insert(id)
        } else {
            manuallyReadOnly.remove(id)
        }
        refresh()
    }

    public func isManuallyReadOnly(_ device: NTFSDevice) -> Bool {
        manuallyReadOnly.contains(device.stableId)
    }

    public func retainAfterUnmount(_ device: NTFSDevice) {
        var d = device
        d.isUnmounted = true
        d.isMounted = false
        d.isReadOnly = true
        retainedUnmounted[device.disk] = d
    }

    public func dropRetained(_ device: NTFSDevice) {
        retainedUnmounted.removeValue(forKey: device.disk)
    }

    public var manuallyReadOnlyIDs: Set<String> {
        get { manuallyReadOnly }
        set { manuallyReadOnly = newValue }
    }

    // MARK: - 查询

    public func device(withDisk disk: String) -> NTFSDevice? {
        devices.first { $0.disk == disk }
    }

    public var readWriteCount: Int {
        devices.filter { $0.isMounted && !$0.isReadOnly }.count
    }

    public var readOnlyCount: Int {
        devices.filter { !$0.isMounted && !$0.isUnmounted }.count
    }
}
