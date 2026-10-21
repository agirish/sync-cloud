import AppKit
import SwiftUI
import Testing
@testable import Design
@testable import FileExplorer

/// **Edit's words and sizes, one surface to the next** (TE120, TE123, TE129, TE132, TE134 — the
/// 2026-10-20 polish audit's "across Edit" findings). Each literal pinned here is what the screen
/// says; the scans hold the rule for strings nobody has written yet.
@MainActor
@Suite struct EditorAcrossPolishTests {

    private let defaults = ScratchDefaults("EditorAcrossPolishTests")

    // MARK: TE120 — "the file list", never "the rail"

    @Test func theFileListIsNeverCalledTheRail() {
        #expect(EditorStatusHeadings.railOutlineTitle == "Show Outline in File List")
        #expect(EditorWorkspaceView.emptyCaption(hasFolder: true, showsRail: true)
                == "Choose a file from the list — or press ⌘O on a text file in Browse, Compare or Organize.")
    }

    /// The rail's own sentences: "Edit", not "the editor", for the place that opens a file.
    @Test func theEmptyListSaysEditOpensFiles() throws {
        let code = try Self.source("EditorFileRailView.swift")
        #expect(code.contains("\"The one file in this folder isn’t one Edit opens. \""))
        #expect(code.contains("are ones Edit opens. \""))
        #expect(!code.contains("the editor opens"))
        let tab = try Self.source("EditorRailTab.swift")
        #expect(tab.contains(".accessibilityLabel(\"File list\")"), "VoiceOver's name for the list's panel")
    }

    /// **No sentence in Edit's sources says "rail"** — strings with a space in them, that is, which
    /// is what a person reads; `"editor.rail.tabs"` and the like are keys. Mutation: put back
    /// "Rail contents" and this names EditorRailTab.swift.
    @Test func noSentenceInEditSaysRail() throws {
        let rail = try NSRegularExpression(pattern: #"\brails?\b"#, options: .caseInsensitive)
        var found: [String] = []
        for (file, literal) in try Self.sentenceLiterals() {
            let range = NSRange(literal.startIndex..., in: literal)
            if rail.firstMatch(in: literal, range: range) != nil { found.append("\(file): \(literal)") }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    // MARK: TE123 — the keys in the tooltips

    @Test func goToLineNamesItsChord() {
        #expect(EditorStatusGoToLine.help == "Go to Line   ⌃⌘L")
    }

    @Test func thePDFCapsulesButtonsNameTheirKeys() {
        #expect(EditorPDFCapsule.pageStepHelp(forward: false) == "Previous page   ⌥←")
        #expect(EditorPDFCapsule.pageStepHelp(forward: true) == "Next page   ⌥→")
        #expect(EditorPDFCapsule.zoomStepHelp(in: true) == "Zoom in   ⌘+")
        #expect(EditorPDFCapsule.zoomStepHelp(in: false) == "Zoom out   ⌘−")
    }

    /// The call sites — a rule extracted for a test is one revert away from unused.
    @Test func theTooltipsAreTheOnesDrawn() throws {
        let capsule = try Self.source("EditorPDFCapsule.swift")
        #expect(capsule.contains(".help(Self.pageStepHelp(forward: forward))"))
        #expect(capsule.contains(".help(Self.zoomStepHelp(in: zoomingIn))"))
        #expect(!capsule.contains(".help(label)"), "a capsule button's tooltip without its key")
        let mode = try Self.source("EditorMode.swift")
        #expect(mode.contains(".help(ShortcutHint.tooltip(candidate.title, candidate.chord.display))"))
        let header = Self.squashed(try Self.source("EditorWorkspaceView.swift"))
        #expect(header.contains(".accessibilityLabel(\"Find in this document\") .shortcutKeycap(AppChord.findInPane.display) "
                                + ".help(ShortcutHint.tooltip(\"Find and replace in this document\", AppChord.findInPane.display))"),
                "Find in a text file: the ＋'s keycap and a tooltip with ⌘F")
        let card = Self.squashed(try Self.source("EditorPDFCard.swift"))
        #expect(card.contains(".accessibilityLabel(\"Find in this PDF\") .shortcutKeycap(AppChord.findInPane.display)"),
                "Find in a PDF: Expand's keycap beside it, so a keycap on Find too")
    }

    /// Source, Preview and Split are ⌃⌘1, ⌃⌘2 and ⌃⌘3 — the tooltip and the menu say one thing.
    @Test func theModeTooltipsCarryTheirChords() {
        #expect(EditorMode.allCases.map { ShortcutHint.tooltip($0.title, $0.chord.display) }
                == ["Source   ⌃⌘1", "Preview   ⌃⌘2", "Split   ⌃⌘3"])
    }

    /// **The zoom label's menu shows Fit Page's and Fit Width's keys, and ticks Actual Size at
    /// 100%.** Labels only: the menu is gone before a key could reach it, and the menu bar's Text ▸
    /// Fit Page answers ⌃⌘1.
    @Test func theZoomMenuShowsTheFitsKeysAndTicksActualSize() throws {
        let state = EditorPDFViewState(defaults: defaults)
        state.fit = nil
        state.scale = 1
        var menu = EditorPDFZoomMenu.menu(for: state)
        for (title, key) in [("Fit Page", "1"), ("Fit Width", "2")] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.keyEquivalent == key && item.keyEquivalentModifierMask == [.control, .command],
                    "\(title): “\(item.keyEquivalent)” \(item.keyEquivalentModifierMask)")
        }
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Actual Size", "100%"])
        state.fit = .actual
        menu = EditorPDFZoomMenu.menu(for: state)
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Actual Size", "100%"])
        // Not at another scale, and not while a fit holds the page — even one that lands on 100%.
        state.fit = nil
        state.scale = 1.25
        #expect(EditorPDFZoomMenu.menu(for: state).items.filter { $0.state == .on }.map(\.title) == ["125%"])
        state.fit = .page
        state.scale = 1
        #expect(EditorPDFZoomMenu.menu(for: state).items.filter { $0.state == .on }.map(\.title) == ["Fit Page"])
    }

    // MARK: TE129 — curly apostrophes, US spelling

    @Test func theSpellingIsAmerican() {
        #expect(EditorPDFCapsulePlace.top.title == "Top Center")
        #expect(EditorPDFCapsulePlace.bottom.title == "Bottom Center")
        #expect(EditorPDFFind.unreadableCaption == "Couldn’t read this PDF’s text")
    }

    /// **No sentence in Edit's sources has a straight apostrophe.** Log lines are not read by
    /// anyone but us, so they are skipped. Mutation: straighten “Couldn’t” in EditorFileStore and
    /// this names the line.
    @Test func editsSentencesUseCurlyApostrophes() throws {
        let straight = try NSRegularExpression(pattern: "[A-Za-z]'[A-Za-z]")
        var found: [String] = []
        for (file, literal) in try Self.sentenceLiterals() {
            if straight.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil {
                found.append("\(file): \(literal)")
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    // MARK: TE132 — one tooltip pattern

    /// **Every palette tooltip reads "Name — what it does"**, the name as the tool's title is
    /// capitalised: Date's used to say "Date · …" and Text Size's "Text size — …".
    @Test func thePalettesTooltipsReadNameDashWhatItDoes() throws {
        let palette = try Self.source("EditorPDFFillPalette.swift")
        // What a live tool says (`hint`), and why a greyed one is greyed (`refusal`, TE108).
        var cases: [Substring] = []
        for head in ["static func hint(_ tool: Tool) -> String {", "static func refusal(_ tool: Tool, fill: EditorPDFFillSign) -> String? {"] {
            let start = try #require(palette.range(of: head))
            let body = palette[start.upperBound...]
            let end = try #require(body.range(of: "\n    }\n"))
            cases += body[..<end.lowerBound].split(separator: "\n").filter { $0.contains("return \"") }
        }
        try #require(cases.count >= 12, "not reading the palette's tooltips: \(cases.count)")
        for line in cases {
            #expect(line.contains(" — ") && !line.contains(" · "), "\(line)")
        }
        #expect(palette.contains("case .date: return \"Date — click to place today’s date\""))
        #expect(palette.contains("case .size: return \"Text Size — of the selected text, and of the next\""))
    }

    /// **Both ＋s say the header's sentence**, and the list's folder row no longer shows it over the
    /// folder's name — only the ＋ does.
    @Test func bothPlusButtonsShareOneTooltip() throws {
        #expect(EditorWorkspaceView.newTextFileTitle(folderName: "Downloads") == "New text file in Downloads")
        let rail = try Self.source("EditorFileRailView.swift")
        #expect(rail.contains("EditorWorkspaceView.newTextFileTitle(folderName: newFileFolderName ?? folderName)"))
        #expect(rail.contains(".help(ShortcutHint.tooltip(newFileDestination, AppChord.newTextFile.display))"))
        #expect(!rail.contains("New files are created in"))
        // The row-wide tooltip is gone: `.help(contextHelp)` sits once, on the other tabs' name.
        #expect(rail.components(separatedBy: ".help(contextHelp)").count == 2)
        let row = try #require(rail.range(of: "private var contextRow: some View"))
        let rowBody = rail[row.upperBound...]
        let help = try #require(rowBody.range(of: ".help(contextHelp)"))
        let elseBranch = try #require(rowBody.range(of: "} else {"))
        let spacer = try #require(rowBody.range(of: "Spacer(minLength: 0)"))
        #expect(elseBranch.lowerBound < help.lowerBound && help.lowerBound < spacer.lowerBound,
                "the name's tooltip has left the Pages and Outline name for the whole row")
    }

    // MARK: TE134 — sizes that grow with the text

    /// **The line numbers fit their column at every text size.** A `Text` in a frame narrower than
    /// its own width is cut ("10…"), so the column must be at least the width SwiftUI lays the
    /// number out at — measured from the view, at that text size, not from the font arithmetic the
    /// column uses. The control: the old fixed 34pt is narrower than 10482 at Largest.
    @Test func theLineNumbersFitTheirColumn() {
        for scale in [FontSize.small.scale, 1, FontSize.large.scale, FontSize.extraLarge.scale] {
            for number in [9, 482, 10_482, 1_204_830] {
                let width = TextPairDiffView.gutterWidth(largestNumber: number, scale: scale)
                let needed = Self.laidOutWidth(of: number, scale: scale)
                #expect(width >= needed, "\(number) at \(scale) needs \(needed)pt, in a \(width)pt column")
            }
        }
        #expect(Self.laidOutWidth(of: 10_482, scale: FontSize.extraLarge.scale) > 34,
                "the control: the old 34pt column should be too narrow for 10482 at Largest")
        // It grows with the text and with the file, and a short file keeps three digits' room.
        let small = TextPairDiffView.gutterWidth(largestNumber: 7, scale: 1)
        #expect(small == TextPairDiffView.gutterWidth(largestNumber: 999, scale: 1))
        #expect(TextPairDiffView.gutterWidth(largestNumber: 10_482, scale: 1) > small)
        #expect(TextPairDiffView.gutterWidth(largestNumber: 10_482, scale: FontSize.extraLarge.scale)
                > TextPairDiffView.gutterWidth(largestNumber: 10_482, scale: 1))
    }

    @Test func theLargestNumberIsTheLastOnEitherSide() {
        let diff = TextPairDiff.make(left: (1...12).map { "l\($0)" }, right: (1...3).map { "l\($0)" })
        #expect(diff.largestLineNumber == 12)
        let other = TextPairDiff.make(left: ["a"], right: (1...140).map { "r\($0)" })
        #expect(other.largestLineNumber == 140)
    }

    @Test func theSheetsHaveAFloorRatherThanAWidth() throws {
        #expect(EditorPDFBatchSheet.minWidth == 400 && EditorPDFBatchSheet.idealWidth == 420)
        let tools = try Self.source("PanePDFTools.swift")
        #expect(tools.contains(".frame(minWidth: EditorPDFBatchSheet.minWidth, idealWidth: EditorPDFBatchSheet.idealWidth)"))
        #expect(!tools.contains(".frame(width: 400)"))
        let signature = try Self.source("EditorPDFSignatureSheet.swift")
        #expect(signature.contains(".frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth)"))
        for label in ["Ink", "Pen", "Style"] {
            #expect(signature.contains("Text(\"\(label)\").scaledFont(.system(size: 11)).foregroundStyle(.secondary)"),
                    "\(label) does not grow with the text size")
        }
    }

    // MARK: Helpers

    /// The width SwiftUI gives the number drawn as the column draws it, unconstrained.
    private static func laidOutWidth(of number: Int, scale: CGFloat) -> CGFloat {
        let text = Text(String(number))
            .scaledFont(.system(size: TextPairDiffView.gutterPointSize, design: .monospaced))
            .fixedSize()
            .environment(\.appFontScale, scale)
        return NSHostingView(rootView: text).fittingSize.width
    }

    /// Runs of whitespace as one space, so a modifier chain reads the same however it is indented.
    static func squashed(_ code: String) -> String {
        code.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A FileExplorer source file, its `//` comments stripped.
    static func source(_ name: String) throws -> String {
        let url = sourcesFolder.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
            }
            .joined(separator: "\n")
    }

    static var sourcesFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
    }

    /// Every string literal with a space in it — a sentence, not a key — in Edit's own files,
    /// skipping comment lines and log lines.
    static func sentenceLiterals() throws -> [(file: String, literal: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: sourcesFolder.path)
            .filter { name in
                name.hasSuffix(".swift")
                    && (name.hasPrefix("Editor") || name.hasPrefix("PlainTextEditor")
                        || ["PaneSaveAsPDF.swift", "PanePDFTools.swift", "TextPairDiffView.swift"].contains(name))
            }
            .sorted()
        try #require(names.count > 40, "not reading Edit's sources: \(names.count) files")
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var out: [(String, String)] = []
        for name in names {
            // A log call can run over several lines; its depth in parentheses says when it ends.
            var logDepth = 0
            for line in try source(name).split(separator: "\n") {
                let line = String(line)
                let range = NSRange(line.startIndex..., in: line)
                if logDepth > 0 || line.contains("Logger.") || line.contains("log(") {
                    let code = literal.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                    logDepth += code.filter { $0 == "(" }.count - code.filter { $0 == ")" }.count
                    logDepth = max(logDepth, 0)
                    continue
                }
                for match in literal.matches(in: line, range: range) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let text = String(line[range])
                    if text.contains(" ") { out.append((name, text)) }
                }
            }
        }
        return out
    }
}
