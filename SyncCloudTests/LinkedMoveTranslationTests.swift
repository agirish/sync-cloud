import Testing
import Foundation
import Sync

/// Every linked action that hands the sibling pane a path measured from this pane's root translates
/// it with `PathBoundary.reanchor`: sources land at different `openAt` depths (`""` for iCloud,
/// `Documents` for Dropbox, `My Drive/Documents` for Google Drive), so one string can name folders
/// two components apart. Untranslated, it fails quietly: `PaneTabMirror` prunes a missing path, so
/// the tab opens at the top of the account or on an unrelated folder of the same name.
@Suite struct LinkedMoveTranslationTests {
    /// Crumb click, drill and Open in New Tab, named so a failure says which lost the translation.
    /// The app's pair go through `relativePathForPane`, whose own body is checked too;
    /// `FileActionHandler` can't see `ContentView` and calls the rule itself.
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

    /// The negative control: ⌘T's mirror opens the sibling at its own folder, so no path crosses and
    /// nothing is translated. Keeps ``everyLinkedHandoffTranslatesTheSiblingsPath`` from passing on
    /// "the file mentions reanchor somewhere".
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
