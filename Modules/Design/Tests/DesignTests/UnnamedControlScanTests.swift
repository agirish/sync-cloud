import AppKit
import Testing
@testable import Design

/// Every button whose entire label is a glyph must carry an `accessibilityLabel`. On macOS
/// `.help()` is the accessibility help, not the name, so a control whose label is one
/// `Image(systemName:)` is announced with no name: VoiceOver reads "button", and Voice Control can
/// click it only by number.
///
/// A source scan, not a rendered assertion: SwiftUI builds no accessibility tree in a test process
/// without an assistive client, so asking a rendered button for its label gets nothing back either
/// way and would pass vacuously.
@Suite struct UnnamedControlScanTests {

    /// A `Button`/`Menu` whose modifier chain contains a system image, no text of any kind, and no
    /// accessibility label.
    private struct Unnamed {
        let file: String
        let line: Int
    }

    /// The chain belonging to the control declared at `start`. Extent is decided by indentation,
    /// not a fixed number of lines (which can miss a label one line past the window), and comment
    /// lines continue the chain, since the codebase explains a modifier directly above it.
    ///
    /// A comment extends the chain but is not part of it: the text returned is code only, so a
    /// comment that mentions `accessibilityLabel` can't satisfy the check. Whole-line comments are
    /// dropped and a trailing `//` is cut where it stands outside a string literal.
    private static func chain(in lines: [String], from start: Int) -> String {
        let base = lines[start].prefix { $0 == " " }.count
        var code = [AccentFillScanTests.codeOnly(lines[start])]
        var end = start + 1
        while end < lines.count {
            let raw = lines[end]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { end += 1; continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                end += 1; continue
            }
            let ind = raw.prefix { $0 == " " }.count
            let continues = trimmed.hasPrefix(".") || trimmed.hasPrefix("}")
                || trimmed.hasPrefix(")") || trimmed.hasPrefix("]")
            if ind <= base && !continues { break }
            code.append(AccentFillScanTests.codeOnly(raw))
            end += 1
        }
        return code.joined(separator: "\n")
    }

    /// Glyph-only components that deliberately name themselves nowhere, so each call site can say
    /// what it closes (`CloseButton`'s doc). Their call sites are checked instead.
    private static let namedByCallers = ["Modules/Design/Sources/Design/CloseButton.swift"]

    private static func unnamedControls(in files: [URL]) throws -> [Unnamed] {
        var found: [Unnamed] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Button") || trimmed.hasPrefix("Menu") else { continue }
                let block = chain(in: lines, from: i)
                // A glyph is an SF Symbol, or one of the app's own glyph views: `SwapPanesGlyph` and
                // its kind draw a symbol and no text, so a control could hide behind one unnamed.
                guard block.contains("Image(systemName:")
                        || block.range(of: #"\b[A-Z][A-Za-z]*Glyph\("#, options: .regularExpression) != nil
                else { continue }
                // Any text in the label names the control already, as `Label(_:systemImage:)` does.
                guard !block.contains("Text(") && !block.contains("Label(") else { continue }
                guard !block.contains("accessibilityLabel") else { continue }
                // A control hidden from accessibility is not an unnamed one; it is not there at all.
                guard !block.contains("accessibilityHidden(true)") else { continue }
                // Named by every caller instead, which `theGlyphOnlyComponentsAreNamedSomewhere`
                // checks site by site. Listed by path, not trusted to the component's own comments.
                guard !Self.namedByCallers.contains(where: { file.path.hasSuffix($0) }) else { continue }
                found.append(Unnamed(file: file.lastPathComponent, line: i + 1))
            }
        }
        return found
    }

    @Test func noButtonIsAGlyphWithNoName() throws {
        let files = try AccentFillScanTests.appSources()
        let unnamed = try Self.unnamedControls(in: files)
        let report = unnamed.prefix(12).map { "\($0.file):\($0.line)" }.joined(separator: "\n")
        #expect(unnamed.isEmpty,
                "\(unnamed.count) glyph-only control(s) announce no name. `.help` is the accessibility HELP on macOS, not the name — add `.accessibilityLabel`, using the control's own help text where it has one so the spoken name and the tooltip agree:\n\(report)")
    }

    /// The scan has to be able to fail: a chain-walker that silently stopped matching would make
    /// the test above pass on any tree.
    @Test func theScanFindsAnUnnamedControl() {
        let planted = """
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete this thing")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: planted, from: 0)
        #expect(block.contains("Image(systemName:"), "the walker no longer reaches the label")
        #expect(block.contains(".help("), "the walker stops before the modifier chain")
        #expect(!block.contains("accessibilityLabel"), "the planted control is supposed to be unnamed")
    }

    /// And the other direction: a named control must not be reported, including when the label sits
    /// below a comment.
    @Test func theScanAcceptsANamedControlPastAComment() {
        let named = """
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                // The name has to survive somewhere reachable, so it is spelled out here.
                .accessibilityLabel("Delete this thing")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: named, from: 0)
        #expect(block.contains("accessibilityLabel"),
                "a comment cut the chain — every control explained above its label would be a phantom hit")
    }

    /// A comment that mentions the label is not the label. The chain walks past comment lines but
    /// must not return them, or a control explained by "// accessibilityLabel comes later" and
    /// never named would pass.
    @Test func aCommentOnlyLabelDoesNotName() {
        let planted = """
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                // Gets its .accessibilityLabel("Delete") from the row.
                .buttonStyle(.bordered) // accessibilityLabel set by the caller
                .help("Delete this thing")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: planted, from: 0)
        #expect(block.contains(".help("), "the comment stopped the chain — the walker must still pass it")
        #expect(!block.contains("accessibilityLabel"),
                "a comment's mention of accessibilityLabel counted as the control's name")
        // A `//` inside a string survives the cut.
        #expect(AccentFillScanTests.codeOnly(#".help("See https://example.com") // note"#) == #".help("See https://example.com") "#)
    }

    /// A switch with an empty title must be named some other way. `Toggle("")` with its label
    /// hidden is announced as "switch, on", and in a list (one per account in Settings ▸ Sources)
    /// nothing tells the rows apart.
    @Test func noUntitledSwitchIsUnnamed() throws {
        var untitled = 0
        var unnamed: [String] = []
        for file in try AccentFillScanTests.appSources() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated()
            where line.trimmingCharacters(in: .whitespaces).hasPrefix("Toggle(\"\",") {
                untitled += 1
                if !Self.chain(in: lines, from: i).contains("accessibilityLabel") {
                    unnamed.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(untitled >= 3, "found \(untitled) untitled switches, expected at least 3 — the scan has stopped matching")
        #expect(unnamed.isEmpty,
                "\(unnamed.count) untitled switch(es) announce no name — add `.accessibilityLabel` naming what they switch:\n\(unnamed.joined(separator: "\n"))")
    }

    // MARK: - What the scan cannot see

    /// The scan above only recognises a literal `Button` or `Menu`, so a glyph control built as its
    /// own `View` is invisible to it. `CloseButton`, a bare `xmark`, never appears as a `Button` at
    /// a call site, and naming it inside the component would put a generic "Close" under its
    /// callers' specific names. So the known components are listed: each must carry a label itself
    /// or be named at every call site.
    @Test func theGlyphOnlyComponentsAreNamedSomewhere() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        // Components whose body is a glyph control, and where the name lives for each.
        // `CloseButton` names itself nowhere (its doc says callers own that), so it is checked at
        // the call sites below.
        let selfNaming: [(component: String, path: String)] = [
            ("FolderJumpMenu", "Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift"),
            ("ExpandingSearchToggle", "Modules/Design/Sources/Design/ExpandingSearchField.swift"),
            ("SettingsSearchField", "Modules/Settings/Sources/Settings/SettingsLayout.swift"),
        ]
        for (component, path) in selfNaming {
            let text = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            guard let start = text.range(of: "struct \(component): View") else {
                Issue.record("\(component) is gone from \(path) — this list is stale"); continue
            }
            // To the struct's closing brace, not a fixed number of characters: a label can sit
            // further in than any window guessed, and would be reported missing.
            let tail = text[start.lowerBound...]
            let end = tail.range(of: "\n}")?.upperBound ?? tail.endIndex
            let body = String(tail[..<end])
            #expect(body.contains("accessibilityLabel"),
                    "\(component) renders a glyph control and no longer names it")
        }

        // `CloseButton` is named by every caller. A call site that forgets is announced as
        // "button", through the one door the scan above can't watch. Every source and both
        // spellings (`CloseButton(` and a trailing closure), since a list of call sites goes stale.
        var seen = 0
        for file in try AccentFillScanTests.appSources() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"),
                      !line.contains("struct CloseButton"),
                      line.contains("CloseButton(") || line.contains("CloseButton {") else { continue }
                seen += 1
                let chain = Self.chain(in: lines, from: i)
                #expect(chain.contains("accessibilityLabel"),
                        "\(file.lastPathComponent):\(i + 1) uses CloseButton without naming it — the component deliberately does not name itself")
            }
        }
        // Six today (Help, the banner, Settings, the destination picker, setup's ✕, the Info
        // inspector). At least that many, so a scan that stopped matching can't pass on none.
        #expect(seen >= 6, "found \(seen) CloseButton call sites, expected at least 6 — the scan has stopped matching")

        // And the component still declines to name itself; if it did, the call-site names would
        // sit on top of a generic one.
        let component = try String(contentsOf: repo.appendingPathComponent(
            "Modules/Design/Sources/Design/CloseButton.swift"), encoding: .utf8)
        #expect(!component.contains(".accessibilityLabel("),
                "CloseButton names itself again — that puts a generic label under four specific ones")
    }
}
