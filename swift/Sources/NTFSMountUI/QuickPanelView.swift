import SwiftUI
import AppKit
import NTFSMountCore

struct QuickPanelView: View {

    @ObservedObject var state: AppState

    let onShowMain: () -> Void
    let onQuit: () -> Void

    @State private var pendingAction: (DeviceAction, NTFSDevice)?

    private static let panelWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Self.panelWidth)
        .background(.background)   // 跟随系统浅/深色，不用自绘背景
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action, device in
            Button(action.label, role: action.isDestructive ? .destructive : nil) {
                perform(action, on: device)
                pendingAction = nil
            }
            Button(Localization.shared.t("dialog.cancel"), role: .cancel) { pendingAction = nil }
        } message: { action, device in
            Text(note(for: action))
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected")
                .foregroundStyle(.tint)
            Text(Localization.shared.t("tray.ntfsDevices"))
                .font(.headline)
            Spacer(minLength: 4)
            Button {
                state.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Localization.shared.t("devices.refreshDevices"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 设备列表

    @ViewBuilder
    private var content: some View {
        if state.devices.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(Localization.shared.t("tray.noDevices"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Localization.shared.t("tray.panelHint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.devices) { device in
                        row(device)
                        if device.id != state.devices.last?.id { Divider().padding(.leading, 12) }
                    }
                }
            }
            .frame(maxHeight: 320)
            batchBar
        }
    }

    private func row(_ device: NTFSDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusSymbol(for: device))
                    .foregroundStyle(statusColor(for: device))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.volumeName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isBusy(device) {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(verbatim: state.busyDeviceMessages[device.disk] ?? "")
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: subtitle(for: device))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 2)
                actions(for: device)
            }

            // 与卷名文字左对齐：状态图标宽约 14pt + 行内间距 8pt
            capacityBar(device)
                .padding(.leading, 22)

            if !isBusy(device), let error = state.deviceErrors[device.disk] {
                failureRow(error)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contextMenu { contextActions(for: device) }
    }

    private func isBusy(_ device: NTFSDevice) -> Bool {
        state.busyDeviceIDs.contains(device.disk)
    }

    /// 容量条。格式化与色阶共用 `NativeFormat`；未挂载设备也能拿到容量（回退到 IOMedia 总容量，used 为 0）。
    @ViewBuilder
    private func capacityBar(_ device: NTFSDevice) -> some View {
        if let cap = device.capacity, cap.total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: min(1, max(0, cap.usageFraction)))
                    .progressViewStyle(.linear)
                    .tint(NativeFormat.capacityTint(cap.usageFraction))

                HStack(spacing: 0) {
                    Text(verbatim: NativeFormat.bytes(cap.available))
                    Text(verbatim: " / \(NativeFormat.bytes(cap.total))")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(Int((cap.usageFraction * 100).rounded()))%")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    /// 操作失败原因。快捷面板没有日志页，失败必须在行内说清；不设 lineLimit，指引文案截断等于没说。
    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(verbatim: message)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(Color(nsColor: .systemRed))
    }

    @ViewBuilder
    private func actions(for device: NTFSDevice) -> some View {
        HStack(spacing: 3) {
            if device.isUnmounted {
                iconButton("arrow.triangle.2.circlepath", help: "devices.mount") {
                    pendingAction = (.mount, device)
                }
            } else if device.isReadWrite {
                iconButton("lock.open", help: "devices.restoreReadOnly") {
                    pendingAction = (.restore, device)
                }
            } else {
                iconButton("lock.open", help: "devices.mount") {
                    pendingAction = (.mount, device)
                }
            }

            if !device.volume.isEmpty {
                iconButton("folder", help: "tray.openInFinder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.volume)])
                }
            }

            if !device.isUnmounted {
                iconButton("eject", help: "devices.eject", destructive: true) {
                    pendingAction = (.eject, device)
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isBusy(device))
    }

    private func iconButton(_ symbol: String, help key: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(destructive ? Color(nsColor: .systemRed) : Color.secondary)
        }
        .help(Localization.shared.t(key))
    }

    @ViewBuilder
    private func contextActions(for device: NTFSDevice) -> some View {
        Button(Localization.shared.t("devices.mount")) { pendingAction = (.mount, device) }
        Button(Localization.shared.t("devices.restoreReadOnly")) { pendingAction = (.restore, device) }
        Button(Localization.shared.t("devices.unmount")) { pendingAction = (.unmount, device) }
        Divider()
        if !device.volume.isEmpty {
            Button(Localization.shared.t("tray.openInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.volume)])
            }
        }
        Button(role: .destructive) {
            pendingAction = (.eject, device)
        } label: {
            Label(Localization.shared.t("devices.eject"), systemImage: "eject")
        }
    }

    // MARK: - 一键操作

    private var batchBar: some View {
        HStack(spacing: 6) {
            Button {
                state.mountAll()
            } label: {
                Label(Localization.shared.t("tray.mountAll"),
                      systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .disabled(state.mountableTargets.isEmpty)

            Button {
                state.restoreAll()
            } label: {
                Label(Localization.shared.t("tray.unmountAll"), systemImage: "lock")
                    .font(.caption)
            }
            .disabled(state.mountedTargets.isEmpty)

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: onShowMain) {
                Label(Localization.shared.t("tray.showMainWindow"), systemImage: "macwindow")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(Localization.shared.t("tray.settings"))

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(Localization.shared.t("tray.quit"))
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 状态样式

    private func subtitle(for device: NTFSDevice) -> String {
        if device.isUnmounted { return Localization.shared.t("devices.unmounted") }
        if device.isReadWrite  { return Localization.shared.t("tray.mounted") }
        return device.volume.isEmpty
            ? Localization.shared.t("tray.readOnly")
            : "\(Localization.shared.t("tray.readOnly")) · \(device.volume)"
    }

    private func statusSymbol(for device: NTFSDevice) -> String {
        if device.isUnmounted { return "externaldrive.badge.xmark" }
        return device.isReadWrite ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }

    private func statusColor(for device: NTFSDevice) -> Color {
        if device.isUnmounted { return .secondary }
        return device.isReadWrite ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }

    // MARK: - 确认

    private var dialogTitle: String {
        guard let (action, device) = pendingAction else { return "" }
        switch action {
        case .mount:   return Localization.shared.t("devices.mountConfirm", ["name": device.volumeName])
        case .unmount: return Localization.shared.t("devices.unmountConfirm", ["name": device.volumeName])
        case .eject:   return Localization.shared.t("devices.ejectConfirm", ["name": device.volumeName])
        case .restore: return Localization.shared.t("devices.restoreConfirm", ["name": device.volumeName])
        case .reset:   return Localization.shared.t("devices.mountConfirm", ["name": device.volumeName])
        }
    }

    private func note(for action: DeviceAction) -> String {
        switch action {
        case .mount, .reset:  return Localization.shared.t("devices.mountConfirmNote")
        case .eject:          return Localization.shared.t("devices.ejectConfirmNote")
        case .restore:        return Localization.shared.t("devices.restoreConfirmNote")
        case .unmount:        return Localization.shared.t("devices.unmountConfirmNote")
        }
    }

    private func perform(_ action: DeviceAction, on device: NTFSDevice) {
        switch action {
        case .mount:   state.mount(device)
        case .unmount: state.unmount(device)
        case .eject:   state.eject(device)
        case .restore: state.restoreReadOnly(device)
        case .reset:   state.reset(device)
        }
    }
}
