import Foundation
import AppKit
import FinderSync
import NTFSMountFinderBridge

// MARK: - 扩展主体

/// FIFinderSync 扩展的 principal class（Info.plist 里 `NSExtensionPrincipalClass`）。
open class NTFSFinderSync: FIFinderSync, @unchecked Sendable {

    // MARK: 缓存状态（受 lock 保护）

    private let lock = NSLock()
    /// 挂载点 → 条目。Finder 回调里唯一读的东西。
    private var indexByMountPath: [String: VolumeSnapshot.Entry] = [:]
    /// 未挂载卷（mountPath 为空）的条目
    private var unmountedEntries: [VolumeSnapshot.Entry] = []
    /// 最近一次快照内容摘要，用于只判断「内容变了没有」。
    private var lastAppliedDigest: Int?
    /// 最近一次快照时间戳（仅作诊断参考，不用于 gate）
    private var snapshotUpdatedAt: Date = .distantPast
    /// 当前正在处理的命令（用于把菜单项显示为「正在处理…」并禁用）
    private var inFlightCommand: MountCommandResult?
    /// 已经被观察过的 URL —— `setBadgeIdentifier` 只能对已请求过的条目调用
    private var badgedURLs: Set<String> = []

    /// 已注册的徽标 ID → 语义。Finder 只认注册过的 ID。
    private enum BadgeID {
        static let readWrite = "ntfs.rw"
        static let readOnly = "ntfs.ro"
        static let unmounted = "ntfs.unmounted"
        /// 处理中（蓝色 hourglass）
        static let busy = "ntfs.busy"
    }

    // MARK: 观察者

    private var stateToken: ObservationToken?
    private var resultToken: ObservationToken?
    private var terminateToken: ObservationToken?
    private var refreshTimer: Timer?

    // MARK: - 初始化

    public override init() {
        super.init()

        registerBadges()

        // 监控 /Volumes：徽标只加在卷根目录，但监控它才能让 Finder 在打开
        // 某个 NTFS 卷时把回调路由给我们。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/Volumes", isDirectory: true)]

        loadSnapshot()
        startObserving()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - 徽标注册

    /// 必须在 `init` 里一次性注册：Finder 只认 `setBadgeImage(...)` 注册过的 ID，事后注册对已显示条目无效。
    private func registerBadges() {
        let controller = FIFinderSyncController.default()

        if let image = Self.symbolImage(named: "checkmark.circle.fill",
                                        colors: [.systemGreen]) {
            controller.setBadgeImage(image,
                                     label: FinderStrings.badgeLabelReadWrite,
                                     forBadgeIdentifier: BadgeID.readWrite)
        }

        if let image = Self.symbolImage(named: "exclamationmark.triangle.fill",
                                        colors: [.systemOrange]) {
            controller.setBadgeImage(image,
                                     label: FinderStrings.badgeLabelReadOnly,
                                     forBadgeIdentifier: BadgeID.readOnly)
        }

        if let image = Self.symbolImage(named: "bolt.slash.fill",
                                        colors: [.systemGray]) {
            controller.setBadgeImage(image,
                                     label: FinderStrings.badgeLabelUnmounted,
                                     forBadgeIdentifier: BadgeID.unmounted)
        }

        if let image = Self.symbolImage(named: "hourglass",
                                        colors: [.systemBlue]) {
            controller.setBadgeImage(image, label: "", forBadgeIdentifier: BadgeID.busy)
        }
    }

    /// 构造带颜色的 SF Symbol（`paletteColors` 需 macOS 12+，本项目部署目标为 14）。
    private static func symbolImage(named name: String,
                                    colors: [NSColor]) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(paletteColors: colors)
        return base.withSymbolConfiguration(config) ?? base
    }

    // MARK: - 快照加载

    /// 从磁盘读快照并刷新内存缓存；磁盘是最终一致来源，通知不可靠，只在通知/定时器调用，绝不在 Finder 同步回调里调用。
    @discardableResult
    private func loadSnapshot() -> Bool {
        // 读失败 ≠ 快照为空：这里必须提前 return 而非 `?? .empty`，否则会误判「内容变了」
        // 而清空全部徽标、下次读成功再贴回，造成可见抖动。
        guard let snapshot = SnapshotStore.read() else { return false }

        let digest = Self.digest(of: snapshot)

        lock.lock()
        // 用内容摘要而非 updatedAt 比较：事件驱动写入每次都带新时间戳，
        // 仅比时间戳会导致无变化也全量重贴。
        let changed = digest != lastAppliedDigest
        lastAppliedDigest = digest
        snapshotUpdatedAt = snapshot.updatedAt
        indexByMountPath = snapshot.indexByMountPath()
        unmountedEntries = snapshot.entries.filter { $0.mountPath.isEmpty }
        lock.unlock()

        guard changed else { return false }
        refreshBadges()
        return true
    }

    /// 快照内容摘要；`Hasher` 种子每进程随机，只能在进程内跨轮询比较，绝不跨进程或写文件。
    private static func digest(of snapshot: VolumeSnapshot) -> Int {
        var hasher = Hasher()
        for entry in snapshot.entries {
            hasher.combine(entry.mountPath)
            hasher.combine(entry.devicePath)
            hasher.combine(entry.volumeName)
            hasher.combine(entry.state)
        }
        return hasher.finalize()
    }

    /// 重贴徽标到所有已知挂载点；只能对已请求过的 URL 调用 `setBadgeIdentifier`，故只遍历 `badgedURLs`。
    private func refreshBadges() {
        lock.lock()
        let urls = badgedURLs
        lock.unlock()

        for path in urls {
            applyBadge(to: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func applyBadge(to url: URL) {
        let path = FinderPathNormalizer.normalize(url.path)

        lock.lock()
        let busy = inFlightCommand != nil && !inFlightCommand!.isTerminal
        let entry = indexByMountPath[path]
            ?? unmountedEntries.first { "/Volumes/\($0.volumeName)" == path }
        lock.unlock()

        let controller = FIFinderSyncController.default()

        if busy {
            controller.setBadgeIdentifier(BadgeID.busy, for: url)
            return
        }
        guard let entry else {
            // 不在快照里 → 清掉可能存在的旧徽标
            controller.setBadgeIdentifier("", for: url)
            return
        }

        switch entry.state {
        case .readWrite:   controller.setBadgeIdentifier(BadgeID.readWrite, for: url)
        case .readOnly:    controller.setBadgeIdentifier(BadgeID.readOnly, for: url)
        case .unmounted:   controller.setBadgeIdentifier(BadgeID.unmounted, for: url)
        case .unavailable: controller.setBadgeIdentifier(BadgeID.unmounted, for: url)
        }
    }

    // MARK: - 观察者启动

    private func startObserving() {
        stateToken = DarwinNotifier.observe(FinderBridgeNotification.stateChanged) { [weak self] in
            self?.loadSnapshot()
        }

        resultToken = DarwinNotifier.observe(FinderBridgeNotification.commandFinished) { [weak self] in
            self?.loadCommandResult()
        }

        terminateToken = DarwinNotifier.observe(FinderBridgeNotification.appWillTerminate) { [weak self] in
            self?.handleAppTermination()
        }

        // 轮询是本扩展最终一致性的主通道，不是兜底：Darwin 通知不可靠，
        // 状态正确由定时读盘保证，通知只让更新提前到达。
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.loadSnapshot()
            self?.loadCommandResult()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - 命令结果

    private func loadCommandResult() {
        let latest = ResultStore.latest()

        lock.lock()
        // `latest == nil` 既可能是「确实没有结果」也可能是「临时读失败」，无法区分，
        // 所以不要用 nil 清 inFlightCommand，否则会撤掉 busy 徽标又贴回。
        let now = Date()
        var shouldClearInFlight = false
        if let inflight = inFlightCommand,
           inflight.status == .running,
           now.timeIntervalSince(inflight.finishedAt) > FinderBridgeContainer.commandTimeout {
            shouldClearInFlight = true
        }

        let changed = latest?.requestID != inFlightCommand?.requestID
            || latest?.status != inFlightCommand?.status
        if shouldClearInFlight {
            inFlightCommand = nil
        } else if latest != nil {
            inFlightCommand = latest
        }
        lock.unlock()

        guard changed || shouldClearInFlight else { return }

        // 结果回来后重新拉快照（与快照到达顺序不确定）；loadSnapshot 已按摘要去重，
        // 只有它没重贴时才需要在这里补一次。
        if !loadSnapshot() {
            refreshBadges()
        }
    }

    private func handleAppTermination() {
        lock.lock()
        inFlightCommand = nil
        lock.unlock()
        refreshBadges()
    }

    // MARK: - FIFinderSync 回调（热路径，必须极快）

    /// 热路径：Finder 为每个可见条目调用，只做字典查找，绝不 I/O（否则会被 terminate）。
    public override func requestBadgeIdentifier(for url: URL) {
        let path = FinderPathNormalizer.normalize(url.path)

        lock.lock()
        badgedURLs.insert(path)
        let busy = inFlightCommand.map { !$0.isTerminal } ?? false
        let entry = indexByMountPath[path]
            ?? unmountedEntries.first { "/Volumes/\($0.volumeName)" == path }
        lock.unlock()

        let controller = FIFinderSyncController.default()
        if busy {
            controller.setBadgeIdentifier(BadgeID.busy, for: url)
            return
        }
        switch entry?.state {
        case .readWrite:              controller.setBadgeIdentifier(BadgeID.readWrite, for: url)
        case .readOnly:               controller.setBadgeIdentifier(BadgeID.readOnly, for: url)
        case .unmounted, .unavailable: controller.setBadgeIdentifier(BadgeID.unmounted, for: url)
        case nil:                     controller.setBadgeIdentifier("", for: url)
        }
    }

    /// 用户正在查看某个目录（用于后续可能的按需刷新；当前无需额外处理）。
    public override func beginObservingDirectory(at url: URL) {}

    public override func endObservingDirectory(at url: URL) {}

    // MARK: - 工具栏

    public override var toolbarItemName: String { FinderStrings.toolbarName }
    public override var toolbarItemToolTip: String { FinderStrings.toolbarToolTip }

    public override var toolbarItemImage: NSImage {
        Self.symbolImage(named: "externaldrive.badge.checkmark",
                         colors: [.systemGreen]) ?? NSImage()
    }

    // MARK: - 上下文菜单

    /// 构造右键菜单；`toolbarItemMenu` 也会走这里，故对 toolbar 额外读 `selectedItemURLs`。
    public override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()

        let candidates: [URL]
        if menuKind == .toolbarItemMenu {
            candidates = controller.selectedItemURLs() ?? []
        } else if let targeted = controller.targetedURL() {
            candidates = [targeted]
        } else {
            candidates = controller.selectedItemURLs() ?? []
        }

        // 找出第一个（或全部）我们认识的 NTFS 卷
        lock.lock()
        let byPath = indexByMountPath
        let unmounted = unmountedEntries
        let busy = inFlightCommand.map { !$0.isTerminal } ?? false
        lock.unlock()

        var targets: [VolumeSnapshot.Entry] = []
        for url in candidates {
            let path = FinderPathNormalizer.normalize(url.path)
            if let entry = byPath[path] {
                targets.append(entry)
            } else if let entry = unmounted.first(where: { "/Volumes/\($0.volumeName)" == path }) {
                targets.append(entry)
            }
        }

        // 一个都没匹配上：工具栏菜单给出「打开应用」的兜底，
        // 右键菜单返回 nil（不往用户的右键菜单里塞无关项）
        if targets.isEmpty {
            guard menuKind == .toolbarItemMenu else { return nil }
            let menu = NSMenu()
            let open = NSMenuItem(title: FinderStrings.actionOpenApp,
                                  action: #selector(openMainApp(_:)),
                                  keyEquivalent: "")
            open.target = self
            open.image = NSImage(systemSymbolName: "app.badge",
                                 accessibilityDescription: nil)
            menu.addItem(open)
            return menu
        }

        let menu = NSMenu()

        for (index, entry) in targets.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            appendItems(for: entry, to: menu, busy: busy)
        }

        menu.addItem(.separator())
        let reveal = NSMenuItem(title: FinderStrings.actionRevealInApp,
                                action: #selector(openMainApp(_:)),
                                keyEquivalent: "")
        reveal.target = self
        reveal.image = NSImage(systemSymbolName: "macwindow",
                               accessibilityDescription: nil)
        menu.addItem(reveal)

        return menu
    }

    private func appendItems(for entry: VolumeSnapshot.Entry,
                             to menu: NSMenu,
                             busy: Bool) {
        let actions: [MountCommand.Kind]

        switch entry.state {
        case .readWrite:
            actions = [.unmount, .restoreReadOnly, .eject]
        case .readOnly:
            actions = [.mount, .eject]
        case .unmounted, .unavailable:
            actions = [.mount]
        }

        if busy {
            let item = NSMenuItem(title: FinderStrings.actionProcessing,
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for kind in actions {
            let item = NSMenuItem(title: kind.title,
                                  action: #selector(performCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: kind.symbolName,
                                 accessibilityDescription: nil)
            item.representedObject = CommandContext(kind: kind, devicePath: entry.devicePath)
            menu.addItem(item)
        }
    }

    // MARK: - 菜单动作

    /// 菜单项携带的上下文（NSMenuItem.representedObject 必须是 AnyObject）。
    private final class CommandContext: NSObject {
        let kind: MountCommand.Kind
        let devicePath: String

        init(kind: MountCommand.Kind, devicePath: String) {
            self.kind = kind
            self.devicePath = devicePath
        }
    }

    /// 用户点击操作：只写一个 JSON 文件 + 发通知后立刻返回，挂载由主应用提权完成。
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? CommandContext else { return }

        let command = MountCommand(kind: context.kind, devicePath: context.devicePath)

        // 立刻打上「处理中」徽标，让用户看到反馈
        lock.lock()
        inFlightCommand = MountCommandResult(requestID: command.requestID, status: .running)
        lock.unlock()
        refreshBadges()

        // 写盘 + 广播后立刻返回，不阻塞 Finder
        let posted = CommandQueue.post(command)
        if !posted {
            // 共享目录不可写（通常是主应用没装 App Group，或扩展未启用）
            NSLog("[NTFSMount] Finder 命令投递失败：共享目录不可写")
            lock.lock()
            inFlightCommand = MountCommandResult(
                requestID: command.requestID,
                status: .failed,
                message: "无法写入共享目录，请确认主应用已启动且 App Group 配置正确")
            lock.unlock()
            refreshBadges()
        }
    }

    /// 打开主应用：用 `openApplication(at:configuration:)` 以「激活已有实例，没有就启动」。
    @objc private func openMainApp(_ sender: Any?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/NTFSMount.app"),
            configuration: config
        ) { _, _ in
            // 启动失败时静默：扩展里弹不出有意义的错误
        }
    }
}