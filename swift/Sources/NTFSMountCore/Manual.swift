import Foundation

// MARK: - 文档模型

public struct ManualChapter: Identifiable, Sendable {
    /// 章节在文档中的序号，同时用作锚点 id。
    public let id: Int
    public let title: String
    public let blocks: [MarkdownBlock]

    /// 章节正文的纯文本。用于搜索命中并给列表做摘要。
    public var searchText: String {
        let body = blocks.map { block -> String in
            switch block {
            case .heading(_, let text):            return text
            case .paragraph(let text):             return InlineMarkdown.plainText(text)
            case .bullet(let items):               return items.map(InlineMarkdown.plainText).joined(separator: " ")
            case .ordered(let items):              return items.map { InlineMarkdown.plainText($0.text) }.joined(separator: " ")
            case .code(_, let lines):              return lines.joined(separator: " ")
            case .table(let header, let rows):     return (header + rows.flatMap { $0 }).joined(separator: " ")
            case .callout(_, let lines):           return lines.map(InlineMarkdown.plainText).joined(separator: " ")
            case .divider:                         return ""
            }
        }.joined(separator: "\n")
        return "\(title)\n\(body)"
    }
}

public struct ManualDocument: Sendable {

    public let title: String
    public let chapters: [ManualChapter]
    public let languageCode: String
    /// 手册文件缺失、内容由兜底生成
    public let isFallback: Bool

    public var isEmpty: Bool { chapters.isEmpty }
}

// MARK: - 加载

public enum Manual {

    /// 语言代码 → 手册文件名
    private static func fileName(for code: String) -> String {
        "help.\(code).md"
    }

    /// 载入指定语言的手册。回退顺序：请求语言 → 英文 → 内置极简说明。
    public static func load(language: AppLanguage) -> ManualDocument {
        let requested = languageCode(for: language)

        for code in [requested, "en"] {
            guard let code,
                  let url = ResourceLocator.locate(fileName(for: code)),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.isEmpty else { continue }
            let document = parse(text, languageCode: code, isFallback: false)
            if !document.isEmpty { return document }
        }

        return fallbackDocument()
    }

    /// 切分章节：`##` 为章节，首个 `#` 为文档标题，`###` 及更深保留层级。
    static func parse(_ text: String, languageCode: String, isFallback: Bool) -> ManualDocument {
        let blocks = Markdown.parse(text)

        var documentTitle = Localization.shared.t("manual.title")
        var chapters: [ManualChapter] = []
        var currentTitle: String?
        var currentBlocks: [MarkdownBlock] = []

        func commit() {
            guard let title = currentTitle else { return }
            chapters.append(ManualChapter(id: chapters.count,
                                          title: title,
                                          blocks: currentBlocks))
            currentTitle = nil
            currentBlocks = []
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text) where level == 1 && currentTitle == nil && chapters.isEmpty:
                // 文档标题，仅取第一个
                documentTitle = text

            case .heading(let level, let text) where level <= 2:
                commit()
                currentTitle = text

            default:
                if currentTitle == nil {
                    // 章节出现之前的引言，归到「概览」章节
                    currentTitle = Localization.shared.t("manual.overview")
                }
                currentBlocks.append(block)
            }
        }
        commit()

        return ManualDocument(title: documentTitle,
                              chapters: chapters,
                              languageCode: languageCode,
                              isFallback: isFallback)
    }

    private static func languageCode(for language: AppLanguage) -> String? {
        switch language {
        case .system:
            // 复用 Localization 的解析，不要在这里复制判定规则（否则两处会分叉）。
            return Localization.resolvedSystemCode()
        case .zhCN: return "zh-CN"
        case .zhTW: return "zh-TW"
        case .ja:   return "ja"
        case .en:   return "en"
        case .de:   return "de"
        }
    }

    /// 兜底文档：手册文件缺失时至少告诉用户去哪找完整说明。
    private static func fallbackDocument() -> ManualDocument {
        let chapter = ManualChapter(
            id: 0,
            title: Localization.shared.t("manual.title"),
            blocks: [
                .paragraph(Localization.shared.t("manual.loadError")),
                .bullet([
                    Localization.shared.t("manual.fallback.1"),
                    Localization.shared.t("manual.fallback.2"),
                ]),
            ])
        return ManualDocument(title: Localization.shared.t("manual.title"),
                              chapters: [chapter],
                              languageCode: "en",
                              isFallback: true)
    }
}
