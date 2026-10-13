import Foundation
import Combine

@MainActor
public final class LogStore: ObservableObject {

    @Published public private(set) var entries: [LogEntry] = []
    @Published public var isEnabled: Bool = false {
        didSet { if isEnabled { save() } }
    }

    private let fileURL: URL
    private let maxEntries = 2000
    private let retentionDays = 30

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("NTFSMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("logs.json")

        // 默认关闭写入，但仍加载历史记录供查看
        load()
    }

    // MARK: - 写入

    public func add(_ message: String, type: LogType = .info) {
        guard isEnabled else { return }
        entries.append(LogEntry(message: message, type: type))
        trim()
    }

    private func trim() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        purgeOld()
    }

    private func purgeOld() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let before = entries.count
        entries.removeAll { $0.time < cutoff }
        if entries.count != before { save() }
    }

    // MARK: - 持久化

    private func save() {
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data)
        else { return }
        purgeOld()
        entries = decoded.sorted { $0.time < $1.time }
    }

    // MARK: - 导出

    public func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { entry in
            "[\(formatter.string(from: entry.time))] [\(entry.type.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    public func clear() {
        entries.removeAll()
        save()
    }
}
