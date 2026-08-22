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
    ]

    /// Every Swift file under `FileExplorer/Sources/FileExplorer` that is not exempt.
    private static func bannedFromKeyEquivalents() throws -> [(url: URL, text: String)] {
        let all = try sweptSources().filter {
            $0.url.deletingLastPathComponent().lastPathComponent == "FileExplorer"
                && $0.url.pathComponents.contains("Sources")
        }
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

    @Test func noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll() throws {
        var offenders: [String] = []
        for (url, text) in try Self.bannedFromKeyEquivalents() {
            let code = Self.codeOnly(text)
            for banned in Self.bannedSpellings where code.contains(banned) {
                offenders.append("\(url.lastPathComponent) contains `\(banned)`")
            }
        }
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
        let all = try Self.sweptSources().filter {
            $0.url.deletingLastPathComponent().lastPathComponent == "FileExplorer"
                && $0.url.pathComponents.contains("Sources")
        }
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
            guard file.url.deletingLastPathComponent().lastPathComponent == "FileExplorer",
                  file.url.pathComponents.contains("Sources") else { return false }
            let code = Self.codeOnly(file.text)
            return Self.bannedSpellings.contains { code.contains($0) }
        }.map { $0.url.lastPathComponent }
        #expect(Set(registering) == exemptNames, """
                files registering a key equivalent: \(Set(registering).sorted()); \
                exempted: \(exemptNames.sorted()). These must agree exactly — a difference either \
                way means the exemption list has drifted from the code.
                """)
    }
}
