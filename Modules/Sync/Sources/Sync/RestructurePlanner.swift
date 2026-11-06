import Foundation

/// The family mapping the plan editor edits: source child name → target child name, one row per
/// distinct source name across every member.
///
/// Edited once, applied to every member; per member the operations are derived, never typed
/// (``RestructurePlanner``). A `nil` target is keep, the default for every row: the editor never
/// guesses a mapping.
public struct RestructureMapping: Equatable, Sendable {

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        /// A distinct child folder name somewhere in the family, disk-cased.
        public let source: String
        /// The name this folder should have in the target shape, or `nil` for keep, which leaves it
        /// where and as it stands, listed in the manifest.
        public var target: String?

        public var id: String { source }

        public init(source: String, target: String? = nil) {
            self.source = source
            self.target = target
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// Rows that would change something. A row mapped to its own name is the vocabulary agreeing
    /// with itself, not an operation.
    var activeRows: [Row] {
        rows.filter { row in
            guard let target = row.target else { return false }
            return target != row.source
        }
    }
}

/// What the planner may know about the tree: narrow on purpose, so the derivation is a pure
/// function testable with no disk.
///
/// Two backings: ``fromProfile(_:)`` knows folders and counts but no file names, enough for
/// renames, and the disk-backed view adds file names, which merges need to expand into `move-file`
/// rows. A merge the view can't expand is a refusal, never a guess.
public struct RestructureTreeView {
    /// Direct child folder names of a path (relative to the profile root), disk-cased. Empty for a
    /// leaf; nil for a path the view has never heard of.
    public let childFolders: (String) -> [String]?
    /// File names directly inside a path; nil when the view can't name them (a profile knows
    /// counts, not names).
    public let files: (String) -> [String]?
    /// How many files a path holds directly: `filesCarried` on a rename.
    public let fileCount: (String) -> Int?

    /// One directory, one read: set by a view that answers both halves of a listing at once, so
    /// ``memoized()`` caches one shared listing instead of reading the directory once per closure.
    /// nil for a view that can't (``fromProfile(_:)`` knows counts, not names), which keeps
    /// per-closure caching. Internal: an optimisation of this module's disk view, not a shape every
    /// caller must satisfy.
    let listing: ((String) -> (folders: [String], files: [String])?)?

    /// Called as each family's manifest starts to derive, so the disk view's "one unanswered
    /// folder, one wait" rule resets per plan. The plan sheet holds one view across every family of
    /// a group plan, and otherwise one family's stalled folder would list every other family's
    /// cloud-only folders as unknown without asking them. Nil for a view with no such state.
    let beginsDerivation: (() -> Void)?

    public init(childFolders: @escaping (String) -> [String]?,
                files: @escaping (String) -> [String]?,
                fileCount: @escaping (String) -> Int?) {
        self.childFolders = childFolders
        self.files = files
        self.fileCount = fileCount
        self.listing = nil
        self.beginsDerivation = nil
    }

    /// The single-listing spelling: all three answers derived from one read of a directory.
    init(listing: @escaping (String) -> (folders: [String], files: [String])?,
         beginsDerivation: (() -> Void)? = nil) {
        self.listing = listing
        self.childFolders = { listing($0)?.folders }
        self.files = { listing($0)?.files }
        self.fileCount = { listing($0)?.files.count }
        self.beginsDerivation = beginsDerivation
    }

    /// The view the live disk gives: folders, files and counts, read lazily as the planner asks. A
    /// plan is derived against the tree as it stands now, and merges need file names the profile
    /// never stores. Hidden entries are skipped, as the survey skips them.
    ///
    /// Directory-ness comes from the enumeration's prefetched keys, not a `stat` per entry, which
    /// would cost a syscall per child on the main thread. A symbolic link still gets its own probe,
    /// because `URL.resourceValues` doesn't follow links (a link to a directory, and a dangling
    /// link, both read `isDirectory == false`) while `fileExists(atPath:)` does. A dangling link is
    /// dropped, so the apply-time veto still sees it as an unlisted name; a link that resolves is
    /// an item, listed with the files whatever it points at.
    ///
    /// Packages and links are moved whole, never merged through. A merge goes one level down into a
    /// same-named subfolder file by file, which across two packages would move one document's
    /// insides into the other, and across a link would move the target's files into this tree.
    /// Listed as items, both travel as one `move-file`, and a taken name keeps both, as every
    /// collision does.
    ///
    /// `options: []` and a `.` prefix test, not `.skipsHiddenFiles`: the option also drops items
    /// with the hidden flag and an ordinary name, which the survey walks. Matching the survey is
    /// the point.
    ///
    /// A folder whose contents are not on this Mac is asked for first, for a bounded time. This is
    /// read on the main actor while the sheet derives, and a cloud-only folder whose app has
    /// stopped never answers `contentsOfDirectory`, which would hang the sheet. It goes through
    /// `DatalessFolderReads` (`waitForContentsBlocking`), and one that doesn't answer lists as nil:
    /// unknown, which the planner refuses on, never empty. `contentsFrom` is who is asked: the same
    /// disk, except in a test that stands a dataless folder in front of a real one.
    public static func fromDisk(root: URL, fileManager: FileManager = .default)
        -> RestructureTreeView {
        fromDisk(root: root, fileManager: fileManager, contentsFrom: fileManager)
    }

    static func fromDisk(root: URL, fileManager: FileManager, contentsFrom: any FileManaging)
        -> RestructureTreeView {
        // One unanswered folder, one wait. Each dataless folder that doesn't answer waits out the
        // deadline on the main actor, one after another, so once one hasn't answered, every later
        // dataless folder lists as unknown at once: the plan is refused either way. Per family's
        // plan, not per view: `beginsDerivation` resets it for each family of a group plan.
        final class Stall { var unanswered = false }
        let stall = Stall()
        return RestructureTreeView(listing: { path in
            let url = root.appendingPathComponent(path)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
            // A package asked about by its own path is a document, not a folder with a listing, or
            // the pair route (`TODO/Return.pages` → `Return.pages`) would merge one document's
            // insides into another's. So is any path inside one (`Song.band/Media`), so every
            // folder from the root down is asked.
            var walkedDown = [root]
            for component in path.split(separator: "/") {
                walkedDown.append(walkedDown[walkedDown.count - 1].appendingPathComponent(String(component)))
            }
            if walkedDown.contains(where: {
                (try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            }) { return nil }
            if stall.unanswered, contentsFrom.isDataless(at: url) { return nil }
            guard contentsFrom.waitForContentsBlocking(of: url) else {
                stall.unanswered = true
                return nil
            }
            guard let urls = try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [])
            else { return nil }
            var folders: [String] = []
            var files: [String] = []
            for child in urls {
                let name = child.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if let isDirectory = values?.isDirectory, values?.isSymbolicLink != true {
                    if isDirectory && values?.isPackage != true { folders.append(name) } else { files.append(name) }
                    continue
                }
                // A link, or an entry the volume wouldn't answer for. One that resolves is an item;
                // one that doesn't is dropped.
                guard fileManager.fileExists(atPath: child.path) else { continue }
                if values?.isSymbolicLink == true {
                    files.append(name)
                    continue
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory)
                else { continue }
                if isDirectory.boolValue { folders.append(name) } else { files.append(name) }
            }
            return (folders.sorted(), files.sorted())
        }, beginsDerivation: { stall.unanswered = false })
    }

    /// The same view with every listing read once and remembered. The plan sheet re-derives the
    /// whole manifest on each edit, which would re-list every mapped directory per keystroke; a
    /// plan is re-probed at apply anyway, so the derivation never promised to see mid-sheet disk
    /// changes.
    ///
    /// The cache lives as long as this view value does, which is not one sheet presentation: a view
    /// built inside a SwiftUI body is rebuilt, empty, on every render, so the sheet holds it in
    /// `@State` (`RestructurePlanSheet.diskTree`).
    ///
    /// A view with a ``listing`` caches that, so folders, files and count come from one read. The
    /// three-map fallback is for views that can't: ``fromProfile(_:)`` and the tests' dictionary
    /// views.
    public func memoized() -> RestructureTreeView {
        if let listing {
            final class ListingCache {
                var entries: [String: (folders: [String], files: [String])?] = [:]
            }
            let cache = ListingCache()
            return RestructureTreeView(listing: { path in
                if let hit = cache.entries[path] { return hit }
                let value = listing(path)
                cache.entries[path] = value
                return value
            }, beginsDerivation: beginsDerivation)
        }
        final class Cache {
            var folders: [String: [String]?] = [:]
            var files: [String: [String]?] = [:]
            var counts: [String: Int?] = [:]
        }
        let cache = Cache()
        let base = self
        return RestructureTreeView(
            childFolders: { path in
                if let hit = cache.folders[path] { return hit }
                let value = base.childFolders(path)
                cache.folders[path] = value
                return value
            },
            files: { path in
                if let hit = cache.files[path] { return hit }
                let value = base.files(path)
                cache.files[path] = value
                return value
            },
            fileCount: { path in
                if let hit = cache.counts[path] { return hit }
                let value = base.fileCount(path)
                cache.counts[path] = value
                return value
            })
    }

    /// The view a profile can give: structure and counts, no file names.
    public static func fromProfile(_ profile: FolderProfile) -> RestructureTreeView {
        var children: [String: [String]] = [:]
        for path in profile.folders.keys {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { continue }
            children[parent, default: []].append((path as NSString).lastPathComponent)
        }
        let sorted = children.mapValues { $0.sorted() }
        let known = Set(profile.folders.keys)
        return RestructureTreeView(
            childFolders: { path in
                if let names = sorted[path] { return names }
                return known.contains(path) ? [] : nil
            },
            files: { _ in nil },
            fileCount: { profile.folders[$0]?.fileCount })
    }
}

/// Mapping → manifest, per member: a pure function of the mapping and the view.
///
/// The rules:
/// - one source → a target absent in that member: `rename-dir` (atomic, carries its files);
/// - N sources → one absent target: rename the source with the most files, merge the rest into it;
/// - N sources → a target already present: merge all N into it;
/// - a target with no source in that member: nothing (the scaffold's `create-dir` has its own
///   builder);
/// - a source mapped to keep: a listed `keep` row;
/// - ordering inside a member is derived too: a folder is vacated before its name is filled, a pure
///   rename cycle goes through a temporary name, and a case-only rename stays one `rename-dir`
///   (apply's `safeMoveItem` owns the two-step).
///
/// A merge is `move-file` per file plus `move-dir` per subfolder into the target, never a
/// `move-dir` of the source onto the target, which would nest it. A subfolder whose name exists at
/// the target merges one level down by the same rules; deeper than that it is `keep` and reported.
/// The emptied source is left for the removal step's own manifest: this planner never emits
/// `remove-empty-dir`.
public enum RestructurePlanner {

    /// Why a plan couldn't be derived: sentences for the sheet, not codes.
    public enum PlanRefusal: Error, Equatable {
        /// Every row is keep or self: nothing to do, which is a card sentence rather than an empty
        /// manifest.
        case nothingMapped
        /// A merge needs the files inside `source` and the view can't name them.
        case unknownFiles(source: String)
        /// The mapping lists one source name on two rows. Only a hand-built or imported mapping can
        /// (the sheet seeds one row per distinct name), and the rows may disagree, so neither is
        /// safe to prefer.
        case duplicateMappingRows(source: String)
        /// A vacancy cycle runs through a multi-source group: a mapping this contorted needs a
        /// person, not a heuristic.
        case unresolvableOrder(member: String)
        /// Two distinct target names collide case-insensitively (`Forms` and `forms`). On the
        /// case-insensitive volumes this app runs against both can't exist side by side, so
        /// deriving operations toward them would fail at apply.
        case conflictingTargets(String, String)
        /// A target name is held by a sibling differing only by case that this mapping doesn't step
        /// up (`Files → Forms` while `forms/` stands, kept or merely emptied). The volume can't
        /// create `Forms/` beside `forms/`, so refusing here keeps a plan that can't land from
        /// being reviewed.
        case targetTakenByCase(target: String, standing: String, member: String)
        /// A target name is not one folder name: it carries a path separator or is a dot traversal
        /// (`Tax/2024`, `../Shared`). Every target lands as a sibling inside the member; a
        /// path-shaped name would aim the rename outside the family, and the apply's `absolute()`
        /// would follow it. Reachable from a typed name, an imported draft or a refine proposal, so
        /// the derivation closes the door.
        case invalidTargetName(target: String)
        /// A target name is held by a file of that name in the member. The planner's occupancy
        /// model is folder-shaped but the disk isn't: a rename onto a standing file would fail at
        /// apply, blamed on drift that never happened.
        case targetTakenByFile(target: String, member: String)
    }

    /// The one test of "is this string a folder name and not a path": no separator, no dot
    /// traversal, not blank. The sheet's custom-name field, the refine proposal filter and the
    /// derivation all ask it, so they can't drift, and `.invalidTargetName` backstops anything that
    /// arrives another way. Colons count as separators: Finder shows `:` as `/`, and HFS paths
    /// treat it as one.
    public static func isValidTargetName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/") && !trimmed.contains(":")
    }

    /// Every distinct child folder name across the members, disk-cased and sorted: the editor's row
    /// list.
    public static func distinctSources(family: String, members: [String],
                                       in view: RestructureTreeView) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for member in members {
            let path = (family as NSString).appendingPathComponent(member)
            for child in view.childFolders(path) ?? [] where seen.insert(child).inserted {
                names.append(child)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Sibling families that share this one's mapping vocabulary, which should usually be planned
    /// together: fixing one immigration family alone can leave it disagreeing with its siblings. A
    /// sibling counts when at least three of its members' child names also appear across this
    /// family's members. Three, because generic role names (`Statements`, `Reference`) recur
    /// correctly all over a filed tree, and a pointer that fires everywhere is one nobody reads.
    public static func parallelFamilies(of family: String, in view: RestructureTreeView,
                                        minimumShared: Int = 3) -> [String] {
        let parent = (family as NSString).deletingLastPathComponent
        guard !parent.isEmpty, let siblings = view.childFolders(parent) else { return [] }
        let familyName = (family as NSString).lastPathComponent
        let mine = Set(distinctSources(family: family,
                                       members: view.childFolders(family) ?? [], in: view))
        guard mine.count >= minimumShared else { return [] }
        return siblings.filter { sibling in
            guard sibling != familyName else { return false }
            let path = (parent as NSString).appendingPathComponent(sibling)
            let theirs = Set(distinctSources(family: path,
                                             members: view.childFolders(path) ?? [], in: view))
            return mine.intersection(theirs).count >= minimumShared
        }
    }

    /// The side-by-side table behind that pointer. `parallelFamilies` names the set; this shows
    /// what planning them together would have to reconcile, since disagreements between
    /// near-identical families are invisible until laid out in a grid.
    ///
    /// One row per distinct child name across the group, one column per family, each cell a plain
    /// yes/no. No counts and no judgement: "3 files" invites reading weight into a name that is
    /// either there or not, and "wrong" would assert a shape before the user has chosen one.
    ///
    /// Rows are ordered by how many families carry the name, then alphabetically: the shared names
    /// are the spine, and the disagreements collect at the bottom.
    public static func familyGroupTable(families: [String], in view: RestructureTreeView)
        -> FamilyGroupTable? {
        guard families.count >= 2 else { return nil }
        var namesByFamily: [String: Set<String>] = [:]
        for family in families {
            namesByFamily[family] = Set(distinctSources(family: family,
                                                        members: view.childFolders(family) ?? [],
                                                        in: view))
        }
        let allNames = namesByFamily.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !allNames.isEmpty else { return nil }
        let rows = allNames
            .map { name in
                FamilyGroupTable.Row(
                    name: name,
                    presentIn: families.map { namesByFamily[$0]?.contains(name) == true })
            }
            .sorted {
                let mine = $0.presentIn.filter { $0 }.count
                let theirs = $1.presentIn.filter { $0 }.count
                if mine != theirs { return mine > theirs }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        return FamilyGroupTable(families: families, rows: rows)
    }

    /// One shared mapping, derived separately per family. That separation is the safety of batch
    /// planning: a row can be right for one family and a collision in a sibling, so only the intent
    /// is shared. Each family's manifest is derived against its own members and tree and carries
    /// its own refusal, so one bad row can't stop or poison the other plans.
    ///
    /// A family whose derivation refuses stays in the result with its refusal, in the order asked:
    /// the sheet reviews them all before anything lands, and an unplannable member is a thing to
    /// see, not to drop.
    ///
    /// Manifest ids are `manifestIdPrefix` plus the family's leaf name, so ledger records and
    /// exported filenames stay one per family and a landing can be undone alone.
    /// - Parameter membersByFamily: the member set to plan a family over, where the caller has one.
    ///   The subject family's belongs here: the sheet's single-family plan uses the members the
    ///   finding names (from the profile), and a disk listing also picks up folders created since
    ///   the survey, so the landing would rename folders the review never showed. Families with no
    ///   entry fall back to the disk, the only source for a sibling the finding says nothing about.
    public static func groupManifests(
        families: [String], mapping: RestructureMapping, kind: FindingKind,
        in view: RestructureTreeView, profileId: String, manifestIdPrefix: String,
        createdAt: String, membersByFamily: [String: [String]] = [:])
        -> [(family: String, result: Result<RestructureManifest, PlanRefusal>)] {
        families.map { family in
            view.beginsDerivation?()
            let members = membersByFamily[family] ?? view.childFolders(family) ?? []
            // Each family's mapping is the shared one narrowed to the sources it has: a row naming
            // a folder this family lacks is simply not about it, and passing it through would
            // refuse the whole plan on a name only a sibling has.
            let mine = Set(distinctSources(family: family, members: members, in: view))
            let narrowed = RestructureMapping(
                rows: mapping.rows.filter { mine.contains($0.source) })
            return (family,
                    derivedManifest(family: family, members: members, mapping: narrowed, kind: kind,
                             in: view, profileId: profileId,
                             manifestId: manifestIdPrefix + "-"
                                + (family as NSString).lastPathComponent,
                             createdAt: createdAt))
        }
    }

    /// Every distinct child name across a group: the sources one shared mapping is edited over.
    public static func groupSources(families: [String], in view: RestructureTreeView) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for family in families {
            for name in distinctSources(family: family,
                                        members: view.childFolders(family) ?? [], in: view)
            where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Child names across a group of families, as a grid.
    public struct FamilyGroupTable: Equatable, Sendable {
        /// The columns, in the order asked for: the subject family first, by the caller's
        /// convention, so the table reads outward from the one being planned.
        public let families: [String]
        public let rows: [Row]

        public struct Row: Equatable, Sendable {
            public let name: String
            /// One flag per family, positionally aligned with ``families``.
            public let presentIn: [Bool]

            public init(name: String, presentIn: [Bool]) {
                self.name = name
                self.presentIn = presentIn
            }

            /// True when every family in the group carries this name: the spine, and the rows a
            /// shared mapping can leave alone.
            public var isUniversal: Bool { presentIn.allSatisfy { $0 } }
        }

        public init(families: [String], rows: [Row]) {
            self.families = families
            self.rows = rows
        }

        /// Names not every family has: what planning the group together would reconcile, and the
        /// honest measure of how far apart these families are.
        public var disagreements: [Row] { rows.filter { !$0.isUniversal } }
    }

    /// The derived manifest: every member's operations in member order, each member ordered so it
    /// can run top to bottom.
    /// - Parameter recordedFamily: what the manifest, the ledger card and the exported filename
    ///   call this family, when that differs from the path the members hang off. A seeded pair
    ///   under `Travel/` is planned with `family: ""` and `members: ["Travel"]`, and recording `""`
    ///   would head its landing card "Across the tree". nil records `family`, as every family
    ///   mapping wants.
    public static func manifest(family: String, members: [String],
                                mapping: RestructureMapping, kind: FindingKind,
                                in view: RestructureTreeView,
                                profileId: String, manifestId: String, createdAt: String,
                                note: String? = nil, recordedFamily: String? = nil)
        -> Result<RestructureManifest, PlanRefusal> {
        view.beginsDerivation?()
        return derivedManifest(family: family, members: members, mapping: mapping, kind: kind,
                               in: view, profileId: profileId, manifestId: manifestId,
                               createdAt: createdAt, note: note, recordedFamily: recordedFamily)
    }

    /// ``manifest(family:members:mapping:kind:in:profileId:manifestId:createdAt:note:recordedFamily:)``
    /// without starting a derivation, for
    /// ``groupManifests(families:mapping:kind:in:profileId:manifestIdPrefix:createdAt:membersByFamily:)``,
    /// which starts each family's before listing its members.
    private static func derivedManifest(family: String, members: [String],
                                        mapping: RestructureMapping, kind: FindingKind,
                                        in view: RestructureTreeView,
                                        profileId: String, manifestId: String, createdAt: String,
                                        note: String? = nil, recordedFamily: String? = nil)
        -> Result<RestructureManifest, PlanRefusal> {
        guard !mapping.activeRows.isEmpty else { return .failure(.nothingMapped) }
        // Distinct targets differing only by case can't coexist on a case-insensitive volume.
        let targets = Set(mapping.activeRows.compactMap(\.target)).sorted()
        let byLowered = Dictionary(grouping: targets, by: { $0.lowercased() })
        if let clash = byLowered.values.first(where: { $0.count > 1 }) {
            return .failure(.conflictingTargets(clash[0], clash[1]))
        }
        var actions: [RestructureManifest.Action] = []
        for member in members {
            let path = (family as NSString).appendingPathComponent(member)
            switch memberActions(memberPath: path, member: member, mapping: mapping, in: view) {
            case .success(let derived): actions.append(contentsOf: derived)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        guard actions.contains(where: { $0.action != .keep }) else {
            // Rows were mapped, but no member holds any mapped name: the same sentence as an
            // all-keep mapping, because the same nothing would land.
            return .failure(.nothingMapped)
        }
        return .success(RestructureManifest(
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            family: recordedFamily ?? family, kind: kind, note: note,
            mapping: mapping.rows, actions: actions))
    }

    /// One folder's contents moved into a folder that is not its sibling: the merge kinds whose two
    /// paths sit under different parents (a mirrored inbox, a loose folder beside its container, a
    /// child echoing its parent).
    ///
    /// A mapping row renames a child within its member and can't change its parent, so the pair is
    /// derived directly, but by the same rules and code as a mapped merge, so the two can't drift.
    ///
    /// - A destination that doesn't exist yet is one `move-dir`: the folder travels whole and its
    ///   files ride along, as the loose-folder card promises.
    /// - A standing destination is drained into per
    ///   ``emitMerge(of:sourceName:into:targetName:in:landed:residue:actions:)``: `move-file` per
    ///   file, `move-dir` per subfolder, one level of same-name recursion, `keep` beyond, and never
    ///   a `move-dir` of the source onto the target, which would nest it.
    ///
    /// The emptied source is left for the removal step's own manifest, as the mapped planner leaves
    /// it.
    public static func pairMergeManifest(source: String, destination: String, kind: FindingKind,
                                         in view: RestructureTreeView,
                                         profileId: String, manifestId: String, createdAt: String,
                                         note: String? = nil)
        -> Result<RestructureManifest, PlanRefusal> {
        view.beginsDerivation?()
        guard source != destination else { return .failure(.nothingMapped) }
        // A folder can't be moved inside itself, which a destination under the source would mean.
        // Refused, like an unresolvable order, rather than a plan that eats its own source.
        guard !RestructurePaths.isInside(destination, of: source) else {
            return .failure(.unresolvableOrder(member: source))
        }
        // The source must exist before either branch is worth deriving, or the whole-move branch
        // would plan a `move-dir` out of a folder that vanished since the survey, while the merge
        // branch refuses that through `view.files`.
        guard view.childFolders(source) != nil else {
            return .failure(.unknownFiles(source: source))
        }
        let sourceName = (source as NSString).lastPathComponent
        let targetName = (destination as NSString).lastPathComponent
        var actions: [RestructureManifest.Action] = []

        // `childFolders(destination) == nil` means "not a readable directory": nothing there, or a
        // file of that name. A move-dir onto a standing file would always skip at apply as false
        // "appeared since the plan" drift, which the mapped planner already refuses; the pair route
        // reaches it because a profile stores no file names for the detector to see.
        let destinationParent = (destination as NSString).deletingLastPathComponent
        // Case-insensitively, like the mapped planner's occupancy test: on these volumes a file
        // called `att bill` occupies `ATT Bill` just as surely.
        if view.childFolders(destination) == nil,
           view.files(destinationParent)?
               .contains(where: { $0.lowercased() == targetName.lowercased() }) == true {
            return .failure(.targetTakenByFile(target: targetName, member: destinationParent))
        }
        // No listing is not "nothing there". A folder that stands but can't be listed (cloud-only,
        // its app not answering) lists as nil just as an absent one does, so absence is read off
        // the parent: refused unless the parent lists and holds no folder of that name.
        if view.childFolders(destination) == nil {
            guard let standing = view.childFolders(destinationParent) else {
                return .failure(.unknownFiles(source: destinationParent))
            }
            if standing.contains(where: { $0.lowercased() == targetName.lowercased() }) {
                return .failure(.unknownFiles(source: destination))
            }
        }
        if view.childFolders(destination) == nil {
            // Nothing stands at the destination: the whole folder travels, files included.
            let newParent = (destination as NSString).deletingLastPathComponent
            actions.append(RestructureManifest.Action(
                action: .moveDir, src: source, dst: destination,
                evidence: "\(sourceName)/ belongs in \(newParent)/ and nothing of that name "
                    + "stands there — the folder moves whole and its files ride along.",
                filesCarried: view.fileCount(source),
                // The source's parent is not being drained (see the field's own doc). Without the
                // flag the apply's unlisted veto would skip every one of these (the detector
                // requires a sibling container, which is exactly what the veto sees), and the
                // removal step would offer that parent as a folder this landing emptied.
                movesWholeFolder: true))
        } else {
            // The source's own refusal first, as `emitMerge` would give it; then the target is
            // read, never assumed empty.
            guard view.files(source) != nil else { return .failure(.unknownFiles(source: source)) }
            guard var landed = LandedContents.reading(destination, in: view) else {
                return .failure(.unknownFiles(source: destination))
            }
            var residue = LandedContents(of: nil, in: view)
            if let refusal = emitMerge(of: source, sourceName: sourceName,
                                       into: destination, targetName: targetName,
                                       in: view, landed: &landed, residue: &residue,
                                       actions: &actions) {
                return .failure(refusal)
            }
        }
        guard actions.contains(where: { $0.action != .keep }) else {
            return .failure(.nothingMapped)
        }
        return .success(RestructureManifest(
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            family: RestructurePaths.commonAncestor(of: [source, destination]),
            kind: kind, note: note, actions: actions))
    }

    // MARK: - One member's before and after

    /// One member's children as they stand and as the plan would leave them: the shape the reviewed
    /// operations produce.
    ///
    /// Derived from the manifest's own actions for that member, so it can't describe a different
    /// plan, and from the tree view's counts, never a second walk of the disk: the sheet re-derives
    /// on every keystroke.
    public struct RestructurePreview: Equatable, Sendable {

        /// What the plan does to one child folder, as the after-column labels it.
        public enum Fate: Equatable, Sendable {
            /// Renamed from another name, which is named.
            case renamedFrom(String)
            /// Other folders were drained into this one, and, when the row also took its name from
            /// a folder, which one. Both, so the reader isn't left hunting for where the renamed
            /// folder went.
            case mergedFrom(renamedFrom: String?, sources: [String])
            /// Created by the plan; it holds nothing yet.
            case created
            /// The target shape has no slot for it, so it stays exactly as it is.
            case kept
            /// Untouched by the plan and untouched in the after column.
            case unchanged
        }

        public struct Row: Equatable, Sendable {
            public let name: String
            /// Files directly inside, or nil when the view can't count them.
            public let files: Int?
            public let fate: Fate
        }

        /// The member's children now, in name order, with their current file counts.
        public let before: [Row]
        /// The member's children after the plan, in name order.
        public let after: [Row]
    }

    /// The before and after of one member under a manifest. nil when the view has never heard of
    /// the member: an absent folder has no before to show.
    ///
    /// An ordered simulation, not a set of deltas. Reconstructing the after column from per-name
    /// changes can't survive a rename chain: the planner routes a swap through a temporary name,
    /// and the temp would show as a surviving row (`B.restructure-swap`). Walking the actions in
    /// the order they run, as the apply does, gets chains, cycles and vacate-before-fill right.
    public static func preview(member: String, in manifest: RestructureManifest,
                               tree view: RestructureTreeView) -> RestructurePreview? {
        guard let children = view.childFolders(member) else { return nil }
        func path(_ name: String) -> String {
            (member as NSString).appendingPathComponent(name)
        }
        /// The parts of a path below the member, or nil when it isn't under it.
        func parts(_ full: String?) -> [String]? {
            guard let full, RestructurePaths.isInside(full, of: member), full != member else {
                return nil
            }
            let rest = full.dropFirst(member.isEmpty ? 0 : member.count + 1)
            return rest.split(separator: "/").map(String.init)
        }
        /// A direct child folder of the member: `member/Forms`, never `member/Forms/Sub`.
        func directChild(_ full: String?) -> String? {
            guard let p = parts(full), p.count == 1 else { return nil }
            return p[0]
        }
        /// The direct child a deeper path lives under, whatever its depth.
        func owner(_ full: String?) -> String? {
            guard let p = parts(full), p.count >= 2 else { return nil }
            return p[0]
        }
        /// True when the path is an item directly in a child: the only depth that changes that
        /// child's own file or subfolder count.
        func isDirectlyInAChild(_ full: String?) -> Bool {
            (parts(full)?.count ?? 0) == 2
        }

        /// One folder as the simulation currently sees it, under the name it currently wears.
        struct Live {
            var files: Int
            var subfolders: Int
            /// The name this folder started the plan under, when that differs from its current one.
            /// Chains collapse into it, so a swap reports the original name rather than the
            /// planner's temporary.
            var origin: String?
            var absorbed: Set<String> = []
            var created = false
            var kept = false
        }
        var live: [String: Live] = [:]
        for name in children {
            live[name] = Live(files: view.fileCount(path(name)) ?? 0,
                              subfolders: view.childFolders(path(name))?.count ?? 0,
                              origin: nil)
        }
        /// Names something was taken out of: the candidates for disappearing entirely.
        var drained: Set<String> = []

        func absorb(from source: String, into target: String) {
            guard source != target else { return }
            drained.insert(source)
            let name = live[source]?.origin ?? source
            live[target, default: Live(files: 0, subfolders: 0, origin: nil)]
                .absorbed.insert(name)
        }

        for action in manifest.actions {
            switch action.action {
            case .renameDir, .moveDir:
                let from = directChild(action.src)
                let to = directChild(action.dst)
                if let from, let to {
                    // The whole folder changes name inside this member.
                    var moved = live.removeValue(forKey: from)
                        ?? Live(files: action.filesCarried ?? 0, subfolders: 0, origin: nil)
                    moved.origin = moved.origin ?? from
                    if var standing = live[to] {
                        // Vacate-before-fill normally frees the name first; if it didn't, this is a
                        // merge and reads as one.
                        standing.files += moved.files
                        standing.subfolders += moved.subfolders
                        standing.absorbed.insert(moved.origin ?? from)
                        live[to] = standing
                    } else {
                        live[to] = moved
                    }
                } else if let from {
                    // Left the member entirely.
                    live.removeValue(forKey: from)
                } else if let to {
                    // Arrived from outside it, carrying its files with it.
                    live[to] = Live(files: action.filesCarried ?? 0, subfolders: 0,
                                    origin: nil, created: true)
                } else if let source = owner(action.src) {
                    // A subfolder moved between children: the shape a merge takes when the source
                    // holds no loose files, which must still count as draining it.
                    if isDirectlyInAChild(action.src) { live[source]?.subfolders -= 1 }
                    if let target = owner(action.dst) {
                        if isDirectlyInAChild(action.dst) { live[target]?.subfolders += 1 }
                        absorb(from: source, into: target)
                    } else {
                        drained.insert(source)
                    }
                }

            case .moveFile:
                let landed = action.collidedInto ?? action.dst
                if let source = owner(action.src) {
                    if isDirectlyInAChild(action.src) { live[source]?.files -= 1 }
                    if let target = owner(landed) {
                        if isDirectlyInAChild(landed) { live[target]?.files += 1 }
                        absorb(from: source, into: target)
                    } else {
                        drained.insert(source)
                    }
                } else if let target = owner(landed), isDirectlyInAChild(landed) {
                    live[target]?.files += 1
                }

            case .createDir:
                if let name = directChild(action.dst) {
                    live[name] = Live(files: 0, subfolders: 0, origin: nil, created: true)
                }

            case .keep:
                if let name = directChild(action.src) { live[name]?.kept = true }

            case .removeEmptyDir:
                if let name = directChild(action.src) { live.removeValue(forKey: name) }
            }
        }

        // A drained source stops existing only when nothing of it is left: every file and every
        // subfolder gone. A folder that gave up one file still stands.
        for source in drained {
            guard let state = live[source], state.files <= 0, state.subfolders <= 0 else {
                continue
            }
            live.removeValue(forKey: source)
        }

        let before = children.sorted().map { name in
            RestructurePreview.Row(name: name, files: view.fileCount(path(name)),
                                   fate: .unchanged)
        }
        let after = live.keys.sorted().map { name -> RestructurePreview.Row in
            let state = live[name]!
            let fate: RestructurePreview.Fate
            if !state.absorbed.isEmpty {
                fate = .mergedFrom(renamedFrom: state.origin, sources: state.absorbed.sorted())
            } else if let origin = state.origin {
                fate = .renamedFrom(origin)
            } else if state.created {
                fate = .created
            } else if state.kept {
                fate = .kept
            } else {
                fate = .unchanged
            }
            return RestructurePreview.Row(name: name, files: max(0, state.files), fate: fate)
        }
        return RestructurePreview(before: before, after: after)
    }

    // MARK: - One member

    /// One target's work inside one member: the sources the mapping sends there, and whether the
    /// name is already standing when this group runs.
    private struct Group {
        let target: String
        var sources: [String]
        /// The folder currently wearing the target's name, when its rename elsewhere is what
        /// vacates it: the vacate-before-fill dependency (this group may not run until that folder
        /// is in the vacated set). nil when the name is free or standing for good.
        var vacatedBy: String?
        /// The name is standing when this group runs, so the group merges into it: either it was
        /// never mapped away, or it is mapped away by a merge, which empties the folder but leaves
        /// the directory.
        var destExists: Bool
    }

    private static func memberActions(memberPath: String, member: String,
                                      mapping: RestructureMapping, in view: RestructureTreeView)
        -> Result<[RestructureManifest.Action], PlanRefusal> {
        let children = view.childFolders(memberPath) ?? []
        let childSet = Set(children)
        // One row per source is the mapping's shape, but `RestructureMapping` is public and doesn't
        // enforce it: a hand-built or imported mapping can repeat one. Imperfect input gets a
        // refusal, never a trap.
        var rowBySource: [String: RestructureMapping.Row] = [:]
        for row in mapping.rows {
            guard rowBySource[row.source] == nil else {
                return .failure(.duplicateMappingRows(source: row.source))
            }
            rowBySource[row.source] = row
        }

        // The active rows this member can act on.
        let active = mapping.activeRows.filter { childSet.contains($0.source) }
        // Every target must be one folder name: `dst` paths append it under the member, and the
        // apply's `absolute()` is a bare append, so a separator or dot traversal would aim a rename
        // outside the family or the profile root. The sheet's vocabulary is clean, but an imported
        // draft or a refine proposal may not be.
        for row in active {
            guard let target = row.target, Self.isValidTargetName(target) else {
                return .failure(.invalidTargetName(target: row.target ?? ""))
            }
        }
        var groups: [String: [String]] = [:]
        for row in active { groups[row.target!, default: []].append(row.source) }

        // Resolve, per target name, whether it stands when its group runs. Recursive, because "is
        // `Forms` vacated?" depends on whether `Forms` is the chosen rename of its own target
        // group, which depends on whether that target stands. Memoised, with the path stack as the
        // cycle detector.
        enum Vacancy { case free, vacated(by: String), standing, taken(by: String), fileTaken }
        // The member's files, for the occupancy test below: the disk can wear a target's name as a
        // file just as surely as a folder, and `childSet` can't see it.
        let memberFileSet = Set((view.files(memberPath) ?? []).map { $0.lowercased() })
        var memo: [String: Vacancy] = [:]
        var resolving: [String] = []
        var cycleMembers: Set<String> = []

        func renameChoice(target: String, sources: [String], destExists: Bool) -> String? {
            guard !destExists else { return nil }
            // A source differing from the target only by case must be the rename: while it stands,
            // the volume can't create the target beside it, and merging it into the target would
            // move its files onto themselves. The case-step beats file count.
            if let caseStep = sources.first(where: {
                $0 != target && $0.lowercased() == target.lowercased()
            }) { return caseStep }
            // The fewest moves that reach the shape: rename the source with the most files.
            return sources.max {
                let a = view.fileCount((memberPath as NSString).appendingPathComponent($0)) ?? 0
                let b = view.fileCount((memberPath as NSString).appendingPathComponent($1)) ?? 0
                // Ties broken lexicographically descending here, so `max` lands on the first name.
                return (a, $1) < (b, $0)
            }
        }

        func vacancy(of name: String) -> Vacancy {
            if let cached = memo[name] { return cached }
            // A case-only rename occupies its own name: `forms → Forms` is one rename-dir on a
            // case-insensitive volume, so the name never blocks its own group.
            guard childSet.contains(name) else {
                // A file wearing the name (either case) occupies it as surely as a folder, and no
                // mapping row can vacate a file, so the rename would fail at apply. Checked before
                // the folder-twin path, because a file can never be the case-step.
                if memberFileSet.contains(name.lowercased()) {
                    memo[name] = .fileTaken
                    return .fileTaken
                }
                // The exact name is absent, but on a case-insensitive volume a sibling differing
                // only by case occupies it. The one shape that steps through is the case-step
                // itself: the twin mapped onto this very name, whose single rename occupies and
                // vacates at once. Anything else (kept, emptied by a merge, or renamed away in an
                // order this resolver doesn't track across case) is a clash to refuse, not guess.
                guard let twin = children.first(where: {
                    $0 != name && $0.lowercased() == name.lowercased()
                }) else { return .free }
                if rowBySource[twin]?.target == name { return .free }
                memo[name] = .taken(by: twin)
                return .taken(by: twin)
            }
            guard let row = rowBySource[name], let rowTarget = row.target,
                  rowTarget != name, !groups[rowTarget, default: []].isEmpty else {
                memo[name] = .standing
                return .standing
            }
            if rowTarget.lowercased() == name.lowercased() {
                memo[name] = .vacated(by: name)
                return .vacated(by: name)
            }
            if let index = resolving.firstIndex(of: name) {
                // A vacancy cycle: every name in it is mapped onto the next. Mark the ring; the
                // emitter breaks it with a temporary name, and only for pure renames.
                cycleMembers.formUnion(resolving[index...])
                return .vacated(by: name)
            }
            resolving.append(name)
            defer { resolving.removeLast() }
            let targetVacancy = vacancy(of: rowTarget)
            let destExists: Bool
            switch targetVacancy {
            case .standing, .taken, .fileTaken: destExists = true
            case .free, .vacated: destExists = false
            }
            let chosen = renameChoice(target: rowTarget,
                                      sources: groups[rowTarget] ?? [], destExists: destExists)
            let result: Vacancy = chosen == name ? .vacated(by: name) : .standing
            memo[name] = result
            return result
        }

        // Resolve every group.
        var resolved: [Group] = []
        for (target, sources) in groups {
            let targetVacancy = vacancy(of: target)
            var group = Group(target: target, sources: sources.sorted(),
                              vacatedBy: nil, destExists: false)
            switch targetVacancy {
            case .free: break
            case .standing: group.destExists = true
            // `by` is the folder wearing this group's target name, renamed away. A case-only
            // vacancy (`forms` stepping up to `Forms`) never reaches here: the exact-cased name
            // isn't in `childSet`, so it resolves `.free`.
            case .vacated(let by): group.vacatedBy = by
            case .taken(let by):
                return .failure(.targetTakenByCase(target: target, standing: by, member: member))
            case .fileTaken:
                return .failure(.targetTakenByFile(target: target, member: member))
            }
            resolved.append(group)
        }
        if !cycleMembers.isEmpty {
            // A ring is breakable only when every link is a pure rename: one source, no merge.
            let ringGroups = resolved.filter { cycleMembers.contains($0.target) }
            guard ringGroups.allSatisfy({ $0.sources.count == 1 && !$0.destExists }) else {
                return .failure(.unresolvableOrder(member: member))
            }
        }

        // Topological order on vacate-before-fill, stable by target name. A cycle picks its
        // lexicographically first group, renames that group's source to a temporary name up front,
        // and restores it at the end: the two-way swap, generalised.
        resolved.sort { $0.target < $1.target }
        var pending = resolved
        var tempFinal: [RestructureManifest.Action] = []
        var vacatedNames: Set<String> = []
        var actions: [RestructureManifest.Action] = []
        // What remains of each drained source, by path. A standing target that is itself an earlier
        // group's merge source (drain-before-fill guarantees the drain ran first) must be read as
        // the drain left it: its files gone (no false collisions), its whole-carried subfolders
        // gone (a later same-named arrival lands whole), and a merged subfolder's shell still
        // occupying its name.
        var residues: [String: LandedContents] = [:]

        func emit(_ group: Group) -> PlanRefusal? {
            let targetPath = (memberPath as NSString).appendingPathComponent(group.target)
            let chosen = renameChoice(target: group.target, sources: group.sources,
                                      destExists: group.destExists)
            // The chosen rename is what creates the target directory when it doesn't stand yet, so
            // it must run before any sibling's merge writes into it, or those moves fail at apply
            // against the absent parent.
            if let chosen {
                let sourcePath = (memberPath as NSString).appendingPathComponent(chosen)
                actions.append(RestructureManifest.Action(
                    action: .renameDir, src: sourcePath, dst: targetPath,
                    evidence: "The mapping names \(chosen)/ as \(group.target)/ in the "
                        + "target shape; the rename is atomic and carries its files.",
                    filesCarried: view.fileCount(sourcePath) ?? 0))
                vacatedNames.insert(chosen)
            }
            // What the target holds as each merge source lands: the standing folder's contents, or,
            // when the chosen rename creates the target, that rename's payload, growing with every
            // landing. Judged against the plan-time target alone, the plan would promise
            // whole-folder carries into a destination its own rename had filled, and each would
            // skip at apply as "appeared since the plan".
            let chosenPath = chosen.map { (memberPath as NSString).appendingPathComponent($0) }
            // Read, never assumed empty, and only once a source is about to land in it, so a lone
            // rename asks nothing of a view that can't list. A target or chosen rename that doesn't
            // list refuses the plan, as an unreadable merge source does; the source's own refusal
            // comes first, as `emitMerge` gives it.
            var landedSoFar: LandedContents?
            for source in group.sources where source != chosen {
                let sourcePath = (memberPath as NSString).appendingPathComponent(source)
                guard view.files(sourcePath) != nil else { return .unknownFiles(source: sourcePath) }
                var landed: LandedContents
                if let landedSoFar {
                    landed = landedSoFar
                } else if group.destExists {
                    guard let standing = residues[targetPath] ?? LandedContents.reading(targetPath, in: view)
                    else { return .unknownFiles(source: targetPath) }
                    landed = standing
                } else if let chosenPath {
                    guard let payload = LandedContents.reading(chosenPath, in: view)
                    else { return .unknownFiles(source: chosenPath) }
                    landed = payload
                } else {
                    landed = LandedContents(of: nil, in: view)
                }
                var residue = LandedContents(of: nil, in: view)
                if let refusal = emitMerge(of: sourcePath, sourceName: source,
                                           into: targetPath, targetName: group.target,
                                           in: view, landed: &landed, residue: &residue,
                                           actions: &actions) {
                    return refusal
                }
                landedSoFar = landed
                residues[sourcePath] = residue
            }
            return nil
        }

        while !pending.isEmpty {
            if let index = pending.firstIndex(where: { group in
                if let by = group.vacatedBy, !vacatedNames.contains(by) { return false }
                // Drain before fill, the merge half: a standing target that is another pending
                // group's source must be drained before anything merges into it. Its outbound moves
                // were listed at plan time, and files arriving first would trip the apply's
                // unlisted veto on the very folder the plan is emptying. (`vacatedBy` above is the
                // rename half.)
                if group.destExists, pending.contains(where: { other in
                    other.target != group.target && other.sources.contains(group.target)
                }) { return false }
                return true
            }) {
                let group = pending.remove(at: index)
                if let refusal = emit(group) { return .failure(refusal) }
                continue
            }
            // Nothing runnable: the remaining groups form a ring. The temp-name break is only sound
            // for a pure-rename ring. The resolver pre-validates every ring it detects, so an
            // impure stall should be unreachable, but drain-before-fill is a second stall source;
            // refusing beats temp-renaming a merge source and stranding its files under a scratch
            // name.
            guard pending.allSatisfy({ $0.sources.count == 1 && !$0.destExists }) else {
                return .failure(.unresolvableOrder(member: member))
            }
            let ring = pending.removeFirst()
            let source = ring.sources[0]
            let sourcePath = (memberPath as NSString).appendingPathComponent(source)
            let temp = temporaryName(for: source, avoiding: childSet)
            let tempPath = (memberPath as NSString).appendingPathComponent(temp)
            actions.append(RestructureManifest.Action(
                action: .renameDir, src: sourcePath, dst: tempPath,
                evidence: "Two names trade places: \(source)/ steps aside so its own name can "
                    + "be filled, and takes its target's name at the end.",
                filesCarried: view.fileCount(sourcePath) ?? 0))
            vacatedNames.insert(source)
            tempFinal.append(RestructureManifest.Action(
                action: .renameDir, src: tempPath,
                dst: (memberPath as NSString).appendingPathComponent(ring.target),
                evidence: "The second half of the swap: the set-aside folder takes its "
                    + "target's now-vacated name.",
                filesCarried: view.fileCount(sourcePath) ?? 0))
            // The ring group's whole emission is the temp pair; nothing more to derive for it.
        }
        actions.append(contentsOf: tempFinal)

        // Keeps last: they never run, and read best as the plan's signature block.
        for row in mapping.rows where row.target == nil && childSet.contains(row.source) {
            actions.append(RestructureManifest.Action(
                action: .keep,
                src: (memberPath as NSString).appendingPathComponent(row.source),
                evidence: "Mapped to keep — the target shape has no slot for it, and it stays "
                    + "exactly where and as it stands."))
        }
        return .success(actions)
    }

    /// What the merge target holds as a source lands: the plan's running model of the destination,
    /// so a later source sees the chosen rename's payload and every earlier landing, not just the
    /// plan-time disk.
    private struct LandedContents {
        var files: Set<String>
        /// Occupied subfolder name → the plan-time path whose contents landed under it (the
        /// standing target's own subfolder, the chosen rename's, or an earlier source's carried
        /// folder). Presence is the occupancy test; the path is where a one-level-down merge reads
        /// that occupant's contents from.
        var subfolderOrigins: [String: String]
        /// The running state of subfolders a one-level-down merge has already written into,
        /// so two sources merging into the same occupied subfolder see each other's files.
        var merged: [String: LandedSubfolder]

        init(of path: String?, in view: RestructureTreeView) {
            guard let path else {
                files = []; subfolderOrigins = [:]; merged = [:]
                return
            }
            files = Set(view.files(path) ?? [])
            subfolderOrigins = Dictionary(uniqueKeysWithValues:
                (view.childFolders(path) ?? []).map {
                    ($0, (path as NSString).appendingPathComponent($0))
                })
            merged = [:]
        }

        /// What `path` holds, or nil when the view can't list it: a folder that is there but didn't
        /// answer, which a merge must not read as empty.
        static func reading(_ path: String, in view: RestructureTreeView) -> LandedContents? {
            guard view.files(path) != nil, view.childFolders(path) != nil else { return nil }
            return LandedContents(of: path, in: view)
        }
    }

    /// `LandedContents` one level down: a separate flat type because the merge stops there (deeper
    /// same-name pairs are `keep`), so it needs no origins of its own.
    private struct LandedSubfolder {
        var files: Set<String>
        var subfolders: Set<String>
    }

    /// One source folder merged into the target: `move-file` per file, `move-dir` per subfolder,
    /// one level of same-name recursion, `keep` beyond. Never a `move-dir` of the source onto the
    /// target. `landed` is the group's running model of the target, which collisions and occupancy
    /// are judged against. `residue` gathers what remains of the source after the drain (merged
    /// subfolders leave shells; everything else leaves), for a later group whose standing target
    /// this source is.
    private static func emitMerge(of sourcePath: String, sourceName: String,
                                  into targetPath: String, targetName: String,
                                  in view: RestructureTreeView,
                                  landed: inout LandedContents,
                                  residue: inout LandedContents,
                                  actions: inout [RestructureManifest.Action]) -> PlanRefusal? {
        guard let files = view.files(sourcePath) else {
            return .unknownFiles(source: sourcePath)
        }
        for file in files.sorted() {
            // Folded, as folder occupancy is: `receipt.pdf` in the target takes `Receipt.PDF`'s
            // name on a case-insensitive volume, and the apply lands it under a unique name, so the
            // plan says so. A folder wearing the name takes it too: the apply finds something at
            // the destination either way.
            let collision = Self.occupant(named: file, in: landed.files) != nil
                || Self.occupant(named: file, in: landed.subfolderOrigins.keys) != nil
            actions.append(RestructureManifest.Action(
                action: .moveFile,
                src: (sourcePath as NSString).appendingPathComponent(file),
                dst: (targetPath as NSString).appendingPathComponent(file),
                evidence: "Merging \(sourceName)/ into \(targetName)/ — the mapping sends both "
                    + "names to one folder.",
                collisionExpected: collision ? true : nil))
            landed.files.insert(file)
        }
        for subfolder in (view.childFolders(sourcePath) ?? []).sorted() {
            let subSource = (sourcePath as NSString).appendingPathComponent(subfolder)
            let actionsBefore = actions.count
            // Occupancy folds case, as the member-level test does: on these volumes
            // `Payments/receipts/` occupies `Receipts` as surely as an exact twin. Matched by exact
            // case, the plan would carry a folder whole onto it and the apply would skip it as
            // "appeared since the plan". So the merge goes one level down into the occupant under
            // its own spelling, the folder actually on disk.
            let occupant = Self.occupant(named: subfolder, in: landed.subfolderOrigins.keys)
            let subTarget = (targetPath as NSString).appendingPathComponent(occupant ?? subfolder)
            if let occupant, let origin = landed.subfolderOrigins[occupant] {
                // One level down by the same rules, against the occupant's contents wherever they
                // stand at plan time, plus whatever earlier sources already merged into it. The
                // occupant is read, never assumed empty, as the source below is.
                var sub: LandedSubfolder
                if let merged = landed.merged[occupant] {
                    sub = merged
                } else {
                    guard let originFiles = view.files(origin),
                          let originFolders = view.childFolders(origin) else {
                        return .unknownFiles(source: origin)
                    }
                    sub = LandedSubfolder(files: Set(originFiles), subfolders: Set(originFolders))
                }
                guard let subFiles = view.files(subSource) else {
                    return .unknownFiles(source: subSource)
                }
                var keptDeeper: Set<String> = []
                for file in subFiles.sorted() {
                    let collision = Self.occupant(named: file, in: sub.files) != nil
                        || Self.occupant(named: file, in: sub.subfolders) != nil
                    actions.append(RestructureManifest.Action(
                        action: .moveFile,
                        src: (subSource as NSString).appendingPathComponent(file),
                        dst: (subTarget as NSString).appendingPathComponent(file),
                        evidence: "Merging \(subfolder)/ into \(occupant)/ — the mapping "
                            + "sends both names to one folder.",
                        collisionExpected: collision ? true : nil))
                    sub.files.insert(file)
                }
                for deeper in (view.childFolders(subSource) ?? []).sorted() {
                    let deepSource = (subSource as NSString).appendingPathComponent(deeper)
                    // Folded too, one level down, for the same reason.
                    if Self.occupant(named: deeper, in: sub.files) != nil {
                        // A file wearing the folder's name on the target side: the carry would fail
                        // at apply against a destination the occupancy sets can't see.
                        actions.append(RestructureManifest.Action(
                            action: .keep, src: deepSource,
                            evidence: "A file named \(deeper) stands where this folder would "
                                + "land — kept and reported rather than guessed at."))
                        keptDeeper.insert(deeper)
                    } else if Self.occupant(named: deeper, in: sub.subfolders) == nil {
                        actions.append(RestructureManifest.Action(
                            action: .moveDir, src: deepSource,
                            dst: (subTarget as NSString).appendingPathComponent(deeper),
                            evidence: "Carried whole into \(subfolder)/ — the target has no "
                                + "\(deeper)/ of its own."))
                        sub.subfolders.insert(deeper)
                    } else {
                        actions.append(RestructureManifest.Action(
                            action: .keep, src: deepSource,
                            evidence: "Both sides have \(deeper)/ two levels down — deeper "
                                + "than the merge reaches, so it is kept and reported rather "
                                + "than guessed at."))
                        keptDeeper.insert(deeper)
                    }
                }
                // An empty same-name subfolder produces no file moves and no deeper rows, so
                // nothing in the manifest names it, and the apply's unlisted-file rule would read
                // it as an unlisted item and veto the whole merge. A listed `keep` records what
                // happens to it: nothing.
                if actions.count == actionsBefore {
                    actions.append(RestructureManifest.Action(
                        action: .keep, src: subSource,
                        evidence: "Both sides have \(subfolder)/ and this one is empty — there "
                            + "is nothing to move, so it is kept and reported."))
                }
                landed.merged[occupant] = sub
                // The merge moved this subfolder's files but the directory remains: a shell at the
                // source, still occupying its name (a later whole-carry to it would skip at apply),
                // holding only the deeper folders the merge kept.
                residue.subfolderOrigins[subfolder] = subSource
                residue.merged[subfolder] = LandedSubfolder(files: [], subfolders: keptDeeper)
            } else if Self.occupant(named: subfolder, in: landed.files) != nil {
                // Same rule one level up: a file in the target wearing this subfolder's name.
                // `subfolderOrigins` is folder-shaped and can't see it, and a whole-carry onto it
                // would always skip at apply as false drift.
                actions.append(RestructureManifest.Action(
                    action: .keep, src: subSource,
                    evidence: "A file named \(subfolder) stands in \(targetName)/ where this "
                        + "folder would land — kept and reported rather than guessed at."))
                residue.subfolderOrigins[subfolder] = subSource
            } else {
                actions.append(RestructureManifest.Action(
                    action: .moveDir, src: subSource, dst: subTarget,
                    evidence: "Carried whole into \(targetName)/ — the target has no "
                        + "\(subfolder)/ of its own."))
                landed.subfolderOrigins[subfolder] = subSource
            }
        }
        return nil
    }

    /// The name in `names` that `name` lands on: itself when present, else the one differing only
    /// by case (the first, sorted, so the manifest is reproducible), else nil. Always case-folded,
    /// as every occupancy test here is: the volumes this app runs against are case-insensitive.
    private static func occupant(named name: String, in names: some Collection<String>) -> String? {
        if names.contains(name) { return name }
        let folded = name.lowercased()
        return names.filter { $0.lowercased() == folded }.sorted().first
    }

    /// A name no child is wearing, deterministic so the manifest is reproducible.
    static func temporaryName(for source: String, avoiding existing: Set<String>) -> String {
        var candidate = source + ".restructure-swap"
        var counter = 2
        while existing.contains(candidate) {
            candidate = source + ".restructure-swap-\(counter)"
            counter += 1
        }
        return candidate
    }
}

/// The plan's cost as a pure function of its actions: "8 renames · 12 moved · 92 carried · 5 kept"
/// is derived, never pasted.
///
/// It separates what a merge does from what a rename does: files moved counts `move-file` rows,
/// files carried sums the renames' and whole moves' `filesCarried`, and folders emptied counts the
/// distinct source folders the moves drained.
public struct RestructureLedger: Equatable, Sendable {
    public let foldersRenamed: Int
    public let filesCarried: Int
    public let filesMoved: Int
    public let foldersMovedWhole: Int
    public let foldersEmptied: Int
    public let foldersCreated: Int
    public let kept: Int
    public let collisionsKept: Int

    /// The source folders a manifest's moves drained, shallowest only: what the removal step is
    /// scoped to, and the ledger's folders emptied. Whether each is still empty is the removal
    /// sheet's re-probe, not this function's claim.
    public static func emptiedFolders(of manifest: RestructureManifest) -> [String] {
        var drained: Set<String> = []
        for action in manifest.actions
        where action.action == .moveFile || action.action == .moveDir {
            // A whole-folder relocation empties nothing: its source travels intact, and its parent,
            // which the line below would otherwise record, keeps every other child.
            guard action.movesWholeFolder != true, let src = action.src else { continue }
            drained.insert((src as NSString).deletingLastPathComponent)
        }
        // Shallowest only, by walking each path's ancestors rather than comparing every pair: a
        // path is dropped exactly when another drained folder is a proper ancestor of it. This runs
        // per applied record per render, so it stays linear in path depth.
        return drained.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if drained.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    public init(of manifest: RestructureManifest) {
        var renames = 0, carried = 0, moved = 0, movedWhole = 0, created = 0, kept = 0
        var collisions = 0
        for action in manifest.actions {
            switch action.action {
            case .renameDir:
                renames += 1
                carried += action.filesCarried ?? 0
            case .moveFile:
                moved += 1
                if action.collisionExpected == true || action.collidedInto != nil {
                    collisions += 1
                }
            case .moveDir:
                movedWhole += 1
                // A whole-folder relocation carries its files exactly as a rename does.
                carried += action.filesCarried ?? 0
            case .createDir: created += 1
            case .keep: kept += 1
            case .removeEmptyDir: break
            }
        }
        foldersRenamed = renames
        filesCarried = carried
        filesMoved = moved
        foldersMovedWhole = movedWhole
        // One rule, not a second copy: `emptiedFolders(of:)` excludes whole-folder relocations, and
        // the count must agree with what the removal step offers.
        foldersEmptied = Self.emptiedFolders(of: manifest).count
        foldersCreated = created
        self.kept = kept
        collisionsKept = collisions
    }

    /// The one-line reading. Counts that are zero stay out of the sentence, except the first three,
    /// which are the plan's size.
    public var summary: String {
        var parts = [
            "\(foldersRenamed) rename\(foldersRenamed == 1 ? "" : "s")",
            "\(filesMoved) moved",
            "\(filesCarried) carried",
        ]
        if foldersMovedWhole > 0 {
            parts.append("\(foldersMovedWhole) folder"
                + "\(foldersMovedWhole == 1 ? "" : "s") carried whole")
        }
        if kept > 0 { parts.append("\(kept) kept") }
        if foldersCreated > 0 { parts.append("\(foldersCreated) created") }
        if collisionsKept > 0 {
            parts.append("\(collisionsKept) name collision\(collisionsKept == 1 ? "" : "s"), both kept")
        }
        return parts.joined(separator: " · ")
    }
}
