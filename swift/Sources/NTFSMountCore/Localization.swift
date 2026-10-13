import Foundation

public final class Localization: @unchecked Sendable {

    public static let shared = Localization()

    /// 随包提供的语言代码。顺序即回退优先级。
    public static let supportedCodes = ["en", "zh-CN", "zh-TW", "ja", "de"]

    /// 启动自检与排障用的运行期诊断。
    public struct Diagnostics: Sendable {
        /// 语言代码 → 实际命中的文件路径
        public var loadedFrom: [String: String] = [:]
        /// 语言代码 → 词条数
        public var entryCount: [String: Int] = [:]
        /// 查表失败的 key 集合
        public var missingKeys: Set<String> = []
        /// 一个语言都没加载到 —— 说明产物缺资源，界面会大面积退化
        public var isResourceMissing: Bool { loadedFrom.isEmpty }
    }

    private var table: [String: String] = [:]
    private let lock = NSLock()
    private var currentLanguage: AppLanguage = .system
    private var diag = Diagnostics()

    private init() {
        load(language: .system)
    }

    /// 载入指定语言。缺失则回退到英文，再回退到由 key 推导的可读文案。
    public func load(language: AppLanguage) {
        lock.lock()
        defer { lock.unlock() }
        currentLanguage = language

        var merged: [String: String] = [:]
        var loaded: [String: String] = [:]
        var counts: [String: Int] = [:]

        // 1) 英文兜底，保证任何 key 都有值
        if let (flat, path) = Self.loadResource("en") {
            merged.merge(flat) { _, new in new }
            loaded["en"] = path
            counts["en"] = flat.count
        }

        // 2) 用户显式选择的语言优先级最高，最后合并以覆盖英文。
        let code = Self.code(for: language)
        let systemCode = Self.systemLanguageCode()
        let effective: String? = {
            if let code { return code == "en" ? nil : code }
            return systemCode == "en" ? nil : systemCode
        }()

        if let effective, let (flat, path) = Self.loadResource(effective) {
            merged.merge(flat) { _, new in new }
            loaded[effective] = path
            counts[effective] = flat.count
        }

        table = merged
        diag.loadedFrom = loaded
        diag.entryCount = counts

        // 一个语言包都没找到：产物或安装包缺资源。
        if merged.isEmpty {
            FileHandle.standardError.write(Data(
                ("[NTFSMount] 致命：未找到任何语言包，界面文案将退化为 key 推导值。"
                 + "已搜索 bundle：\(ResourceLocator.candidateBundles().map(\.bundlePath).joined(separator: ", "))\n"
                ).utf8))
        }
    }

    // MARK: - 查表

    /// 查表。缺失时返回由 key 推导的可读文案（绝不返回裸 key）。
    public func t(_ key: String) -> String {
        t(key, [:])
    }

    /// 带参数查表，占位符形如 `{name}`。
    public func t(_ key: String, _ params: [String: String]) -> String {
        guard var value = lookup(key) else { return fallback(key) }
        for (k, v) in params {
            value = value.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return value
    }

    /// 分组标题。优先 `<key>._title`，回退 `<key>`。
    public func title(_ key: String) -> String {
        if let v = lookup(key + "._title") { return v }
        if let v = lookup(key) { return v }
        return fallback(key)
    }

    /// 是否存在该 key。构造动态 key 时用来判断，避免拿到兜底值。
    public func has(_ key: String) -> Bool {
        lookup(key) != nil
    }

    private func lookup(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = table[key] { return hit }
        diag.missingKeys.insert(key)
        return nil
    }

    /// 缺失回退：把 key 的末段转成可读文案，如 `devices.mountAll` → `Mount All`。
    private func fallback(_ key: String) -> String {
        var segment = key.split(separator: ".").last.map(String.init) ?? key
        if segment.hasPrefix("_") { segment.removeFirst() }
        guard !segment.isEmpty else { return key }

        // camelCase / snake_case / kebab-case 拆词
        var words: [String] = []
        var current = ""
        for ch in segment {
            if ch == "_" || ch == "-" {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isUppercase, !current.isEmpty {
                words.append(current); current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }

        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - 状态

    public func setLanguage(_ language: AppLanguage) {
        load(language: language)
    }

    public var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return currentLanguage
    }

    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return diag
    }

    // MARK: - 语言解析

    private static func code(for language: AppLanguage) -> String? {
        switch language {
        case .system: return nil
        case .zhCN:   return "zh-CN"
        case .zhTW:   return "zh-TW"
        case .ja:     return "ja"
        case .en:     return "en"
        case .de:     return "de"
        }
    }

    /// 把系统首选语言映射到随包提供的代码之一。
    private static func systemLanguageCode() -> String {
        resolve(preferredLanguage: Locale.preferredLanguages.first ?? "en")
    }

    /// 首选语言标签 → 随包语言代码。
    public static func resolve(preferredLanguage raw: String) -> String {
        if raw.hasPrefix("zh") {
            // 顺序很关键：先看显式脚本标记，再看地区（`zh-Hans-HK` 同时含两者）。
            if raw.contains("Hans") { return "zh-CN" }
            if raw.contains("Hant") { return "zh-TW" }
            // 无脚本标记时才看地区：港澳台用繁体
            if raw.contains("-TW") || raw.contains("-HK") || raw.contains("-MO") {
                return "zh-TW"
            }
            return "zh-CN"
        }
        let primary = raw.split(separator: "-").first.map(String.init) ?? "en"
        return supportedCodes.contains(primary) ? primary : "en"
    }

    /// 当前实际生效的语言代码（已解析「跟随系统」）。
    public static func resolvedSystemCode() -> String {
        systemLanguageCode()
    }

    // MARK: - 资源加载

    /// 按语言代码载入 JSON。返回（扁平表, 文件路径）。
    private static func loadResource(_ code: String) -> ([String: String], String)? {
        guard let url = ResourceLocator.locate("\(code).json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (flatten(json: obj), url.path)
    }

    /// 把嵌套 JSON 压平成 "a.b.c" → value。数组标题存 `<key>._title`，避免与 `<key>.1` 冲突。
    private static func flatten(json: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in json {
            let full = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let s = value as? String {
                out[full] = s
            } else if let dict = value as? [String: Any] {
                out.merge(flatten(json: dict, prefix: full)) { _, new in new }
            } else if let array = value as? [Any] {
                for (index, element) in array.enumerated() {
                    if let s = element as? String {
                        out["\(full).\(index + 1)"] = s
                    } else if let dict = element as? [String: Any] {
                        out.merge(flatten(json: dict, prefix: "\(full).\(index + 1)")) { _, new in new }
                    }
                }
            }
        }
        return out
    }
}
