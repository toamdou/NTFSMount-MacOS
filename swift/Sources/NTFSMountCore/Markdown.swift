import Foundation

// MARK: - 结构

/// 提示框类型。对应 Markdown 的 `> [!NOTE]` 扩展写法。
public enum CalloutKind: String, Sendable {
    case note, tip, important, warning

    /// 从 `[!WARN]` 这类标记解析，未知标记按 NOTE 处理。
    public init(marker: String) {
        switch marker.uppercased() {
        case "TIP", "HINT":                  self = .tip
        case "IMPORTANT":                    self = .important
        case "WARN", "WARNING", "CAUTION":   self = .warning
        default:                             self = .note
        }
    }

    public var titleKey: String {
        switch self {
        case .note:      return "manual.callout.note"
        case .tip:       return "manual.callout.tip"
        case .important: return "manual.callout.important"
        case .warning:   return "manual.callout.warning"
        }
    }

    public var symbolName: String {
        switch self {
        case .note:      return "info.circle.fill"
        case .tip:       return "lightbulb.fill"
        case .important: return "exclamationmark.circle.fill"
        case .warning:   return "exclamationmark.triangle.fill"
        }
    }
}

/// 解析后的内容块。
public enum MarkdownBlock: Sendable {

    /// 标题。level 1 为手册章节，2/3 依次为子级。
    case heading(level: Int, text: String)

    case paragraph(String)

    /// 一组连续的无序列表项（合并渲染才能统一控制间距）。
    case bullet([String])

    /// 有序列表。保留原编号，方便正文里交叉引用「第 2 步」。
    case ordered([(index: Int, text: String)])

    /// 围栏代码块。language 仅用于展示，不做语法高亮。
    case code(language: String?, lines: [String])

    case table(header: [String], rows: [[String]])

    case callout(kind: CalloutKind, lines: [String])

    case divider
}

// MARK: - 解析

public enum Markdown {

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .components(separatedBy: "\n")

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1 // 吃掉收尾的 ```
                blocks.append(.code(language: language.isEmpty ? nil : language, lines: body))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            // 表格：当前行以 | 开头且下一行是分隔行
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                var header = splitTableRow(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                // header 用 var 声明是为了可读性；此处不再修改
                header.removeAll()
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[index].trimmingCharacters(in: .whitespaces)
                    content.removeFirst()
                    quoted.append(content.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(parseCallout(quoted))
                continue
            }

            if bulletItem(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let text = bulletItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(text)
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            if orderedItem(trimmed) != nil {
                var items: [(index: Int, text: String)] = []
                while index < lines.count,
                      let parsed = orderedItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append((index: parsed.0, text: parsed.1))
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isBlockStart(candidate, lines: lines, at: index) { break }
                paragraph.append(candidate)
                index += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: - 行级识别

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        // `#标题` 这种没有空格的写法不算标题
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// 匹配 `1. 内容` / `1) 内容`
    private static func orderedItem(_ line: String) -> (Int, String)? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: " ", with: "")
            return !stripped.isEmpty
                && stripped.allSatisfy { $0 == "-" || $0 == ":" }
                && stripped.contains("-")
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseCallout(_ quoted: [String]) -> MarkdownBlock {
        var kind: CalloutKind = .note
        var body = quoted

        // 首行形如 `[!WARN]`；其余内容为正文
        if let first = body.first,
           first.hasPrefix("[!"), first.hasSuffix("]") {
            kind = CalloutKind(marker: String(first.dropFirst(2).dropLast()))
            body.removeFirst()
        }
        let lines = body
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return .callout(kind: kind, lines: lines)
    }

    /// 判断某行是否会开启一个新块。用于段落收尾。
    private static func isBlockStart(_ line: String, lines: [String], at index: Int) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("```") { return true }
        if line.hasPrefix(">") || line.hasPrefix("|") { return true }
        if line == "---" || line == "***" || line == "___" { return true }
        if bulletItem(line) != nil || orderedItem(line) != nil { return true }
        return false
    }
}

// MARK: - 行内标记

/// 行内片段。渲染层按类型分别呈现，故解析阶段即拆分。
public enum InlineSpan: Sendable, Equatable {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case link(text: String, url: String)
}

public enum InlineMarkdown {

    /// 解析行内标记。手工扫描而非正则（嵌套与转义用正则难写对）。
    public static func parse(_ text: String) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            if !buffer.isEmpty {
                spans.append(.text(buffer))
                buffer = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]

            if character == "*", text[index...].hasPrefix("**") {
                let after = text.index(index, offsetBy: 2)
                if let end = text.range(of: "**", range: after..<text.endIndex) {
                    flushBuffer()
                    spans.append(.bold(String(text[after..<end.lowerBound])))
                    index = end.upperBound
                    continue
                }
            }

            if character == "*" {
                let after = text.index(after: index)
                if let end = text.range(of: "*", range: after..<text.endIndex) {
                    let inner = String(text[after..<end.lowerBound])
                    if !inner.isEmpty, !inner.contains("\n") {
                        flushBuffer()
                        spans.append(.italic(inner))
                        index = end.upperBound
                        continue
                    }
                }
            }

            if character == "`" {
                let after = text.index(after: index)
                if let end = text.range(of: "`", range: after..<text.endIndex) {
                    flushBuffer()
                    spans.append(.code(String(text[after..<end.lowerBound])))
                    index = end.upperBound
                    continue
                }
            }

            if character == "[" {
                if let close = text.range(of: "](", range: index..<text.endIndex),
                   let end = text.range(of: ")", range: close.upperBound..<text.endIndex) {
                    let label = String(text[text.index(after: index)..<close.lowerBound])
                    let url = String(text[close.upperBound..<end.lowerBound])
                    flushBuffer()
                    spans.append(.link(text: label, url: url))
                    index = end.upperBound
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }

        flushBuffer()
        return spans
    }

    /// 去掉行内标记，得到纯文本。用于搜索与无障碍朗读。
    public static func plainText(_ text: String) -> String {
        parse(text).map { span in
            switch span {
            case .text(let value):            return value
            case .bold(let value):            return value
            case .italic(let value):          return value
            case .code(let value):            return value
            case .link(let label, _):         return label
            }
        }.joined()
    }
}
