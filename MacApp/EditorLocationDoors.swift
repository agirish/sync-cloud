import Foundation
import Dashboard
import Events
import FileExplorer
import Sync

/// The Edit header's location, and the doors in it. `EditorDocumentLocation` is drawn by
/// `FileExplorer`, which can't see the pane's breadcrumb model; this builds the location from that
/// model and turns a press on it into a move of the left pane, the one pane Edit reads (see
/// `editorFolder`).
enum EditorHeaderLocation {

    /// Where the document at `documentPath` lives, as the left pane's breadcrumb would name it.
    ///
    /// In the pane's own words: the first segment is `BreadcrumbTrail.rootDisplayName` (honouring a
    /// rename) and the rest are `BreadcrumbTrail.crumbs` under the source's root, with the targets
    /// those crumbs navigate to. The root test is `PaneLogic.relativePath`, which knows linked
    /// folders such as iCloud Drive's `Documents`, so such a document is placed, not refused.
    ///
    /// With no document open it names the pane's folder (`paneFolder`, which is `editorFolder`,
    /// where ⌘N and ＋ create), and that folder's own level is not a door, since it would go
    /// nowhere; the levels above stay doors, the empty page's only way up.
    ///
    /// A folder under another of `otherSources` is spelled from that source's name down ("in
    /// Dropbox › Backup"), most specific root first; any other folder by its last component, with
    /// its `~` path as the tooltip. Neither gets doors: switching the pane's source is a bigger move
    /// than a click on a word should make.
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

    /// The other source `folder` lies under, with its path below that source's root; the most
    /// specific root when two nest (a folder source inside a cloud's folder).
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

    /// The survey's subfolders, only while the survey is of `folder`. A move is instant but its
    /// survey can take seconds, and the old folder's names under the new folder's target would name
    /// folders that don't exist; picking one would re-root the pane there.
    static func subfolders(_ surveyFolders: [String], surveyed: String?, folder: String) -> [String] {
        surveyed == folder ? surveyFolders : []
    }

    /// The rail's folder menu (``EditorFolderTrail``): the location's levels for the pane's folder,
    /// with the same words and targets and the folder's own level not offered, plus the folder's
    /// own target, which a subfolder's is built from. `nil` with no folder.
    static func folderTrail(paneFolder: String, sourceRoot: String, providerName: String?,
                            subfolders: [String],
                            otherSources: [(name: String, root: String)] = [],
                            links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> EditorFolderTrail? {
        guard let location = location(documentPath: nil, paneFolder: paneFolder, sourceRoot: sourceRoot,
                                      providerName: providerName, paneIsOpen: true,
                                      otherSources: otherSources, links: links) else { return nil }
        // The same root test `location` made: a folder it gave doors is one this answers for.
        let here = sourceRoot.isEmpty ? nil
            : PaneLogic.relativePath(of: paneFolder, under: sourceRoot, links: links)
        return EditorFolderTrail(levels: location.segments, currentTarget: here, subfolders: subfolders)
    }

    /// What the ＋, the naming row and the rail call the folder a new file goes in: the pane
    /// breadcrumb's word, the location's last word with no document open. Not `lastPathComponent`,
    /// which says "com~apple~CloudDocs" at the top of iCloud Drive. Empty with no folder.
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
/// A value holding only what it needs, so a test can drive it against a real `FileSyncManager`.
/// It gets no pane-visibility state, so no door can expand a collapsed pane, and no document, so
/// no door can settle, reload or replace the open file.
@MainActor
struct EditorLocationDoors {
    let syncManager: FileSyncManager
    /// Whether the left pane draws columns, which the crumb route needs to tell a browse move from
    /// a re-root. It must be the mode the pane is actually in (`resolvedViewMode`); see
    /// `editorFolder`.
    let drawsColumns: Bool
    /// Where the one line per press goes: `Logger.shared.info` in the app. Info, because a re-root
    /// also re-scopes Compare and clears the session's ignored paths, and under "Just the text" the
    /// log is the only place the press shows. A closure, so a test can read what was said.
    let log: (String) -> Void
    /// Selects a file in the left pane. In the app, `owePaneSelection`, the one rule for every door
    /// that shows the open document in the pane: selected once the pane lists it, through the
    /// click's setter, and scrolled into view.
    let selectInPane: (String) -> Void

    /// Sends the left pane to `target`, a combined pane path, and logs it under `origin` (a header
    /// crumb, or a pick in the rail's folder menu). The pane breadcrumb's own route, so all three
    /// do the same: a browse move inside the scope, a re-root above it. A collapsed pane moves
    /// anyway, and the rail follows it.
    func goTo(_ target: String, from origin: String) {
        let before = PaneMove.State(of: syncManager)
        syncManager.navigatePane(isLeft: true, toCombinedPath: target, drawsColumns: drawsColumns)
        log("\(origin): \(PaneMove.describe(from: before, to: .init(of: syncManager), target: target))")
    }

    /// - Parameters:
    ///   - documentPath: the open document, read at press time, since the header's closure was
    ///     built during a render and the document may have changed since.
    ///   - location: likewise, the location as it stands now.
    func open(_ door: EditorDocumentLocation.Door, documentPath: String?,
              location: EditorDocumentLocation?) {
        switch door {
        case .goTo(let target):
            goTo(target, from: "Edit header crumb")
        case .showInPane:
            // Re-read the folder's target from the live location, not the press: a door drawn for
            // one document must not select a file in another's folder.
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
            // Owed, not written, since a re-root publishes the folder's tree only after the move.
            // In Edit a selected text file opens (`openSelectedPaneFileInEditor`), but this one is
            // already open and the write is marked as the app's own, so nothing is reloaded.
            selectInPane(documentPath)
        }
    }

    /// What a door did to the left pane, in the log's words. Read off the manager before and
    /// after, not predicted, so it can't disagree with `navigatePane`'s own decision.
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
