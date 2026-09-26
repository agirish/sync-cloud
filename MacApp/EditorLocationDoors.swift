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
    /// **A folder under ANOTHER source is placed there, in words.** The right pane's Dropbox copy
    /// opened from the differences list stays where it is (`.staysPut`), so the left pane is on a
    /// different source and the header used to read "in Backup" with nothing to say which cloud
    /// that was. `otherSources` — every other enabled source, by display name and expanded root —
    /// is tried with the same root test, most specific root first, and the folder is spelled from
    /// that source's name down: "in Dropbox › Backup", or the whole crumb. **No doors**: the left
    /// pane is not on that source, and switching its source is a bigger move than a click on a word
    /// should make — the rule for any folder outside the pane's source, unchanged.
    ///
    /// - Returns: `nil` with no document open and no folder.
    static func location(documentPath: String?, paneFolder: String, sourceRoot: String,
                         providerName: String?, paneIsOpen: Bool,
                         otherSources: [(name: String, root: String)] = [],
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
            if let other = otherSource(of: folder, among: otherSources, links: links) {
                let segments = [EditorDocumentLocation.Segment(name: other.name, target: nil)]
                    + BreadcrumbTrail.crumbs(forRelativePath: other.relative).map {
                        EditorDocumentLocation.Segment(name: $0.name, target: nil)
                    }
                return EditorDocumentLocation(
                    segments: segments, style: style,
                    help: segments.map(\.name).joined(separator: EditorDocumentLocation.separator),
                    otherSourceName: other.name)
            }
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

    /// The other source `folder` lies under, with its path below that source's root — the one
    /// with the most specific root when two nest (a folder source inside a cloud's folder).
    static func otherSource(of folder: String, among sources: [(name: String, root: String)],
                            links: PathBoundary.LinkedFolders) -> (name: String, relative: String)? {
        sources
            .filter { !$0.root.isEmpty }
            .sorted { $0.root.split(separator: "/").count > $1.root.split(separator: "/").count }
            .lazy
            .compactMap { source in
                PaneLogic.relativePath(of: folder, under: source.root, links: links)
                    .map { (name: source.name, relative: $0) }
            }
            .first
    }

    /// **What the ＋, the naming row and the rail call the folder a new file goes in** — the pane
    /// breadcrumb's word for it, which is the location's own last word with no document open.
    /// `lastPathComponent` said "com~apple~CloudDocs" at the top of iCloud Drive, a name the pane
    /// never shows; the breadcrumb says "iCloud". Empty with no folder.
    static func folderName(paneFolder: String, sourceRoot: String, providerName: String?,
                           otherSources: [(name: String, root: String)] = [],
                           links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> String {
        location(documentPath: nil, paneFolder: paneFolder, sourceRoot: sourceRoot,
                 providerName: providerName, paneIsOpen: true, otherSources: otherSources,
                 links: links)?.segments.last?.name ?? ""
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
    /// Where the one line per press goes — `Logger.shared.info` in the app. **INFO, because the
    /// press is a user-visible act**, and a re-root in particular changes more than the pane: it
    /// re-scopes Compare and clears this session's ignored paths. At `.debug` none of that reached
    /// the log anyone reads, and under "Just the text" — where the pane that moved is folded away —
    /// the log is the only place the press shows at all. A closure, not a call, so a test can read
    /// what was said, as `EditorDocumentClose.run` does.
    let log: (String) -> Void
    /// Selects a file in the left pane — in the app, `owePaneSelection`, the one rule every door
    /// that shows the open document in the pane goes through (TE47): selected once the pane lists
    /// it, through the setter a click uses, and brought into view.
    let selectInPane: (String) -> Void

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
            let before = PaneMove.State(of: syncManager)
            syncManager.navigatePane(isLeft: true, toCombinedPath: target, drawsColumns: drawsColumns)
            log("Edit header crumb: \(PaneMove.describe(from: before, to: .init(of: syncManager), target: target))")
        case .showInPane:
            // The folder's target is re-read from the live location rather than trusted from the
            // press: a door drawn for one document must not select a file in another's folder.
            guard let documentPath else {
                log("Edit header folder name pressed with no document open — nothing to show")
                return
            }
            guard let folder = location?.segments.last?.target else {
                log("Edit header folder name: \(documentPath) is outside the pane's source — the pane was not moved")
                return
            }
            let before = PaneMove.State(of: syncManager)
            syncManager.navigatePane(isLeft: true, toCombinedPath: folder, drawsColumns: drawsColumns)
            log("Edit header folder name: \(PaneMove.describe(from: before, to: .init(of: syncManager), target: folder)), selecting \(documentPath)")
            // The file it names, selected where it lives — OWED rather than written, since a
            // re-root (a Tree pane, or a folder above the scope) publishes the folder's tree only
            // after the move. In Edit a selected text file OPENS (`openSelectedPaneFileInEditor`);
            // this one is already open and the write is marked as the app's own, so nothing is
            // settled or reloaded.
            selectInPane(documentPath)
        }
    }

    /// What a door did to the left pane, in the log's words.
    ///
    /// **Read off the manager before and after, not predicted.** `navigatePane` decides between a
    /// browse move and a re-root from the pane's mode and scope, and a second copy of that decision
    /// here could disagree with it; the pane's root either moved or it did not.
    enum PaneMove {
        struct State: Equatable {
            let root: String
            let combined: String
            @MainActor init(of manager: FileSyncManager) {
                root = manager.leftRelativePath
                combined = manager.combinedRelativePath(isLeft: true)
            }
            init(root: String, combined: String) {
                self.root = root
                self.combined = combined
            }
        }

        static func describe(from before: State, to after: State, target: String) -> String {
            let place = target.isEmpty ? "the source's top" : target
            if after.root != before.root {
                return "left pane re-rooted at \(place) — Compare's left side is scoped there now, and this session's ignored paths were cleared"
            }
            if after.combined != before.combined {
                return "left pane browsed to \(place)"
            }
            return "left pane already showed \(place) — nothing moved"
        }
    }
}
