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
    ///
    /// Switched exhaustively rather than tested with `!=`, which is the guarantee
    /// ``DirectoryListingOutcome`` states and the reason it has three cases. A `!=` here read a
    /// PARTIAL listing with no subfolders as "Empty" — the exact conflation the type was built to
    /// stop, reintroduced one case along.
    public var emptyMessage: String? {
        guard folders.isEmpty else { return nil }
        switch outcome {
        case .listed:
            return "Empty"
        case .listedWithUnreadableDescendants:
            // Not reachable from `listSubfolders`, which always lists shallowly and so can never
            // meet a descendant — but this type is public and the wording must not be a lie the
            // day something recursive builds one.
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

/// What a bounded search found, and — in two separate facts — why it might not be everything.
///
/// One boolean was not enough. All three of `search`'s caps stop it *early*, and for those
/// "showing the first N, narrow the search" is exactly right. A directory it could not READ is a
/// fourth way to miss a match with the opposite properties: the walk ran to completion, so these
/// are not "the first N", and narrowing the query will never reach what sits behind a
/// permission-denied folder. Rolled into one flag, the advice the picker renders was false on both
/// halves for that fourth cause.
public struct DestinationSearchOutcome: Equatable, Sendable {
    /// The folders found, in discovery (breadth-first) order.
    public let matches: [DestinationFolder]

    /// True when a CAP stopped the walk before it exhausted the tree — the match limit, the
    /// listing budget, the depth ceiling, or cancellation. More matches may exist further out, and
    /// a tighter query is the way to reach them.
    public let stoppedEarly: Bool

    /// True when at least one directory in range could not be listed. The walk was not cut short;
    /// part of the tree was simply withheld from it, and no amount of narrowing will open it.
    ///
    /// Deliberately NOT joined to `stoppedEarly` by a convenience `isComplete`. There was one, and
    /// nothing in the app ever read it — the picker asks `emptyMessage` and `footnote`, both of
    /// which switch on the PAIR, because the sentence a person needs is different for each cause.
    /// A single boolean over a type whose own reason for existing is that "one boolean was not
    /// enough" is the shape that gets read as the answer and then re-split at every call site, so
    /// it went the way of the `subfolders` wrapper before it. Tests state the two facts.
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
    /// Here rather than in the view for the same reason as ``DestinationFolderListing/emptyMessage``:
    /// "No folders match" is a claim about a corpus, and a walk that stopped short or was refused a
    /// directory has not earned it. Each cause names what a person could do about it, which is a
    /// different thing in each case — and nothing at all in the withheld case, so it says that too.
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
            // NOT "the first \(shown)": this walk finished. And not "narrow the search": the
            // folders it could not open stay shut however short the query gets.
            return "Some folders couldn’t be read — a match may be inside one of them."
        case (true, true):
            return "Showing the first \(shown), and some folders couldn’t be read — there may be more either way."
        }
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

    /// Immediate subdirectories of `path`, name-sorted case-insensitively, keeping "there are no
    /// subfolders here" apart from "this folder could not be read".
    ///
    /// Those were one value until recently, and the column that renders it said **"Empty"** — a
    /// statement about a folder nobody managed to look inside. Same root cause as the
    /// folder-replace warning's "0 items": the enumerator returns non-nil and yields nothing for a
    /// directory it cannot list, so the `guard let … else { return [] }` wrapped around it never
    /// fired and would have returned `[]` in any case.
    ///
    /// Files are dropped: this picker chooses a destination *folder*, and a file row would be a
    /// target you cannot pick. Dot-directories are dropped unless `showHidden` — the enumerator's
    /// own `.skipsHiddenFiles` covers the OS-hidden flag, and the name check covers the rest,
    /// because a folder can be one without the other.
    ///
    /// The dropping happens **inside** the walk, through `listing`'s `keeping:` filter, rather than
    /// on an array it hands back. This runs on the user's own folders, which can hold tens of
    /// thousands of loose files next to a handful of subfolders; collecting every entry first would
    /// cost memory proportional to the files to answer a question about the folders. That is the
    /// same reasoning `childCount` and the sidebar's size walk already state for not using
    /// `listing(of:)` at all, and this is the site where it had not been applied.
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

        let listing = fileManager.listing(of: URL(fileURLWithPath: root), options: options) { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return showHidden || !url.lastPathComponent.hasPrefix(".")
        }

        // Switched rather than compared with `!=`: `DirectoryListingOutcome` promises callers
        // handle every case, and that promise is what makes a fourth case a compile error instead
        // of a wrong answer that ships.
        switch listing.outcome {
        case .unreadable:
            return DestinationFolderListing(folders: [], outcome: .unreadable)
        case .listed, .listedWithUnreadableDescendants:
            let folders = listing.urls.map { DestinationFolder(path: $0.path) }
            return DestinationFolderListing(
                folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                outcome: listing.outcome)
        }
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
    ///
    /// **No directory is listed twice, however many names lead to it.** `listSubfolders`' filter
    /// keeps symlinked directories — `fileExists(atPath:isDirectory:)` follows links — so once a
    /// `listSubfolders` of one started succeeding, this walk began descending through them, and a
    /// link pointing back up its own tree is a cycle. Measured on a real disk, with
    /// `root/Shortcuts/Home -> root`, `search("Medical")` returned **three matches carrying one
    /// `path`**: `DestinationFolder`'s `id` IS its path, so `ForEach` in the picker got three rows
    /// with the same id, which SwiftUI's own documentation calls undefined. With eight sibling
    /// links back to the root, `search("d3")` returned the whole 60-match limit for one real folder
    /// and `search("zzz")` reported itself truncated having spent its entire listing budget going
    /// nowhere. Before the symlink fallback landed a symlinked directory was a dead end for this
    /// walk, so all of that is newly reachable.
    ///
    /// The guard is a set of canonical identities, and skipping is **silent** — deliberately not
    /// `skippedUnreadableDirectory`. Nothing is withheld: the folder is perfectly readable and its
    /// contents are in the results already, under the first name the walk reached them by. Being
    /// breadth-first, that is also the *shallowest* name, which is the one the picker wants to
    /// show. Two spellings at the same level resolve by listing order, which is name-sorted and so
    /// deterministic; either is a real, browsable destination.
    ///
    /// This does not stop a link being a *result*. A link whose own name matches is offered like
    /// any other folder, and browsing into one column by column is unaffected — only arriving at
    /// the same directory a second time is refused.
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
        // Directories already listed, by canonical identity rather than by the spelling they were
        // reached through — the whole point is that two spellings name one directory.
        var visited: Set<String> = []
        // A directory the walk could not read is a FOURTH way to leave matches unseen, alongside
        // the three caps — and it is not one of them. The caps stop the walk EARLY, so a tighter
        // query reaches further; this one lets the walk finish and withholds a subtree from it,
        // which no query can reach. Reported as its own fact for exactly that reason: rolled in
        // with the caps, the picker's "showing the first N — narrow the search" was false on both
        // halves whenever this was the cause.
        var missedADirectory = false
        func outcome(stoppedEarly: Bool) -> DestinationSearchOutcome {
            .init(matches: matches, stoppedEarly: stoppedEarly, skippedUnreadableDirectory: missedADirectory)
        }

        while !frontier.isEmpty, depth < maxDepth, matches.count < limit {
            var next: [String] = []
            for directory in frontier {
                if isCancelled() { return outcome(stoppedEarly: true) }
                // Checked BEFORE the budget is charged, because nothing was read: a second name for
                // a directory already walked is not a listing, and counting it would let a fan of
                // links spend the budget that exists to bound real work.
                guard visited.insert(identity(of: directory, using: fileManager)).inserted else { continue }
                if listings >= maxListings { return outcome(stoppedEarly: true) }
                listings += 1
                let listing = listSubfolders(of: directory, showHidden: showHidden, fileManager: fileManager)
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
        // Falling out with directories still queued means the DEPTH cap stopped it, which is the
        // third way to leave matches unseen. Only an exhausted frontier is a complete answer.
        return outcome(stoppedEarly: !frontier.isEmpty)
    }

    /// One name per directory, so `search` can tell "somewhere new" from "somewhere it has already
    /// been, spelled differently".
    ///
    /// ``DirectoryListingSupport/identity(of:)`` rather than a second notion of the same thing:
    /// that function is already this codebase's written-down answer to "are these two URLs the same
    /// directory", and `classify` decides with it one file away. A `realpath(3)` version was
    /// written first and measured against it — on the shapes this walk meets they agree, because
    /// `resolvingSymlinksInPath` closes the `/var` vs `/private/var` gap by STRIPPING `/private`
    /// rather than adding it, so both spellings land on one form either way. Two identity functions
    /// that agree is one more than the codebase needs.
    ///
    /// Not run for an injected `FileManaging`, the same refusal ``DirectoryListingSupport/traversableTarget(of:using:)``
    /// makes and for the same reason: a mock's paths are not on this disk, `/var` is itself a
    /// symlink here, and resolving would answer about the machine's own tree. A mock disk holds no
    /// symlinks, so there is nothing to collapse and the path IS the identity.
    private static func identity(of path: String, using fileManager: FileManaging) -> String {
        guard fileManager is FileManager else { return path }
        return DirectoryListingSupport.identity(of: URL(fileURLWithPath: path))
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
    /// a `Son` under `Health/Medical/Kaiser` and another under `School`.
    ///
    /// A path that is not under `root` yields its own parent components, so a result from the
    /// system panel still reads sensibly rather than coming back empty.
    ///
    /// The root itself trails **nothing**: there is no level between a folder and itself. Handling
    /// that explicitly rather than letting it fall through to the outside-the-root branch, which
    /// answered with the root's own ancestors — `trail(of: "~/Dropbox", under: "~/Dropbox")` came
    /// back as `["Users", "father"]`, and `crumbs` then read "Dropbox › father › Dropbox".
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
