import Foundation
import Darwin

// MARK: - 文件锁

/// 基于 `flock(2)` 的跨进程互斥锁（不用 `NSFileCoordinator`：需 run loop 驱动、跨系统版本行为不一致、会给目录打 `._` 标记）。
public final class FileLock {
    private let fd: Int32

    public init?(url: URL) {
        let path = url.path
        let handle = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard handle >= 0 else { return nil }
        fd = handle
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// 阻塞获取独占锁；`timeout` 为 nil 时无限等待，超时返回 false。
    @discardableResult
    public func lockExclusive(timeout: TimeInterval? = 5) -> Bool {
        guard let timeout else {
            return flock(fd, LOCK_EX) == 0
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { return false }
            if Date() >= deadline { return false }
            // 10ms 退避：命令执行间隔通常是秒级，10ms 足够灵敏又不至于空转
            usleep(10_000)
        }
    }

    public func unlock() {
        _ = flock(fd, LOCK_UN)
    }

    public func withLock<T>(timeout: TimeInterval? = 5, _ body: () throws -> T) rethrows -> T? {
        guard lockExclusive(timeout: timeout) else { return nil }
        defer { unlock() }
        return try body()
    }
}

// MARK: - 原子写

enum AtomicFile {
    /// 原子写：临时文件 → fsync → rename，读者不会读到写了一半的 JSON。
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        // O_EXCL 保证临时名不冲突；即使冲突（概率可忽略）也不影响正确性
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: "NTFSMount.FinderBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件 \(tmp.path)"])
        }
        defer { close(fd); try? FileManager.default.removeItem(at: tmp) }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: "NTFSMount.FinderBridge", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "写入失败: \(String(cString: strerror(errno)))"])
                }
                offset += n
            }
        }
        _ = fsync(fd)
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(domain: "NTFSMount.FinderBridge", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "替换目标文件失败: \(String(cString: strerror(errno)))"])
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL,
                                        encoder: JSONEncoder = JSONEncoder()) throws {
        try write(try encoder.encode(value), to: url)
    }
}

// MARK: - 快照存储

public enum SnapshotStore {

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        // 固定格式：不排序也可以，但固定下来便于 diff 与排障
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// 主应用侧：写入完整快照（非增量）。
    public static func write(_ snapshot: VolumeSnapshot) throws {
        guard FinderBridgeContainer.ensureDirectories() else {
            throw NSError(domain: "NTFSMount.FinderBridge", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建共享目录"])
        }
        try AtomicFile.writeJSON(snapshot,
                                 to: FinderBridgeContainer.snapshotURL,
                                 encoder: makeEncoder())
    }

    /// 读取快照；失败一律返回 nil，绝不抛错（badge 回调里不能崩）。
    public static func read() -> VolumeSnapshot? {
        guard let data = try? Data(contentsOf: FinderBridgeContainer.snapshotURL) else {
            return nil
        }
        return try? makeDecoder().decode(VolumeSnapshot.self, from: data)
    }

    /// 删除快照（主应用退出时调用，让扩展不再显示过期徽标）
    public static func clear() {
        try? FileManager.default.removeItem(at: FinderBridgeContainer.snapshotURL)
    }
}

// MARK: - 命令队列

/// 扩展 → 主应用的单槽命令队列：挂载/卸载本身排他，单槽 + flock 让后来的命令覆盖前面的。
public enum CommandQueue {

    // MARK: 扩展侧（生产者）

    /// 写入命令并广播通知；必须极快返回（扩展菜单回调里同步调用）。
    @discardableResult
    public static func post(_ command: MountCommand) -> Bool {
        guard FinderBridgeContainer.ensureDirectories() else { return false }

        // 先清掉过期命令，避免上一次崩溃残留的脏命令被误执行
        removeIfExpired()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(command) else { return false }

        guard let lock = FileLock(url: FinderBridgeContainer.commandLockURL) else { return false }
        guard lock.withLock(timeout: 0.5, { try? AtomicFile.write(data, to: FinderBridgeContainer.pendingCommandURL) }) != nil else {
            return false
        }

        DarwinNotifier.post(FinderBridgeNotification.commandPosted)
        return true
    }

    // MARK: 主应用侧（消费者）

    /// 取走待处理命令并删除；锁内「读 + 删」，并发不会拿到同一条。
    public static func take() -> MountCommand? {
        guard FinderBridgeContainer.ensureDirectories() else { return nil }
        guard let lock = FileLock(url: FinderBridgeContainer.commandLockURL) else { return nil }

        return lock.withLock(timeout: 2) { () -> MountCommand? in
            let url = FinderBridgeContainer.pendingCommandURL
            guard let data = try? Data(contentsOf: url) else { return nil }
            // 读到了就必须删掉：即使内容损坏也不能让主应用反复卡在同一条脏命令上
            try? FileManager.default.removeItem(at: url)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let command = try? decoder.decode(MountCommand.self, from: data) else { return nil }
            guard !command.isExpired else { return nil }
            return command
        } ?? nil
    }

    /// 删除当前待处理命令（命令执行完毕后调用，确保不会重复执行）
    public static func clearPending() {
        guard let lock = FileLock(url: FinderBridgeContainer.commandLockURL) else { return }
        lock.withLock(timeout: 1) {
            try? FileManager.default.removeItem(at: FinderBridgeContainer.pendingCommandURL)
        }
    }

    /// 是否有待处理命令（用于主应用决定是否需要拉起自己）
    public static func hasPending() -> Bool {
        FileManager.default.fileExists(atPath: FinderBridgeContainer.pendingCommandURL.path)
    }

    /// 清理过期命令文件（扩展与主应用都可调用）
    public static func removeIfExpired(now: Date = Date()) {
        guard let data = try? Data(contentsOf: FinderBridgeContainer.pendingCommandURL),
              let command = decodeRelaxed(data),
              now.timeIntervalSince(command.requestedAt) > FinderBridgeContainer.commandTimeout
        else { return }
        clearPending()
    }

    /// 解码命令，容忍日期格式差异（.iso8601 / 默认 Double）
    private static func decodeRelaxed(_ data: Data) -> MountCommand? {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let c = try? iso.decode(MountCommand.self, from: data) { return c }
        return try? JSONDecoder().decode(MountCommand.self, from: data)
    }
}

// MARK: - 结果存储

public enum ResultStore {

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 主应用侧：写结果并广播。
    public static func write(_ result: MountCommandResult) {
        guard FinderBridgeContainer.ensureDirectories() else { return }
        guard let data = try? makeEncoder().encode(result) else { return }
        let url = FinderBridgeContainer.resultDirectory
            .appendingPathComponent("\(result.requestID.uuidString).json", isDirectory: false)
        guard let lock = FileLock(url: FinderBridgeContainer.resultLockURL),
              lock.withLock(timeout: 2, { try? AtomicFile.write(data, to: url) }) != nil
        else { return }

        purgeOld()
        DarwinNotifier.post(FinderBridgeNotification.commandFinished)
    }

    /// 扩展侧：读指定请求的结果。
    public static func read(requestID: UUID) -> MountCommandResult? {
        let url = FinderBridgeContainer.resultDirectory
            .appendingPathComponent("\(requestID.uuidString).json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(MountCommandResult.self, from: data)
    }

    /// 扩展侧：取最新结果（用于「处理中」判定）。
    public static func latest() -> MountCommandResult? {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: FinderBridgeContainer.resultDirectory.path)
        else { return nil }

        var newest: MountCommandResult?
        for name in names where name.hasSuffix(".json") && name != "result.lock" {
            let stem = String(name.dropLast(5))
            guard let uuid = UUID(uuidString: stem) else { continue }
            guard let result = read(requestID: uuid) else { continue }
            if newest == nil || result.finishedAt > newest!.finishedAt {
                newest = result
            }
        }
        return newest
    }

    public static func purgeOld(now: Date = Date()) {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: FinderBridgeContainer.resultDirectory.path)
        else { return }

        for name in names where name.hasSuffix(".json") && name != "result.lock" {
            let url = FinderBridgeContainer.resultDirectory
                .appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > FinderBridgeContainer.resultRetention {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - Darwin 通知

/// Darwin 通知封装：无负载，接收方自行读文件；App 与 appex 间无需 XPC entitlement。
public enum DarwinNotifier {

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }

    /// 持续监听一个通知名；handler 在任意线程触发，实现方自行保证线程安全。
    public static func observe(_ name: String,
                               queue: DispatchQueue = .main,
                               handler: @escaping @Sendable () -> Void) -> ObservationToken {
        ObservationToken(name: name, queue: queue, handler: handler)
    }
}

/// 观察者句柄。持有即监听，释放即停止。
public final class ObservationToken: @unchecked Sendable {
    private let name: String
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private var isObserving = true

    fileprivate init(name: String, queue: DispatchQueue, handler: @Sendable @escaping () -> Void) {
        self.name = name
        self.queue = queue
        self.handler = handler

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            ctx,
            { _, observer, cfName, _, _ in
                guard let observer else { return }
                let token = Unmanaged<ObservationToken>.fromOpaque(observer).takeUnretainedValue()
                token.fire()
            },
            name as CFString,
            nil,
            .deliverImmediately)
    }

    fileprivate func fire() {
        // Darwin 回调可能落在任意线程。统一 async 到目标队列，
        // 让扩展侧的处理函数只需假设「在主队列上执行」。
        queue.async(execute: handler)
    }

    public func cancel() {
        guard isObserving else { return }
        isObserving = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil)
    }

    deinit { cancel() }
}