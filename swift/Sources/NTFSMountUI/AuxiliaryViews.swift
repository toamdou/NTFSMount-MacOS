import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NTFSMountCore

// MARK: - 操作日志

struct LogsView: View {

    @ObservedObject var state: AppState

    @State private var searchText = ""

    private var logStore: LogStore { state.logStore }

    private var filtered: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return logStore.entries }
        return logStore.entries.filter {
            $0.message.lowercased().contains(query) || $0.formattedTime.contains(query)
        }
    }

    var body: some View {
        Group {
            if logStore.entries.isEmpty {
                ContentUnavailableView {
                    Label(Localization.shared.t("logs.empty"), systemImage: "list.bullet.rectangle")
                } description: {
                    Text(Localization.shared.t("logs.disabled"))
                }
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(state: state) }
        .searchable(text: $searchText, placement: .toolbar, prompt: Localization.shared.t("logs.title"))
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(
                    get: { state.settings.settings.enableLogs },
                    set: { on in state.settings.update { $0.enableLogs = on } }
                )) {
                    Label(Localization.shared.t("settings.enableLogs"), systemImage: "list.bullet.rectangle")
                }
                .toggleStyle(.switch)
                .help(Localization.shared.t("settings.enableLogs"))

                Button {
                    export()
                } label: {
                    Label(Localization.shared.t("settings.exportLogs"), systemImage: "square.and.arrow.up")
                }
                .disabled(logStore.entries.isEmpty)
                .help(Localization.shared.t("settings.exportLogs"))

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Label(Localization.shared.t("logs.clear"), systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)
                .help(Localization.shared.t("logs.clear"))
            }
        }
    }

    private var list: some View {
        List(filtered) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: entry.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                Image(systemName: entry.type.symbolName)
                    .foregroundStyle(color(for: entry.type))
                    .font(.caption)

                Text(verbatim: entry.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func color(for type: LogType) -> Color {
        switch type {
        case .info:    return .secondary
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .error:   return Color(nsColor: .systemRed)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "NTFSMount-logs.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? logStore.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 可复制的命令行

/// 点击右侧按钮把整行命令复制到剪贴板。
struct CopyableCommand: View {

    let command: String

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: command)
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

            Button {
                copyToPasteboard(command)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    await MainActor.run { withAnimation { copied = false } }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Localization.shared.t("dependencies.copyCommand"))
        }
    }
}
