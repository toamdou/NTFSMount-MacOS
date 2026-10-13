import SwiftUI
import NTFSMountCore

struct DevicesView: View {

    @ObservedObject var state: AppState

    @State private var searchText = ""
    @State private var selection: Set<String> = []
    @State private var pendingAction: (DeviceAction, NTFSDevice)?

    private var filteredDevices: [NTFSDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.devices }
        return state.devices.filter { d in
            d.volumeName.lowercased().contains(query)
                || d.disk.lowercased().contains(query)
                || d.devicePath.lowercased().contains(query)
                || d.volume.lowercased().contains(query)
        }
    }

    private var targets: [NTFSDevice] { state.targets(forSelection: selection) }

    var body: some View {
        Group {
            if state.devices.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(state: state) }
        .searchable(text: $searchText, placement: .toolbar, prompt: Localization.shared.t("devices.title"))
        .toolbar { toolbarContent }
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
        } message: { _, device in
            Text(actionNote(for: device))
        }
    }

    // MARK: - 表格

    private var table: some View {
        Table(filteredDevices, selection: $selection) {
            TableColumn(Localization.shared.t("devices.deviceLabel")) { device in
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol(for: device))
                        .foregroundStyle(statusColor(for: device))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.volumeName)
                            .fontWeight(.medium)
                        Text(device.devicePath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 160, ideal: 220)

            TableColumn(Localization.shared.t("devices.capacityLabel")) { device in
                capacityCell(device)
            }
            .width(min: 110, ideal: 150)

            TableColumn(Localization.shared.t("devices.readOnly")) { device in
                statusCell(device)
            }
            .width(min: 90, ideal: 110)

            TableColumn(Localization.shared.t("devices.mountPointLabel")) { device in
                Text(device.volume.isEmpty
                     ? Localization.shared.t("devices.notMounted")
                     : device.volume)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(device.volume.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
            .width(min: 120, ideal: 200)

            TableColumn(Localization.shared.t("devices.title")) { device in
                actionCell(device)
            }
            .width(min: 180, ideal: 240)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            let devices = state.devices.filter { ids.contains($0.disk) }
            ForEach(devices) { device in
                Button(Localization.shared.t(DeviceAction.mount.labelKey)) { state.mount(device) }
                Button(Localization.shared.t(DeviceAction.unmount.labelKey)) { state.unmount(device) }
                Button(Localization.shared.t(DeviceAction.eject.labelKey)) { state.eject(device) }
            }
        } primaryAction: { ids in
            guard let disk = ids.first,
                  let device = state.devices.first(where: { $0.disk == disk }) else { return }
            device.isReadWrite ? state.unmount(device) : state.mount(device)
        }
    }

    @ViewBuilder
    private func capacityCell(_ device: NTFSDevice) -> some View {
        if let cap = device.capacity, cap.total > 0 {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: NativeFormat.bytes(cap.available))
                        .monospacedDigit()
                    Text(verbatim: "/ \(NativeFormat.bytes(cap.total))")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
                ProgressView(value: min(1, max(0, cap.usageFraction)))
                    .progressViewStyle(.linear)
                    .tint(capacityTint(cap.usageFraction))
            }
            .padding(.vertical, 2)
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    private func statusCell(_ device: NTFSDevice) -> some View {
        HStack(spacing: 6) {
            if state.busyDeviceIDs.contains(device.disk) {
                ProgressView().controlSize(.small)
                Text(verbatim: state.busyDeviceMessages[device.disk] ?? "")
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Image(systemName: statusSymbol(for: device))
                    .foregroundStyle(statusColor(for: device))
                Text(statusText(for: device))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func actionCell(_ device: NTFSDevice) -> some View {
        let isBusy = state.busyDeviceIDs.contains(device.disk)
        HStack(spacing: 6) {
            if device.isReadWrite {
                Button {
                    pendingAction = (.restore, device)
                } label: {
                    Label(Localization.shared.t("devices.restoreReadOnly"), systemImage: "lock.open")
                }
                Button {
                    pendingAction = (.unmount, device)
                } label: {
                    Label(Localization.shared.t("devices.unmount"), systemImage: "eject")
                }
            } else if device.isUnmounted {
                Button {
                    pendingAction = (.mount, device)
                } label: {
                    Label(Localization.shared.t("devices.mount"), systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button {
                    pendingAction = (.mount, device)
                } label: {
                    Label(Localization.shared.t("devices.mount"), systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    pendingAction = (.reset, device)
                } label: {
                    Label(Localization.shared.t("devices.reset"), systemImage: "wrench.and.screwdriver")
                }
                .help(Localization.shared.t("devices.resetTooltip"))
                Button(role: .destructive) {
                    pendingAction = (.eject, device)
                } label: {
                    Label(Localization.shared.t("devices.eject"), systemImage: "eject")
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .disabled(isBusy)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label(Localization.shared.t("devices.emptyState"), systemImage: "externaldrive.badge.plus")
        } description: {
            Text(Localization.shared.t("devices.emptyHint"))
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                state.refreshDevices()
            } label: {
                Label(Localization.shared.t("devices.refreshDevices"), systemImage: "arrow.clockwise")
            }
            .help(Localization.shared.t("devices.refreshDevices"))

            Button {
                state.mount(selection: selection)
            } label: {
                Label(Localization.shared.t("devices.mountAll"), systemImage: "arrow.up.arrow.down.square")
            }
            .disabled(!targets.contains { !$0.isReadWrite && !$0.isUnmounted })
            .help(Localization.shared.t("devices.mountAll"))

            Button {
                state.restore(selection: selection)
            } label: {
                Label(Localization.shared.t("devices.restoreAllReadOnly"), systemImage: "lock.square")
            }
            .disabled(!targets.contains(where: { $0.isReadWrite }))
            .help(Localization.shared.t("devices.restoreAllReadOnly"))

            Button {
                state.unmount(selection: selection)
            } label: {
                Label(Localization.shared.t("devices.unmountAll"), systemImage: "eject.square")
            }
            .disabled(!targets.contains(where: { $0.isReadWrite }))
            .help(Localization.shared.t("devices.unmountAll"))

            Button(role: .destructive) {
                state.eject(selection: selection)
            } label: {
                Label(Localization.shared.t("devices.ejectAll"), systemImage: "eject")
            }
            .disabled(!targets.contains(where: { !$0.isUnmounted }))
            .help(Localization.shared.t("devices.ejectAll"))
        }
    }

    // MARK: - 状态样式

    private func statusSymbol(for device: NTFSDevice) -> String {
        if device.isUnmounted { return "externaldrive.badge.xmark" }
        return device.isReadWrite ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }

    private func statusColor(for device: NTFSDevice) -> Color {
        if device.isUnmounted { return .secondary }
        return device.isReadWrite ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }

    private func capacityTint(_ fraction: Double) -> Color {
        NativeFormat.capacityTint(fraction)
    }

    private func statusText(for device: NTFSDevice) -> String {
        if device.isUnmounted { return Localization.shared.t("devices.unmounted") }
        if device.isReadWrite { return Localization.shared.t("devices.readWrite") }
        return Localization.shared.t("devices.readOnly")
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

    private func actionNote(for device: NTFSDevice) -> String {
        switch pendingAction?.0 {
        case .mount, .reset:  return Localization.shared.t("devices.mountConfirmNote")
        case .eject:          return Localization.shared.t("devices.ejectConfirmNote")
        case .restore:        return Localization.shared.t("devices.restoreConfirmNote")
        case .unmount, .none: return device.volumeName
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

// MARK: - 设备操作

enum DeviceAction: String, CaseIterable {
    case mount, unmount, eject, restore, reset

    var labelKey: String {
        switch self {
        case .mount:   return "devices.mount"
        case .unmount: return "devices.unmount"
        case .eject:   return "devices.eject"
        case .restore: return "devices.restoreReadOnly"
        case .reset:   return "devices.reset"
        }
    }

    var label: String { Localization.shared.t(labelKey) }

    var isDestructive: Bool { self == .eject }
}
