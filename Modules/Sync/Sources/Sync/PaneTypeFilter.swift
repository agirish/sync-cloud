import Foundation

/// Which file types a pane is showing — the Filter button's state (RD70).
///
/// **`nil` on the pane means no filter.** A value is always a narrowing; one that would tick every
/// extension the folder holds is normalized back to `nil` by the editing operations below, so the
/// button returns to normal the moment the list is all ticked again (TE268).
///
/// Two sets because a ticked kind and a ticked extension mean different things (TE278): `families`
/// are whole kinds, which take in extensions that appear later — a `.gif` arriving while Images is
/// ticked shows — and `extensions` are ticked one by one, which do not. Unticking one extension
/// inside a whole kind turns that kind into its present extensions minus the one.
public struct PaneTypeFilter: Equatable, Hashable, Sendable {
    public var families: Set<FileTypeFamily>
    /// Lowercased, as `FileTypeFamily.fileExtension(ofName:)` returns them.
    public var extensions: Set<String>

    public init(families: Set<FileTypeFamily> = [], extensions: Set<String> = []) {
        self.families = families
        self.extensions = extensions
    }

    /// A file with this extension is shown.
    public func matches(extension ext: String) -> Bool {
        extensions.contains(ext) || families.contains(FileTypeFamily.of(extension: ext))
    }

    /// Nothing ticked: the pane shows no files at all, which is a filter, not the absence of one.
    public var isEmpty: Bool { families.isEmpty && extensions.isEmpty }

    // MARK: - The type list's state

    /// A checkbox's three states.
    public enum Tick: Sendable, Equatable { case on, mixed, off }

    /// The extensions of `family` present in `census`, most common first, then by name.
    public static func presentExtensions(of family: FileTypeFamily, in census: [String: Int]) -> [String] {
        census.keys.filter { FileTypeFamily.of(extension: $0) == family }
            .sorted { (census[$0] ?? 0, $1) > (census[$1] ?? 0, $0) }
    }

    /// The kinds present in `census`, in the list's order.
    public static func presentFamilies(in census: [String: Int]) -> [FileTypeFamily] {
        let present = Set(census.keys.map(FileTypeFamily.of(extension:)))
        return FileTypeFamily.allCases.filter(present.contains)
    }

    /// How a kind's checkbox draws. `filter` nil is "everything", so every box is on.
    public static func tick(of family: FileTypeFamily, in filter: PaneTypeFilter?,
                            census: [String: Int]) -> Tick {
        guard let filter else { return .on }
        if filter.families.contains(family) { return .on }
        let present = presentExtensions(of: family, in: census)
        let ticked = present.filter(filter.extensions.contains)
        // A ticked extension that is not in this folder (it was ticked elsewhere, FG) still counts
        // toward the kind, so the box does not read as off while its row shows a ticked 0.
        let tickedAbsent = filter.extensions.contains { !present.contains($0) && FileTypeFamily.of(extension: $0) == family }
        if !present.isEmpty, ticked.count == present.count { return .on }
        return ticked.isEmpty && !tickedAbsent ? .off : .mixed
    }

    /// Whether one extension's checkbox is ticked.
    public static func isTicked(_ ext: String, in filter: PaneTypeFilter?) -> Bool {
        filter?.matches(extension: ext) ?? true
    }

    /// The ticked extensions of `family` that `census` does not hold — listed at 0 under the kind,
    /// so a type ticked in another folder can still be unticked here (TE278).
    public static func absentTickedExtensions(of family: FileTypeFamily, in filter: PaneTypeFilter?,
                                              census: [String: Int]) -> [String] {
        guard let filter else { return [] }
        return filter.extensions.filter { census[$0] == nil && FileTypeFamily.of(extension: $0) == family }.sorted()
    }

    // MARK: - Editing

    /// The filter after the kind's checkbox is clicked.
    public static func toggling(_ family: FileTypeFamily, in filter: PaneTypeFilter?,
                                census: [String: Int]) -> PaneTypeFilter? {
        var next = filter ?? everything
        let wasOn = tick(of: family, in: filter, census: census) == .on
        next.extensions = next.extensions.filter { FileTypeFamily.of(extension: $0) != family }
        if wasOn { next.families.remove(family) } else { next.families.insert(family) }
        return normalized(next, census: census)
    }

    /// The filter after one extension's checkbox is clicked.
    public static func toggling(extension ext: String, in filter: PaneTypeFilter?,
                                census: [String: Int]) -> PaneTypeFilter? {
        let family = FileTypeFamily.of(extension: ext)
        var next = filter ?? everything
        if next.matches(extension: ext) {
            if next.families.contains(family) {
                // Unticking inside a whole kind: the kind becomes its present extensions minus this
                // one, so it stops taking in new arrivals (TE278).
                next.families.remove(family)
                next.extensions.formUnion(presentExtensions(of: family, in: census))
            }
            next.extensions.remove(ext)
        } else {
            next.extensions.insert(ext)
            // Every present extension of the kind ticked one by one is the whole kind again.
            let present = presentExtensions(of: family, in: census)
            if !present.isEmpty, present.allSatisfy(next.extensions.contains) {
                next.extensions = next.extensions.filter { FileTypeFamily.of(extension: $0) != family }
                next.families.insert(family)
            }
        }
        return normalized(next, census: census)
    }

    /// Only this kind.
    public static func only(_ family: FileTypeFamily, census: [String: Int]) -> PaneTypeFilter? {
        normalized(PaneTypeFilter(families: [family]), census: census)
    }

    /// Only this extension.
    public static func only(extension ext: String, census: [String: Int]) -> PaneTypeFilter? {
        normalized(PaneTypeFilter(extensions: [ext]), census: census)
    }

    /// Every kind, as a value — what an edit starts from when the pane had no filter. **Every kind,
    /// not every kind present** (his call GR): unticking Images from no filter means "all but
    /// Images", so a kind the walk has not reached yet, or a file of a new kind arriving later, still
    /// shows. Ticking kinds one by one after Only is the other way to build a filter, and that one
    /// stays a list of what is wanted.
    static let everything = PaneTypeFilter(families: Set(FileTypeFamily.allCases))

    /// `nil` when `filter` shows every file `census` holds.
    static func normalized(_ filter: PaneTypeFilter, census: [String: Int]) -> PaneTypeFilter? {
        guard !census.isEmpty else { return filter }
        return census.keys.allSatisfy(filter.matches(extension:)) ? nil : filter
    }

    // MARK: - Words

    /// The status-bar chip and VoiceOver value: "Images", "Images, PDFs", ".jpg, .png",
    /// "Images, PDFs +2". Kinds in the list's order, then any loose extensions of each. A filter
    /// that shows most kinds is named by what it leaves out (GR): "All but Images", and "All but
    /// some Images" for a kind split into its extensions.
    public var summary: String {
        if isExclusion {
            let parts = FileTypeFamily.allCases.filter { !families.contains($0) }.map { family in
                extensions.contains { FileTypeFamily.of(extension: $0) == family } ? "some \(family.title)" : family.title
            }
            return "All but " + Self.joined(parts)
        }
        var parts: [String] = []
        for family in FileTypeFamily.allCases {
            if families.contains(family) {
                parts.append(family.title)
            } else {
                parts += extensions.filter { FileTypeFamily.of(extension: $0) == family }.sorted()
                    .map { $0.isEmpty ? "No extension" : ".\($0)" }
            }
        }
        if parts.isEmpty { return "Nothing ticked" }
        return Self.joined(parts)
    }

    /// "Showing only Images" or "Showing all but Images" — the button's tooltip and what Ask Claude
    /// is told, which need the verb the summary leaves out.
    public var showingPhrase: String {
        isExclusion ? "all but " + summary.dropFirst("All but ".count) : "only \(summary)"
    }

    /// Most kinds wholly ticked, at least one not: read by what is left out.
    var isExclusion: Bool {
        families.count > FileTypeFamily.allCases.count / 2 && families.count < FileTypeFamily.allCases.count
    }

    private static func joined(_ parts: [String]) -> String {
        parts.count > 3 ? parts.prefix(2).joined(separator: ", ") + " +\(parts.count - 2)"
                        : parts.joined(separator: ", ")
    }

    /// The one kind this filter shows, when it shows only one — what a folder's pill names its
    /// count after ("2 images"). `nil` when it spans kinds, so the pill says "files".
    public var soleFamily: FileTypeFamily? {
        let kinds = families.union(extensions.map(FileTypeFamily.of(extension:)))
        return kinds.count == 1 ? kinds.first : nil
    }

    /// A closed folder's pill: "2 images", "9 files".
    public func countPhrase(_ count: Int) -> String {
        (soleFamily ?? .other).countPhrase(count)
    }
}

/// What the type filter's pass learned about one pane's tree, for the type list, the folder pills
/// and the status bar.
public struct PaneTypeFilterFacts: Equatable, Sendable {
    /// Extension → how many files carry it, over the tree before the type filter (after Hidden).
    /// Unexplored folders contribute nothing; packages count once, by their own extension.
    public var census: [String: Int]
    /// Folder id → matching files strictly beneath it. Absent for a folder with none. Empty when
    /// there is no filter.
    public var matchCounts: [String: Int]
    /// Folders the walk never listed (TE270), which the census could not count.
    public var unexploredCount: Int
    /// Every file and folder before the type filter — the "of 52" in "28 of 52 items".
    public var itemCountBeforeFilter: Int

    public init(census: [String: Int] = [:], matchCounts: [String: Int] = [:],
                unexploredCount: Int = 0, itemCountBeforeFilter: Int = 0) {
        self.census = census
        self.matchCounts = matchCounts
        self.unexploredCount = unexploredCount
        self.itemCountBeforeFilter = itemCountBeforeFilter
    }

    /// How many files the census counted.
    public var fileCount: Int { census.values.reduce(0, +) }
}

/// The type filter itself: one recursive pass over a pane's tree.
///
/// **Folders are kept where they stand, not flattened** (TE269). `PaneTreeSearch` refuses to be a
/// filter because rebuilding the tree "destroys the one thing a tree communicates — where a hit
/// sits"; this keeps every ancestor of a match, so the hit still sits where it did, and drops only
/// branches with nothing in them.
public enum PaneTypeFilterPass {

    /// The pruned tree plus its facts.
    ///
    /// Kept: a file that matches or whose path is in `keep` (what this pane just made, TE277, and
    /// the folders open in it, GQ); a package, judged as one file by its own extension and never
    /// entered (TE275); a folder that is unexplored (TE270 — the filter cannot know what it holds),
    /// in `keep`, or left with any child.
    public static func apply(_ filter: PaneTypeFilter, to tree: [FileNode],
                             keep: Set<String> = []) -> (tree: [FileNode], facts: PaneTypeFilterFacts) {
        var walk = Walk(filter: filter, keep: keep)
        let (kept, _) = walk.visit(tree)
        return (kept, walk.facts)
    }

    /// The facts alone, for a pane with no filter whose type list is open: nothing is pruned.
    public static func census(of tree: [FileNode]) -> PaneTypeFilterFacts {
        var walk = Walk(filter: nil, keep: [])
        _ = walk.visit(tree)
        return walk.facts
    }

    private struct Walk {
        let filter: PaneTypeFilter?
        let keep: Set<String>
        var facts = PaneTypeFilterFacts()
        /// `FileNode.isPackage` builds a `UTType` per call; a tree has few distinct folder kinds.
        var packageByKind: [String: Bool] = [:]

        init(filter: PaneTypeFilter?, keep: Set<String>) {
            self.filter = filter
            self.keep = keep
        }

        mutating func isPackage(_ node: FileNode) -> Bool {
            guard node.isDirectory, let kind = node.kind else { return false }
            if let known = packageByKind[kind] { return known }
            let answer = node.isPackage
            packageByKind[kind] = answer
            return answer
        }

        /// Returns the kept nodes and how many matching files they hold.
        mutating func visit(_ nodes: [FileNode]) -> ([FileNode], Int) {
            var out: [FileNode] = []
            var matched = 0
            for node in nodes {
                facts.itemCountBeforeFilter += 1
                if node.isDirectory, !isPackage(node) {
                    if node.isUnexplored == true {
                        facts.unexploredCount += 1
                        out.append(node)
                        continue
                    }
                    let (children, inside) = visit(node.children ?? [])
                    if inside > 0, filter != nil { facts.matchCounts[node.id] = inside }
                    matched += inside
                    if filter == nil || !children.isEmpty || keep.contains(node.id) {
                        var copy = node
                        copy.children = filter == nil ? node.children : children
                        out.append(copy)
                    }
                } else {
                    let ext = FileTypeFamily.fileExtension(ofName: node.name)
                    facts.census[ext, default: 0] += 1
                    if node.isDirectory {
                        // A package's contents still count as items: `countItems` walks into them,
                        // and the "of N" has to be the number the unfiltered status bar shows.
                        facts.itemCountBeforeFilter += FileSyncManager.countItems(in: node.children ?? [])
                    }
                    let shown = filter?.matches(extension: ext) ?? true
                    if shown { matched += 1 }
                    if shown || keep.contains(node.id) { out.append(node) }
                }
            }
            return (out, matched)
        }
    }
}
