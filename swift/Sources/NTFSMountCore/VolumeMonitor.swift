import Foundation
import IOKit
import IOKit.storage
import AppKit

/// 会被投递到非主队列与 IOKit 的 C 回调线程，必须 Sendable（否则 Swift 6 拒绝跨线程捕获）。
public enum DeviceChange: Sendable {
    case refresh(reason: String)
    case detached(identifier: String)
}

public final class VolumeMonitor: @unchecked Sendable {

    private let callbackQueue: DispatchQueue
    /// 调用方（AppState）必须自行保证内部状态的主线程隔离。
    private var handler: (@Sendable (DeviceChange) -> Void)?

    // IOKit 通知端口需绑定 run loop，因此使用独立线程。
    private var ioThread: Thread?
    private let ioReady = DispatchSemaphore(value: 0)
    private var notifyPort: OpaquePointer?
    private var armedIterators: [io_iterator_t] = []

    private let stateLock = NSLock()
    private var running = false

    /// 事件去重：极短时间窗内的重复事件合并为一次
    private var lastRefresh: Date = .distantPast
    private let dedupWindow: TimeInterval = 0.25

    private var workspaceObservers: [NSObjectProtocol] = []

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    deinit { stop() }

    // MARK: - 生命周期

    public func start(onChange: @escaping @Sendable (DeviceChange) -> Void) {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        handler = onChange
        stateLock.unlock()

        startIOKitMonitoring()
        startWorkspaceObservers()
    }

    public func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        let port = notifyPort
        notifyPort = nil
        let thread = ioThread
        ioThread = nil
        stateLock.unlock()

        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        if let port {
            for iter in armedIterators { IOObjectRelease(iter) }
            armedIterators.removeAll()
            IONotificationPortDestroy(port)
        }
        thread?.cancel()
    }

    // MARK: - IOKit 通知端口

    private func startIOKitMonitoring() {
        let t = Thread { [weak self] in self?.ioRunLoopBody() }
        t.name = "ntfsmount.io-monitor"
        t.qualityOfService = .utility
        ioThread = t
        t.start()
        _ = ioReady.wait(timeout: .now() + 2)
    }

    private func ioRunLoopBody() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            ioReady.signal()
            return
        }
        notifyPort = port

        let source = IONotificationPortGetRunLoopSource(port).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // 两层都要监听：只监听驱动层会漏掉「设备早已接好、分区稍后才发布」；
        // 且 BSD Name 只长在 IOMedia 上，驱动层 kIOTerminated 里拿不到标识。
        //
        // arm 必须写成嵌套函数：IOServiceAddMatchingNotification 的回调参数是
        // @convention(c)，只有直接引用函数才允许隐式转换，经变量传递会编译失败。
        func arm(_ className: String) {
            var matched: io_iterator_t = 0
            IOServiceAddMatchingNotification(
                port,
                kIOMatchedNotification,
                IOServiceMatching(className),
                diskMatchedCallback,
                ctx,
                &matched)
            armedIterators.append(matched)

            var terminated: io_iterator_t = 0
            IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                IOServiceMatching(className),
                diskTerminatedCallback,
                ctx,
                &terminated)
            armedIterators.append(terminated)
        }

        arm(kIOBlockStorageDriverClass)
        arm(kIOMediaClass)

        ioReady.signal()

        while true {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
            if Thread.current.isCancelled || !isRunning { break }
        }

        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    // MARK: - NSWorkspace 卷事件

    private func startWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let mounted = center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitRefresh(reason: "ws:mounted")
        }

        let unmounted = center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitRefresh(reason: "ws:unmounted")
        }

        // 推出（eject）不单独监听：IOKit kIOTerminated 通知已覆盖，
        // 且 NSWorkspace.didEjectNotification 在现代 SDK 中已被移除。

        workspaceObservers = [mounted, unmounted]
    }

    // MARK: - 事件投递

    fileprivate func notifyRefresh(reason: String) { emitRefresh(reason: reason) }

    fileprivate func notifyDetached(_ id: String) { emitDetached(id) }

    private func emitRefresh(reason: String) {
        stateLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) > dedupWindow, running else {
            stateLock.unlock()
            return
        }
        lastRefresh = now
        let h = handler
        stateLock.unlock()

        guard let h else { return }
        let change = DeviceChange.refresh(reason: reason)
        if Thread.isMainThread { h(change) } else { callbackQueue.async { h(change) } }
    }

    private func emitDetached(_ identifier: String) {
        stateLock.lock()
        let h = running ? handler : nil
        stateLock.unlock()

        guard let h else { return }
        let change = DeviceChange.detached(identifier: identifier)
        if Thread.isMainThread { h(change) } else { callbackQueue.async { h(change) } }
    }
}


// MARK: - C 回调

/// IOKit 回调必须是 C 函数指针（不能捕获上下文），
/// 通过 refCon 取回 monitor 实例。
private func diskMatchedCallback(_ refCon: UnsafeMutableRawPointer?,
                                 _ iterator: io_iterator_t) {
    // 排空迭代器即完成「重新 arm」通知，必须读完
    var obj = IOIteratorNext(iterator)
    while obj != 0 {
        IOObjectRelease(obj)
        obj = IOIteratorNext(iterator)
    }
    guard let refCon else { return }
    let monitor = Unmanaged<VolumeMonitor>.fromOpaque(refCon).takeUnretainedValue()
    monitor.notifyRefresh(reason: "io:matched")
}

private func diskTerminatedCallback(_ refCon: UnsafeMutableRawPointer?,
                                    _ iterator: io_iterator_t) {
    var names: [String] = []
    var obj = IOIteratorNext(iterator)
    while obj != 0 {
        if let name = DiskInventory.bsdName(forIOService: obj) { names.append(name) }
        IOObjectRelease(obj)
        obj = IOIteratorNext(iterator)
    }
    guard let refCon else { return }
    let monitor = Unmanaged<VolumeMonitor>.fromOpaque(refCon).takeUnretainedValue()
    for name in names { monitor.notifyDetached(name) }
    monitor.notifyRefresh(reason: "io:terminated")
}
