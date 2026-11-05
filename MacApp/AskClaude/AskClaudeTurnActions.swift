import AppKit
import Design
import SwiftUI

/// What a turn in the thread offers: Copy on a question or an answer, Edit on a question
/// typed in the box, Retry on the last answer.
enum AskClaudeTurnAction: Hashable, Identifiable {
    case copy, edit, retry

    var id: Self { self }

    var title: String {
        switch self {
        case .copy: "Copy"
        case .edit: "Edit"
        case .retry: "Retry"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .edit: "pencil"
        case .retry: "arrow.clockwise"
        }
    }

    var help: String {
        switch self {
        case .copy: "Copies it, with any table as a table"
        case .edit: "Puts the question back in the box. Sending it takes back everything after it."
        case .retry: "Asks the question again in its place"
        }
    }
}

/// The thread's turns: which question each row answers, and which questions were
/// answered in words. A row before any question (a note) belongs to none.
struct AskClaudeTurns {
    private var questionOf: [UUID: UUID] = [:]
    private(set) var answered: Set<UUID> = []

    init(_ items: [AskClaudeChat.Item]) {
        var current: UUID?
        for item in items {
            if case .user = item.kind {
                current = item.id
                continue
            }
            guard let current else { continue }
            questionOf[item.id] = current
            if case .assistant(let text) = item.kind, !text.isEmpty { answered.insert(current) }
        }
    }

    func question(of item: AskClaudeChat.Item) -> UUID? { questionOf[item.id] }

    /// What hovering the row shows the bar of: a question's own, or the answer's for any of its rows.
    func hoverKey(of item: AskClaudeChat.Item) -> AskClaudeHoverKey? {
        if case .user = item.kind { return .question(item.id) }
        return questionOf[item.id].map { .answer($0) }
    }
}

/// A question's bar, or the bar of the answer to it.
enum AskClaudeHoverKey: Hashable {
    case question(UUID)
    case answer(UUID)
}

/// A question's bar, beside its bubble on the left while hovered: under the bubble it covered the
/// answer's first line, and over it, the question.
struct AskClaudeBarBeside<Bar: View>: ViewModifier {
    let shows: Bool
    @ViewBuilder let bar: () -> Bar
    @Environment(\.appFontScale) private var scale

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                // The guide goes on the group: set inside the `if`, SwiftUI drops it, and the bar
                // lands on the bubble's text.
                Group { if shows { bar() } }
                    .alignmentGuide(.leading) { $0[.trailing] + 4 }
            }
            // Room for it beside a question as wide as the panel; it grows with the text size.
            .padding(.leading, 48 * scale)
    }
}

/// The small bar of a turn's actions, shown while the turn is hovered: icons only, their names in
/// the tooltips. The same actions are on its right-click menu and VoiceOver's actions, for anyone
/// who doesn't hover.
struct AskClaudeTurnBar: View {
    let actions: [AskClaudeTurnAction]
    let perform: (AskClaudeTurnAction) -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    perform(action)
                    guard action == .copy else { return }
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(action == .copy && copied ? "Copied" : action.title,
                          systemImage: action == .copy && copied ? "checkmark" : action.symbol)
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(action.help)
            }
        }
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
}

/// An answer copied: plain text, HTML and RTF on one pasteboard item, from the blocks
/// `AskClaudeMarkdown` makes, so a table pastes into Numbers as cells and into Mail or Pages as a
/// table.
enum AskClaudeAnswerCopy {
    /// Puts `markdown`, an answer as Claude wrote it, on `pasteboard`.
    static func write(_ markdown: String, to pasteboard: NSPasteboard = .general) {
        let blocks = AskClaudeMarkdown.blocks(markdown)
        let html = html(blocks)
        let item = NSPasteboardItem()
        item.setString(plainText(blocks), forType: .string)
        item.setString(html, forType: .html)
        if let rtf = rtf(fromHTML: html) { item.setData(rtf, forType: .rtf) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// A question copied: its words, as plain text.
    static func write(question: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(question, forType: .string)
    }

    /// Paragraphs apart, list items a line each with their marker, a table as tab-separated rows.
    static func plainText(_ blocks: [AskClaudeMarkdown.Block]) -> String {
        var out = ""
        var previousInList = false
        for block in blocks {
            let inList = block.depth > 0
            if !out.isEmpty { out += inList && previousInList ? "\n" : "\n\n" }
            previousInList = inList
            let indent = String(repeating: "    ", count: max(0, block.depth - 1))
            let lead = block.marker.map { $0 + " " } ?? (inList ? "  " : "")
            let quote = block.quoted ? "> " : ""
            switch block.kind {
            case .text(let text), .heading(let text):
                out += indent + quote + lead + String(text.characters)
            case .code(let code):
                out += code
            case .table(let table):
                out += ([table.header] + table.rows).map { row in row.map { String($0.characters) }.joined(separator: "\t") }
                    .joined(separator: "\n")
            case .rule:
                out += "———"
            }
        }
        return out
    }

    /// The same blocks as a small HTML document: tables as tables, code as `pre`, the answer's own
    /// links as plain text (they reveal files in this app, nowhere else).
    static func html(_ blocks: [AskClaudeMarkdown.Block]) -> String {
        var body = ""
        for block in blocks {
            // Unquoted attribute values: the app-wide copy scan reads any straight quote as a typo.
            let margin = block.depth > 1 ? " style=margin-left:\(Double(block.depth - 1) * 1.5)em" : ""
            let lead = block.marker.map { escape($0) + " " } ?? ""
            var piece: String
            switch block.kind {
            case .text(let text):
                piece = "<p\(margin)>\(lead)\(inline(text))</p>"
            case .heading(let text):
                piece = "<p\(margin)><b>\(inline(text))</b></p>"
            case .code(let code):
                piece = "<pre>\(escape(code))</pre>"
            case .table(let table):
                let head = table.header.map { "<th>\(inline($0))</th>" }.joined()
                let rows = table.rows.map { row in "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                piece = "<table><thead><tr>\(head)</tr></thead><tbody>\(rows)</tbody></table>"
            case .rule:
                piece = "<hr>"
            }
            if block.quoted { piece = "<blockquote>\(piece)</blockquote>" }
            body += piece + "\n"
        }
        return "<html><head><meta charset=utf-8></head><body>\n\(body)</body></html>"
    }

    /// A run of text with its bold, italic, code and struck-through kept.
    private static func inline(_ text: AttributedString) -> String {
        text.runs.map { run in
            var piece = escape(String(text[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<b>\(piece)</b>" }
            if intent.contains(.emphasized) { piece = "<i>\(piece)</i>" }
            if intent.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
            return piece
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// RTF for apps that read only that, made by AppKit's own HTML reader: tables become text tables.
    static func rtf(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil)
        else { return nil }
        return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }
}
