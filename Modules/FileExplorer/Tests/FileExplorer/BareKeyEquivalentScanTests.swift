import Foundation
import Testing
@testable import FileExplorer

/// No window-level key equivalent may claim a bare key, in any module.
///
/// A SwiftUI `.keyboardShortcut` registers a window-level key equivalent, consulted before the
/// first responder. With no modifier it claims a key people type: a bare ⏎ on a filing button
/// would move a file on disk when ⏎ is pressed in a search field, and key equivalents fire on
/// key-repeat, so holding the key repeats the action.
///
/// The rule is the whole class: any `.keyboardShortcut(…, modifiers: [])` eats that key everywhere
/// in the window. A bare key belongs to whoever has key focus; a surface that wants one uses a
/// focusable anchor and `.onKeyPress`, as `ReviewCardView` and the filing walkthrough card do. The
/// repo-wide scan has no allowlist, since the shape has no legitimate use. The narrower
/// `.defaultAction`/`.cancelAction` ban has one, for modal sheets, each entry named, justified and
/// asserted to still be needed.
///
/// Source-level because the registration is invisible to a hosted view (`swift test` has no key
/// window to type into), and swept over every module's Sources plus `MacApp/`. It follows
/// `OrganizeScopeCallSiteTests`' habits: name what you scan, fail when it can't be read, and keep a
/// positive control so a rename can't hollow the scan out.
@Suite struct BareKeyEquivalentScanTests {

    /// The repo's `Modules/` directory, derived from this file's own path.
    private static let modulesDir = SourceText.modules

    /// Every Swift file under every module's `Sources/`, plus `MacApp/`, which is in no SPM
    /// package, so only this sweep can read it. Tests are exempt: a test may host the banned shape
    /// to characterise it, and the defect only matters where it ships.
    private static func sweptSources() throws -> [(url: URL, text: String)] {
        let fm = FileManager.default
        let modules = try #require(
            try? fm.contentsOfDirectory(at: modulesDir, includingPropertiesForKeys: nil),
            "cannot list \(modulesDir.path) — the sweep below would be vacuous")
        var roots = modules.map { $0.appendingPathComponent("Sources") }
        roots.append(modulesDir.deletingLastPathComponent().appendingPathComponent("MacApp"))
        var files: [(URL, String)] = []
        for root in roots {
            // An enumerator can come back non-nil yet empty for an unlistable folder, so the count
            // floor below is the real guard.
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                        "cannot read \(url.path) — the sweep would silently skip it")
                files.append((url, text))
            }
        }
        // Non-vacuity: the tree holds hundreds of source files, so a sweep that finds a fraction
        // of them is reading the wrong directory.
        try #require(files.count > 150,
                     "swept only \(files.count) files under \(modulesDir.path) — wrong root?")
        try #require(files.contains { $0.0.lastPathComponent == "AutomationsLens.swift" },
                     "AutomationsLens.swift — where both original offenders lived — was not swept")
        try #require(files.contains { $0.0.path.contains("/MacApp/") },
                     "MacApp/ was not swept — and no other test can read it (it is in no package)")
        return files
    }

    /// Comment lines dropped, so prose about the banned shape can't trip the scan.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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
            let code = Self.codeOnly(text)
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
        // The positive control: `.keyboardShortcut` is still in real use (⌘ chords,
        // `.defaultAction`/`.cancelAction` on modal sheets). If the sweep sees none, the API moved
        // out from under the regex and this test is blind.
        //
        // A hole this scan can't close: `.defaultAction` is bare ⏎ and `.cancelAction` bare esc,
        // but their uses here sit on modal sheets and alerts, the platform convention. A regex
        // can't tell a sheet from an always-mounted surface, so
        // `noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll` below covers that.
        #expect(keyboardShortcutSeen,
                "no `.keyboardShortcut(` anywhere in Modules — the scan is measuring nothing")
    }

    /// The always-mounted surfaces of `FileExplorer` register no key equivalents: no
    /// `.keyboardShortcut(` in any spelling, no `.defaultAction`, no `.cancelAction`.
    ///
    /// An always-mounted surface shares the window with text fields taking typing (the filing
    /// walkthrough beside the header's search, `ReviewCardView` beside the differences search), so
    /// a window-level equivalent would eat a keystroke aimed at a field: an esc typed to clear the
    /// search would cancel the walkthrough and discard its approvals. The repo-wide scan can't ban
    /// these spellings because modal sheets use them; this scoped ban lists its exemptions.
    ///
    /// The net is every file minus a written-down exemption, not a filename glob: a glob decides by
    /// what a file is called and misses always-mounted views without "Lens" in the name. It
    /// defaults to in, so a new view is covered the day it is added; taking it out costs an entry
    /// and a reason here. `aFileInASubdirectoryOfSourcesIsStillInTheNet` checks the net's depth.
    ///
    /// Not extended past `FileExplorer/Sources/FileExplorer`: the other modules' uses haven't been
    /// read one by one, and guessed exemptions would defeat the net. The repo-wide
    /// `modifiers: []` ban already covers them for the narrower shape.
    private static let exemptFromTheKeyEquivalentBan: [String: String] = [
        // Presented as a `.sheet`: modal, so nothing else in the window can hold key focus, and
        // ⏎/esc on its Save/Cancel pair are the platform convention.
        "AutomationRuleEditor.swift":
            "modal sheet: the rule editor's Cancel/Save pair (.cancelAction/.defaultAction)",
        // Also a sheet. Its ⇧⌘N is a real chord, not a bare key, and its Cancel/Choose pair is
        // the same modal convention.
        "DestinationPicker.swift":
            "modal sheet: Cancel/Choose pair, plus ⇧⌘N (a chord, not a bare key)",
        // One-way sync's sheets, each presented with `.sheet` over the window that asked
        // for it: ⏎ on the primary, esc on Later/Cancel, the platform convention for a modal.
        "OneWaySyncSheets.swift":
            "modal sheets: each primary carries .defaultAction, Later/Cancel .cancelAction",
        // Sheet with a single Done button.
        "FilingSpendHistoryView.swift":
            "modal sheet: a lone Done button carrying .defaultAction",
        // Restructure's plan sheet, presented via `.sheet` over the lens: modal, so ⏎ on
        // `Export plan` is the platform convention and can't eat a key from the lens below.
        "RestructurePlanSheet.swift":
            "modal sheet: Export plan carries .defaultAction beside Close/Cancel",
        // Restructure's removal sheet, the same modal convention: Escape on Cancel can't eat a
        // key from the lens below a `.sheet`.
        "RestructureRemovalSheet.swift":
            "modal sheet: Cancel carries .cancelAction so Escape dismisses",
        // The cross-parent pair's confirm sheet, presented the same way and by the same rule as
        // the two above it.
        "RestructurePairMergeSheet.swift":
            "modal sheet: Cancel carries .cancelAction so Escape dismisses",
        // The PDF tools' sheets, each presented with `.sheet` from the header's Tools menu:
        // modal, and kept in a file of their own so the always-mounted menu stays in the net.
        "EditorPDFToolSheets.swift":
            "modal sheets: each tool's Cancel/run pair (.cancelAction/.defaultAction)",
        // The batch's one sheet, presented with `.sheet` by the window for a pane-launched run:
        // modal, and apart from `PanePDFTools.swift`, whose layer is always mounted.
        "EditorPDFBatchSheet.swift":
            "modal sheet: the batch's Cancel/run pair (.cancelAction/.defaultAction)",
        // Combine's and Split's sheet, presented with `.sheet` by `PanePDFCombineSplitLayer`.
        "EditorPDFCombineSplitSheet.swift":
            "modal sheet: Combine's and Split's Cancel/run pair (.cancelAction/.defaultAction)",
        // Add Signature / Add Initials, presented with `.sheet` by Fill & Sign's palette: modal,
        // and apart from `EditorPDFFillPalette.swift`, which is mounted while the palette is up.
        "EditorPDFSignatureSheet.swift":
            "modal sheet: Add Signature's Cancel/Add pair (.cancelAction/.defaultAction)",
    ]

    /// Whether this file is in `FileExplorer`'s shipped source tree, at any depth under it.
    ///
    /// Depth matters: checking only the parent directory's name would let a file in a
    /// subdirectory of `Sources/FileExplorer/` leave the net unannounced, and a big lens split into
    /// a folder is the likely first case.
    ///
    /// One predicate for every place that filters, so a fix can't land in only some of them.
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

    /// The ban itself, over whatever files it is handed, so the test below runs it on the real
    /// tree and `aFileInASubdirectoryOfSourcesIsStillInTheNet` runs the same code on a planted
    /// file.
    private static func offenders(in files: [(url: URL, text: String)]) -> [String] {
        var found: [String] = []
        for (url, text) in files {
            let code = codeOnly(text)
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
            let code = Self.codeOnly(file.text)
            #expect(Self.bannedSpellings.contains { code.contains($0) }, """
                    \(name) is exempted (\(reason)) but registers no key equivalent any more. \
                    Drop the exemption and put the file back in the net.
                    """)
        }
    }

    /// The exemptions are the only way out, and the net is otherwise total. This keeps the two
    /// tests above from being mutually vacuous: every file registering a key equivalent must be
    /// exempt, so the ban applies to every other file, not to a hand-picked set.
    ///
    /// It sees exemption, not membership: it uses the same `isFileExplorerSource` as the net, so a
    /// file the predicate misses is invisible to both. Membership is pinned by
    /// `aFileInASubdirectoryOfSourcesIsStillInTheNet`.
    @Test func theExemptionsAreTheOnlyWayOut() throws {
        // Mutations that must fail: `.keyboardShortcut(.defaultAction)` added to ReviewCardView
        // or DestinationPicker's exemption deleted (`noAlwaysMountedSurface…`); a bogus exemption
        // for a file that registers nothing (`everyExemptionNamesALiveFileThatStillRegistersOne`).
        let exemptNames = Set(Self.exemptFromTheKeyEquivalentBan.keys)
        let netted = try Self.bannedFromKeyEquivalents().map { $0.url.lastPathComponent }
        #expect(Set(netted).isDisjoint(with: exemptNames),
                "an exempt file is in the net — the filter is not applying the map")
        // Every file that registers one is either in the net (and so an offender) or exempt.
        // With the suite green the first set is empty, so the exemptions account for all of them
        // and nothing escapes the ban some third way.
        let registering = try Self.sweptSources().filter { file in
            guard Self.isFileExplorerSource(file.url) else { return false }
            let code = Self.codeOnly(file.text)
            return Self.bannedSpellings.contains { code.contains($0) }
        }.map { $0.url.lastPathComponent }
        #expect(Set(registering) == exemptNames, """
                files registering a key equivalent: \(Set(registering).sorted()); \
                exempted: \(exemptNames.sorted()). These must agree exactly — a difference either \
                way means the exemption list has drifted from the code.
                """)
    }

    /// The other half of the rule: a surface that wants a bare key uses `.onKeyPress`, but that
    /// doesn't refuse chords as an equivalent does. No overload filters modifiers (see
    /// `KeyPress.isPlainKeystroke`), and keyed on `.return` alone none matches the keypad's Enter,
    /// whose keyCode 76 sends U+0003, not U+000D.
    ///
    /// So the panes' ↩-rename must take both keycaps and refuse chords, or ⌘↩/⌥↩ would open the
    /// rename editor and steal a chord another surface owns, and the keypad's Enter would do
    /// nothing while the File menu's Rename advertises ↩.
    ///
    /// Source-level because `MacApp/` is in no SPM package and this sweep is the only test that
    /// can read it.
    @Test func thePanesRenameKeyTakesBothEnterKeycapsAndRefusesChords() throws {
        let contentView = try #require(
            try Self.sweptSources().first { $0.url.path.hasSuffix("/MacApp/ContentView.swift") },
            "MacApp/ContentView.swift was not swept — has it moved, or did the sweep stop reading MacApp/?")
        // Indentation-insensitive: the handler sits deep inside a view builder and a reflow would
        // otherwise fail this for a reason that is not the rule.
        let code = Self.codeOnly(contentView.text)
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

    /// Depth is no way out of the net: a file below the first level of `Sources/FileExplorer/`
    /// is netted like any other, so "a new view is covered the day it is added" holds there too.
    ///
    /// The plant is a synthesized entry, not a file written into the source tree, which every
    /// other scan in this package reads and a dying test could leave debris in. It goes through
    /// the real `isFileExplorerSource`, exemption map and `offenders(in:)`.
    ///
    /// Non-vacuity both ways: the same plant in another module's tree
    /// (`Design/Sources/Design/Sub/`) must not be netted, or a filter that nets everything passes.
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
