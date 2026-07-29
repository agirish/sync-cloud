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

/// The folder tree behind the destination picker.
///
/// Deliberately **not** `PaneChildrenIndex`. That index is built from a pane's published tree,
/// which is rooted at the pane's *focused* path — for the Tidy rail that is the lens folder (the
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
        let root = PaneBrowsePath.normalized(path)
        guard !root.isEmpty else { return [] }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil,
            options: options
        ) else { return [] }

        var folders: [DestinationFolder] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let name = url.lastPathComponent
            if !showHidden, name.hasPrefix(".") { continue }
            folders.append(DestinationFolder(path: url.path))
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Folders under `root` whose name contains `query`, breadth-first.
    ///
    /// Breadth-first and bounded on purpose. The corpus is a live provider, which can be very large
    /// and very deep; a depth-first walk would spend its whole budget inside the first branch and
    /// return matches from one corner of the tree. Going level by level means the results are the
    /// *shallowest* matches, which are also the ones a person filing a document is most likely to
    /// mean — and the caps turn an unbounded walk into a predictable one.
    ///
    /// `limit` counts matches, `maxDepth` counts levels below `root`. Both are hit rather than
    /// exceeded: the walk stops as soon as it has enough.
    public static func search(
        _ query: String,
        under root: String,
        showHidden: Bool = false,
        limit: Int = 60,
        maxDepth: Int = 6,
        fileManager: FileManaging
    ) -> [DestinationFolder] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, limit > 0, maxDepth > 0 else { return [] }

        var matches: [DestinationFolder] = []
        var frontier = [PaneBrowsePath.normalized(root)]
        var depth = 0

        while !frontier.isEmpty, depth < maxDepth, matches.count < limit {
            var next: [String] = []
            for directory in frontier {
                for folder in subfolders(of: directory, showHidden: showHidden, fileManager: fileManager) {
                    if folder.name.localizedCaseInsensitiveContains(needle) {
                        matches.append(folder)
                        if matches.count >= limit { return matches }
                    }
                    next.append(folder.path)
                }
            }
            frontier = next
            depth += 1
        }
        return matches
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
    public static func trail(of path: String, under root: String) -> [String] {
        let normalizedPath = PaneBrowsePath.normalized(path)
        let normalizedRoot = PaneBrowsePath.normalized(root)
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

    /// Names among `sources` that already exist in `destination`.
    ///
    /// The absolute move is flat — every selected item lands beside the others — so two files of
    /// the same name from different folders collide with each other's target, and any of them can
    /// collide with something already there. The collision prompt handles all of that at execution
    /// time, one modal per item; surfacing the count beforehand is what turns "confirm, then answer
    /// four questions you did not expect" into a decision made once, up front.
    ///
    /// An item already sitting in `destination` is NOT a collision with itself — it is the
    /// already-there case, which `allSourcesAlreadyIn` answers and which a move skips rather than
    /// prompts about.
    public static func collidingNames(
        movingFrom sources: [String],
        into destination: String,
        fileManager: FileManaging
    ) -> [String] {
        let target = PaneBrowsePath.normalized(destination)
        guard !target.isEmpty else { return [] }
        return sources.compactMap { source in
            let normalized = PaneBrowsePath.normalized(source)
            guard (normalized as NSString).deletingLastPathComponent != target else { return nil }
            let name = (normalized as NSString).lastPathComponent
            let candidate = (target as NSString).appendingPathComponent(name)
            return fileManager.fileExists(atPath: candidate) ? name : nil
        }
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
