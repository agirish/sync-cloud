import Foundation
import Testing
@testable import FileExplorer

/// No window-level key equivalent may claim a bare key, in any module.
///
/// A `.keyboardShortcut` with no modifier is consulted before the first responder, so it eats that
/// key typed into every field in the window (a bare ⏎ on a filing button would move a file when ⏎
/// is pressed in a search field) and fires on key-repeat. A surface that wants a bare key uses a
/// focusable anchor and `.onKeyPress`, as `ReviewCardView` does. The repo-wide scan has no
/// allowlist; the narrower `.defaultAction`/`.cancelAction` ban has one, for modal sheets.
/// Source-level because `swift test` has no key window to type into.
@Suite struct BareKeyEquivalentScanTests {

    /// The repo's `Modules/` directory, derived from this file's own path.
    private static let modulesDir = SourceText.modules

    /// Every Swift file under every module's `Sources/`, plus `MacApp/`, which is in no SPM
    /// package, so only this sweep can read it. Tests are exempt: a test may host the banned shape
    /// to characterise it, and the defect only matters where it ships.
    private static func sweptSources() throws -> [(url: URL, text: String)] {
        let files = try AppCopyScan.sourceFiles().map {
            (url: AppCopyScan.repoRoot.appendingPathComponent($0.path), text: $0.code)
        }
        // Non-vacuity: the tree holds hundreds of source files, so a sweep that finds a fraction
        // of them is reading the wrong directory.
        try #require(files.count > 150,
                     "swept only \(files.count) files under \(modulesDir.path) — wrong root?")
        try #require(files.contains { $0.url.lastPathComponent == "AutomationsLens.swift" },
                     "AutomationsLens.swift — where both original offenders lived — was not swept")
        try #require(files.contains { $0.url.path.contains("/MacApp/") },
                     "MacApp/ was not swept — and no other test can read it (it is in no package)")
        return files
    }

    /// `.keyboardShortcut(<anything>, modifiers: <empty>)`: any key, across line breaks, with the
    /// empty set spelled `[]`, `EventModifiers()` or `.init()`. `[^)]*` can't cross the call's own
    /// closing paren, so the `modifiers:` found is this call's. Known hole: an empty set behind a
    /// name (`modifiers: noMods`) needs a compiler to resolve. The FileExplorer ban below bans the
    /// call outright, so it doesn't share the hole.
    private static let bareEquivalent = try! NSRegularExpression(
        pattern: #"\.keyboardShortcut\(\s*[^)]*modifiers:\s*(\[\s*\]|EventModifiers\(\s*\)|\.init\(\s*\))"#)

    @Test func noModuleSourceRegistersABareKeyEquivalent() throws {
        var offenders: [String] = []
        var keyboardShortcutSeen = false
        for (url, text) in try Self.sweptSources() {
            let code = SourceText.codeOnly(text)
            if code.contains(".keyboardShortcut(") { keyboardShortcutSeen = true }
            let range = NSRange(code.startIndex..., in: code)
            for match in Self.bareEquivalent.matches(in: code, range: range) {
                let upTo = code.index(code.startIndex,
                                      offsetBy: match.range.location, limitedBy: code.endIndex)
                let line = code[..<(upTo ?? code.endIndex)].count(where: { $0 == "\n" }) + 1
                offenders.append("\(url.lastPathComponent):~\(line) (line in comment-stripped text)")
            }
        }
        #expect(offenders.isEmpty, """
                \(offenders.count) bare key equivalent(s): \(offenders.joined(separator: ", ")). \
                A `.keyboardShortcut(…, modifiers: [])` is a window-level key equivalent, consulted \
                before the first responder — it eats that key typed into every field in the window, \
                and fires on key-repeat. Give the surface a focusable anchor and `.onKeyPress` \
                instead (see ReviewCardView / FilingWalkthroughCard). Do not allowlist it here.
                """)
        // Positive control: `.keyboardShortcut` is still in real use (⌘ chords, modal sheets); if
        // the sweep sees none, the regex is blind. A regex can't tell a sheet's bare ⏎/esc from an
        // always-mounted surface's; `noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll` does.
        #expect(keyboardShortcutSeen,
                "no `.keyboardShortcut(` anywhere in Modules — the scan is measuring nothing")
    }

    /// The always-mounted surfaces of `FileExplorer` register no key equivalents: no
    /// `.keyboardShortcut(` in any spelling, no `.defaultAction`, no `.cancelAction`. They share
    /// the window with text fields, so an esc typed to clear the search would cancel the filing
    /// walkthrough and discard its approvals. The net is every file minus a written-down exemption,
    /// not a filename glob, so a new view is covered the day it is added. Limited to
    /// `FileExplorer/Sources/FileExplorer`: the other modules' uses haven't been read one by one,
    /// and guessed exemptions would defeat the net.
    private static let exemptFromTheKeyEquivalentBan: [String: String] = [
        // Each is presented with `.sheet`: modal, so nothing else in the window can hold key focus,
        // and ⏎/esc on its buttons are the platform convention.
        "AutomationRuleEditor.swift":
            "modal sheet: the rule editor's Cancel/Save pair (.cancelAction/.defaultAction)",
        "DestinationPicker.swift":
            "modal sheet: Cancel/Choose pair, plus ⇧⌘N (a chord, not a bare key)",
        "OneWaySyncSheets.swift":
            "modal sheets: each primary carries .defaultAction, Later/Cancel .cancelAction",
        "RestructurePlanSheet.swift":
            "modal sheet: Export plan carries .defaultAction beside Close/Cancel",
        "RestructureRemovalSheet.swift":
            "modal sheet: Cancel carries .cancelAction so Escape dismisses",
        "RestructurePairMergeSheet.swift":
            "modal sheet: Cancel carries .cancelAction so Escape dismisses",
        // Kept in a file of their own so the always-mounted Tools menu stays in the net.
        "EditorPDFToolSheets.swift":
            "modal sheets: each tool's Cancel/run pair (.cancelAction/.defaultAction)",
        // Apart from `PanePDFTools.swift`, whose layer is always mounted.
        "EditorPDFBatchSheet.swift":
            "modal sheet: the batch's Cancel/run pair (.cancelAction/.defaultAction)",
        // Combine's and Split's sheet, presented with `.sheet` by `PanePDFCombineSplitLayer`.
        "EditorPDFCombineSplitSheet.swift":
            "modal sheet: Combine's and Split's Cancel/run pair (.cancelAction/.defaultAction)",
        // Apart from `EditorPDFFillPalette.swift`, which is mounted while the palette is up.
        "EditorPDFSignatureSheet.swift":
            "modal sheet: Add Signature's Cancel/Add pair (.cancelAction/.defaultAction)",
    ]

    /// Whether this file is in `FileExplorer`'s shipped source tree, at any depth: checking only
    /// the parent directory's name would let a lens split into a subfolder leave the net
    /// unannounced. One predicate for every place that filters, so a fix lands in all of them.
    static func isFileExplorerSource(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard let sources = components.lastIndex(of: "Sources"), sources + 1 < components.count
        else { return false }
        return components[sources + 1] == "FileExplorer"
    }

    /// Every Swift file under `FileExplorer/Sources/FileExplorer` that is not exempt.
    private static func bannedFromKeyEquivalents() throws -> [(url: URL, text: String)] {
        let all = try sweptSources().filter { isFileExplorerSource($0.url) }
        // Non-vacuity: the net must hold the known always-mounted surfaces by name, including
        // the four with no "Lens" in theirs.
        for required in ["AutomationsLens.swift", "OrganizeLens.swift", "ReviewCardView.swift",
                         "DifferencesView.swift", "FilingWalkthrough.swift",
                         "FilingSuggestionCard.swift"] {
            try #require(all.contains { $0.url.lastPathComponent == required },
                         "\(required) was not swept — has it been renamed or moved?")
        }
        try #require(all.count > 60, "only \(all.count) file(s) swept — wrong root?")
        return all.filter { exemptFromTheKeyEquivalentBan[$0.url.lastPathComponent] == nil }
    }

    private static let bannedSpellings = [".keyboardShortcut(", ".defaultAction", ".cancelAction"]

    /// The ban itself, over whatever files it is handed, so the real tree and the plant in
    /// `aFileInASubdirectoryOfSourcesIsStillInTheNet` run the same code.
    private static func offenders(in files: [(url: URL, text: String)]) -> [String] {
        var found: [String] = []
        for (url, text) in files {
            let code = SourceText.codeOnly(text)
            for banned in bannedSpellings where code.contains(banned) {
                found.append("\(url.lastPathComponent) contains `\(banned)`")
            }
        }
        return found
    }

    @Test func noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll() throws {
        let offenders = Self.offenders(in: try Self.bannedFromKeyEquivalents())
        #expect(offenders.isEmpty, """
                \(offenders.joined(separator: ", ")). These files ship always-mounted surfaces — \
                any key equivalent registered from one eats that key typed into every field in the \
                window (`.defaultAction` is bare ⏎, `.cancelAction` is bare esc), and key \
                equivalents fire on key-repeat. Use a focusable anchor and `.onKeyPress` (see \
                FilingWalkthroughCard / ReviewCardView). If the file really is a modal sheet, add \
                it to `exemptFromTheKeyEquivalentBan` WITH the reason — an exemption is a decision \
                to write down, not a line to delete.
                """)
    }

    /// Every exemption is a real file that still needs one. An exemption list rots two ways: the
    /// file is renamed and the entry exempts nothing, or the key equivalent goes and the entry
    /// keeps the file out of the net for good. Both fail here.
    @Test func everyExemptionNamesALiveFileThatStillRegistersOne() throws {
        let all = try Self.sweptSources().filter { Self.isFileExplorerSource($0.url) }
        for (name, reason) in Self.exemptFromTheKeyEquivalentBan {
            let file = try #require(all.first { $0.url.lastPathComponent == name },
                                    "exemption for \(name) (\(reason)) names no file under FileExplorer/Sources")
            let code = SourceText.codeOnly(file.text)
            #expect(Self.bannedSpellings.contains { code.contains($0) }, """
                    \(name) is exempted (\(reason)) but registers no key equivalent any more. \
                    Drop the exemption and put the file back in the net.
                    """)
        }
    }

    /// `.onKeyPress` doesn't refuse chords as an equivalent does (see `KeyPress.isPlainKeystroke`),
    /// and keyed on `.return` alone it misses the keypad's Enter (keyCode 76 sends U+0003, not
    /// U+000D). So the panes' ↩-rename must take both keycaps and refuse chords, or ⌘↩/⌥↩ would
    /// open the rename editor and the keypad's Enter would do nothing while the File menu
    /// advertises ↩. Source-level because `MacApp/` is in no SPM package.
    @Test func thePanesRenameKeyTakesBothEnterKeycapsAndRefusesChords() throws {
        let contentView = try #require(
            try Self.sweptSources().first { $0.url.path.hasSuffix("/MacApp/ContentView.swift") },
            "MacApp/ContentView.swift was not swept — has it moved, or did the sweep stop reading MacApp/?")
        // Indentation-insensitive: the handler sits deep inside a view builder and a reflow would
        // otherwise fail this for a reason that is not the rule.
        let code = SourceText.codeOnly(contentView.text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(code.contains(
            ".onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in "
            + "guard press.isPlainKeystroke else { return .ignored } return paneRename() }"), """
                the panes' ↩-rename handler is no longer `keys: [.return, .keypadEnter], phases: \
                .down` guarded on `press.isPlainKeystroke`. Keyed on `.return` alone it is deaf to \
                the keypad's Enter keycap; without the guard, ⌘↩/⇧↩/⌥↩/⌃↩ each open the rename \
                editor and swallow a chord aimed somewhere else. `.isPlainKeystroke` and NOT \
                `modifiers.isEmpty`: the keypad's Enter always carries .numericPad + .function, \
                and .capsLock rides every event while the lock is engaged.
                """)
    }

    /// Depth is no way out of the net: a file below the first level of `Sources/FileExplorer/` is
    /// netted like any other. The plant is a synthesized entry, not a file written into the source
    /// tree, which other scans read and a dying test could leave debris in. Non-vacuity: the same
    /// plant in another module (`Design/Sources/Design/Sub/`) must not be netted.
    @Test func aFileInASubdirectoryOfSourcesIsStillInTheNet() throws {
        let modules = Self.modulesDir
        let planted = modules.appendingPathComponent(
            "FileExplorer/Sources/FileExplorer/Sub/EvilAlwaysMountedCard.swift")
        let elsewhere = modules.appendingPathComponent(
            "Design/Sources/Design/Sub/EvilAlwaysMountedCard.swift")
        // Bare ⏎ at window level, on a card that is always mounted.
        let body = """
            struct EvilAlwaysMountedCard: View {
                var body: some View {
                    Button("File") {}.keyboardShortcut(.defaultAction)
                }
            }
            """

        #expect(Self.isFileExplorerSource(planted), """
                a file at \(planted.path) is not counted as a FileExplorer source. Anything under \
                Sources/FileExplorer is shipped code and belongs in the net whatever depth it \
                sits at — a filter keyed on the immediate parent directory's name is what let \
                this shape through before.
                """)
        #expect(!Self.isFileExplorerSource(elsewhere),
                "\(elsewhere.path) is another module's tree and must not be netted")

        let netted = [(url: planted, text: body)].filter { Self.isFileExplorerSource($0.url) }
            .filter { Self.exemptFromTheKeyEquivalentBan[$0.url.lastPathComponent] == nil }
        #expect(Self.offenders(in: netted) == ["EvilAlwaysMountedCard.swift contains `.keyboardShortcut(`",
                                               "EvilAlwaysMountedCard.swift contains `.defaultAction`"], """
                the planted subdirectory card was not reported: \(Self.offenders(in: netted)). \
                A `.keyboardShortcut(.defaultAction)` on an always-mounted surface is bare ⏎ at \
                window level — it eats Return typed into every field in the window.
                """)
    }
}
