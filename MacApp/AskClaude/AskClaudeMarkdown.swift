import AppKit
import Design
import SwiftUI

/// An answer's markdown as the blocks the panel draws (TE298): paragraphs, headings, list items,
/// code blocks, tables and rules. Foundation's own parser reads it; this only regroups its runs.
enum AskClaudeMarkdown {
    struct Block: Equatable, Identifiable {
        enum Kind: Equatable {
            case text(AttributedString)
            /// Drawn as a bold line: no big type in a panel this narrow.
            case heading(AttributedString)
            case code(String)
            case table(Table)
            case rule
        }

        /// Its place in the answer, which a growing answer keeps.
        let id: Int
        var kind: Kind
        /// How many lists it sits in; 0 outside any.
        var depth = 0
        /// "•" or "3." where it begins a list item; nil for a later block in the same item.
        var marker: String?
        var quoted = false
    }

    struct Table: Equatable {
        var alignments: [HorizontalAlignment]
        var header: [AttributedString]
        var rows: [[AttributedString]]
    }

    static func blocks(_ text: String) -> [Block] {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else {
            return text.isEmpty ? [] : [Block(id: 0, kind: .text(AttributedString(text)))]
        }
        // Runs grouped by the block they belong to: a table's whole, anything else its innermost.
        var groups: [[(intent: PresentationIntent?, piece: AttributedString)]] = []
        var lastKey: Int?
        for run in parsed.runs {
            let intent = run.presentationIntent
            let key = tableIntent(intent)?.identity ?? intent?.components.first?.identity ?? -1
            var piece = AttributedString(parsed[run.range])
            // A single newline in the answer stays a line break, as it was before blocks.
            if run.inlinePresentationIntent?.contains(.softBreak) == true { piece = AttributedString("\n") }
            piece.presentationIntent = nil
            if key == lastKey, !groups.isEmpty {
                groups[groups.count - 1].append((intent, piece))
            } else {
                groups.append([(intent, piece)])
            }
            lastKey = key
        }

        var blocks: [Block] = []
        var startedItems: Set<Int> = []
        for group in groups {
            let intent = group.first?.intent
            let components = intent?.components ?? []
            let joined = group.reduce(into: AttributedString()) { $0.append($1.piece) }
            let kind: Block.Kind
            if let table = tableIntent(intent) {
                kind = .table(assemble(table, from: group))
            } else {
                switch components.first?.kind {
                case .header?: kind = .heading(emboldened(joined))
                case .codeBlock?:
                    var code = String(joined.characters)
                    if code.hasSuffix("\n") { code.removeLast() }
                    kind = .code(code)
                case .thematicBreak?: kind = .rule
                default: kind = .text(joined)
                }
            }
            var block = Block(id: blocks.count, kind: kind)
            let items = components.filter { if case .listItem = $0.kind { true } else { false } }
            block.depth = items.count
            if let item = items.first, !startedItems.contains(item.identity),
               case .listItem(let ordinal) = item.kind {
                let ordered = components.drop { $0.identity != item.identity }.dropFirst().first
                    .map { if case .orderedList = $0.kind { true } else { false } } ?? false
                block.marker = ordered ? "\(ordinal)." : (items.count == 1 ? "•" : "◦")
            }
            startedItems.formUnion(items.map(\.identity))
            block.quoted = components.contains { if case .blockQuote = $0.kind { true } else { false } }
            blocks.append(block)
        }
        return blocks
    }

    /// The table `intent` sits in, if any.
    private static func tableIntent(_ intent: PresentationIntent?) -> PresentationIntent.IntentType? {
        intent?.components.first { if case .table = $0.kind { true } else { false } }
    }

    private static func assemble(_ table: PresentationIntent.IntentType, from runs: [(intent: PresentationIntent?, piece: AttributedString)]) -> Table {
        guard case .table(let columns) = table.kind else { return Table(alignments: [], header: [], rows: []) }
        var header = Array(repeating: AttributedString(), count: columns.count)
        var rows: [Int: [AttributedString]] = [:]
        for (intent, piece) in runs {
            guard let components = intent?.components else { continue }
            var column: Int?
            var row: Int?
            for component in components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow: row = 0
                case .tableRow(let index): row = index
                default: break
                }
            }
            guard let column, let row, column < columns.count else { continue }
            if row == 0 {
                header[column].append(piece)
            } else {
                rows[row, default: Array(repeating: AttributedString(), count: columns.count)][column].append(piece)
            }
        }
        let alignments: [HorizontalAlignment] = columns.map {
            switch $0.alignment {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        return Table(alignments: alignments, header: header, rows: rows.keys.sorted().map { rows[$0]! })
    }

    /// `text` with every run strong, as `**text**` would be.
    private static func emboldened(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        }
        return text
    }

    /// `text` as far as it can be drawn while more is still arriving: without a last line that is
    /// so far only a list, heading, quote or fence marker, and without table lines whose header
    /// and divider haven't both arrived. So the answer grows without a half-written table showing
    /// as pipes, or a bullet's dash showing as a dash, for a moment.
    static func settled(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last {
            let marker = last.trimmingCharacters(in: .whitespaces)
            let markerOnly = !marker.isEmpty && (marker.allSatisfy { "-*+=_~`#>|".contains($0) }
                || marker.wholeMatch(of: /\d{1,9}[.)]?/) != nil)
            if markerOnly || marker.hasPrefix("```") || marker.hasPrefix("~~~") { lines.removeLast() }
        }
        // The newline just after a header row is no reason to draw the row as text.
        let open = lines.last == "" ? 1 : 0
        let pipes = lines.dropLast(open).reversed().prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }.count
        if pipes > 0 {
            let run = lines.dropLast(open).suffix(pipes).joined(separator: "\n")
            let isTable = (try? AttributedString(markdown: run, options: .init(interpretedSyntax: .full)))?
                .runs.contains { tableIntent($0.presentationIntent) != nil } ?? false
            if !isTable { lines.removeLast(pipes + open) }
        }
        return lines.joined(separator: "\n")
    }

    /// `blocks` with each name in `targets` linked, in paragraphs, headings, list items and table
    /// cells alike, and the answer's own links dropped (`AskClaudeLinks.linked`).
    static func linked(_ blocks: [Block], targets: [String: String], scheme: String, underline: Color) -> [Block] {
        func link(_ text: AttributedString) -> AttributedString {
            AskClaudeLinks.linked(text, targets: targets, scheme: scheme, underline: underline)
        }
        return blocks.map { block in
            var block = block
            switch block.kind {
            case .text(let text): block.kind = .text(link(text))
            case .heading(let text): block.kind = .heading(link(text))
            case .table(var table):
                table.header = table.header.map(link)
                table.rows = table.rows.map { $0.map(link) }
                block.kind = .table(table)
            case .code, .rule: break
            }
            return block
        }
    }
}

/// An answer drawn as its blocks (TE298). Selectable a block at a time; VoiceOver reads the blocks
/// in order, list markers and table cells included.
struct AskClaudeAnswerView: View {
    let blocks: [AskClaudeMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                row(block)
                    .padding(.top, block.id == 0 ? 0 : gap(before: block))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude")
    }

    /// Items of one list sit close; anything else a paragraph's gap apart.
    private func gap(before block: AskClaudeMarkdown.Block) -> CGFloat {
        block.depth > 0 && blocks[block.id - 1].depth > 0 ? 3 : 8
    }

    private func row(_ block: AskClaudeMarkdown.Block) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if block.depth > 0 {
                Text(block.marker ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                    .accessibilityHidden(block.marker == nil)
            }
            content(block.kind)
        }
        .padding(.leading, CGFloat(max(block.depth - 1, 0)) * 18)
        .padding(.leading, block.quoted ? 10 : 0)
        .overlay(alignment: .leading) {
            if block.quoted {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
            }
        }
        .foregroundStyle(block.quoted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    @ViewBuilder
    private func content(_ kind: AskClaudeMarkdown.Block.Kind) -> some View {
        switch kind {
        case .text(let text), .heading(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            AskClaudeCodeBlock(code: code)
        case .table(let table):
            AskClaudeTableView(table: table)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// A fenced code block: monospaced, wrapped, with a Copy button in its corner.
struct AskClaudeCodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Text(code)
            .scaledFont(ScaledFont.system(.callout, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.leading, 8).padding(.trailing, 28)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .scaledFont(ScaledFont.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(2)
                .help("Copy")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Code")
    }
}

/// A table on its own card, as the mockup drew it (M1): a muted bold header, a rule under each
/// row, and each column aligned as the answer set it. Cells wrap in a narrow panel.
struct AskClaudeTableView: View {
    let table: AskClaudeMarkdown.Table

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    Text(table.header[column])
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(textAlignment(column))
                        .gridColumnAlignment(table.alignments[column])
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        Text(table.rows[row][column])
                            .monospacedDigit()
                            .multilineTextAlignment(textAlignment(column))
                    }
                }
            }
        }
        .scaledFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(table.header.count) columns, \(table.rows.count) rows")
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }
}
