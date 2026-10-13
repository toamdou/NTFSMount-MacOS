import Foundation
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - 登录时自启

public enum LaunchAtLogin {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 系统需要用户到「登录项」里手动批准（macOS 13+ 的行为）。
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public enum Failure: LocalizedError {
        case registerFailed(String)
        case unregisterFailed(String)

        public var errorDescription: String? {
            switch self {
            case .registerFailed(let reason):   return reason
            case .unregisterFailed(let reason): return reason
            }
        }
    }

    public static func enable() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw Failure.registerFailed(error.localizedDescription)
        }
    }

    public static func disable() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw Failure.unregisterFailed(error.localizedDescription)
        }
    }
}

// MARK: - 防止系统休眠

/// 持有电源断言，阻止系统进入空闲休眠。
/// 只阻止空闲休眠，不阻止用户主动合盖或手动睡眠。
public final class SleepPreventer: @unchecked Sendable {

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    public init() {}

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// 幂等：重复调用无副作用。
    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return true }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NTFSMount 正在执行磁盘操作，暂时阻止系统休眠" as CFString,
            &id)

        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        active = true
        return true
    }

    /// 幂等：重复调用无副作用。
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        active = false
    }

    deinit {
        // deinit 是 nonisolated 的，这里访问的是自带锁保护的属性，
        // 且断言必须释放 —— 否则进程退出前系统一直不休眠。
        if active {
            IOPMAssertionRelease(assertionID)
        }
    }
}
