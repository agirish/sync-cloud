import Testing
import Foundation
import Sync

/// Every linked action that drives the sibling pane with a path measured from this pane's root
/// must translate it first; this is the one place they can all be seen. A linked crumb click
/// (`ContentView.navigateBothPanes`), a linked drill (`FileActionHandler.focusFolder`, in
/// `Dashboard`) and a linked Open in New Tab (`ContentView+PaneTabs.mirrorOpenInNewTab`) each hand
/// a root-relative path to the other pane. Sources land at different `openAt` depths (`""` for
/// iCloud, `Documents` for OneDrive and Dropbox, `My Drive/Documents` for Google Drive), so the
/// same string can name folders up to two components apart; `PathBoundary.reanchor` translates.
///
/// An untranslated mirror fails quietly: `PaneTabMirror` prunes a missing path, so the tab opens at
/// the top of the account, or on an unrelated folder of the same name. The negative control below
/// stops the set's assertion passing on a coincidence.
@Suite struct LinkedMoveTranslationTests {

    /// All three, named individually so a failure says which lost the translation. Two spellings:
    /// the app's pair go through `ContentView.relativePathForPane`, while `FileActionHandler`, in
    /// `Dashboard`, can't see `ContentView` and calls the rule itself. The seam's own body is checked
    /// too, or "calls the seam" would be a claim about a name.
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
            let body = try declarationBody(of: site.declaration, in: try repoFile(site.file))
            #expect(body.contains(site.translator),
                    "\(site.what) drives the sibling with this pane's own root-relative path — on a pair whose sources land at different depths that names a different folder, or none")
        }

        // The seam the first two lean on actually translates.
        let seam = try declarationBody(of: "func relativePathForPane(_ relative: String, isLeft: Bool)",
                                       in: try repoFile("MacApp/ContentView.swift"))
        #expect(seam.contains("PathBoundary.reanchor"),
                "relativePathForPane does not reanchor, so the two call sites above translate nothing")
        // Both anchors, from opposite panes: a seam reading one pane twice would compile, return
        // its input unchanged (source == destination short-circuits), and fail nothing.
        #expect(seam.contains("PaneSideChoice.sibling(isLeft)") && seam.contains("paneOpenAt(isLeft: isLeft)"),
                "relativePathForPane does not read both panes' landing folders: \(seam)")
    }

    /// The negative control. ⌘T's mirror must not translate: neither pane moves, and the sibling
    /// opens a tab at its own current folder, so no path crosses between panes. A `reanchor` here
    /// would be a no-op while the panes are in step and wrong once they drift. Without this control
    /// the test above could pass on "the file mentions reanchor somewhere".
    @Test func theMirrorThatDoesNotCrossPanesDoesNotTranslate() throws {
        let source = try repoFile("MacApp/ContentView+PaneTabs.swift")
        let body = try declarationBody(of: "func openNewTabHere(isLeft: Bool)", in: source)
        // Both spellings: the app's sites reach the rule through `relativePathForPane`, so ruling
        // out only `PathBoundary.reanchor` would let this pass on a member translating that way.
        for translator in ["PathBoundary.reanchor", "relativePathForPane"] {
            #expect(!body.contains(translator),
                    "⌘T's mirror translates a path through \(translator), but it opens the sibling at its own folder and has no path to translate")
        }
        #expect(body.contains("openTabHere(isLeft: sibling"),
                "⌘T's mirror no longer opens the sibling at its own folder — this control is measuring something else now")
    }
}
