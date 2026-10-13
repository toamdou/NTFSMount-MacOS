import SwiftUI
import Combine
import NTFSMountCore

@MainActor
public final class AppState: ObservableObject {

    /// 进程级单例。托盘在 AppDelegate 中安装，那个时点拿不到 App 的 `@StateObject`。
    public static let shared = AppState()

    @Published public private(set) var dependencies = DependencyStatus()
    @Published public private(set) var isCheckingDependencies = false

    @Published public private(set) var devices: [NTFSDevice] = []

    @Published public var selectedTab: AppTab = .dependencies

    @Published public private(set) var statusText: String = ""
    @Published public private(set) var statusKind: StatusKind = .checking

    @Published public private(set) var busyDeviceIDs: Set<String> = []
    @Published public private(set) var busyDeviceMessages: [String: String] = [:]

    /// 每台设备最近一次操作的失败原因，键是 `device.disk`；发起新操作或成功时清空。
    @Published public private(set) var deviceErrors: [String: String] = [:]

    /// 语言版本号。`Localization` 不是 ObservableObject，切换语言后靠自增此值配合 `.id(token)` 强制重建视图树。
    @Published public private(set) var localeToken = 0

    // 登录时自启：以系统状态为准，不以设置文件为准 ——
    // 用户可能在「系统设置 → 登录项」里直接关掉，那才是事实。
    @Published public private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @Published public private(set) var launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval

    /// 钥匙串里是否已保存管理员密码。以真实状态为准，不以设置文件里的开关为准。
    @Published public private(set) var savedPasswordExists = KeychainStore.shared.hasPassword

    /// 密码保存/删除的结果提示，供设置页展示一次；nil 表示当前没有待展示的消息。
    @Published public var passwordNotice: PasswordNotice?

    public struct PasswordNotice: Equatable {
        public enum Kind { case success, failure }
        public let kind: Kind
        public let text: String
    }

    public let settings: SettingsStore
    public let logStore: LogStore
    private let deviceService: DeviceService
    private let sleepPreventer = SleepPreventer()
    private var cancellables = Set<AnyCancellable>()
    private var appliedLanguage: AppLanguage = .system

    public enum StatusKind {
        case checking, ready, warning, error

        var color: Color {
            switch self {
            case .checking: return .secondary
            case .ready:    return Color(nsColor: .systemGreen)
            case .warning:  return Color(nsColor: .systemOrange)
            case .error:    return Color(nsColor: .systemRed)
            }
        }

        var symbolName: String {
            switch self {
            case .checking: return "clock"
            case .ready:    return "checkmark.circle.fill"
            case .warning:  return "exclamationmark.triangle.fill"
            case .error:    return "xmark.octagon.fill"
            }
        }
    }

    /// 侧边栏显示的页面。设置不在此列 —— 它归属应用菜单与 ⌘,（macOS 惯例位置）。
    public static let navigationTabs: [AppTab] = AppTab.allCases

    /// - Note: 默认值用 optional —— Swift 6 中默认参数表达式不属于任何 actor 隔离上下文，而 `LogStore` 是 `@MainActor` 的。
    public init(settings: SettingsStore? = nil, logStore: LogStore? = nil) {
        let settings = settings ?? SettingsStore()
        let logStore = logStore ?? LogStore()
        self.settings = settings
        self.logStore = logStore
        self.deviceService = DeviceService()
        self.logStore.isEnabled = settings.settings.enableLogs

        selectedTab = settings.settings.startupTab

        deviceService.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                self.devices = list
                self.updateStatus()
                self.applyAutoMount(to: list)
            }
            .store(in: &cancellables)

        settings.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self else { return }
                self.logStore.isEnabled = s.enableLogs
                self.deviceService.manuallyReadOnlyIDs = Set(s.manuallyReadOnlyDevices)

                // 提权偏好：核心层每次提权都会读它。
                PrivilegedExecutor.shared.prefersSavedPassword = s.savePassword
                // 挂载参数：核心层每次组装 argv 都会读它。
                MountContract.ioBlockSize = s.ioBlockSize

                // 语言变化：文案表已由 SettingsStore 重载，这里只负责
                // 通知 SwiftUI 重建视图树（否则界面停留在旧语言）。
                if s.language != self.appliedLanguage {
                    self.appliedLanguage = s.language
                    self.localeToken &+= 1
                }
            }
            .store(in: &cancellables)

        // 保存的密码被判失效并自动清除 —— 由核心层在提权失败后发出。
        NotificationCenter.default
            .publisher(for: .ntfsmountSavedPasswordInvalidated)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.savedPasswordExists = false
                self.passwordNotice = PasswordNotice(
                    kind: .failure,
                    text: Localization.shared.t("settings.passwordInvalidated"))
            }
            .store(in: &cancellables)

        appliedLanguage = settings.language
        deviceService.manuallyReadOnlyIDs = Set(settings.settings.manuallyReadOnlyDevices)
        PrivilegedExecutor.shared.prefersSavedPassword = settings.settings.savePassword
        MountContract.ioBlockSize = settings.settings.ioBlockSize
    }

    // MARK: - 启动

    private var didBootstrap = false

    /// 首次启动检测 + 设备列表。幂等：多处会调用它，但依赖检测是启动项而非每次刷新项。
    public func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        checkDependencies()
        deviceService.refresh()
        startDependencyPolling()
    }

    /// 窗口重新打开时刷新设备（不重跑依赖检测）。
    public func refreshAll() {
        deviceService.refresh()
    }

    // MARK: - 依赖

    public func checkDependencies() {
        isCheckingDependencies = true
        statusKind = .checking
        statusText = Localization.shared.t("status.checking")

        // 检测是纯文件系统调用，放到后台避免阻塞首帧
        Task.detached(priority: .userInitiated) {
            let status = DependencyDetector().detect()
            await MainActor.run {
                self.dependencies = status
                self.isCheckingDependencies = false
                self.updateStatus()
                self.logStore.add(
                    status.coreInstalled
                        ? Localization.shared.t("dependencies.allInstalled")
                        : Localization.shared.t("dependencies.missingDepsDetected"),
                    type: status.coreInstalled ? .success : .warning)
            }
        }
    }

    public var dependencyEntries: [DependencyEntry] {
        InstallGuideBuilder.entries(for: dependencies)
    }

    public var preferredMethod: InstallMethod? {
        if dependencies.macPorts.isPresent && !dependencies.homebrew.isPresent { return .macPorts }
        if dependencies.homebrew.isPresent { return .homebrew }
        return nil
    }

    /// DependencyStatus 未实现 Equatable，用签名做变化检测。
    public var dependencySignature: String { Self.signature(of: dependencies) }

    static func signature(of d: DependencyStatus) -> String {
        [d.macOS, d.commandLineTools, d.macFUSE, d.ntfs3g,
         d.homebrew.isPresent, d.macPorts.isPresent].map { $0 ? "1" : "0" }.joined()
    }

    // MARK: - 依赖实时刷新

    /// 依赖轮询间隔。检测是纯同步文件系统调用，开销可忽略；换来终端里装完依赖后回到应用即见状态更新。
    private static let dependencyPollInterval = Duration.seconds(3)

    private var dependencyPoller: Task<Void, Never>?

    /// 启动依赖实时轮询。幂等，重复调用不会叠加多个轮询。
    public func startDependencyPolling() {
        guard dependencyPoller == nil else { return }

        dependencyPoller = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppState.dependencyPollInterval)
                if Task.isCancelled { return }

                // 检测本身很轻，但仍放后台执行，避免打断主线程的
                // 滚动与动画。
                let status = DependencyDetector().detect()

                let alive: Bool = await MainActor.run {
                    guard let self else { return false }
                    self.applyPolledDependency(status)
                    return true
                }
                if !alive { return }
            }
        }
    }

    public func stopDependencyPolling() {
        dependencyPoller?.cancel()
        dependencyPoller = nil
    }

    /// 应用一次轮询结果。只在签名真正变化时才写状态、记日志，避免无变化轮询反复重建视图树。
    private func applyPolledDependency(_ status: DependencyStatus) {
        guard !isCheckingDependencies else { return }
        guard Self.signature(of: status) != dependencySignature else { return }

        dependencies = status
        updateStatus()
        logStore.add(
            status.coreInstalled
                ? Localization.shared.t("dependencies.allInstalled")
                : Localization.shared.t("dependencies.missingDepsDetected"),
            type: status.coreInstalled ? .success : .warning)
    }

    private func updateStatus() {
        if isCheckingDependencies {
            statusKind = .checking
            statusText = Localization.shared.t("status.checking")
            return
        }
        guard dependencies.coreInstalled else {
            statusKind = .error
            statusText = Localization.shared.t("status.missingDeps")
            return
        }
        if devices.isEmpty {
            statusKind = .ready
            statusText = Localization.shared.t("status.waitingDevices")
            return
        }
        let rw = devices.filter { $0.isReadWrite }.count
        let ro = devices.filter { !$0.isReadWrite && !$0.isUnmounted }.count
        statusKind = .ready
        statusText = rw > 0
            ? Localization.shared.t("status.devicesReady", ["count": String(rw)])
            : Localization.shared.t("status.devicesReadOnly", ["count": String(ro)])
    }

    // MARK: - 设备

    public func refreshDevices() {
        deviceService.refresh()
    }

    // MARK: 单设备操作

    public func mount(_ device: NTFSDevice) {
        run(device, busyMessage: Localization.shared.t("messages.mounting", ["name": device.volumeName]),
            successKey: "messages.mountSuccess", failureKey: "messages.mountError") {
            try await MountEngine.shared.mountReadWrite(device: device)
        }
    }

    public func unmount(_ device: NTFSDevice) {
        run(device, busyMessage: Localization.shared.t("messages.unmounting", ["name": device.volumeName]),
            successKey: "messages.unmountSuccess", failureKey: "messages.unmountError") {
            try await MountEngine.shared.unmount(device: device)
        } onSuccess: {
            self.deviceService.retainAfterUnmount(device)
        }
    }

    /// 重新以读写方式挂载（先卸载当前读写挂载，再重新挂载）
    public func remount(_ device: NTFSDevice) {
        unmount(device)
        mount(device)
    }

    public func restoreReadOnly(_ device: NTFSDevice) {
        run(device, busyMessage: Localization.shared.t("messages.restoring", ["name": device.volumeName]),
            successKey: "messages.restoreSuccess", failureKey: "messages.restoreError") {
            try await MountEngine.shared.restoreToReadOnly(device: device)
        }
    }

    public func eject(_ device: NTFSDevice) {
        run(device, busyMessage: Localization.shared.t("messages.ejecting", ["name": device.volumeName]),
            successKey: "messages.ejectSuccess", failureKey: "messages.ejectError") {
            try await MountEngine.shared.eject(device: device)
        } onSuccess: {
            self.deviceService.dropRetained(device)
        }
    }

    public func reset(_ device: NTFSDevice) {
        run(device, busyMessage: Localization.shared.t("messages.resetting", ["name": device.volumeName]),
            successKey: "messages.resetSuccess", failureKey: "messages.resetError") {
            try await MountEngine.shared.reset(device: device)
        }
    }

    /// 所有设备操作的统一入口：行内忙碌态、日志、刷新。
    private func run(
        _ device: NTFSDevice,
        busyMessage: String,
        successKey: String,
        failureKey: String,
        _ operation: @escaping @Sendable () async throws -> Void,
        onSuccess: @MainActor @escaping () -> Void = {}
    ) {
        busyDeviceIDs.insert(device.disk)
        busyDeviceMessages[device.disk] = busyMessage
        // 新操作开始：先清掉上一次的失败原因，否则一整行会挂着陈年旧账，
        // 用户分不清那是历史还是这次的结果。
        deviceErrors[device.disk] = nil

        Task {
            do {
                try await operation()
                finish(device.disk, success: true, messageKey: successKey, detail: nil, device: device)
                onSuccess()
            } catch {
                finish(device.disk, success: false, messageKey: failureKey,
                      detail: error.localizedDescription, device: device)
            }
        }
    }

    private func finish(_ disk: String, success: Bool, messageKey: String,
                        detail: String?, device: NTFSDevice) {
        busyDeviceIDs.remove(disk)
        busyDeviceMessages[disk] = nil

        // 行内只放「失败原因」本身。日志那条才需要带卷名做上下文，
        // 而设备行的标题就是卷名，再拼一遍只是噪音。
        if success {
            deviceErrors[disk] = nil
        } else {
            deviceErrors[disk] = detail ?? Localization.shared.t(messageKey)
        }

        let message: String
        if let detail {
            message = String(format: "%@ - %@: %@", device.volumeName,
                             Localization.shared.t(messageKey), detail)
        } else {
            message = String(format: "%@ - %@", device.volumeName,
                             Localization.shared.t(messageKey))
        }
        logStore.add(message, type: success ? .success : .error)
        deviceService.refresh()
    }

    // MARK: - 批量操作

    public var mountableTargets: [NTFSDevice] {
        devices.filter { !$0.isReadWrite && !$0.isUnmounted }
    }

    public var mountedTargets: [NTFSDevice] {
        devices.filter { $0.isReadWrite }
    }

    public var ejectableTargets: [NTFSDevice] {
        devices.filter { !$0.isUnmounted }
    }

    public func mountAll() {
        let targets = mountableTargets
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("messages.noDevicesToMount"), type: .warning)
            return
        }
        logStore.add(Localization.shared.t("messages.mountAllStart", ["count": String(targets.count)]), type: .info)
        for device in targets { mount(device) }
    }

    public func unmountAll() {
        let targets = mountedTargets
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("messages.noDevicesToUnmount"), type: .warning)
            return
        }
        for device in targets { unmount(device) }
    }

    public func restoreAll() {
        let targets = mountedTargets
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("devices.noDevicesToRestore"), type: .warning)
            return
        }
        for device in targets { restoreReadOnly(device) }
    }

    public func ejectAll() {
        let targets = ejectableTargets
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("devices.noDevicesToEject"), type: .warning)
            return
        }
        for device in targets { eject(device) }
    }

    /// 批量操作的目标集合：有选中项时只作用于选中项，否则作用于全部。
    public func targets(forSelection selection: Set<String>) -> [NTFSDevice] {
        selection.isEmpty ? devices : devices.filter { selection.contains($0.disk) }
    }

    public func mount(selection: Set<String>) {
        let targets = targets(forSelection: selection).filter { !$0.isReadWrite && !$0.isUnmounted }
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("messages.noDevicesToMount"), type: .warning)
            return
        }
        logStore.add(Localization.shared.t("messages.mountAllStart", ["count": String(targets.count)]), type: .info)
        for device in targets { mount(device) }
    }

    public func unmount(selection: Set<String>) {
        let targets = targets(forSelection: selection).filter { $0.isReadWrite }
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("messages.noDevicesToUnmount"), type: .warning)
            return
        }
        for device in targets { unmount(device) }
    }

    public func restore(selection: Set<String>) {
        let targets = targets(forSelection: selection).filter { $0.isReadWrite }
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("devices.noDevicesToRestore"), type: .warning)
            return
        }
        for device in targets { restoreReadOnly(device) }
    }

    public func eject(selection: Set<String>) {
        let targets = targets(forSelection: selection).filter { !$0.isUnmounted }
        guard !targets.isEmpty else {
            logStore.add(Localization.shared.t("devices.noDevicesToEject"), type: .warning)
            return
        }
        for device in targets { eject(device) }
    }

    // MARK: - 自动读写

    /// 已经自动尝试过的设备（按 `stableId`）。没有这道闸，挂载失败的系统授权框会在每次刷新时反复弹出。
    private var autoMountAttempted: Set<String> = []

    /// 是否已处理过「启动时已在机」的那批设备，用来切开 `mountOnLaunch`（启动在机）与 `autoMount`（之后接入）的适用范围。
    private var didInitialDeviceSweep = false

    private func applyAutoMount(to list: [NTFSDevice]) {
        let s = settings.settings

        // 空列表不算「首次扫描」：启动瞬间设备枚举可能先返回空列表。
        // 若在空列表上就消费掉这次机会，插着盘开机反而不会自动挂载。
        let isInitialSweep = !didInitialDeviceSweep && !list.isEmpty
        if isInitialSweep { didInitialDeviceSweep = true }

        guard isInitialSweep ? (s.mountOnLaunch || s.autoMount) : s.autoMount else { return }

        for device in list where !device.isUnmounted && !device.isReadWrite {
            guard autoMountAttempted.insert(device.stableId).inserted else { continue }
            logStore.add(
                Localization.shared.t("settings.autoMountTriggered",
                                      ["name": device.volumeName]),
                type: .info)
            mount(device)
        }
    }

    // MARK: - 管理员密码（钥匙串）

    /// 校验并保存管理员密码。顺序必须是「先验证、后保存」—— 未验证的密码写进钥匙串等于把故障推迟到下次挂载。
    public func saveAdminPassword(_ password: String) async {
        guard !password.isEmpty else {
            passwordNotice = PasswordNotice(
                kind: .failure,
                text: Localization.shared.t("settings.passwordEmpty"))
            return
        }

        do {
            _ = try await PrivilegedExecutor.shared
                .executeWithPassword("/usr/bin/true", [], password: password)
        } catch PrivilegeError.wrongPassword {
            passwordNotice = PasswordNotice(
                kind: .failure,
                text: Localization.shared.t("settings.passwordWrong"))
            return
        } catch {
            passwordNotice = PasswordNotice(
                kind: .failure,
                text: "\(Localization.shared.t("settings.passwordSaveFailed")): \(error.localizedDescription)")
            return
        }

        do {
            try KeychainStore.shared.save(password)
        } catch {
            passwordNotice = PasswordNotice(
                kind: .failure,
                text: "\(Localization.shared.t("settings.passwordSaveFailed")): \(error.localizedDescription)")
            return
        }

        settings.update { $0.savePassword = true }
        PrivilegedExecutor.shared.prefersSavedPassword = true
        savedPasswordExists = true
        passwordNotice = PasswordNotice(
            kind: .success,
            text: Localization.shared.t("settings.passwordSaved"))
        logStore.add(Localization.shared.t("settings.passwordSaved"), type: .success)
    }

    /// 删除钥匙串里的密码，并关闭「保存管理员密码」（关开关即等于删密码）。
    public func deleteAdminPassword() {
        let ok = KeychainStore.shared.delete()
        savedPasswordExists = false
        settings.update { $0.savePassword = false }
        PrivilegedExecutor.shared.prefersSavedPassword = false

        if ok {
            passwordNotice = PasswordNotice(
                kind: .success,
                text: Localization.shared.t("settings.deletePasswordSuccess"))
            logStore.add(Localization.shared.t("settings.deletePasswordSuccess"), type: .info)
        } else {
            passwordNotice = PasswordNotice(
                kind: .failure,
                text: Localization.shared.t("settings.deletePasswordError"))
            logStore.add(Localization.shared.t("settings.deletePasswordError"), type: .error)
        }
    }

    /// 重新读一次钥匙串状态。设置页出现时调用，跟用户在别处改过的条目。
    public func refreshSavedPasswordState() {
        let exists = KeychainStore.shared.hasPassword
        if exists != savedPasswordExists { savedPasswordExists = exists }
    }

    // MARK: - 系统集成

    /// 防止空闲休眠。大文件传输期间系统若休眠，USB 设备可能被重新枚举、写入被打断。
    public func setPreventSleep(_ enabled: Bool) {
        settings.update { $0.preventSleep = enabled }

        if enabled {
            if sleepPreventer.start() {
                logStore.add(Localization.shared.t("settings.preventSleepOn"), type: .info)
            } else {
                // 断言创建失败不常见，但不能吞掉 —— 否则用户以为已经生效。
                logStore.add(Localization.shared.t("settings.preventSleepFailed"), type: .warning)
                settings.update { $0.preventSleep = false }
            }
        } else {
            sleepPreventer.stop()
        }
    }

    /// 登录时自启。成功与否以系统返回状态为准，失败原样告知。
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try LaunchAtLogin.enable()
                logStore.add(Localization.shared.t("settings.launchAtLoginOn"), type: .success)
            } else {
                try LaunchAtLogin.disable()
                logStore.add(Localization.shared.t("settings.launchAtLoginOff"), type: .info)
            }
        } catch {
            logStore.add("\(Localization.shared.t("settings.launchAtLoginFailed")): \(error.localizedDescription)",
                         type: .warning)
        }
        refreshLaunchAtLoginState()
    }

    /// 重新读取系统的登录项状态。用户可能在系统设置里改过。
    public func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    }
}
