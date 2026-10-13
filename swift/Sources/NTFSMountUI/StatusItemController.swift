import AppKit
import SwiftUI
import Combine
import NTFSMountCore

@MainActor
public final class StatusItemController: NSObject {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var menu: NSMenu?

    /// 面板与菜单都直接读同一个 AppState，不维护第二份状态。
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var isInstalled = false

    public init(state: AppState) {
        self.state = state
        super.init()
    }

    // MARK: - 安装

    /// 幂等：由 AppDelegate 在拿到 AppState 后调用一次。
    public func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeIcon(active: false)
        item.button?.toolTip = Localization.shared.t("tray.tooltip")

        // 关键：不设 item.menu，否则系统吞掉左键点击。
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        configurePopover()
        observeDevices()

        // 启动后立刻拉一次设备列表，
        // 否则「窗口全关 → 从托盘打开」时看到的是空列表，要手动刷新才有内容。
        state.bootstrap()
    }

    /// 退出时显式回收。托盘生命周期等于进程生命周期，无需（也无法在 Swift 6 下安全地）写 `deinit`。
    public func uninstall() {
        closePanel()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        isInstalled = false
    }

    /// 运行时图标用系统 SF Symbol（资源缺失时 NSStatusItem 没有 fallback）；`isTemplate` 让它跟随菜单栏明暗反色。
    private static func makeIcon(active: Bool) -> NSImage {
        let symbol = active ? "externaldrive.connected" : "internaldrive"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15,
                                              weight: active ? .medium : .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        return img
    }

    // MARK: - 点击分发

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            presentMenu()
        } else {
            togglePanel(relativeTo: sender)
        }
    }

    // MARK: - 右键菜单

    private func presentMenu() {
        // 每次重建：NSMenu 的标题是创建时固化的，不随语言切换刷新
        let m = buildMenu()
        menu = m
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        let rwCount = state.devices.filter(\.isReadWrite).count
        if rwCount > 0 {
            let info = NSMenuItem(title: String(
                format: "%@ · %@ %d",
                Localization.shared.t("app.windowTitle"),
                Localization.shared.t("tray.mounted"), rwCount), action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
            m.addItem(.separator())
        }

        m.addItem(item(Localization.shared.t("tray.showMainWindow"),
                       #selector(showMainWindow)))
        m.addItem(.separator())
        m.addItem(item(Localization.shared.t("tray.refreshDevices"),
                       #selector(refreshDevices)))
        m.addItem(item(Localization.shared.t("tray.mountAll"),
                       #selector(mountAll)))
        m.addItem(item(Localization.shared.t("tray.unmountAll"),
                       #selector(unmountAll)))
        m.addItem(.separator())
        m.addItem(item(Localization.shared.t("tray.settings"),
                       #selector(openSettings)))
        m.addItem(.separator())
        m.addItem(item(Localization.shared.t("tray.quit"),
                       #selector(quitApp)))
        return m
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.isEnabled = true
        return it
    }

    // MARK: - 左键面板

    private func configurePopover() {
        popover.behavior = .transient      // 点击面板外自动关闭
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: QuickPanelView(
                state: state,
                onShowMain: { [weak self] in
                    self?.closePanel()
                    self?.showMainWindow()
                },
                onQuit: { [weak self] in
                    self?.closePanel()
                    self?.quitApp()
                }
            )
        )
    }

    private func togglePanel(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePanel()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func closePanel() {
        popover.performClose(nil)
    }

    // MARK: - 动作

    @objc private func showMainWindow() {
        // 关窗口只是隐藏，Window scene 仍保留 NSWindow 实例，直接叫到前台即可；
        // relay 内部还有 openWindow 兜底，处理实例被系统回收的情况。
        MainWindowRelay.shared.reveal()
    }

    @objc private func refreshDevices() {
        state.refreshDevices()
    }

    @objc private func mountAll() {
        state.mountAll()
    }

    @objc private func unmountAll() {
        state.unmountAll()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // 触发 SwiftUI Settings scene（系统响应 ⌘, 的 selector）
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 图标随挂载状态变化

    /// 有读写挂载时换成实心图标，作为「正在写入」的可见提示。
    private func observeDevices() {
        state.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self, let button = self.statusItem?.button else { return }
                button.image = Self.makeIcon(active: devices.contains { $0.isReadWrite })
            }
            .store(in: &cancellables)
    }
}

extension Notification.Name {
    /// 主窗口被重新叫到前台时发出，用于刷新可能过期的设备状态。
    static let ntfsmountShowMainWindow = Notification.Name("ntfsmount.showMainWindow")
}
