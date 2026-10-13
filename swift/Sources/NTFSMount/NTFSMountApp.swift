import SwiftUI
import AppKit
import NTFSMountCore
import NTFSMountUI
import NTFSMountFinderBridge

@main
struct NTFSMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// 必须是进程级单例（`AppState.shared`）：托盘在 applicationDidFinishLaunching
    /// 安装时 App body 可能还没求值，否则会出现两份不同步的 AppState。
    @StateObject private var state = AppState.shared

    var body: some Scene {
        // 用 Window 而非 WindowGroup：托盘应用要求「关窗口不销毁」，
        // Window 是单例 scene，生命周期才与菜单栏驻留一致。
        Window(Localization.shared.t("app.windowTitle"), id: WindowID.main) {
            RootView(state: state)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear {
                    // 托盘已由 AppDelegate 在启动时安装；这里只做一次
                    // 幂等的状态注入，保证窗口出现时设备列表是新的。
                    state.bootstrap()
                    delegate.attach(state: state)
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 680)
        .commands { AppCommands(state: state) }

        Settings {
            SettingsScene(state: state)
        }
    }
}

// MARK: - 菜单命令

struct AppCommands: Commands {

    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(Localization.shared.t("menu.about")) {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "NTFSMount",
                    .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
                ])
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu(Localization.shared.t("tabs.devices")) {
            Button(Localization.shared.t("devices.refreshDevices")) {
                state.refreshDevices()
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button(Localization.shared.t("devices.mountAll")) { state.mountAll() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(state.mountableTargets.isEmpty)

            Button(Localization.shared.t("devices.unmountAll")) { state.unmountAll() }
                .disabled(state.mountedTargets.isEmpty)

            Button(Localization.shared.t("devices.restoreAllReadOnly")) { state.restoreAll() }
                .disabled(state.mountedTargets.isEmpty)

            Button(Localization.shared.t("devices.ejectAll")) { state.ejectAll() }
                .disabled(state.ejectableTargets.isEmpty)
        }

        CommandMenu(Localization.shared.t("tabs.dependencies")) {
            Button(Localization.shared.t("dependencies.checkButton")) {
                state.checkDependencies()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu(Localization.shared.t("menu.view")) {
            ForEach(AppState.navigationTabs) { tab in
                Button(Localization.shared.t(tab.titleKey)) {
                    state.selectedTab = tab
                    // Commands 里拿不到 App 的 @NSApplicationDelegateAdaptor 属性，
                    // 统一走 MainWindowRelay —— 它是 AppDelegate 用的同一个入口。
                    MainWindowRelay.shared.reveal()
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button(Localization.shared.t("menu.guide")) {
                state.selectedTab = .help
                MainWindowRelay.shared.reveal()
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

// MARK: - 应用代理

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?

    private var suppressesMainWindow = false

    /// 由 App 的 onAppear 调用（幂等）。托盘的实际安装发生在
    /// `applicationDidFinishLaunching`，这里只做状态注入。
    func attach(state: AppState) {
        guard statusItem == nil else { return }
        let controller = StatusItemController(state: state)
        controller.install()      // 安装托盘并做一次启动检测
        statusItem = controller
    }

    /// 窗口引用必须只有一个来源（RootView 上报给 MainWindowRelay），
    /// 刻意不自己缓存，否则关窗后两边各持过期引用。
    func revealMainWindow() {
        endSilentSuppression()
        MainWindowRelay.shared.reveal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SettingsStore.silentLaunchRequested() {
            beginSilentSuppression()
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        // 托盘必须在这里安装：静默自启下窗口不出现，挂在窗口生命周期上的
        // 托盘会一起消失，表现为「开机后应用像没启动一样」。
        attach(state: AppState.shared)

        // 访达集成同理，必须在进程级入口启动：它负责把设备状态写成扩展能读的
        // 快照，否则静默自启用户会得到「扩展装了但徽标全无」且无任何报错。
        FinderSyncBridge.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // 先清快照再拆托盘：清快照会通知扩展重置「处理中」标记，
        // 否则扩展会一直以为主应用还在处理上一条命令，菜单永久禁用。
        FinderSyncBridge.shared.prepareForTermination()
        statusItem?.uninstall()
    }

    /// 点程序坞图标也要能唤回窗口（配合 .regular 激活策略）
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        if !flag { revealMainWindow() }
        return true
    }

    // MARK: - 静默启动的抑制与解除

    private func beginSilentSuppression() {
        suppressesMainWindow = true

        // 同时切到 .accessory：静默自启下不该在程序坞里留图标。
        // 用户点「主界面」时再切回 .regular（见 endSilentSuppression）。
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil)

        // 通知是异步的，而窗口此刻可能已经建好了 —— 同步先扫一遍。
        suppressExistingMainWindows()
    }

    private func endSilentSuppression() {
        guard suppressesMainWindow else { return }
        suppressesMainWindow = false
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeMainNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard suppressesMainWindow else { return }
        (note.object as? NSWindow)?.orderOut(nil)
    }

    private func suppressExistingMainWindows() {
        // `canBecomeMain` 用来排除面板类窗口（如 NSPopover 的宿主），
        // 那些窗口被 orderOut 掉会导致托盘面板点不开。
        for window in NSApp.windows where window.canBecomeMain {
            window.orderOut(nil)
        }
    }
}
