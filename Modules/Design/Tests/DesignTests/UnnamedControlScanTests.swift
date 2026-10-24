import AppKit
import Testing
@testable import Design

/// **Every button whose entire label is a glyph must carry an `accessibilityLabel`.**
///
/// On macOS `.help()` is the accessibility *help*, not the name, so a control whose label is one
/// `Image(systemName:)` and nothing else is announced with no name at all — VoiceOver reads
/// "button", and Voice Control cannot be told to click it by name, only by number. Twenty-six such
/// controls were named in one pass; this is what stops the twenty-seventh appearing.
///
/// **Why a source scan and not a rendered assertion.** SwiftUI builds no accessibility tree in a
/// test process without an assistive client attached, so a test that renders one of these buttons
/// and asks for its label gets nothing back whether the label is present or absent — it would pass
/// vacuously in exactly the state it exists to catch. The source is the only place the answer is
/// legible here.
@Suite struct UnnamedControlScanTests {

    /// A `Button`/`Menu` whose modifier chain contains a system image, no text of any kind, and no
    /// accessibility label.
    private struct Unnamed {
        let file: String
        let line: Int
    }

    /// The chain belonging to the control declared at `start`.
    ///
    /// Extent is decided by indentation rather than a fixed number of lines, and **comment lines
    /// continue the chain**. Both matter: a fixed window found phantom hits because a label sat one
    /// line past the window, and the codebase habitually explains a modifier directly above it, so
    /// stopping at a comment cut chains in half. The first version of this scan reported 43 sites;
    /// with both fixed, 26 — and every one of the 17 differences was a control that was already
    /// named.
    ///
    /// **A comment extends the chain but is not part of it.** The text returned is code only, so a
    /// comment that merely mentions `accessibilityLabel` — "no accessibilityLabel needed here" —
    /// cannot satisfy the check for one. Whole-line comments are dropped and a trailing `//` is cut
    /// where it stands outside a string literal.
    private static func chain(in lines: [String], from start: Int) -> String {
        let base = lines[start].prefix { $0 == " " }.count
        var code = [codeOnly(lines[start])]
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
            code.append(codeOnly(raw))
            end += 1
        }
        return code.joined(separator: "\n")
    }

    /// `line` without a trailing `//` comment. A `//` inside a string literal (a URL) is kept: the
    /// cut is taken at the first `//` with an even number of quotes before it.
    private static func codeOnly(_ line: String) -> String {
        var quotes = 0
        var previous: Character? = nil
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && previous != "\\" { quotes += 1 }
            if character == "/", previous == "/", quotes % 2 == 0 {
                return String(line[..<line.index(before: index)])
            }
            previous = character
            index = line.index(after: index)
        }
        return line
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
                // A glyph is an SF Symbol, or one of the app's own glyph views — `SwapPanesGlyph`
                // and its kind draw a symbol and no text, and the swap half of the pane seam went
                // unnamed behind exactly that indirection.
                guard block.contains("Image(systemName:")
                        || block.range(of: #"\b[A-Z][A-Za-z]*Glyph\("#, options: .regularExpression) != nil
                else { continue }
                // Any text in the label names the control already — that is what `Label(_:systemImage:)` is.
                guard !block.contains("Text(") && !block.contains("Label(") else { continue }
                guard !block.contains("accessibilityLabel") else { continue }
                // A control hidden from accessibility is not an unnamed one; it is not there at all.
                guard !block.contains("accessibilityHidden(true)") else { continue }
                // Named by every caller instead, which `theGlyphOnlyComponentsAreNamedSomewhere`
                // checks site by site. Listed here by path: its body's comment saying so used to
                // satisfy this scan, by mentioning `accessibilityLabel`.
                guard !Self.namedByCallers.contains(where: { file.path.hasSuffix($0) }) else { continue }
                found.append(Unnamed(file: file.lastPathComponent, line: i + 1))
            }
        }
        return found
    }

    @Test func noButtonIsAGlyphWithNoName() throws {
        let files = try Self.appSwiftSources()
        let unnamed = try Self.unnamedControls(in: files)
        let report = unnamed.prefix(12).map { "\($0.file):\($0.line)" }.joined(separator: "\n")
        #expect(unnamed.isEmpty,
                "\(unnamed.count) glyph-only control(s) announce no name. `.help` is the accessibility HELP on macOS, not the name — add `.accessibilityLabel`, using the control's own help text where it has one so the spoken name and the tooltip agree:\n\(report)")
    }

    /// **The scan has to be able to fail.** A chain-walker that silently stopped matching would make
    /// the test above pass on any tree at all — the failure mode a source scan dies of.
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

    /// And the other direction: a named control must NOT be reported, including when the label sits
    /// below a comment. That pairing is what the 43-vs-26 discrepancy was.
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

    /// **A comment that mentions the label is not the label.** The chain keeps comment lines going,
    /// and once returned them too, so a control explained by "// accessibilityLabel comes later"
    /// — and never named — passed.
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
        #expect(Self.codeOnly(#".help("See https://example.com") // note"#) == #".help("See https://example.com") "#)
    }

    /// **A switch with an empty title must be named some other way.** `Toggle("")` with its label
    /// hidden is announced as "switch, on" — and in a list of them, once per row with nothing to
    /// tell the rows apart. Settings ▸ Sources had one per account; setup's copy of the same
    /// switch was named.
    @Test func noUntitledSwitchIsUnnamed() throws {
        var untitled = 0
        var unnamed: [String] = []
        for file in try Self.appSwiftSources() {
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

    /// **The scan above only recognises a literal `Button` or `Menu`.** A glyph control built as its
    /// own `View` is invisible to it — and that blind spot had an occupant: `CloseButton` wraps a
    /// bare `xmark` and never appears as a `Button` at any call site, so the sweep that named 26
    /// controls did not see it, and the attempt to fix it inside the component put a generic
    /// "Close" underneath the specific names two callers already gave it.
    ///
    /// The lesson is that "the scan is clean" means less than it looks. This closes the gap for the
    /// components that exist today by naming them: each of these renders a glyph-only control, so
    /// each must either carry a label itself or be named by every one of its call sites.
    @Test func theGlyphOnlyComponentsAreNamedSomewhere() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        // Components whose body is a glyph control, and where the name lives for each.
        // `CloseButton` is the one that names itself NOWHERE: its doc says callers own that, so it
        // is checked at the call sites instead, below.
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
            // To the struct's CLOSING BRACE, not a fixed number of characters. A 1600-char window
            // was tried first and reported `ExpandingSearchToggle` as unnamed: its label sits 1753
            // characters in. That is the same fixed-window mistake the main scan above already
            // records, made a second time in the test written to describe it — which is the best
            // argument there is for never sizing one of these by guess.
            let tail = text[start.lowerBound...]
            let end = tail.range(of: "\n}")?.upperBound ?? tail.endIndex
            let body = String(tail[..<end])
            #expect(body.contains("accessibilityLabel"),
                    "\(component) renders a glyph control and no longer names it")
        }

        // `CloseButton` is named by its callers, every one of them. A new call site that forgets is
        // a control announced as "button" — the exact defect, arriving through the one door the
        // scan above cannot watch.
        //
        // **Every source, every spelling.** This was a list of four files matching
        // `CloseButton(action:` — and the Info inspector's close button, written with a trailing
        // closure in a file not on the list, went unnamed past it. A list of where a component is
        // used is stale the day someone uses it somewhere else.
        var seen = 0
        for file in try Self.appSwiftSources() {
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
        // Six today: Help, the banner, Settings, the destination picker, setup's ✕ and the Info
        // inspector. At least that many, so a scan that stopped matching cannot pass on none.
        #expect(seen >= 6, "found \(seen) CloseButton call sites, expected at least 6 — the scan has stopped matching")

        // And the component still declines to name itself, which is what makes the check above the
        // one that matters. If this flips, the call-site names are sitting on top of a generic one.
        let component = try String(contentsOf: repo.appendingPathComponent(
            "Modules/Design/Sources/Design/CloseButton.swift"), encoding: .utf8)
        #expect(!component.contains(".accessibilityLabel("),
                "CloseButton names itself again — that puts a generic label under four specific ones")
    }

    /// Same roots and same vacuity guards as `GeometryScaleTests` — `MacApp/` is a sibling of
    /// `Modules/` and in no SPM package, so it has to be added by hand or the scan silently skips
    /// the app's own views.
    private static func appSwiftSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        let modules = repo.appendingPathComponent("Modules")
        var roots = [repo.appendingPathComponent("MacApp")]
        roots += try FileManager.default
            .contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources") }

        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            files += FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        #expect(files.count > 100, "found only \(files.count) app sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("MacApp/SyncCloudApp.swift") }, "MacApp is not being scanned")
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
