import Testing
import Foundation
import Sync

/// Every linked action that drives the SIBLING pane with a path measured from THIS pane's root has
/// to translate it first, and this is the one place all of them can be seen at once.
///
/// **Three call sites, in three modules, and the rule is invisible at each of them.** A linked
/// crumb click (`ContentView.navigateBothPanes`), a linked drill (`FileActionHandler.focusFolder`,
/// in `Dashboard`) and a linked Open in New Tab (`ContentView+PaneTabs.mirrorOpenInNewTab`) each
/// hold a root-relative path and hand it to the other pane. That was exact while every source was
/// rooted at its documents folder. Sources land at `openAt` now — `""` for iCloud, `Documents` for
/// OneDrive and Dropbox, `My Drive/Documents` for Google Drive — so the same string names folders
/// up to two components apart, and the fix is `PathBoundary.reanchor` at each site.
///
/// **The third one was missed, and stayed missed through a whole review round**, because its
/// failure does not look like a failure: `PaneTabMirror` prunes a path the sibling does not have,
/// so an untranslated mirror quietly opens a tab at the top of the account and reads as "that
/// folder isn't over there" — the honest-looking answer — while the folder sits at
/// `Documents/<same name>`. The other direction is worse: `<account>/Family` can exist as an
/// unrelated tree, and then the tab opens on it.
///
/// So the set is asserted as a set. A fourth linked action added later is not covered by this —
/// nothing can be — but a fourth that copies one of these three inherits the translation with it,
/// and the negative control below is what stops the assertion passing on a coincidence.
@Suite struct LinkedMoveTranslationTests {

    static func repoFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCloudTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(path)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(path) — every check below would be vacuous")
    }

    /// The body of the member whose declaration line contains `declaration`, brace-matched and with
    /// its comments stripped.
    ///
    /// Brace-matched rather than a fixed prefix: a `prefix(n)` window over a function is a test that
    /// silently stops covering whatever is added at the END of it, which is the direction that
    /// matters — the same trap `WalkHandoffTests` was repaired for.
    ///
    /// **Comments stripped, and this test is why the rule needs saying twice.** Each of these call
    /// sites carries a comment naming the translator and explaining why it is there — that is the
    /// house style, and it means a scan over the raw text answers "the word appears" rather than
    /// "the call happens". Measured: with the translation deleted from `mirrorOpenInNewTab` and
    /// only its explanatory comment left behind, the un-stripped version of this test **passed**.
    /// A test that a correct comment can satisfy is one that rewards deleting the code and keeping
    /// the prose.
    static func body(of declaration: String, in source: String) throws -> String {
        Self.codeOnly(try rawBody(of: declaration, in: source))
    }

    /// Line and block comments removed. Deliberately not a Swift parser: it does not understand
    /// string literals, so a `"//"` inside one would truncate the line. None of these three bodies
    /// contains one, and a scan that silently reads less than it claims is the failure mode this
    /// whole file is about — so if one ever does, the assertion goes red rather than quiet.
    static func codeOnly(_ source: String) -> String {
        var out = source
        while let start = out.range(of: "/*"), let end = out.range(of: "*/", range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func rawBody(of declaration: String, in source: String) throws -> String {
        let declRange = try #require(source.range(of: declaration),
                                     "cannot find `\(declaration)` — this test names something that no longer exists")
        let after = source[declRange.upperBound...]
        let open = try #require(after.firstIndex(of: "{"), "no body for `\(declaration)`")
        var depth = 0
        var index = open
        while index < after.endIndex {
            if after[index] == "{" { depth += 1 }
            if after[index] == "}" {
                depth -= 1
                if depth == 0 { return String(after[after.index(after: open)..<index]) }
            }
            index = after.index(after: index)
        }
        Issue.record("unbalanced braces in `\(declaration)`")
        return ""
    }

    /// All three, named individually so a failure says which one lost the translation.
    ///
    /// Two spellings, because the two modules cannot share one seam. The app's pair go through
    /// `ContentView.relativePathForPane`, which exists so a tab verb's call names only the pane it
    /// moves (see there); `FileActionHandler` is in `Dashboard`, which cannot see a `ContentView`
    /// member, so it reaches for the rule itself. The seam's own body is checked below, or "calls
    /// the seam" would be a claim about a name rather than about a translation.
    @Test func everyLinkedHandoffTranslatesTheSiblingsPath() throws {
        let sites: [(file: String, declaration: String, translator: String, what: String)] = [
            ("MacApp/ContentView.swift",
             "func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool)",
             "relativePathForPane", "a linked crumb click"),
            ("MacApp/ContentView+PaneTabs.swift",
             "private func mirrorOpenInNewTab(_ relative: String, from isLeft: Bool)",
             "relativePathForPane", "a linked Open in New Tab"),
            ("Modules/Dashboard/Sources/Dashboard/FileActionHandler.swift",
             "public func focusFolder(",
             "PathBoundary.reanchor", "a linked drill into a folder"),
        ]
        for site in sites {
            let body = try Self.body(of: site.declaration, in: try Self.repoFile(site.file))
            #expect(body.contains(site.translator),
                    "\(site.what) drives the sibling with this pane's own root-relative path — on a pair whose sources land at different depths that names a different folder, or none")
        }

        // The seam the first two lean on actually translates.
        let seam = try Self.body(of: "func relativePathForPane(_ relative: String, isLeft: Bool)",
                                 in: try Self.repoFile("MacApp/ContentView.swift"))
        #expect(seam.contains("PathBoundary.reanchor"),
                "relativePathForPane does not reanchor, so the two call sites above translate nothing")
        // Both anchors, and from opposite panes — a seam reading one pane twice would compile,
        // return its input unchanged (source == destination short-circuits), and fail nothing.
        #expect(seam.contains("PaneSideChoice.sibling(isLeft)") && seam.contains("paneOpenAt(isLeft: isLeft)"),
                "relativePathForPane does not read both panes' landing folders: \(seam)")
    }

    /// **The negative control**, and it is what makes the assertion above mean anything.
    ///
    /// ⌘T's mirror is the linked action that must NOT translate: its contract is that neither pane
    /// moves, so the sibling opens a tab at *its own* current folder rather than at this one's.
    /// There is no path crossing between panes, so a `reanchor` here would be translating a path
    /// that was never in the other pane's coordinates to begin with — and, since the two panes are
    /// usually in step, it would be a no-op almost always and wrong exactly when they had drifted.
    ///
    /// Without this control the test above passes on "the file mentions reanchor somewhere".
    @Test func theMirrorThatDoesNotCrossPanesDoesNotTranslate() throws {
        let source = try Self.repoFile("MacApp/ContentView+PaneTabs.swift")
        let body = try Self.body(of: "func openNewTabHere(isLeft: Bool)", in: source)
        // **Both spellings**, since the app's two sites reach the rule through a seam: ruling out
        // only the raw `PathBoundary.reanchor` would leave this control passing on a member that
        // translates through `relativePathForPane`, which is the form the sites it is a control for
        // actually use.
        for translator in ["PathBoundary.reanchor", "relativePathForPane"] {
            #expect(!body.contains(translator),
                    "⌘T's mirror translates a path through \(translator), but it opens the sibling at its own folder and has no path to translate")
        }
        #expect(body.contains("openTabHere(isLeft: sibling"),
                "⌘T's mirror no longer opens the sibling at its own folder — this control is measuring something else now")
    }
}
