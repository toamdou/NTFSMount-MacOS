import AppKit
import SwiftUI

/// 主窗口的 scene 标识。托盘与菜单栏都用它定位窗口。
public enum WindowID {
    public static let main = "ntfsmount.main"
}

@MainActor
public final class MainWindowRelay {

    public static let shared = MainWindowRelay()

    /// 主窗口实例。用 weak：窗口被系统回收后自动置空，避免悬空指针。
    private weak var window: NSWindow?

    /// 兜底重建路径（Window 实例已被回收时用）
    private var reopen: OpenWindowAction?

    private init() {}

    public func report(window: NSWindow?, reopen: OpenWindowAction?) {
        self.window = window
        self.reopen = reopen
    }

    /// 把主窗口叫到前台。返回 false 表示窗口已被回收、需要重建。
    @discardableResult
    public func reveal() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // 窗口可能被长时间隐藏后回收，或用户从未打开过主界面
        let reused = window.map { $0.makeKeyAndOrderFront(nil); return true } ?? false
        if !reused { reopen?(id: WindowID.main) }
        NotificationCenter.default.post(name: .ntfsmountShowMainWindow, object: nil)
        return reused
    }
}

// MARK: - 视图桥

/// 透明视图，只为在视图挂载时抓到所属 NSWindow 与 openWindow 动作。
struct WindowReporter: NSViewRepresentable {

    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // 挂到 window 上后再上报，避免 makeNSView 时 window 还是 nil
        DispatchQueue.main.async {
            MainWindowRelay.shared.report(window: view.window, reopen: openWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MainWindowRelay.shared.report(window: nsView.window, reopen: openWindow)
        }
    }
}
