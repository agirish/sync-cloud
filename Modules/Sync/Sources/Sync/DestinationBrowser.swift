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
}

/// One column's worth of subfolders, and whether the folder could be read at all.
public struct DestinationFolderListing: Equatable, Sendable {
    /// The subfolders found, name-sorted. Empty and meaningless when `outcome == .unreadable`.
    public let folders: [DestinationFolder]

    /// How much of the folder the listing covers.
    public let outcome: DirectoryListingOutcome

    /// What a column with no rows to show should say — nil when there are rows.
    ///
    /// Lives here rather than in the view because it is the whole point of this type: a column
    /// rendering `folders.isEmpty` as "Empty" is making a claim about a folder that, in the
    /// unreadable case, nobody read. Having one place decide it means the two states cannot drift
    /// back together.
    public var emptyMessage: String? {
        guard folders.isEmpty else { return nil }
        return outcome == .unreadable ? "Can’t be read" : "Empty"
    }

    public init(folders: [DestinationFolder], outcome: DirectoryListingOutcome) {
        self.folders = folders
        self.outcome = outcome
    }
}

/// What a bounded search found, and whether it saw everything.
///
/// The flag exists because all three of `search`'s caps stop it *early* — a match limit, a listing
/// budget, a depth ceiling — and a truncated walk returning a bare array is indistinguishable from a
/// complete one. That is the difference between "these are the folders that match" and "these are
/// the first folders that match", and only the picker can say which it is showing.
public struct DestinationSearchOutcome: Equatable, Sendable {
    /// The folders found, in discovery (breadth-first) order.
    public let matches: [DestinationFolder]
    /// True when the walk stopped before exhausting the tree, so more matches may exist.
    public let isTruncated: Bool

    public static let empty = DestinationSearchOutcome(matches: [], isTruncated: false)

    public init(matches: [DestinationFolder], isTruncated: Bool) {
        self.matches = matches
        self.isTruncated = isTruncated
    }
}

/// The folder tree behind the destination picker.
///
/// Deliberately **not** `PaneChildrenIndex`. That index is built from a pane's published tree,
/// which is rooted at the pane's *focused* path — for the single-source rail that is the lens folder (the
/// loose-files inbox, say), so browsing it could only ever offer destinations inside the folder you
/// are filing out of. The picker has to reach the whole provider.
///
/// It also lists lazily, one directory at a time, rather than walking the provider up front. A
/// picker only ever shows the folders along one path, so a full walk would buy nothing and cost the
/// user a spinner on a tree that can hold tens of thousands of entries. Search is the one operation
/// that needs breadth, and it is bounded (see `search`).
///
/// Every function here is pure and takes its `FileManaging`, so the whole model is exercised
/// against the in-memory mock rather than the disk.
public enum DestinationBrowser {

    /// Immediate subdirectories of `path`, name-sorted case-insensitively.
    ///
    /// Files are dropped: this picker chooses a destination *folder*, and a file row would be a
    /// target you cannot pick. Dot-directories are dropped unless `showHidden` — the enumerator's
    /// own `.skipsHiddenFiles` covers the OS-hidden flag, and the name check covers the rest,
    /// because a folder can be one without the other.
    public static func subfolders(
        of path: String,
        showHidden: Bool = false,
        fileManager: FileManaging
    ) -> [DestinationFolder] {
        listSubfolders(of: path, showHidden: showHidden, fileManager: fileManager).folders
    }

    /// The same listing, keeping "there are no subfolders here" apart from "this folder could not
    /// be read".
    ///
    /// Those were one value until now, and the column that renders it says **"Empty"** — a
    /// statement about a folder nobody managed to look inside. Same root cause as the
    /// folder-replace warning's "0 items": the enumerator behind `subfolders` returns non-nil and
    /// yields nothing for a directory it cannot list, so the `guard let … else { return [] }`
    /// wrapped around it never fired and would have returned `[]` in any case.
    public static func listSubfolders(
        of path: String,
        showHidden: Bool = false,
        fileManager: FileManaging
    ) -> DestinationFolderListing {
        let root = PaneBrowsePath.normalized(path)
        // Not a disk failure: there is no folder to read. `.listed` keeps the empty-state wording
        // as it was rather than accusing the filesystem of something it did not do.
        guard !root.isEmpty else { return DestinationFolderListing(folders: [], outcome: .listed) }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let listing = fileManager.listing(of: URL(fileURLWithPath: root), options: options)
        guard listing.outcome != .unreadable else {
            return DestinationFolderListing(folders: [], outcome: .unreadable)
        }

        var folders: [DestinationFolder] = []
        for url in listing.urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let name = url.lastPathComponent
            if !showHidden, name.hasPrefix(".") { continue }
            folders.append(DestinationFolder(path: url.path))
        }
        return DestinationFolderListing(
            folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            outcome: listing.outcome)
    }

    /// Folders under `root` whose name contains `query`, breadth-first.
    ///
    /// Breadth-first and bounded on purpose. The corpus is a live provider, which can be very large
    /// and very deep; a depth-first walk would spend its whole budget inside the first branch and
    /// return matches from one corner of the tree. Going level by level means the results are the
    /// *shallowest* matches, which are also the ones a person filing a document is most likely to
    /// mean — and the caps turn an unbounded walk into a predictable one.
    ///
    /// `limit` counts matches, `maxDepth` counts levels below `root`, and `maxListings` counts
    /// directories actually read. All three are hit rather than exceeded: the walk stops as soon as
    /// it has enough, or as soon as it has looked hard enough.
    ///
    /// `maxListings` is the one that makes the cost predictable, and it is not redundant with the
    /// other two. `limit` only bites once matches are *found*, so the expensive case is the query
    /// that matches nothing: without a listing cap, "zzz" reads every directory within six levels of
    /// the root — tens of thousands of them on a real provider — before it can say "no matches".
    /// The bound is on listings rather than on the frontier because a listing is the unit of cost.
    ///
    /// `isCancelled` is polled per directory. The caller runs this on a detached task, which does
    /// **not** inherit cancellation, so without an explicit hook every superseded keystroke's walk
    /// would run to completion behind the one the user is waiting on.
    public static func search(
        _ query: String,
        under root: String,
        showHidden: Bool = false,
        limit: Int = 60,
        maxDepth: Int = 6,
        maxListings: Int = 3000,
        fileManager: FileManaging,
        isCancelled: () -> Bool = { false }
    ) -> DestinationSearchOutcome {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, limit > 0, maxDepth > 0, maxListings > 0 else { return .empty }

        var matches: [DestinationFolder] = []
        var frontier = [PaneBrowsePath.normalized(root)]
        var depth = 0
        var listings = 0
        // A directory the walk could not read is a FOURTH way to leave matches unseen, alongside
        // the three caps. It is not a cap we chose, but it has the same consequence: the walk
        // stopped short of the tree, so it has not earned "No folders match".
        var missedADirectory = false

        while !frontier.isEmpty, depth < maxDepth, matches.count < limit {
            var next: [String] = []
            for directory in frontier {
                if isCancelled() { return .init(matches: matches, isTruncated: true) }
                if listings >= maxListings { return .init(matches: matches, isTruncated: true) }
                listings += 1
                let listing = listSubfolders(of: directory, showHidden: showHidden, fileManager: fileManager)
                if listing.outcome != .listed { missedADirectory = true }
                for folder in listing.folders {
                    if folder.name.localizedCaseInsensitiveContains(needle) {
                        matches.append(folder)
                        if matches.count >= limit { return .init(matches: matches, isTruncated: true) }
                    }
                    next.append(folder.path)
                }
            }
            frontier = next
            depth += 1
        }
        // Falling out with directories still queued means the DEPTH cap stopped it, which is the
        // third way to leave matches unseen. Only an exhausted frontier is a complete answer.
        return .init(matches: matches, isTruncated: !frontier.isEmpty || missedADirectory)
    }

    /// Orders search results so the folder the user meant is first.
    ///
    /// The order is: folders they have filed into recently (in that order), then an exact name, then
    /// a name that starts with the query, then shallower before deeper, then alphabetical. Recency
    /// leads because filing is repetitive — the same handful of folders absorb most of it — and a
    /// list that re-learns your habits every time is a list you have to read every time.
    ///
    /// Pure, and separate from `search`, so the ordering can be asserted without a filesystem.
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
    /// This is the subtitle under a search match, and it is what makes two folders of the same name
    /// tellable apart — which is not a hypothetical: the report that started this feature involved
    /// a `Divit` under `Health/Medical/Kaiser` and another under `School`.
    ///
    /// A path that is not under `root` yields its own parent components, so a result from the
    /// system panel still reads sensibly rather than coming back empty.
    ///
    /// The root itself trails **nothing**: there is no level between a folder and itself. Handling
    /// that explicitly rather than letting it fall through to the outside-the-root branch, which
    /// answered with the root's own ancestors — `trail(of: "~/Dropbox", under: "~/Dropbox")` came
    /// back as `["Users", "abhishek"]`, and `crumbs` then read "Dropbox › abhishek › Dropbox".
    public static func trail(of path: String, under root: String) -> [String] {
        let normalizedPath = PaneBrowsePath.normalized(path)
        let normalizedRoot = PaneBrowsePath.normalized(root)
        if normalizedPath == normalizedRoot { return [] }
        let parent = (normalizedPath as NSString).deletingLastPathComponent

        guard !normalizedRoot.isEmpty else {
            return parent.split(separator: "/").map(String.init)
        }
        if parent == normalizedRoot { return [(normalizedRoot as NSString).lastPathComponent] }
        guard parent.hasPrefix(normalizedRoot + "/") else {
            return parent.split(separator: "/").map(String.init)
        }
        let relative = String(parent.dropFirst(normalizedRoot.count + 1))
        return [(normalizedRoot as NSString).lastPathComponent] + relative.split(separator: "/").map(String.init)
    }

    /// The chosen folder as breadcrumb components, with `providerName` standing in for the root's
    /// own folder name — the picker's footer line, and the one place that has to get the root case
    /// right, because the rail's "Places" row selects exactly that folder in one click.
    ///
    /// Composed here rather than in the view because it is string arithmetic with a boundary case
    /// at each end (the root itself, and a folder outside the root reached through `Other…`), and
    /// arithmetic with boundary cases belongs somewhere it can be asserted.
    public static func crumbs(for path: String, under root: String, providerName: String) -> [String] {
        let normalizedPath = PaneBrowsePath.normalized(path)
        guard !normalizedPath.isEmpty else { return [] }
        let normalizedRoot = PaneBrowsePath.normalized(root)
        // The root itself is one crumb: the provider. Anything else would repeat its name.
        if normalizedPath == normalizedRoot { return [providerName] }

        let leaf = (normalizedPath as NSString).lastPathComponent
        let levels = trail(of: normalizedPath, under: normalizedRoot)
        // Under the root, `trail` leads with the root's own folder name — drop it and let the
        // provider's display name stand there instead. Outside it (the `Other…` escape) there is no
        // such leading component to drop, and the provider's name would be a lie, so the path
        // speaks for itself.
        let isUnderRoot = !normalizedRoot.isEmpty && normalizedPath.hasPrefix(normalizedRoot + "/")
        return isUnderRoot ? [providerName] + levels.dropFirst() + [leaf] : levels + [leaf]
    }

    // MARK: - Pre-flight refusals

    /// Whether moving `sources` into `destination` is the "into its own descendant" case.
    ///
    /// `validateFileOperation` already refuses this and throws `nestingViolation`, but it does so
    /// per item, inside the operation, *after* the user has confirmed. Asking the same question
    /// before the picker's Move button lights up turns a post-hoc error alert into a button that
    /// simply never offered.
    ///
    /// Deliberately a re-ask rather than a replacement: the operation layer keeps its own check,
    /// because a picker is not the only route in and the guard must hold for all of them.
    public static func destinationIsInsideSelection(_ destination: String, sources: [String]) -> Bool {
        let target = PaneBrowsePath.normalized(destination)
        return sources.contains { source in
            let normalized = PaneBrowsePath.normalized(source)
            return target == normalized || target.hasPrefix(normalized + "/")
        }
    }

    /// Names among `sources` that will raise a collision prompt when moved into `destination`.
    ///
    /// The absolute move is **flat** — every selected item lands beside the others — which makes two
    /// separate causes of the same outcome:
    ///
    /// 1. The name is already taken in `destination`.
    /// 2. Two selected items share a name. They derive the *same* target, so the first arrives and
    ///    the second collides with it. Nothing on disk has to be in the way for this, which is why
    ///    a pure existence check misses it entirely.
    ///
    /// The collision prompt handles both at execution time, one modal per item; surfacing the count
    /// beforehand is what turns "confirm, then answer four questions you did not expect" into a
    /// decision made once, up front. Reporting both together is right because the user-visible
    /// consequence is identical — a prompt, per name — and a preview that covered only the first
    /// cause would still leave the second arriving unannounced.
    ///
    /// De-duplicated and in selection order: the names are what the footer counts, and a name that
    /// collides for both reasons at once is still one prompt.
    ///
    /// An item already sitting in `destination` is NOT a collision with itself — it is the
    /// already-there case, which `allSourcesAlreadyIn` answers and which a move skips rather than
    /// prompts about. It can still be the thing a *different* selected item collides with, and the
    /// existence check catches that on its own.
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
    /// nothing at all. The picker says so instead of offering a Move that silently no-ops — the
    /// same outcome the transfer layer now reports after the fact.
    public static func allSourcesAlreadyIn(_ destination: String, sources: [String]) -> Bool {
        guard !sources.isEmpty else { return false }
        let target = PaneBrowsePath.normalized(destination)
        return sources.allSatisfy { (PaneBrowsePath.normalized($0) as NSString).deletingLastPathComponent == target }
    }
}
