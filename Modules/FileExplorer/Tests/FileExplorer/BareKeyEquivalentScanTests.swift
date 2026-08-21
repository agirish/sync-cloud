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
/// `ReviewCardView` and the filing walkthrough card do. There is deliberately NO allowlist — a
/// registry of permitted exceptions is how this scan stops being the whole set.
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
        // `noLensFileRegistersAnyKeyEquivalentAtAll` below covers.
        #expect(keyboardShortcutSeen,
                "no `.keyboardShortcut(` anywhere in Modules — the scan is measuring nothing")
    }

    /// **A lens file registers NO key equivalents — not `.keyboardShortcut(` in any spelling,
    /// not `.defaultAction`, not `.cancelAction`.**
    ///
    /// Lenses are always-mounted surfaces: `AutomationsLens` keeps its filing walkthrough on
    /// screen while the header's search field takes typing, which is exactly the situation where
    /// a window-level equivalent eats keystrokes aimed at a field — `.cancelAction` on the
    /// walkthrough's Cancel button discarded the user's approvals on an esc typed to clear the
    /// search (removed in `d25dafef`). The repo-wide scan above cannot ban `.defaultAction` /
    /// `.cancelAction` because modal sheets use them legitimately; a file-scoped ban with NO
    /// allowlist can be honest where the repo-wide one cannot. A modal presented FROM a lens that
    /// genuinely wants them belongs in its own file (as `AutomationRuleEditor` already is).
    @Test func noLensFileRegistersAnyKeyEquivalentAtAll() throws {
        let lensFiles = try Self.sweptSources().filter {
            $0.url.deletingLastPathComponent().lastPathComponent == "FileExplorer"
                && $0.url.lastPathComponent.contains("Lens")
        }
        // Non-vacuity: the always-mounted lens surfaces live in files named *Lens* under
        // FileExplorer's Sources (AutomationsLens, OrganizeLens, LensWorkspaceView, …). The known
        // hazard must be in the net, and the net must be more than it.
        try #require(lensFiles.contains { $0.url.lastPathComponent == "AutomationsLens.swift" },
                     "AutomationsLens.swift — the file the walkthrough lives in — was not swept")
        try #require(lensFiles.count >= 5,
                     "only \(lensFiles.count) lens file(s) swept — the naming pattern moved?")
        var offenders: [String] = []
        for (url, text) in lensFiles {
            let code = Self.codeOnly(text)
            for banned in [".keyboardShortcut(", ".defaultAction", ".cancelAction"]
            where code.contains(banned) {
                offenders.append("\(url.lastPathComponent) contains `\(banned)`")
            }
        }
        #expect(offenders.isEmpty, """
                \(offenders.joined(separator: ", ")). A lens is an always-mounted surface — any \
                key equivalent registered from one eats that key typed into every field in the \
                window (`.defaultAction` is bare ⏎, `.cancelAction` is bare esc). Use a focusable \
                anchor and `.onKeyPress` (see FilingWalkthroughCard), or move the modal that \
                wants these into its own file. Do not allowlist here.
                """)
    }
}
