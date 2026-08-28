import Foundation
import Testing
@testable import FileExplorer

/// **No window-level key equivalent may claim a bare key — in any module.**
///
/// A SwiftUI `.keyboardShortcut` registers a WINDOW-level key equivalent, and a key equivalent is
/// consulted BEFORE the first responder — this repo states that as measured fact in
/// `ReviewCardView` and again at `FileTreeView`'s destination verbs. With no modifier on it, the
/// equivalent claims a key people TYPE: the filing walkthrough shipped `.keyboardShortcut(.return,
/// modifiers: [])` on its File button and `.keyboardShortcut(.rightArrow, modifiers: [])` on Skip,
/// so with the walkthrough up, pressing ⏎ in the lens header's search field (or the Settings
/// overlay) moved the current file on disk, and → silently skipped it — with no back-step. Key
/// equivalents also fire on key-repeat, so holding ⏎ approved file after file.
///
/// The rule is the whole class, not those two spellings: ANY `.keyboardShortcut(…, modifiers: [])`
/// eats that key everywhere in the window, whatever the key is. A bare key belongs to whoever has
/// key focus; a surface that wants one uses a focusable anchor and `.onKeyPress`, the way
/// `ReviewCardView` and the filing walkthrough card do. The repo-wide scan below has deliberately
/// NO allowlist — for a shape with no legitimate use, a registry of permitted exceptions is how a
/// scan stops being the whole set. The narrower `.defaultAction`/`.cancelAction` ban does carry
/// one, because that shape DOES have a legitimate use (modal sheets), and there the exemptions are
/// the whole point: each is named, justified, and itself asserted to still be needed.
///
/// Source-level because the registration is invisible to a hosted view (the equivalent lives on
/// the window, and `swift test` has no key window to type into), and swept over EVERY module's
/// Sources plus `MacApp/` from here — FileExplorer is merely where both offenders lived, and a
/// per-file scan is the known blind spot (`OrganizeScopeCallSiteTests` documents the habits this
/// follows: name what you scan, fail when it cannot be read, keep a positive control so a rename
/// cannot hollow the scan out).
@Suite struct BareKeyEquivalentScanTests {

    /// The repo's `Modules/` directory, derived from this file's own path.
    private static let modulesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests/FileExplorer
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests
        .deletingLastPathComponent()   // …/Modules/FileExplorer
        .deletingLastPathComponent()   // …/Modules

    /// Every Swift file under every module's `Sources/`, plus `MacApp/` — which is in NO SPM
    /// package, so this sweep is the only test that can read it at all (only CI's app-target step
    /// even compiles it). Tests are exempt on purpose: a test may host the banned shape to
    /// characterise it (`DifferencesTableBindingTests` hosts key handlers), and the defect is only
    /// a defect where it ships.
    private static func sweptSources() throws -> [(url: URL, text: String)] {
        let fm = FileManager.default
        let modules = try #require(
            try? fm.contentsOfDirectory(at: modulesDir, includingPropertiesForKeys: nil),
            "cannot list \(modulesDir.path) — the sweep below would be vacuous")
        var roots = modules.map { $0.appendingPathComponent("Sources") }
        roots.append(modulesDir.deletingLastPathComponent().appendingPathComponent("MacApp"))
        var files: [(URL, String)] = []
        for root in roots {
            // An enumerator can come back non-nil yielding ZERO entries for an unlistable folder,
            // so absence here proves nothing — the count floor below is the real guard.
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                        "cannot read \(url.path) — the sweep would silently skip it")
                files.append((url, text))
            }
        }
        // Non-vacuity: the tree holds ~280 module source files plus MacApp's today. A sweep that
        // found a fraction of that is enumerating the wrong directory, not a smaller codebase.
        try #require(files.count > 150,
                     "swept only \(files.count) files under \(modulesDir.path) — wrong root?")
        try #require(files.contains { $0.0.lastPathComponent == "AutomationsLens.swift" },
                     "AutomationsLens.swift — where both original offenders lived — was not swept")
        try #require(files.contains { $0.0.path.contains("/MacApp/") },
                     "MacApp/ was not swept — and no other test can read it (it is in no package)")
        return files
    }

    /// Comment lines dropped, so prose ABOUT the banned shape (like this file's own doc comments,
    /// or `ReviewCardView`'s "deliberately NOT window-level" note) cannot trip the scan.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `.keyboardShortcut(<anything>, modifiers: <empty>)` — any key, spanning line breaks, with
    /// the empty set spelled any of the three literal ways: `[]`, `EventModifiers()`, `.init()`.
    /// `[^)]*` cannot cross the call's own closing paren, so the `modifiers:` it finds is this
    /// call's. KNOWN HOLE, out of a regex's reach: an empty set behind a name
    /// (`let noMods: EventModifiers = []` … `modifiers: noMods`) — resolving a reference needs a
    /// compiler, not a pattern. The lens-file ban below does not share the hole (it bans the call
    /// outright), which is one more reason it exists.
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
        // The positive control: `.keyboardShortcut` remains in real use (⌘-anything on menu-ish
        // verbs, `.defaultAction`/`.cancelAction` on modal sheets and alerts). If the sweep stops
        // seeing ANY of them the API moved out from under the regex, and this test is green
        // because it is blind.
        //
        // A HOLE this scan cannot close, stated rather than blessed: `.defaultAction` IS bare ⏎
        // at window level and `.cancelAction` IS bare esc — the exact shapes the walkthrough fix
        // removed — but the repo's dozen uses sit on modal sheets/alerts, where nothing else can
        // hold key focus and they are the platform convention. A regex cannot tell a sheet from
        // an always-mounted surface, so they pass here, and re-adding one to a mounted lens would
        // ship green THROUGH THIS TEST. That known hazard is what
        // `noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll` below covers.
        #expect(keyboardShortcutSeen,
                "no `.keyboardShortcut(` anywhere in Modules — the scan is measuring nothing")
    }

    /// **The always-mounted surfaces of `FileExplorer` register NO key equivalents — not
    /// `.keyboardShortcut(` in any spelling, not `.defaultAction`, not `.cancelAction`.**
    ///
    /// An always-mounted surface shares the window with text fields that are taking typing:
    /// `AutomationsLens` keeps its filing walkthrough on screen while the header's search field
    /// has focus, `ReviewCardView` sits above the differences table beside its search, and both
    /// are exactly the situation where a window-level equivalent — consulted BEFORE the first
    /// responder — eats a keystroke aimed at a field. `.cancelAction` on the walkthrough's Cancel
    /// button discarded the user's approvals on an esc typed to clear the search (removed in
    /// `d25dafef`). The repo-wide scan above cannot ban `.defaultAction` / `.cancelAction`,
    /// because modal sheets use them legitimately; a scoped ban with a named, justified exemption
    /// list can be honest where the repo-wide one cannot.
    ///
    /// **The net is every file, minus a written-down exemption — it used to be a filename glob,
    /// and the glob was the bug.** Until 2026-08-21 this netted `*Lens*.swift` while claiming to
    /// cover "always-mounted surfaces". Those are not the same set: `ReviewCardView.swift`,
    /// `DifferencesView.swift`, `FilingWalkthrough.swift` and `FilingSuggestionCard.swift` are all
    /// always mounted and all sat OUTSIDE the net, so adding `.keyboardShortcut(.defaultAction)`
    /// to `ReviewCardView` — bare ⏎ at window level, firing before the first responder — re-shipped
    /// the original defect with this test green (measured; see the mutation note on
    /// `theExemptionsAreTheOnlyWayOut`). A glob decides membership by what a file is CALLED. This
    /// list decides it by what the file IS, and it defaults to *in*: a new view is covered the day
    /// it is added, and taking it out costs an entry and a reason here.
    ///
    /// **The membership test was itself still a path SHAPE until 2026-08-21**, and that sentence
    /// was false for anything below the top level of `Sources/FileExplorer/` — see
    /// `isFileExplorerSource` for what walked through, and
    /// `aFileInASubdirectoryOfSourcesIsStillInTheNet` for why a claim about a net needs a plant
    /// that tries it rather than prose asserting it.
    ///
    /// Deliberately NOT extended past `FileExplorer/Sources/FileExplorer` in the same change: the
    /// other modules' uses (`Dashboard`, `Settings`, `MacApp`) have not been read one by one, and
    /// a net whose exemptions were guessed is the failure this is fixing. The repo-wide
    /// `modifiers: []` ban above already covers all of them for the narrower shape.
    private static let exemptFromTheKeyEquivalentBan: [String: String] = [
        // Presented as a `.sheet` — modal, so nothing else in the window can hold key focus and
        // ⏎/esc on its Save/Cancel pair are the platform convention.
        "AutomationRuleEditor.swift":
            "modal sheet: the rule editor's Cancel/Save pair (.cancelAction/.defaultAction)",
        // Also a sheet. Its ⇧⌘N is a real chord, not a bare key, and its Cancel/Choose pair is
        // the same modal convention.
        "DestinationPicker.swift":
            "modal sheet: Cancel/Choose pair, plus ⇧⌘N (a chord, not a bare key)",
        // Sheet with a single Done button.
        "FilingSpendHistoryView.swift":
            "modal sheet: a lone Done button carrying .defaultAction",
        // §5.4's plan sheet, presented via `.sheet` over the lens — modal, so ⏎ on
        // `Export plan…` is the platform convention and cannot eat a key from the lens below.
        "RestructurePlanSheet.swift":
            "modal sheet: Export plan… carries .defaultAction beside Cancel",
        // §5.5's removal sheet, the same modal convention: Escape on Cancel cannot eat a key
        // from the lens below a `.sheet`.
        "RestructureRemovalSheet.swift":
            "modal sheet: Cancel carries .cancelAction so Escape dismisses",
    ]

    /// Is this file part of `FileExplorer`'s shipped source tree — at ANY depth under it?
    ///
    /// **The depth is the point, and the first version got it wrong.** It asked whether the file's
    /// PARENT directory is named `FileExplorer`, which nets only files sitting directly in
    /// `Sources/FileExplorer/`. Measured 2026-08-21: planting
    /// `Sources/FileExplorer/Sub/EvilAlwaysMountedCard.swift` carrying
    /// `.keyboardShortcut(.defaultAction)` — the re-shipped P1-6 shape — left all four tests in
    /// this suite GREEN, with no exemption written and no reason recorded. That falsified this
    /// file's own two claims: that the net "defaults to *in*: a new view is covered the day it is
    /// added", and that "the exemptions are the only way out". `theExemptionsAreTheOnlyWayOut` was
    /// blind in exactly the same place, because it repeated the same filter.
    ///
    /// Latent when it was found — no module's `Sources/*` tree has a subdirectory today — which is
    /// the whole reason to fix it now: the day someone adds one, the file that gets a subdirectory
    /// is far more likely to be a big lens being broken up than a leaf, and nothing would announce
    /// that it had left the net.
    ///
    /// One predicate, called from all three places that used to spell the filter out, so a future
    /// correction cannot land in two of them.
    static func isFileExplorerSource(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard let sources = components.lastIndex(of: "Sources"), sources + 1 < components.count
        else { return false }
        return components[sources + 1] == "FileExplorer"
    }

    /// Every Swift file under `FileExplorer/Sources/FileExplorer` that is not exempt.
    private static func bannedFromKeyEquivalents() throws -> [(url: URL, text: String)] {
        let all = try sweptSources().filter { isFileExplorerSource($0.url) }
        // Non-vacuity, and the reason the glob failed: the net must hold the known hazards BY
        // NAME. Each of these is an always-mounted surface, and the last four are the ones the
        // `*Lens*` glob missed.
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

    /// The ban itself, over whatever set of files it is handed — so the test below can run it on
    /// the real tree and `aFileInASubdirectoryOfSourcesIsStillInTheNet` can run the very same code
    /// over a planted file, rather than re-implementing it and proving nothing about this path.
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

    /// **Every exemption is a real file that really needs one.** Two ways an exemption list rots:
    /// the file is renamed and the entry silently stops exempting anything (harmless, but the
    /// list now lies), or the key equivalent is removed and the entry stays, quietly holding a
    /// file out of the net forever. Both are findings.
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

    /// **The exemptions are the only way out, and the net is otherwise total.** The guard that
    /// keeps the two tests above from being mutually vacuous: take one exempt file out of the
    /// exemption map and it must be reported as an offender — proving the ban really is applied
    /// to every non-exempt file rather than to a shrinking hand-picked set.
    ///
    /// **This test cannot see membership, only exemption** — it consults the same
    /// `isFileExplorerSource` the net does, so a file the predicate does not count is invisible to
    /// both, and this test says nothing about it. That was not a theoretical gap: until 2026-08-21
    /// the predicate netted only the top level of `Sources/FileExplorer/`, and a planted
    /// `Sub/EvilAlwaysMountedCard.swift` carrying `.keyboardShortcut(.defaultAction)` left this
    /// test green alongside the other three (measured, both directions — with the predicate fixed
    /// the same plant fails this test AND `noAlwaysMountedSurface…`). Membership is pinned
    /// separately, by `aFileInASubdirectoryOfSourcesIsStillInTheNet`; "the net is total" above is
    /// a claim about the exemption map, not about the predicate.
    @Test func theExemptionsAreTheOnlyWayOut() throws {
        // Measured, 2026-08-21, each mutation restored afterwards:
        //   • `.keyboardShortcut(.defaultAction)` added to ReviewCardView — under the previous
        //     `*Lens*.swift` glob the scan stayed GREEN (the re-shipped P1-6 bug, invisible);
        //     under this net `noAlwaysMountedSurface…` fails naming ReviewCardView.swift.
        //   • DestinationPicker's exemption deleted — `noAlwaysMountedSurface…` fails naming it,
        //     so the map really is what holds an exempt file out, not some other filter.
        //   • a bogus exemption added for PaneActionBar.swift (which registers nothing) —
        //     `everyExemptionNamesALiveFileThatStillRegistersOne` fails.
        let exemptNames = Set(Self.exemptFromTheKeyEquivalentBan.keys)
        let netted = try Self.bannedFromKeyEquivalents().map { $0.url.lastPathComponent }
        #expect(Set(netted).isDisjoint(with: exemptNames),
                "an exempt file is in the net — the filter is not applying the map")
        // Every file that registers one is either in the net (and so an offender) or exempt.
        // With the suite green the first set is empty, so this says: the exemptions account for
        // ALL of them, and nothing is escaping the ban some third way.
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

    /// **The other half of the rule this suite enforces.** The ban says a surface that wants a
    /// bare key uses `.onKeyPress` instead of a window-level equivalent — but `.onKeyPress` does
    /// not do for free the one thing an equivalent did: refuse chords. No overload filters
    /// modifiers (the single-key one included — measured; see `KeyPress.isPlainKeystroke`), and
    /// none of them matches the keypad's Enter when keyed on `.return` alone, because keyCode 76
    /// sends U+0003 rather than U+000D.
    ///
    /// The panes' ↩-rename is the app's third ↩-as-decision site, after the two cards, and it was
    /// the one the conversion range skipped: `.onKeyPress(.return) { paneRename() }`, so ⌘↩/⌥↩ and
    /// friends each opened the rename editor — stealing a chord another surface owns — and the
    /// keypad's Enter did nothing at all while the File menu's Rename item advertises ↩.
    ///
    /// **Source-level because there is no alternative**: `MacApp/` is in NO SPM package, this
    /// sweep is the only test that can read it, and only CI's second step even compiles it. A
    /// behavioural test of this handler cannot exist today.
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

    /// **Depth does not buy a way out of the net.** The claims above — "it defaults to *in*: a new
    /// view is covered the day it is added" and "the exemptions are the only way out" — were false
    /// for any file below the first level of `Sources/FileExplorer/`, because the membership test
    /// asked what the file's PARENT directory was called. Measured 2026-08-21: a real
    /// `Sources/FileExplorer/Sub/EvilAlwaysMountedCard.swift` carrying
    /// `.keyboardShortcut(.defaultAction)` passed all four tests here green.
    ///
    /// The plant is a synthesized entry rather than a file written into the source tree: the tree
    /// is what every other scan in this package reads, and a test that mutates it races them and
    /// can leave debris behind if it dies mid-run. What matters is that the plant goes through the
    /// REAL code — `isFileExplorerSource`, the exemption map, and `offenders(in:)` are the same
    /// three the shipping test calls, so a regression in any of them fails here too.
    ///
    /// Non-vacuity is asserted both ways: the same plant moved one directory sideways (into
    /// `Sources/Design/Sub/`, another module's tree) must NOT be netted, or this test would pass
    /// for a filter that nets everything.
    @Test func aFileInASubdirectoryOfSourcesIsStillInTheNet() throws {
        let modules = Self.modulesDir
        let planted = modules.appendingPathComponent(
            "FileExplorer/Sources/FileExplorer/Sub/EvilAlwaysMountedCard.swift")
        let elsewhere = modules.appendingPathComponent(
            "Design/Sources/Design/Sub/EvilAlwaysMountedCard.swift")
        // The re-shipped P1-6 shape: bare ⏎ at window level, on a card that is always mounted.
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
