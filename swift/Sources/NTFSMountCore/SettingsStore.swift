import Foundation
import Combine

public final class SettingsStore: ObservableObject {

    @Published public var settings: AppSettings {
        didSet { persist() }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ntfsmount.settings", qos: .utility)

    public init() {
        let dir = Self.defaultFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = Self.defaultFileURL

        settings = Self.load(from: fileURL) ?? AppSettings()
        Localization.shared.setLanguage(settings.language)
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NTFSMount", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public static func silentLaunchRequested() -> Bool {
        (load(from: defaultFileURL) ?? AppSettings()).silentLaunch
    }

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func persist() {
        let snapshot = settings
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 便捷访问

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    public var language: AppLanguage {
        get { settings.language }
        set {
            update { $0.language = newValue }
            Localization.shared.setLanguage(newValue)
        }
    }
}
