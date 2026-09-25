import Foundation
import Dashboard
import Events
import FileExplorer
import Sync

/// The Edit header's location, and the doors in it (TE43).
///
/// **The app half.** `EditorDocumentLocation` is drawn by `FileExplorer`, which cannot see the pane's
/// breadcrumb model; this is where the location is built from that model, and where a press on it
/// is turned into a move of the LEFT pane — the one pane Edit reads (see `editorFolder`).
enum EditorHeaderLocation {

    /// Where the document at `documentPath` lives, as the left pane's breadcrumb would name it.
    ///
    /// **The pane's own vocabulary, not a second one.** The first segment is
    /// `BreadcrumbTrail.rootDisplayName` — the source's display name, honouring a rename — and the
    /// rest are `BreadcrumbTrail.crumbs` of the folder's path under the source's root, so every
    /// word here is a word the pane's breadcrumb draws for the same folder, and every target is the
    /// combined path that crumb would navigate to.
    ///
    /// **The root test is `PaneLogic.relativePath`, the hand-off's own.** It knows the folders a
    /// root links in from outside — iCloud Drive's `Documents`, which is `~/Documents` on disk — so
    /// a document the pane lists under `iCloud › Documents` is placed there rather than refused. A
    /// folder outside the source is still named, by its own last component, with its
    /// `~`-abbreviated path as the tooltip — and no doors, because the pane cannot go there without
    /// switching the user's source, which is a bigger move than a click on a word should make.
    ///
    /// **With no document open, the pane's folder instead** — `paneFolder`, which is `editorFolder`:
    /// the folder ⌘N and the header's ＋ create in, and so what the empty page's header names. It is
    /// built by the same rules and drawn by the same label, with one difference: the folder's OWN
    /// level is never a door. A door there would send the pane to the folder it is already showing
    /// — "in Finance" would select nothing, and the crumb's last word would re-navigate in place —
    /// so the word is named, not offered. The levels above it stay doors; with the pane folded away
    /// they are the empty page's only way up the tree.
    ///
    /// - Returns: `nil` with no document open and no folder.
    static func location(documentPath: String?, paneFolder: String, sourceRoot: String,
                         providerName: String?, paneIsOpen: Bool,
                         links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> EditorDocumentLocation? {
        let folder: String
        let namesThePanesOwnFolder: Bool
        if let documentPath, !documentPath.isEmpty {
            folder = (documentPath as NSString).deletingLastPathComponent
            namesThePanesOwnFolder = false
        } else if !paneFolder.isEmpty {
            folder = paneFolder
            namesThePanesOwnFolder = true
        } else {
            return nil
        }
        let style = EditorDocumentLocation.Style.forPane(isOpen: paneIsOpen)
        guard !sourceRoot.isEmpty,
              let relative = PaneLogic.relativePath(of: folder, under: sourceRoot, links: links) else {
            let name = (folder as NSString).lastPathComponent
            return EditorDocumentLocation(
                segments: [.init(name: name.isEmpty ? folder : name, target: nil)],
                style: style,
                help: (folder as NSString).abbreviatingWithTildeInPath)
        }
        let source = EditorDocumentLocation.Segment(
            name: BreadcrumbTrail.rootDisplayName(forRootPath: sourceRoot, providerName: providerName),
            target: "")
        let below = BreadcrumbTrail.crumbs(forRelativePath: relative).map {
            EditorDocumentLocation.Segment(name: $0.name, target: $0.relativePath)
        }
        var segments = [source] + below
        if namesThePanesOwnFolder, let last = segments.popLast() {
            segments.append(.init(name: last.name, target: nil))
        }
        return EditorDocumentLocation(
            segments: segments, style: style,
            help: segments.map(\.name).joined(separator: EditorDocumentLocation.separator))
    }
}

/// What a press on the header's location does to the left pane.
///
/// **A value holding exactly what it needs, so the answer can be driven against a real
/// `FileSyncManager` in a test** — the same shape as `DuplicateRevealCoordinator`. What it is NOT
/// handed is as much the design as what it is: no pane-visibility state, so no door can expand a
/// collapsed pane (leaving "Just the text" does not re-expand it either — a request to look
/// somewhere is not a request for the pane); and no document, so no door can settle, reload or
/// replace the open file. Both of those are properties of the type, not of care taken in a body.
@MainActor
struct EditorLocationDoors {
    let syncManager: FileSyncManager
    /// Whether the left pane draws columns — the pane's crumb route needs it to tell a browse move
    /// from a re-root, and it must be the mode the pane is ACTUALLY in (`resolvedViewMode`), for the
    /// reason `editorFolder` gives.
    let drawsColumns: Bool
    /// The pane's own selection write — the binding a click in the pane goes through.
    let selectInPane: (Set<String>) -> Void

    /// - Parameters:
    ///   - documentPath: the open document, read at press time — the closure the header holds was
    ///     built during a render, and the document can have changed since.
    ///   - location: likewise, the location as it stands now.
    func open(_ door: EditorDocumentLocation.Door, documentPath: String?,
              location: EditorDocumentLocation?) {
        switch door {
        case .goTo(let target):
            // **The pane breadcrumb's own route**, so a header crumb and the pane's crumb for the
            // same folder do the same thing: a browse move inside the pane's scope, a re-root above
            // it. The pane may be collapsed; it moves anyway, and the rail — which lists the pane's
            // folder — follows it.
            Logger.shared.debug("[editor-header] crumb → left pane to \(target.isEmpty ? "root" : target)")
            syncManager.navigatePane(isLeft: true, toCombinedPath: target, drawsColumns: drawsColumns)
        case .showInPane:
            // The folder's target is re-read from the live location rather than trusted from the
            // press: a door drawn for one document must not select a file in another's folder.
            guard let documentPath, let folder = location?.segments.last?.target else { return }
            Logger.shared.debug("[editor-header] folder → left pane to \(folder.isEmpty ? "root" : folder), selecting \(documentPath)")
            syncManager.navigatePane(isLeft: true, toCombinedPath: folder, drawsColumns: drawsColumns)
            // The file it names, selected where it lives. In Edit a selected text file OPENS
            // (`openSelectedPaneFileInEditor`), and this one is already open — `openInEditor`'s
            // first guard returns for it, so nothing is settled or reloaded.
            selectInPane([documentPath])
        }
    }
}
