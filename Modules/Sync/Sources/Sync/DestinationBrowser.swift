import Foundation

/// One folder offered as a move/copy destination.
public struct DestinationFolder: Identifiable, Hashable, Sendable {
    /// Absolute path, standardized (no trailing slash).
    public let path: String
    /// Display name — the folder's own last component.
    public let name: String

    public var id: String { path }

    public init(path: String) {
        self.path = PaneBrowsePath.normalized(path)
        self.name = (self.path as NSString).lastPathComponent
    }

    /// A folder shown under a name that is not its own last component: a folder a root only links
    /// to, listed under the link's name (`Documents` in iCloud Drive) at its real path.
    public init(path: String, name: String) {
        self.path = PaneBrowsePath.normalized(path)
        self.name = name
    }
}

/// One column's worth of subfolders, and whether the folder could be read at all.
public struct DestinationFolderListing: Equatable, Sendable {
    /// The subfolders found, name-sorted. Empty and meaningless when `outcome == .unreadable`.
    public let folders: [DestinationFolder]

    /// How much of the folder the listing covers.
    public let outcome: DirectoryListingOutcome

    /// What a column with no rows should say, or nil when there are rows. Decided here, not in the
    /// view, so "Empty" is never said of a folder nobody could read. Switched exhaustively, never
    /// with `!=`, so a partial listing isn't read as "Empty" (``DirectoryListingOutcome``).
    public var emptyMessage: String? {
        guard folders.isEmpty else { return nil }
        switch outcome {
        case .listed:
            return "Empty"
        case .listedWithUnreadableDescendants:
            // `listSubfolders` lists shallowly and never yields this, but the type is public and
            // a recursive builder must get true wording.
            return "Can’t be fully read"
        case .unreadable:
            return "Can’t be read"
        }
    }

    public init(folders: [DestinationFolder], outcome: DirectoryListingOutcome) {
        self.folders = folders
        self.outcome = outcome
    }
}

/// What a bounded search found, and, as two separate facts, why it might not be everything. A cap
/// stops the walk early, so "showing the first N, narrow the search" is right. An unreadable
/// directory is different: the walk finished, so these aren't "the first N", and no query reaches
/// behind it. One flag for both would make the picker's advice false.
public struct DestinationSearchOutcome: Equatable, Sendable {
    /// The folders found, in discovery (breadth-first) order.
    public let matches: [DestinationFolder]

    /// True when a cap stopped the walk before it exhausted the tree: the match limit, the listing
    /// budget, the depth ceiling, or cancellation. A tighter query can reach further.
    public let stoppedEarly: Bool

    /// True when at least one directory in range could not be listed. The walk wasn't cut short;
    /// part of the tree was withheld, and no narrowing will open it. Not combined with
    /// `stoppedEarly` into an `isComplete`: `emptyMessage` and `footnote` switch on the pair,
    /// because each cause needs its own sentence.
    public let skippedUnreadableDirectory: Bool

    public static let empty = DestinationSearchOutcome(
        matches: [], stoppedEarly: false, skippedUnreadableDirectory: false)

    public init(matches: [DestinationFolder], stoppedEarly: Bool, skippedUnreadableDirectory: Bool) {
        self.matches = matches
        self.stoppedEarly = stoppedEarly
        self.skippedUnreadableDirectory = skippedUnreadableDirectory
    }

    /// What the results pane says when nothing matched.
    ///
    /// Decided here, as in ``DestinationFolderListing/emptyMessage``: "No folders match" is earned
    /// only by a complete walk. Each other case says what the person can do, if anything.
    public func emptyMessage(query: String) -> String {
        switch (stoppedEarly, skippedUnreadableDirectory) {
        case (false, false):
            return "No folders match “\(query)”"
        case (true, false):
            return "No matches in the folders searched — “\(query)” may be deeper in, or further afield."
        case (false, true):
            return "No matches in the folders that could be read — “\(query)” may be inside one that couldn’t."
        case (true, true):
            return "No matches yet — “\(query)” may be deeper in, or inside a folder that couldn’t be read."
        }
    }

    /// The footnote under a non-empty result list, or nil when the list is the whole answer.
    ///
    /// - Parameter shown: how many rows the list is actually rendering, which is what "the first N"
    ///   has to agree with.
    public func footnote(showing shown: Int) -> String? {
        switch (stoppedEarly, skippedUnreadableDirectory) {
        case (false, false):
            return nil
        case (true, false):
            return "Showing the first \(shown) — narrow the search, or browse to it."
        case (false, true):
            // Not "the first \(shown)": this walk finished. Not "narrow the search": the folders
            // it couldn't open stay shut whatever the query.
            return "Some folders couldn’t be read — a match may be inside one of them."
        case (true, true):
            return "Showing the first \(shown), and some folders couldn’t be read — there may be more either way."
        }
    }
}

/// The folder tree behind the destination picker.
///
/// Not `PaneChildrenIndex`: that is rooted at the pane's focused path (on the single-source rail,
/// the lens folder), so it could only offer destinations inside the folder being filed out of. The
/// picker must reach the whole provider.
///
/// Lists lazily, one directory at a time: the picker shows only the folders along one path, so a
/// full walk would just cost a spinner. Search needs breadth and is bounded (`search`). Every
/// function is pure and takes its `FileManaging`, so tests run against the in-memory mock.
public enum DestinationBrowser {

    /// Immediate subdirectories of `path`, name-sorted case-insensitively, keeping "no subfolders
    /// here" apart from "this folder could not be read" (an unlistable directory enumerates as
    /// nothing, which must not read as "Empty").
    ///
    /// Files are dropped, since a file row is a target you can't pick. Dot-directories are dropped
    /// unless `showHidden`: `.skipsHiddenFiles` covers the hidden flag and the name check the rest,
    /// since a folder can have one without the other. The filter runs inside the walk (`keeping:`),
    /// so a folder with tens of thousands of loose files doesn't collect them all first.
    ///
    /// **A root's linked folders are listed as the real folders they point at**, such as iCloud
    /// Drive's `Desktop` and `Documents` (`PathBoundary.LinkedFolders`). macOS flags both links
    /// hidden, so `.skipsHiddenFiles` alone would hide them. Listed at the real path (`~/Documents`),
    /// the spelling nodes, columns and selections use, under the link's name, which the next
    /// column's `PaneBrowsePath.step` looks up.
    public static func listSubfolders(
        of path: String,
        showHidden: Bool = false,
        fileManager: FileManaging,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) -> DestinationFolderListing {
        let root = PaneBrowsePath.normalized(path)
        // Not a disk failure: there is no folder to read, so `.listed` rather than `.unreadable`.
        guard !root.isEmpty else { return DestinationFolderListing(folders: [], outcome: .listed) }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let listing = fileManager.listing(of: URL(fileURLWithPath: root), options: options) { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return showHidden || !url.lastPathComponent.hasPrefix(".")
        }

        // Switched, not compared with `!=`, so a new `DirectoryListingOutcome` case is a compile
        // error rather than a wrong answer.
        switch listing.outcome {
        case .unreadable:
            return DestinationFolderListing(folders: [], outcome: .unreadable)
        case .listed, .listedWithUnreadableDescendants:
            var folders = listing.urls.map { DestinationFolder(path: $0.path) }
            let linked = PathBoundary.linkedFolders(atRoot: root, in: links)
            if !linked.isEmpty {
                // With hidden files shown the link itself is listed too, in its own spelling:
                // the same folder twice. The real path replaces it.
                folders.removeAll { linked[$0.name] != nil }
                for (name, target) in linked {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: target, isDirectory: &isDirectory),
                          isDirectory.boolValue else { continue }
                    folders.append(DestinationFolder(path: target, name: name))
                }
            }
            return DestinationFolderListing(
                folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                outcome: listing.outcome)
        }
    }

    /// ``listSubfolders(of:showHidden:fileManager:)`` for a caller that can suspend: the picker's
    /// column load. A folder whose contents aren't on this Mac is asked for first through
    /// `waitForContents`, holding no thread, so the listing never waits: an answered folder is on
    /// disk, and an unanswered one reads "Can’t be read" at once. Without this, a dataless folder
    /// whose cloud app isn't running would leave its column, and every later one, loading for good.
    public static func listSubfoldersSuspending(
        of path: String,
        showHidden: Bool = false,
        fileManager: FileManaging,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) async -> DestinationFolderListing {
        let root = PaneBrowsePath.normalized(path)
        if !root.isEmpty {
            _ = await fileManager.waitForContents(of: URL(fileURLWithPath: root))
        }
        return listSubfolders(of: path, showHidden: showHidden, fileManager: fileManager, links: links)
    }

    /// Folders under `root` whose name contains `query`, breadth-first.
    ///
    /// Breadth-first, so the results are the shallowest matches, the ones a person filing a document
    /// most likely means; depth-first would spend the budget in one corner of a large provider.
    /// `limit` counts matches, `maxDepth` levels below `root`, and `maxListings` directories read;
    /// the walk stops as soon as one is reached. `maxListings` bounds the costly case, a query that
    /// matches nothing, which would otherwise read every directory within `maxDepth` levels.
    ///
    /// `isCancelled` is polled per directory: the caller runs this on a detached task, which doesn't
    /// inherit cancellation, so a superseded keystroke's walk would otherwise run to completion.
    ///
    /// **No directory is listed twice, however many names lead to it.** `listSubfolders` keeps
    /// symlinked directories, so a link back up the tree is a cycle: it would return the same path
    /// several times (duplicate `id`s in the picker's `ForEach`, which SwiftUI leaves undefined) and
    /// spend the listing budget going nowhere. Skipping is silent, not `skippedUnreadableDirectory`:
    /// nothing is withheld, and breadth-first means the shallowest name was kept. A link whose own
    /// name matches is still a result; only arriving at the same directory twice is refused.
    public static func search(
        _ query: String,
        under root: String,
        showHidden: Bool = false,
        limit: Int = 60,
        maxDepth: Int = 6,
        maxListings: Int = 3000,
        fileManager: FileManaging,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
        isCancelled: () -> Bool = { false }
    ) -> DestinationSearchOutcome {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, limit > 0, maxDepth > 0, maxListings > 0 else { return .empty }

        var matches: [DestinationFolder] = []
        var frontier = [PaneBrowsePath.normalized(root)]
        var depth = 0
        var listings = 0
        // Directories already listed, by canonical identity, since two spellings can name one.
        var visited: Set<String> = []
        // An unreadable directory withholds a subtree no query can reach, unlike a cap, so it is
        // reported apart from `stoppedEarly` (see `DestinationSearchOutcome`).
        var missedADirectory = false
        func outcome(stoppedEarly: Bool) -> DestinationSearchOutcome {
            .init(matches: matches, stoppedEarly: stoppedEarly, skippedUnreadableDirectory: missedADirectory)
        }

        while !frontier.isEmpty, depth < maxDepth, matches.count < limit {
            var next: [String] = []
            for directory in frontier {
                if isCancelled() { return outcome(stoppedEarly: true) }
                // Checked before the budget is charged: a second name for a walked directory reads
                // nothing, and counting it would let a fan of links spend the budget.
                guard visited.insert(identity(of: directory, using: fileManager)).inserted else { continue }
                if listings >= maxListings { return outcome(stoppedEarly: true) }
                listings += 1
                let listing = listSubfolders(of: directory, showHidden: showHidden, fileManager: fileManager,
                                             links: links)
                switch listing.outcome {
                case .listed:
                    break
                case .listedWithUnreadableDescendants, .unreadable:
                    missedADirectory = true
                }
                for folder in listing.folders {
                    if folder.name.localizedCaseInsensitiveContains(needle) {
                        matches.append(folder)
                        if matches.count >= limit { return outcome(stoppedEarly: true) }
                    }
                    next.append(folder.path)
                }
            }
            frontier = next
            depth += 1
        }
        // Directories still queued means the depth cap stopped it. Only an exhausted frontier is a
        // complete answer.
        return outcome(stoppedEarly: !frontier.isEmpty)
    }

    /// One name per directory, so `search` can tell somewhere new from somewhere already visited
    /// under another spelling. Uses ``DirectoryListingSupport/identity(of:)``, the codebase's one
    /// answer to "are these the same directory".
    ///
    /// Not resolved for an injected `FileManaging`, as in
    /// ``DirectoryListingSupport/traversableTarget(of:using:)``: a mock's paths aren't on this disk,
    /// and resolving would answer about the machine's own tree. A mock holds no symlinks, so the
    /// path is the identity.
    private static func identity(of path: String, using fileManager: FileManaging) -> String {
        guard fileManager is FileManager else { return path }
        return DirectoryListingSupport.identity(of: URL(fileURLWithPath: path))
    }

    /// Orders search results so the folder the user meant is first.
    ///
    /// Recently filed-into folders first (in that order), then an exact name, then a prefix match,
    /// then shallower before deeper, then alphabetical. Recency leads because filing is repetitive:
    /// a handful of folders absorb most of it. Pure and apart from `search`, so tests need no disk.
    public static func ranked(
        _ matches: [DestinationFolder],
        recents: [String],
        query: String,
        under root: String
    ) -> [DestinationFolder] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let recentRank = Dictionary(
            recents.enumerated().map { (PaneBrowsePath.normalized($1), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func key(_ folder: DestinationFolder) -> (Int, Int, Int, Int, String) {
            let name = folder.name.lowercased()
            return (
                recentRank[folder.path] ?? Int.max,
                name == needle ? 0 : 1,
                name.hasPrefix(needle) ? 0 : 1,
                trail(of: folder.path, under: root).count,
                name
            )
        }
        return matches.sorted { a, b in
            let (ka, kb) = (key(a), key(b))
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            if ka.2 != kb.2 { return ka.2 < kb.2 }
            if ka.3 != kb.3 { return ka.3 < kb.3 }
            return ka.4 < kb.4
        }
    }

    /// The folder names between `root` and `path`, outermost first, excluding the folder itself.
    ///
    /// The subtitle under a search match, which tells two folders of the same name apart. A path
    /// outside `root` yields its own parent components, so a result from the system panel still
    /// reads sensibly. The root itself trails nothing; handled first, or it would fall into the
    /// outside-the-root branch and list its own ancestors. A folder under one the root links to
    /// (`~/Documents/Travel` under iCloud Drive) is under the root, through the link's name
    /// (`PathBoundary.relativize`).
    public static func trail(of path: String, under root: String,
                             links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [String] {
        let normalizedPath = PaneBrowsePath.normalized(path)
        let normalizedRoot = PaneBrowsePath.normalized(root)
        if normalizedPath == normalizedRoot { return [] }
        let parent = (normalizedPath as NSString).deletingLastPathComponent

        // Relativize the path, not its parent: a linked folder's parent is `~`, which is in no
        // root, so `~/Documents` would fall to the outside-the-root escape below.
        guard !normalizedRoot.isEmpty,
              let relative = PathBoundary.relativize(normalizedPath, under: normalizedRoot, links: links) else {
            return parent.split(separator: "/").map(String.init)
        }
        return [(normalizedRoot as NSString).lastPathComponent] + relative.split(separator: "/").dropLast().map(String.init)
    }

    /// The chosen folder as breadcrumb components, with `providerName` in place of the root's own
    /// folder name: the picker's footer line. The root case matters, since the rail's "Places" row
    /// selects it in one click. Here rather than in the view so tests can pin both boundary cases
    /// (the root itself, and a folder outside it reached through `Other…`).
    public static func crumbs(for path: String, under root: String, providerName: String,
                              links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [String] {
        let normalizedPath = PaneBrowsePath.normalized(path)
        guard !normalizedPath.isEmpty else { return [] }
        let normalizedRoot = PaneBrowsePath.normalized(root)
        // The root itself is one crumb: the provider. Anything else would repeat its name.
        if normalizedPath == normalizedRoot { return [providerName] }

        let leaf = (normalizedPath as NSString).lastPathComponent
        let levels = trail(of: normalizedPath, under: normalizedRoot, links: links)
        // Under the root, `trail` leads with the root's folder name; the provider's name replaces
        // it. Outside it (the `Other…` escape) the provider's name would be false, so the path
        // speaks for itself.
        let isUnderRoot = !normalizedRoot.isEmpty
            && PathBoundary.relativize(normalizedPath, under: normalizedRoot, links: links) != nil
        return isUnderRoot ? [providerName] + levels.dropFirst() + [leaf] : levels + [leaf]
    }

    // MARK: - Pre-flight refusals

    /// Whether moving `sources` into `destination` is the "into its own descendant" case.
    ///
    /// `validateFileOperation` refuses this too (`nestingViolation`), but only after the user has
    /// confirmed; asking here lets the picker never offer the Move. The operation keeps its own
    /// check, because the picker is not the only route in.
    public static func destinationIsInsideSelection(_ destination: String, sources: [String]) -> Bool {
        let target = PaneBrowsePath.normalized(destination)
        return sources.contains { source in
            let normalized = PaneBrowsePath.normalized(source)
            return target == normalized || target.hasPrefix(normalized + "/")
        }
    }

    /// Names among `sources` that will raise a collision prompt when moved into `destination`.
    ///
    /// The move is flat (every item lands beside the others), so a prompt comes from either a name
    /// already taken in `destination`, or two selected items sharing a name, which collide with
    /// each other with nothing on disk in the way. Both mean a prompt per name, so both are counted,
    /// letting the user decide up front instead of meeting unexpected prompts.
    ///
    /// De-duplicated, in selection order. An item already in `destination` doesn't collide with
    /// itself (a move skips it; see `allSourcesAlreadyIn`), though another item can collide with it.
    public static func collidingNames(
        movingFrom sources: [String],
        into destination: String,
        fileManager: FileManaging
    ) -> [String] {
        let target = PaneBrowsePath.normalized(destination)
        guard !target.isEmpty else { return [] }

        let names = sources.map { (PaneBrowsePath.normalized($0) as NSString).lastPathComponent }
        var seen: Set<String> = []
        var sharedWithinSelection: Set<String> = []
        for name in names where !seen.insert(name).inserted {
            sharedWithinSelection.insert(name)
        }

        var reported: Set<String> = []
        var ordered: [String] = []
        for (source, name) in zip(sources, names) {
            let normalized = PaneBrowsePath.normalized(source)
            let isAlreadyThere = (normalized as NSString).deletingLastPathComponent == target
            let takenAtTarget = !isAlreadyThere
                && fileManager.fileExists(atPath: (target as NSString).appendingPathComponent(name))
            guard takenAtTarget || sharedWithinSelection.contains(name) else { continue }
            if reported.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    /// Whether every one of `sources` already sits directly in `destination`, so a move would do
    /// nothing. The picker says so instead of offering a Move that silently does nothing.
    public static func allSourcesAlreadyIn(_ destination: String, sources: [String]) -> Bool {
        guard !sources.isEmpty else { return false }
        let target = PaneBrowsePath.normalized(destination)
        return sources.allSatisfy { (PaneBrowsePath.normalized($0) as NSString).deletingLastPathComponent == target }
    }
}
