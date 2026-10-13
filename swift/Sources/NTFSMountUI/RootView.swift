import SwiftUI
import AppKit
import NTFSMountCore

public struct RootView: View {

    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView {
            Sidebar(state: state)
        } detail: {
            detail
        }
        // 标题必须挂在 NavigationSplitView 上：挂进 detail 时标题与工具栏的布局基准不同，
        // 会与侧边栏右边缘对不齐、切页时跳动。
        .navigationTitle(Localization.shared.t(state.selectedTab.titleKey))
        .navigationSplitViewStyle(.balanced)
        .background(WindowReporter())
        // 托盘「进入主界面」时刷新一次设备
        .onReceive(NotificationCenter.default.publisher(for: .ntfsmountShowMainWindow)) { _ in
            state.refreshAll()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedTab {
        case .dependencies: DependenciesView(state: state)
        case .devices:      DevicesView(state: state)
        case .logs:         LogsView(state: state)
        case .help:         ManualView(state: state)
        }
    }
}

// MARK: - 侧边栏

private struct Sidebar: View {

    @ObservedObject var state: AppState

    var body: some View {
        List(selection: selection) {
            // 设置归属应用菜单与 ⌘,（macOS 惯例位置），侧边栏不再放第二份入口。
            ForEach(AppState.navigationTabs) { tab in
                row(for: tab)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    /// List 单选需要可选类型；nil 表示不改变当前页。
    private var selection: Binding<AppTab?> {
        Binding(
            get: { state.selectedTab },
            set: { if let tab = $0 { state.selectedTab = tab } }
        )
    }

    private func row(for tab: AppTab) -> some View {
        HStack(spacing: 6) {
            Label(Localization.shared.t(tab.titleKey), systemImage: tab.symbolName)
            Spacer(minLength: 4)
            badge(for: tab)
        }
        .tag(tab)
    }

    /// 侧边栏行尾的小徽标：设备数 / 依赖状态 / 日志条数。
    @ViewBuilder
    private func badge(for tab: AppTab) -> some View {
        switch tab {
        case .devices:
            if !state.devices.isEmpty {
                Text("\(state.devices.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .dependencies:
            if state.isCheckingDependencies {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.dependencies.coreInstalled
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(state.dependencies.coreInstalled
                                     ? Color(nsColor: .systemGreen)
                                     : Color(nsColor: .systemOrange))
            }
        case .logs:
            if state.logStore.isEnabled, !state.logStore.entries.isEmpty {
                Text("\(state.logStore.entries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .help:
            EmptyView()
        }
    }
}

// MARK: - 状态栏

/// 详情区底部的原生状态栏。
struct StatusBar: View {

    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.statusKind.symbolName)
                .foregroundStyle(state.statusKind.color)
            Text(state.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if state.isCheckingDependencies {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 工具

enum NativeFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 容量条语义色：越满越警示。用三档而非渐变 —— 托盘面板里进度条只有几毫米宽，渐变分辨不出来。
    static func capacityTint(_ fraction: Double) -> Color {
        if fraction > 0.9 { return Color(nsColor: .systemRed) }
        if fraction > 0.75 { return Color(nsColor: .systemOrange) }
        return .accentColor
    }
}

/// 把字符串复制到剪贴板（依赖页安装命令 / 帮助页命令行）。
@MainActor
func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}
