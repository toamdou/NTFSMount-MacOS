import SwiftUI
import NTFSMountCore

// MARK: - ⌘, 设置窗口

public struct SettingsScene: View {

    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            GeneralSettings(state: state)
                .tabItem { Label(Localization.shared.t("settings.title"), systemImage: "gearshape") }
            AboutSettings(state: state)
                .tabItem { Label(Localization.shared.t("menu.about"), systemImage: "info.circle") }
        }
        // 默认高度需容纳全部四组控件：分组表单虽可滚动，但默认尺寸下要滚动才能看全，
        // 容易让人以为设置项就那么几个。
        .frame(width: 560, height: 560)
    }
}

// MARK: - 通用

struct GeneralSettings: View {

    @ObservedObject var state: AppState

    /// 密码输入框的内容。只活在这个视图里，唯一的去处是钥匙串。
    @State private var passwordField = ""

    private var settings: SettingsStore { state.settings }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: boolBinding(\.autoMount)) {
                    settingLabel("settings.autoMount", detail: "settings.autoMountDesc")
                }

                Toggle(isOn: boolBinding(\.enableLogs)) {
                    settingLabel("settings.enableLogs", detail: "settings.enableLogsDesc")
                }
            } header: {
                Text(Localization.shared.t("settings.general"))
            }

            Section {
                Toggle(isOn: preventSleepBinding) {
                    settingLabel("settings.preventSleep", detail: "settings.preventSleepDesc")
                }

                Toggle(isOn: launchAtLoginBinding) {
                    settingLabel("settings.autoStart", detail: "settings.autoStartDesc")
                }

                if state.launchAtLoginNeedsApproval {
                    Label(Localization.shared.t("settings.autoStartApproval"),
                          systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }

                Toggle(isOn: boolBinding(\.silentLaunch)) {
                    settingLabel("settings.silentLaunch", detail: "settings.silentLaunchDesc")
                }

                Toggle(isOn: boolBinding(\.mountOnLaunch)) {
                    settingLabel("settings.mountOnLaunch", detail: "settings.mountOnLaunchDesc")
                }

                passwordControls
            } header: {
                Text(Localization.shared.t("settings.system"))
            }

            Section {
                Picker(Localization.shared.t("settings.ioSize._title"),
                       selection: ioSizeBinding) {
                    ForEach(IOBlockSize.allCases) { size in
                        Text(Localization.shared.t(size.titleKey)).tag(size)
                    }
                }
                Text(Localization.shared.t("settings.ioSize.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(Localization.shared.t("settings.mountSection"))
            }

            Section {
                Picker(Localization.shared.t("settings.startupTab"),
                       selection: tabBinding) {
                    ForEach(AppState.navigationTabs) { tab in
                        Label(Localization.shared.t(tab.titleKey), systemImage: tab.symbolName)
                            .tag(tab)
                    }
                }

                Picker(Localization.shared.t("settings.language"),
                       selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            } header: {
                Text(Localization.shared.t("settings.title"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            state.refreshLaunchAtLoginState()
            state.refreshSavedPasswordState()
        }
    }

    // MARK: - 管理员密码

    /// 「保存管理员密码」控件。三层状态（关着 / 开着未存密码 / 开着且有密码）必须分开显示，否则用户会误以为已生效。
    @ViewBuilder
    private var passwordControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: savePasswordBinding) {
                settingLabel("settings.savePassword", detail: "settings.savePasswordDesc")
            }

            if settings.settings.savePassword {
                if state.savedPasswordExists {
                    HStack(spacing: 6) {
                        Label(Localization.shared.t("settings.passwordStored"),
                              systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemGreen))

                        Spacer(minLength: 8)

                        Button(Localization.shared.t("settings.deletePassword")) {
                            state.deleteAdminPassword()
                            passwordField = ""
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        SecureField(Localization.shared.t("settings.passwordPlaceholder"),
                                    text: $passwordField)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitPassword() }

                        Button(Localization.shared.t("settings.passwordSaveButton")) {
                            commitPassword()
                        }
                        .controlSize(.small)
                        .disabled(passwordField.isEmpty)
                    }

                    Text(Localization.shared.t("settings.passwordNotStored"))
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }

            if let notice = state.passwordNotice {
                Label(notice.text,
                      systemImage: notice.kind == .success
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(notice.kind == .success
                        ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitPassword() {
        let typed = passwordField
        passwordField = ""
        Task { await state.saveAdminPassword(typed) }
    }

    /// 主标题 + 次级说明的两段式标签。
    private func settingLabel(_ titleKey: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Localization.shared.t(titleKey))
            Text(Localization.shared.t(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.settings[keyPath: keyPath] },
            set: { value in settings.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// 关掉开关的同时把钥匙串里的密码一起删掉。
    private var savePasswordBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.savePassword },
            set: { on in
                state.passwordNotice = nil
                if on {
                    settings.update { $0.savePassword = true }
                    state.refreshSavedPasswordState()
                } else {
                    state.deleteAdminPassword()
                    passwordField = ""
                }
            }
        )
    }

    private var ioSizeBinding: Binding<IOBlockSize> {
        Binding(
            get: { settings.settings.ioBlockSize },
            set: { size in settings.update { $0.ioBlockSize = size } }
        )
    }

    private var tabBinding: Binding<AppTab> {
        Binding(
            get: { settings.settings.startupTab },
            set: { tab in settings.update { $0.startupTab = tab } }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settings.language },
            set: { settings.language = $0 }
        )
    }

    private var preventSleepBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.preventSleep },
            set: { state.setPreventSleep($0) }
        )
    }

    /// 以系统登录项状态为准，而不是设置文件里的值。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.launchAtLoginEnabled },
            set: { state.setLaunchAtLogin($0) }
        )
    }
}

// MARK: - 关于

struct AboutSettings: View {

    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                        .frame(width: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name)
                            .font(.title3.weight(.semibold))
                        Text("\(Localization.shared.t("about.version")) \(AppInfo.versionWithBuild)")
                            .foregroundStyle(.secondary)
                        Text(Localization.shared.t("settings.nativeNote"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent(Localization.shared.t("about.environment")) {
                    Text(verbatim: AppInfo.environment)
                }
                LabeledContent(Localization.shared.t("about.minimumSystem")) {
                    Text(verbatim: "macOS \(AppInfo.minimumSystemVersion)+")
                }
            }

            Section {
                ForEach((1...3).map { Localization.shared.t("help.about.\($0)") }, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                Text(Localization.shared.title("help.about"))
            }
        }
        .formStyle(.grouped)
    }
}
