import SwiftUI
import AppKit
import NTFSMountCore

struct ManualView: View {

    @ObservedObject var state: AppState

    @State private var document: ManualDocument
    @State private var selectedChapter: Int?
    @State private var searchText = ""

    init(state: AppState) {
        self.state = state
        // 首次构造时同步载入，避免先闪一帧空页面
        _document = State(initialValue: Manual.load(language: Localization.shared.language))
    }

    /// 搜索过滤后的章节。空查询返回全部。
    private var visibleChapters: [ManualChapter] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return document.chapters }
        return document.chapters.filter { $0.searchText.lowercased().contains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            tableOfContents
            Divider()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(state: state) }
        // 语言切换后重新载入对应语言的手册
        .id(state.localeToken)
        .onChange(of: state.localeToken) { _, _ in
            document = Manual.load(language: Localization.shared.language)
            selectedChapter = nil
        }
    }

    // MARK: - 目录

    private var tableOfContents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "book")
                    .foregroundStyle(.secondary)
                Text(Localization.shared.t("manual.toc"))
                    .font(.headline)
                Spacer(minLength: 0)
                Text(Localization.shared.t("manual.chapterCount",
                                           ["count": String(visibleChapters.count)]))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if visibleChapters.isEmpty {
                Spacer()
                Text(Localization.shared.t("manual.noResults"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                List(selection: $selectedChapter) {
                    ForEach(visibleChapters) { chapter in
                        Text(chapter.title)
                            .lineLimit(2)
                            .tag(chapter.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 208)
        .searchable(text: $searchText, placement: .sidebar,
                    prompt: Localization.shared.t("manual.search"))
    }

    // MARK: - 正文

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(visibleChapters) { chapter in
                        chapterView(chapter)
                            .id(chapter.id)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: selectedChapter) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(newValue, anchor: .top)
                }
            }
        }
    }

    private func chapterView(_ chapter: ManualChapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chapter.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)

            ForEach(Array(chapter.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }
}

// MARK: - 单个块

struct BlockView: View {

    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(InlineMarkdown.attributed(text))
                .font(level <= 3 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(level <= 3 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.top, level <= 3 ? 6 : 2)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(InlineMarkdown.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                            .foregroundStyle(.tertiary)
                        Text(InlineMarkdown.attributed(item))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.index) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.index).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(InlineMarkdown.attributed(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)

        case .code(let language, let lines):
            CommandBlock(language: language, lines: lines)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)

        case .callout(let kind, let lines):
            CalloutBox(kind: kind, lines: lines)

        case .divider:
            Divider().padding(.vertical, 2)
        }
    }
}

// MARK: - 命令块

/// 等宽命令块，右上角提供复制按钮。
private struct CommandBlock: View {

    let language: String?
    let lines: [String]

    @State private var copied = false

    private var command: String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                copyToPasteboard(command)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .help(Localization.shared.t(copied ? "manual.copied" : "manual.copyCommand"))
            .accessibilityLabel(Localization.shared.t("manual.copyCommand"))
        }
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - 表格

private struct MarkdownTable: View {

    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { index in
                    cell(header.indices.contains(index) ? header[index] : "",
                         isHeader: true)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Divider()
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        cell(row.indices.contains(index) ? row[index] : "",
                             isHeader: false)
                    }
                }
                .background(rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.vertical, 2)
    }

    private func cell(_ text: String, isHeader: Bool) -> some View {
        Text(InlineMarkdown.attributed(text))
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
}

// MARK: - 提示框

private struct CalloutBox: View {

    let kind: CalloutKind
    let lines: [String]

    private var tint: Color {
        switch kind {
        case .note:      return Color(nsColor: .systemBlue)
        case .tip:       return Color(nsColor: .systemGreen)
        case .important: return Color(nsColor: .systemPurple)
        case .warning:   return Color(nsColor: .systemOrange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbolName)
                .foregroundStyle(tint)
                .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                Text(Localization.shared.t(kind.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(InlineMarkdown.attributed(line))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - 行内标记渲染

extension InlineMarkdown {

    /// 把行内片段转成带属性的字符串，交给系统 Text 渲染。
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        for span in parse(text) {
            switch span {
            case .text(let value):
                out += AttributedString(value)

            case .bold(let value):
                var piece = AttributedString(value)
                piece.inlinePresentationIntent = .stronglyEmphasized
                out += piece

            case .italic(let value):
                var piece = AttributedString(value)
                piece.inlinePresentationIntent = .emphasized
                out += piece

            case .code(let value):
                var piece = AttributedString(value)
                piece.font = .system(.body, design: .monospaced)
                piece.foregroundColor = .primary
                piece.backgroundColor = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                out += piece

            case .link(let label, let url):
                var piece = AttributedString(label)
                piece.link = URL(string: url)
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
                out += piece
            }
        }
        return out
    }
}
