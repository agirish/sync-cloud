import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// Ask Claude's answers drawn as blocks (lists, tables, code and headings, not only inline
/// markdown), and a growing answer that never shows a half-written one.
@MainActor
@Suite struct AskClaudeMarkdownTests {

    private typealias Block = AskClaudeMarkdown.Block

    private static let answer = """
        Two files look like **receipts**
        from this month:

        - Receipt Costco 2025.pdf, `2 MB`
        - Also:
          1. one
          2. two

        ### What to do

        | Name | Size |
        |---|---:|
        | Tax.pdf | 2 MB |
        | Notes | |

        ```
        mv a b
        ```

        > Moving is undone with ⌘Z.

        ---

        3. third
        4. fourth
        """

    private static func plain(_ text: AttributedString) -> String { String(text.characters) }

    /// What a block draws, as one line a test can compare.
    private static func describe(_ block: Block) -> String {
        let indent = String(repeating: ">", count: block.depth) + (block.marker.map { "\($0) " } ?? "") + (block.quoted ? "quote " : "")
        switch block.kind {
        case .text(let text): return indent + "text " + plain(text)
        case .heading(let text): return indent + "heading " + plain(text)
        case .code(let code): return indent + "code " + code
        case .rule: return indent + "rule"
        case .table(let table):
            return indent + "table " + ([table.header] + table.rows).map { $0.map(plain).joined(separator: "|") }.joined(separator: " / ")
        }
    }

    @Test func everyKindOfBlockIsItsOwn() {
        let blocks = AskClaudeMarkdown.blocks(Self.answer)
        #expect(blocks.map(Self.describe) == [
            "text Two files look like receipts\nfrom this month:",
            ">• text Receipt Costco 2025.pdf, 2 MB",
            ">• text Also:",
            ">>1. text one",
            ">>2. text two",
            "heading What to do",
            "table Name|Size / Tax.pdf|2 MB / Notes|",
            "code mv a b",
            "quote text Moving is undone with ⌘Z.",
            "rule",
            ">3. text third",
            ">4. text fourth",
        ])
        #expect(blocks.map(\.id) == Array(blocks.indices))
        guard case .table(let table) = blocks[6].kind else { Issue.record("no table"); return }
        #expect(table.alignments == [.leading, .trailing])
        // Inline markdown still reads inside a block: the strong run and the code span.
        guard case .text(let first) = blocks[0].kind, case .text(let item) = blocks[1].kind else { return }
        #expect(first.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized && Self.plain(AttributedString(first[$0.range])) == "receipts" })
        #expect(item.runs.contains { $0.inlinePresentationIntent == .code && Self.plain(AttributedString(item[$0.range])) == "2 MB" })
    }

    @Test func aHeadingIsAsStrongAsBoldText() {
        let heading = AskClaudeMarkdown.blocks("## Taxes *2025*")
        guard case .heading(let text)? = heading.first?.kind else { Issue.record("\(heading)"); return }
        #expect(text.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    @Test func namesLinkInListItemsAndTableCellsAndTheAnswersOwnLinksDont() {
        let text = "- Open Tax.pdf or [this](https://example.com)\n\n| File |\n|---|\n| 2024 Tax.pdf |\n\n```\nTax.pdf\n```"
        let blocks = AskClaudeMarkdown.linked(AskClaudeMarkdown.blocks(text),
                                              targets: ["Tax.pdf": "/a/Tax.pdf", "2024 Tax.pdf": "/a/2024 Tax.pdf"],
                                              scheme: "synccloud-askclaude", underline: .purple)
        func links(_ text: AttributedString) -> [String] {
            text.runs.compactMap { run in run.link.map { _ in Self.plain(AttributedString(text[run.range])) } }
        }
        guard blocks.count == 3, case .text(let item) = blocks[0].kind, case .table(let table) = blocks[1].kind else {
            Issue.record("\(blocks.map(Self.describe))"); return
        }
        #expect(links(item) == ["Tax.pdf"])
        #expect(item.runs.compactMap(\.link).allSatisfy { $0.scheme == "synccloud-askclaude" })
        #expect(table.rows.first.map { links($0[0]) } == ["2024 Tax.pdf"])
        #expect(table.rows.first?[0].runs.compactMap(\.link).first?.absoluteString.contains("2024%20Tax.pdf") == true)
        #expect(blocks[2].kind == .code("Tax.pdf"))
    }

    @Test func settledHoldsBackOnlyWhatCouldStillChangeItsShape() {
        // A table waits for its divider; then its rows show as they come, a cell at a time.
        #expect(AskClaudeMarkdown.settled("Sizes:\n\n| Name | Si") == "Sizes:\n")
        #expect(AskClaudeMarkdown.settled("Sizes:\n\n| Name | Size |\n|--") == "Sizes:\n")
        #expect(AskClaudeMarkdown.settled("Sizes:\n\n| Name | Size |\n") == "Sizes:\n")
        #expect(AskClaudeMarkdown.settled("| Name | Size |\n|---|---|\n| Tax") == "| Name | Size |\n|---|---|\n| Tax")
        // A line that is only a marker so far: a dash, a number, a fence, a heading's hashes.
        #expect(AskClaudeMarkdown.settled("Two:\n-") == "Two:")
        #expect(AskClaudeMarkdown.settled("Two:\n  12.") == "Two:")
        #expect(AskClaudeMarkdown.settled("Run:\n```sw") == "Run:")
        #expect(AskClaudeMarkdown.settled("Done.\n\n##") == "Done.\n")
        // Words are never held back.
        #expect(AskClaudeMarkdown.settled("- one\n- tw") == "- one\n- tw")
        #expect(AskClaudeMarkdown.settled("Pipes | inside a line") == "Pipes | inside a line")
        #expect(AskClaudeMarkdown.settled("In 2024") == "In 2024")
    }

    /// The answer as it streams in, a character at a time: every block drawn on the way is the
    /// block the finished answer has there, of the same kind and with the same marker.
    @Test func aGrowingAnswerNeverChangesABlocksShape() {
        let final = AskClaudeMarkdown.blocks(Self.answer)
        func shape(_ block: Block) -> String {
            let kind: String = switch block.kind {
            case .text: "text"
            case .heading: "heading"
            case .code: "code"
            case .rule: "rule"
            case .table: "table"
            }
            return "\(kind) \(block.depth) \(block.marker ?? "-") \(block.quoted)"
        }
        var shown = 0
        for end in Self.answer.indices.dropFirst() {
            let blocks = AskClaudeMarkdown.blocks(AskClaudeMarkdown.settled(String(Self.answer[..<end])))
            #expect(blocks.count <= final.count)
            for (block, done) in zip(blocks, final) where shape(block) != shape(done) {
                Issue.record("at \(Self.answer.distance(from: Self.answer.startIndex, to: end)): \(Self.describe(block)) became \(Self.describe(done))")
                return
            }
            // A table in the making never shows a pipe as text.
            for block in blocks {
                if case .text(let text) = block.kind { #expect(!Self.plain(text).contains("|")) }
            }
            shown = max(shown, blocks.count)
        }
        #expect(shown == final.count)
    }

    @Test func noTextNoBlocksAndBlankLinesAreNotBlocks() {
        #expect(AskClaudeMarkdown.blocks("").isEmpty)
        #expect(AskClaudeMarkdown.blocks("One.\n\n\n\nTwo.").map(Self.describe) == ["text One.", "text Two."])
    }
}

/// The blocks paint, each kind of them, and the thread draws answers through them.
@MainActor
@Suite(.serialized) struct AskClaudeAnswerPaintTests {

    private static func render<V: View>(_ view: V, width: CGFloat) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.frame.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return try renderAt1x(host)
    }

    private static func answer(_ text: String, width: CGFloat = 340) throws -> NSBitmapImageRep {
        try render(AskClaudeAnswerView(blocks: AskClaudeMarkdown.blocks(text)), width: width)
    }

    /// Pixels below `top` (in points) that aren't white; a rule's light gray counts.
    private static func ink(_ rep: NSBitmapImageRep, below top: CGFloat) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / rep.size.height
        var count = 0
        for y in Int(top * scale)..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), min(c.redComponent, c.greenComponent, c.blueComponent) < 0.995 { count += 1 }
            }
        }
        return count
    }

    /// Each kind added under a paragraph makes the answer taller and draws in the room it takes.
    @Test func everyKindOfBlockPaints() throws {
        let alone = try Self.answer("Alpha")
        for block in ["- bullet item", "3. numbered item", "### Heading", "```\ncode line\n```", "> quoted line",
                      "| A | B |\n|---|---|\n| x | y |", "---"] {
            let rep = try Self.answer("Alpha\n\n" + block)
            #expect(rep.size.height > alone.size.height + 3, "\(block) took no room")
            #expect(Self.ink(rep, below: alone.size.height) > 20, "\(block) painted nothing below the paragraph")
        }
    }

    /// Every row of a table and every column draws: a row more is a row taller, and a cell's
    /// text in the second column changes pixels right of the first column only.
    @Test func everyTableRowAndColumnPaints() throws {
        let two = try Self.answer("| Name | Size |\n|---|---|\n| Tax.pdf | 2 MB |")
        let three = try Self.answer("| Name | Size |\n|---|---|\n| Tax.pdf | 2 MB |\n| Rent.pdf | 9 MB |")
        #expect(three.size.height > two.size.height + 8)
        let other = try Self.answer("| Name | Size |\n|---|---|\n| Tax.pdf | 7 KB |")
        #expect(other.size == two.size)
        var changed: [Int] = []
        for y in 0..<two.pixelsHigh {
            for x in 0..<two.pixelsWide where two.colorAt(x: x, y: y) != other.colorAt(x: x, y: y) { changed.append(x) }
        }
        let firstColumnEnd = 70 * CGFloat(two.pixelsWide) / two.size.width
        #expect(!changed.isEmpty && changed.allSatisfy { CGFloat($0) > firstColumnEnd }, "changed columns \(changed.min() ?? -1)…\(changed.max() ?? -1)")
    }

    /// A wide table in the panel's width wraps its cells rather than running out of the bubble.
    @Test func aWideTableStaysInsideTheBubble() throws {
        let text = "| File | Where it is now | Where it goes |\n|---|---|---|\n| Receipt Costco 2025.pdf | Downloads | Documents/Taxes/2025/Receipts |"
        let rep = try Self.answer(text, width: 300)
        #expect(rep.size.width == 300)
        // No text in the last 2 points: the cells wrapped inside. (Dark ink only: the card's own
        // light border may sit there.)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var edge = 0
        for y in 0..<rep.pixelsHigh {
            for x in Int(298 * scale)..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), min(c.redComponent, c.greenComponent, c.blueComponent) < 0.9 { edge += 1 }
            }
        }
        #expect(edge == 0)
    }

    // MARK: The thread draws its answers as blocks

    private struct Answering: AskClaudeTransport {
        let text: String

        func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
            let escaped = String(data: try JSONEncoder().encode(text), encoding: .utf8)!
            // The encoder's own quotes off: `textBlock` puts the string between its own.
            return SSE.response(SSE.text(String(escaped.dropFirst().dropLast()), outputTokens: 20))
        }
    }

    /// The panel with one question answered with `text`.
    private func panel(answering text: String) async throws -> NSBitmapImageRep {
        let d = ScratchDefaults("AskClaudeAnswerPaintTests")
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: Answering(text: text), defaults: d) },
                                 readKey: { "k" })
        chat.ask("Which?", screen: AskClaudeScreen(workspace: "Browse", source: "iCloud Drive", folder: "Documents", sort: "Name",
                                                  rows: [], selection: [], toolsAvailable: true), tools: NoTools())
        await waitUntil("the chat answers", timeout: 30) { !chat.isRunning }
        #expect(chat.items.contains { $0.kind == .assistant(text) })
        let container = CGSize(width: 1000, height: 800)
        return try Self.render(AskClaudePanel(
            chat: chat, place: AskClaudePanelHostedTests.place,
            accent: LiquidGlassHue.none.accentColor, accentFill: LiquidGlassHue.none.accentFillColor,
            onAccent: LiquidGlassHue.none.onAccentLabelColor, hue: .none, tint: 0, level: .solid,
            onAsk: { _ in }, onClose: {}, onOpenSettings: { _ in })
            .frame(width: container.width, height: container.height, alignment: .topLeading), width: container.width)
    }


    /// The thread's own answer bubble draws a heading as the bold line `**Title**` draws, not as
    /// "# Title". "Title" in plain weight shows the comparison can see the difference.
    @Test func theThreadDrawsAHeadingAsABoldLine() async throws {
        let heading = try await panel(answering: "# Title")
        let bold = try await panel(answering: "**Title**")
        let regular = try await panel(answering: "Title")
        #expect(differingPixels(heading, bold) == 0)
        #expect(differingPixels(regular, bold) > 50)
    }
}
