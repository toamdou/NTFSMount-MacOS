import SwiftUI
import AppKit
import NTFSMountCore

struct DependenciesView: View {

    @ObservedObject var state: AppState

    @State private var expanded: Set<DependencyKey> = []
    @State private var selectedMethod: InstallMethod?
    @State private var copiedCommand: String?

    private var entries: [DependencyEntry] { state.dependencyEntries }

    var body: some View {
        Group {
            if state.isCheckingDependencies {
                ProgressView(Localization.shared.t("dependencies.checking"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(state: state) }
        .toolbar {
            ToolbarItemGroup {
                // 分段控件必须带可见标签，否则用户猜不出它过滤的是每个条目的安装命令。
                // 只列两个包管理器：`direct` 是 Xcode CLT 这类系统组件自己的通道，不可选。
                Picker(selection: methodBinding) {
                    ForEach(InstallMethod.selectableCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                } label: {
                    Text(Localization.shared.t("dependencies.installMethod"))
                        .font(.callout)
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 280)
                .help(Localization.shared.t("dependencies.installMethodTooltip"))

                if unmetCount > 0 {
                    Button {
                        expanded = expanded.isEmpty
                            ? Set(entries.filter { !$0.isSatisfied }.map(\.key))
                            : []
                    } label: {
                        Label(Localization.shared.t(expanded.isEmpty
                                                    ? "dependencies.expandAll"
                                                    : "dependencies.collapseAll"),
                              systemImage: expanded.isEmpty
                                ? "rectangle.expand.vertical"
                                : "rectangle.compress.vertical")
                    }
                    .help(Localization.shared.t(expanded.isEmpty
                                                ? "dependencies.expandAll"
                                                : "dependencies.collapseAll"))
                }

                Button {
                    state.checkDependencies()
                } label: {
                    Label(Localization.shared.t("dependencies.checkButton"), systemImage: "arrow.clockwise")
                }
                .help(Localization.shared.t("dependencies.checkButton"))
            }
        }
        .onAppear { syncPreferredMethod() }
        .onChange(of: state.dependencySignature) { _, _ in syncPreferredMethod() }
    }

    private var unmetCount: Int {
        entries.filter { !$0.isSatisfied }.count
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                ForEach(entries, id: \.key) { entry in
                    DependencyRow(
                        entry: entry,
                        method: selectedMethod,
                        copiedCommand: copiedCommand,
                        isExpanded: Binding(
                            get: { expanded.contains(entry.key) },
                            set: { isOn in
                                if isOn { expanded.insert(entry.key) } else { expanded.remove(entry.key) }
                            }
                        ),
                        onCopy: copy
                    )
                }
            } header: {
                // 汇总一行：4 个条目的状态一眼可辨，不必逐行读各自的小字。
                HStack(spacing: 8) {
                    Text(Localization.shared.t("dependencies.summary", [
                        "ok": String(entries.count - unmetCount),
                        "total": String(entries.count),
                    ]))
                    Spacer(minLength: 8)
                    if unmetCount > 0 {
                        Label(Localization.shared.t("dependencies.missingCount",
                                                     ["count": String(unmetCount)]),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.callout)
                .textCase(nil)
            } footer: {
                environmentFooter
            }
        }
        .listStyle(.inset)
    }

    private var environmentFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label(Localization.shared.t("dependencies.env.homebrew"), systemImage: "mug")
                    .foregroundStyle(state.dependencies.homebrew.isPresent
                                     ? Color(nsColor: .systemGreen) : Color.secondary)
                Label(Localization.shared.t("dependencies.env.macPorts"), systemImage: "shippingbox")
                    .foregroundStyle(state.dependencies.macPorts.isPresent
                                     ? Color(nsColor: .systemGreen) : Color.secondary)
                Label(Localization.shared.t("dependencies.env.arch",
                                             ["arch": HostArchitecture.description]),
                      systemImage: "cpu")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)

            if !state.dependencies.homebrew.isPresent && !state.dependencies.macPorts.isPresent {
                Text(Localization.shared.t("dependencies.env.noPackageManager"))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else if state.dependencies.macPorts.isPresent && !state.dependencies.homebrew.isPresent {
                Text(Localization.shared.t("dependencies.env.macPortsHint"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .font(.caption)
        .textSelection(.enabled)
    }

    // MARK: - 交互

    private var methodBinding: Binding<InstallMethod> {
        Binding(
            get: { selectedMethod ?? state.preferredMethod ?? .macPorts },
            set: { selectedMethod = $0 }
        )
    }

    private func syncPreferredMethod() {
        if let preferred = state.preferredMethod {
            selectedMethod = preferred
        } else {
            selectedMethod = selectedMethod ?? .macPorts
        }
    }

    private func copy(_ command: String) {
        copyToPasteboard(command)
        withAnimation { copiedCommand = command }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run { withAnimation { copiedCommand = nil } }
        }
    }
}

// MARK: - 单条依赖

private struct DependencyRow: View {

    let entry: DependencyEntry
    let method: InstallMethod?
    let copiedCommand: String?
    @Binding var isExpanded: Bool
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 整行做成一个按钮，命中区域可控。不用 DisclosureGroup：展开热区由系统掌管，
            // 放进 List + Section 后点最左侧的小三角没有响应。
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.name)
            .accessibilityValue(statusText)

            if isExpanded {
                guide
                    .padding(.top, 6)
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            // 展开箭头。旋转而不是换成另一个符号，动画才连贯。
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 12)

            Image(systemName: entry.isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(statusTint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // 状态用带底色的小胶囊而不是纯文字：四行并排时
            // 颜色块比小字更快区分「已就绪 / 待安装」。
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusTint.opacity(0.14), in: Capsule())
        }
        // 整行（含中间空白）都可点，而不只是文字与图标本身
        .contentShape(Rectangle())
    }

    private var statusTint: Color {
        if entry.isSatisfied {
            return entry.isOptional ? Color.secondary : Color(nsColor: .systemGreen)
        }
        return entry.isOptional ? Color.secondary : Color(nsColor: .systemOrange)
    }

    private var statusText: String {
        if entry.isSatisfied {
            return entry.isOptional
                ? Localization.shared.t("dependencies.installedOptional")
                : Localization.shared.t("dependencies.installed")
        }
        return entry.isOptional
            ? Localization.shared.t("dependencies.missingOptional")
            : Localization.shared.t("dependencies.missing")
    }

    // MARK: 展开内容

    private var guide: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = entry.warning {
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemOrange))
            }

            if !visibleCommands.isEmpty {
                Text(Localization.shared.t("dependencies.installGuideIntro"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(visibleCommands, id: \.command) { cmd in
                    CommandRow(
                        command: cmd,
                        isCopied: copiedCommand == cmd.command,
                        onCopy: onCopy
                    )
                }
            }

            Text(entry.guide)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 4)
    }

    /// 只展示当前分段选中方式对应的命令；该依赖没有对应命令时展示全部。
    private var visibleCommands: [InstallCommand] {
        guard let method, entry.commands.contains(where: { $0.method == method }) else {
            return entry.commands
        }
        return entry.commands.filter { $0.method == method }
    }
}

// MARK: - 安装命令行（可点击复制）

private struct CommandRow: View {

    let command: InstallCommand
    let isCopied: Bool
    let onCopy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(command.method.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(verbatim: command.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                if let note = command.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Button {
                onCopy(command.command)
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Localization.shared.t("dependencies.copyCommand"))
            .accessibilityLabel(Localization.shared.t("dependencies.copyCommand"))
        }
    }

    private var symbol: String {
        switch command.method {
        case .macPorts: return "shippingbox"
        case .homebrew: return "mug"
        case .direct:   return "terminal"
        }
    }
}
