import Foundation

/// The family mapping §5.4's editor edits: *source child name → target child name*, one row per
/// distinct source name across every member.
///
/// Edited once, applied to every member — per member the operations are **derived, never typed**
/// (``RestructurePlanner``). `nil` target is *keep*, and keep is the default for every row: the
/// editor never guesses a mapping (ROADMAP_V5 §5.4 step 3).
public struct RestructureMapping: Equatable, Sendable {

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        /// A distinct child folder name somewhere in the family, disk-cased.
        public let source: String
        /// The name this folder should have in the target shape — or `nil` for *keep*, which
        /// leaves it where and as it stands, listed in the manifest (invariant 4).
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

    /// Rows that would change something — a row mapped to its own name is the vocabulary
    /// agreeing with itself, not an operation.
    var activeRows: [Row] {
        rows.filter { row in
            guard let target = row.target else { return false }
            return target != row.source
        }
    }
}

/// What the planner is allowed to know about the tree — narrow on purpose, so the derivation is a
/// pure function testable against a fixture (§5.8: "testable with no disk").
///
/// Two backings exist: ``fromProfile(_:)`` knows folders and counts but no file names — enough
/// for renames, which is all the 6 Aug oracle needs — and the app's disk-backed view adds file
/// names, which merges need to expand into `move-file` rows. A merge the view cannot expand is a
/// refusal, never a guess.
public struct RestructureTreeView {
    /// Direct child *folder* names of a path (relative to the profile root), disk-cased.
    /// Empty for a leaf; nil for a path the view has never heard of.
    public let childFolders: (String) -> [String]?
    /// File names directly inside a path — nil when the view cannot name them (a profile knows
    /// counts, not names).
    public let files: (String) -> [String]?
    /// How many files a path holds directly — `filesCarried` on a rename.
    public let fileCount: (String) -> Int?

    public init(childFolders: @escaping (String) -> [String]?,
                files: @escaping (String) -> [String]?,
                fileCount: @escaping (String) -> Int?) {
        self.childFolders = childFolders
        self.files = files
        self.fileCount = fileCount
    }

    /// The view the live disk gives: folders, files and counts, read lazily as the planner asks.
    ///
    /// This is the app's backing — the profile knows the survey's counts, but a plan is derived
    /// against the tree as it stands *now*, and merges need file names the profile never stores.
    /// Hidden entries are skipped, matching what the survey walks.
    public static func fromDisk(root: URL, fileManager: FileManager = .default)
        -> RestructureTreeView {
        func entries(_ path: String) -> (folders: [String], files: [String])? {
            let url = root.appendingPathComponent(path)
            guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else {
                return nil
            }
            var folders: [String] = []
            var files: [String] = []
            for name in names where !name.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.appendingPathComponent(name).path,
                                             isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    folders.append(name)
                } else {
                    files.append(name)
                }
            }
            return (folders.sorted(), files.sorted())
        }
        return RestructureTreeView(
            childFolders: { entries($0)?.folders },
            files: { entries($0)?.files },
            fileCount: { entries($0)?.files.count })
    }

    /// The same view with every listing read once and remembered. The plan sheet re-derives the
    /// whole manifest on each edit, and a disk-backed view re-listed every mapped source and
    /// target directory per keystroke in the name field; a plan is re-probed at apply anyway,
    /// so mid-sheet disk changes were never something the derivation promised to see. The cache
    /// lives as long as this view value does — one sheet presentation.
    public func memoized() -> RestructureTreeView {
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

/// Mapping → manifest, per member, by §5.4's rules — a pure function of the mapping and the view.
///
/// The rules, as written there:
/// - one source → a target absent in that member: **`rename-dir`** (atomic, carries its files);
/// - N sources → one absent target: rename the source with the most files, merge the rest into it;
/// - N sources → a target already present: merge all N into it;
/// - a target with no source in that member: nothing (the scaffold's `create-dir` is §5.2's own
///   builder, not this one);
/// - a source mapped to *keep*: a listed `keep` row.
/// - **Ordering inside a member is derived too**: a folder is vacated before its name is filled, a
///   pure rename cycle goes through a temporary name, and a case-only rename stays one `rename-dir`
///   (apply's `safeMoveItem` owns the two-step).
///
/// A merge is `move-file` per file plus `move-dir` per subfolder **into** the target — never a
/// `move-dir` of the source onto the target, which would nest it. A subfolder whose name already
/// exists at the target merges one level down by the same rules; deeper than that it is `keep`
/// and reported. The emptied source directory is left standing for the removal step's own
/// manifest — this planner never emits `remove-empty-dir`.
public enum RestructurePlanner {

    /// Why a plan could not be derived — sentences for the sheet, not codes.
    public enum PlanRefusal: Error, Equatable {
        /// Every row is keep or self — there is nothing to do, which is a card sentence rather
        /// than an empty manifest.
        case nothingMapped
        /// A merge needs the files inside `source` and the view cannot name them.
        case unknownFiles(source: String)
        /// The mapping lists one source name on two rows — a shape only a hand-built or
        /// imported mapping can produce (the sheet seeds one row per distinct name), and the
        /// rows may disagree, so neither is safe to prefer.
        case duplicateMappingRows(source: String)
        /// A vacancy cycle runs through a multi-source group — a mapping this contorted needs a
        /// person, not a heuristic.
        case unresolvableOrder(member: String)
        /// Two distinct target names collide case-insensitively (`Forms` and `forms`) — on the
        /// case-insensitive volumes this app runs against, both cannot exist side by side, and
        /// deriving operations toward them would fail at apply in a shape the plan promised away.
        case conflictingTargets(String, String)
        /// A target name is occupied by a sibling differing only by case that this mapping does
        /// not step up (`Files → Forms` while `forms/` stands, kept or merely emptied). The
        /// volume cannot create `Forms/` beside `forms/`, so the derivation would fail at apply;
        /// refusing here keeps that from becoming a reviewed plan that cannot land.
        case targetTakenByCase(target: String, standing: String, member: String)
        /// A target name is not one folder name: it carries a path separator or is a dot
        /// traversal (`Tax/2024`, `../Shared`). Every target lands as a SIBLING inside the
        /// member — a path-shaped name would aim the rename outside the family, and the apply's
        /// `absolute()` would follow it there. Reachable from a typed custom name, an imported
        /// draft, or a refine proposal, so the derivation is where the door is closed.
        case invalidTargetName(target: String)
        /// A target name is occupied by a FILE of that name in the member. The planner's
        /// occupancy model is folder-shaped, but the disk is not: a rename onto a standing file
        /// would fail at apply in a shape the plan promised away, blamed on drift that never
        /// happened.
        case targetTakenByFile(target: String, member: String)
    }

    /// The ONE spelling of "is this string a folder name and not a path": no separator, no dot
    /// traversal, not blank. The sheet's custom-name field, the refine proposal filter and the
    /// derivation all ask this function, so the three doors cannot drift — a name that passes
    /// one passes all, and `.invalidTargetName` backstops whatever arrives another way.
    /// (Colons are rejected with separators: Finder displays `:` as `/`, and HFS paths treat it
    /// as one.)
    public static func isValidTargetName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/") && !trimmed.contains(":")
    }

    /// Every distinct child folder name across the members, disk-cased and sorted — the editor's
    /// row list ("24 distinct child names across 17 members" on the flagship family).
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

    /// Sibling families that share this one's mapping vocabulary — §5.4 step 2's warning, as a
    /// rule: fixing H-4 alone would have left it disagreeing with H-1B and H-4 EAD, and the 6 Aug
    /// fix was found by laying the three side by side. A sibling counts when at least three of
    /// its members' child names also appear across this family's members — three, because two
    /// generic role names (`Statements`, `Reference`) recur correctly all over a filed tree, and
    /// a pointer that fires everywhere is a pointer nobody reads.
    ///
    /// A pointer, deliberately not the roadmap's full side-by-side table — that lands with the
    /// Apply milestone, where planning several families in one sitting becomes real.
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

    /// The derived manifest — every member's operations in member order, each member internally
    /// ordered so it can run top to bottom.
    /// - Parameter recordedFamily: what the manifest, the ledger card and the exported filename
    ///   should CALL this family, when that differs from the path the members hang off. They
    ///   differ for a seeded pair: the mapping's unit is a child name inside a member, so a pair
    ///   under `Travel/` is planned with `family: ""` and `members: ["Travel"]` — and recording
    ///   `""` would head its landing card "Across the tree" for two folders inside `Travel`.
    ///   nil records `family`, which is what every family mapping wants.
    public static func manifest(family: String, members: [String],
                                mapping: RestructureMapping, kind: FindingKind,
                                in view: RestructureTreeView,
                                profileId: String, manifestId: String, createdAt: String,
                                note: String? = nil, recordedFamily: String? = nil)
        -> Result<RestructureManifest, PlanRefusal> {
        guard !mapping.activeRows.isEmpty else { return .failure(.nothingMapped) }
        // Distinct targets that differ only by case cannot coexist on a case-insensitive volume.
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
            // Rows were mapped, but no member holds any of the mapped names — same sentence as
            // an all-keep mapping, because the same nothing would land.
            return .failure(.nothingMapped)
        }
        return .success(RestructureManifest(
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            family: recordedFamily ?? family, kind: kind, note: note,
            mapping: mapping.rows, actions: actions))
    }

    /// One folder's contents moved into another folder that is **not its sibling** — the merge
    /// kinds whose two paths sit under different parents (ROADMAP_V5 §5.2's mirrored inbox, loose
    /// folder beside its container, and a child echoing its parent).
    ///
    /// The family mapping cannot express these: a mapping row renames a child *within* its
    /// member, and here the source changes parent. So the pair is derived directly — but by the
    /// same rules and the same code as a mapped merge, because two implementations of "merge a
    /// folder into a folder" is exactly the drift the mapping planner's own doc warns about.
    ///
    /// - A destination that does not exist yet is one `move-dir`: the folder travels whole and
    ///   its files ride along, which is what the loose-folder card promises.
    /// - A destination that stands is drained into per ``emitMerge`` — `move-file` per file,
    ///   `move-dir` per subfolder, one level of same-name recursion, `keep` beyond that, and
    ///   never a `move-dir` of the source onto the target, which would nest it.
    ///
    /// The emptied source is left standing for the removal step's own manifest, exactly as the
    /// mapped planner leaves it.
    public static func pairMergeManifest(source: String, destination: String, kind: FindingKind,
                                         in view: RestructureTreeView,
                                         profileId: String, manifestId: String, createdAt: String,
                                         note: String? = nil)
        -> Result<RestructureManifest, PlanRefusal> {
        guard source != destination else { return .failure(.nothingMapped) }
        // A folder cannot be moved inside itself, and a destination under the source is how a
        // detector pair would express that. Refuse rather than derive a plan that eats its own
        // source — the same class of refusal as an unresolvable order.
        guard !RestructurePaths.isInside(destination, of: source) else {
            return .failure(.unresolvableOrder(member: source))
        }
        // The source has to exist before either branch is worth deriving. Without this the
        // whole-move branch happily plans a `move-dir` out of a folder that vanished since the
        // survey — the merge branch refuses that through `view.files`, and the two sides of one
        // function should not disagree about whether a missing source is a plan.
        guard view.childFolders(source) != nil else {
            return .failure(.unknownFiles(source: source))
        }
        let sourceName = (source as NSString).lastPathComponent
        let targetName = (destination as NSString).lastPathComponent
        var actions: [RestructureManifest.Action] = []

        // `childFolders(destination) == nil` means "not a readable directory", which is true
        // both when nothing is there AND when a FILE of that name is. Deriving a move-dir onto a
        // standing file produces a plan that ALWAYS skips at apply as false "appeared since the
        // plan" drift — the exact class the mapped planner already refuses, and which the pair
        // route reaches because a profile stores no file names for the detector to see.
        let destinationParent = (destination as NSString).deletingLastPathComponent
        if view.childFolders(destination) == nil,
           view.files(destinationParent)?.contains(targetName) == true {
            return .failure(.targetTakenByFile(target: targetName, member: destinationParent))
        }
        if view.childFolders(destination) == nil {
            // Nothing stands at the destination: the whole folder travels, files included.
            let newParent = (destination as NSString).deletingLastPathComponent
            actions.append(RestructureManifest.Action(
                action: .moveDir, src: source, dst: destination,
                evidence: "\(sourceName)/ belongs in \(newParent)/ and nothing of that name "
                    + "stands there — the folder moves whole and its files ride along.",
                filesCarried: view.fileCount(source),
                // The source's PARENT is not being drained by this — see the field's own doc.
                // Without the flag the apply's unlisted veto skips every one of these (the
                // detector requires a sibling container, which is exactly what the veto sees),
                // and the removal step offers that parent as a folder this landing emptied.
                movesWholeFolder: true))
        } else {
            var landed = LandedContents(of: destination, in: view)
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

    /// One member's children as they stand and as the plan would leave them — §5.4's review
    /// section shows the operations, and this is the shape those operations produce.
    ///
    /// Derived from the manifest's own actions filtered to that member, so it cannot describe a
    /// plan other than the one being reviewed, and from the tree view's counts — **never from a
    /// second walk of the disk**. The sheet re-derives on every keystroke, and per-row derivation
    /// there was already measured at hundreds of directory reads per edit.
    public struct RestructurePreview: Equatable, Sendable {

        /// What the plan does to one child folder, as the after-column labels it.
        public enum Fate: Equatable, Sendable {
            /// Renamed from another name, which is named.
            case renamedFrom(String)
            /// Other folders were drained into this one — and, when the row also took its name
            /// from a folder, which one. Both facts, because a row that only says what it
            /// absorbed leaves the reader hunting for where the renamed folder went.
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
            /// Files directly inside, or nil when the view cannot count them.
            public let files: Int?
            public let fate: Fate
        }

        /// The member's children now, in name order, with their current file counts.
        public let before: [Row]
        /// The member's children after the plan, in name order.
        public let after: [Row]
    }

    /// The before and after of one member under a manifest. nil when the view has never heard of
    /// the member — an absent folder has no before to show.
    ///
    /// **An ordered simulation, not a set of deltas.** The first version accumulated per-name
    /// changes and then reconstructed the after column, which cannot survive a rename CHAIN: the
    /// planner routes a two-way swap through a temporary name, and the reconstruction kept that
    /// temp as a surviving row — the review section showed a folder called
    /// `B.restructure-swap` that would never exist. Walking the actions in the order they run is
    /// the only thing that gets chains, cycles and vacate-before-fill right, and it is what the
    /// apply does too.
    public static func preview(member: String, in manifest: RestructureManifest,
                               tree view: RestructureTreeView) -> RestructurePreview? {
        guard let children = view.childFolders(member) else { return nil }
        func path(_ name: String) -> String {
            (member as NSString).appendingPathComponent(name)
        }
        /// The parts of a path below the member, or nil when it is not under it at all.
        func parts(_ full: String?) -> [String]? {
            guard let full, RestructurePaths.isInside(full, of: member), full != member else {
                return nil
            }
            let rest = full.dropFirst(member.isEmpty ? 0 : member.count + 1)
            return rest.split(separator: "/").map(String.init)
        }
        /// A DIRECT child folder of the member — `member/Forms`, never `member/Forms/Sub`.
        func directChild(_ full: String?) -> String? {
            guard let p = parts(full), p.count == 1 else { return nil }
            return p[0]
        }
        /// The direct child a deeper path lives under, whatever its depth.
        func owner(_ full: String?) -> String? {
            guard let p = parts(full), p.count >= 2 else { return nil }
            return p[0]
        }
        /// True when the path is an item sitting DIRECTLY in a child — the only depth that
        /// changes that child's own file or subfolder count.
        func isDirectlyInAChild(_ full: String?) -> Bool {
            (parts(full)?.count ?? 0) == 2
        }

        /// One folder as the simulation currently sees it, under the name it currently wears.
        struct Live {
            var files: Int
            var subfolders: Int
            /// The name this folder started the plan under, when that differs from its current
            /// one. Chains collapse into it, so a swap reports the ORIGINAL name rather than the
            /// temporary the planner passed through.
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
        /// Names something was taken OUT of — the candidates for disappearing entirely.
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
                        // Vacate-before-fill normally frees the name first; if it did not, this
                        // is a merge and reads as one.
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
                    // A subfolder moved between children — the shape a merge takes when the
                    // source holds no loose files at all, which a move-file-only rule missed
                    // entirely and left its drained source standing in the after column.
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

        // A drained source stops existing as itself only when nothing of it is left: every file
        // gone AND every subfolder gone. A folder that gave up one file still stands, and the
        // after column would be lying to drop it.
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
        /// The folder currently wearing the target's name, when its *rename* elsewhere is what
        /// vacates it — the vacate-before-fill dependency (this group may not run until that
        /// folder appears in the vacated set). nil when the name is free or standing for good.
        var vacatedBy: String?
        /// The name is standing when this group runs (so the group merges into it) — either it
        /// was never mapped away, or it is mapped away by a *merge*, which empties the folder
        /// but leaves the directory.
        var destExists: Bool
    }

    private static func memberActions(memberPath: String, member: String,
                                      mapping: RestructureMapping, in view: RestructureTreeView)
        -> Result<[RestructureManifest.Action], PlanRefusal> {
        let children = view.childFolders(memberPath) ?? []
        let childSet = Set(children)
        // One row per source is the mapping's shape, but `RestructureMapping` is public and does
        // not enforce it — the sheet seeds one row per distinct name, while a hand-built or
        // imported mapping can repeat one. Imperfect input gets a refusal, never a trap.
        var rowBySource: [String: RestructureMapping.Row] = [:]
        for row in mapping.rows {
            guard rowBySource[row.source] == nil else {
                return .failure(.duplicateMappingRows(source: row.source))
            }
            rowBySource[row.source] = row
        }

        // The active rows this member can act on.
        let active = mapping.activeRows.filter { childSet.contains($0.source) }
        // Every target must be ONE folder name — the plan's `dst` paths are built by appending
        // it under the member, and the apply's `absolute()` is a bare append with no boundary
        // math, so a separator or a dot traversal in a target aims a rename outside the family
        // (or outside the profile root entirely). The sheet's own vocabulary is clean by
        // construction now, but a hand-imported draft or a refine proposal is not.
        for row in active {
            guard let target = row.target, Self.isValidTargetName(target) else {
                return .failure(.invalidTargetName(target: row.target ?? ""))
            }
        }
        var groups: [String: [String]] = [:]
        for row in active { groups[row.target!, default: []].append(row.source) }

        // Resolve, per target name, whether it stands when its group runs — recursive because
        // "is `Forms` vacated?" depends on whether `Forms` is the chosen *rename* of its own
        // target group, which depends on whether THAT target stands. Memoised, with the path
        // stack doubling as the cycle detector.
        enum Vacancy { case free, vacated(by: String), standing, taken(by: String), fileTaken }
        // The member's FILES, for the occupancy test below — the disk can wear a target's name
        // as a file just as surely as a folder, and `childSet` cannot see it.
        let memberFileSet = Set((view.files(memberPath) ?? []).map { $0.lowercased() })
        var memo: [String: Vacancy] = [:]
        var resolving: [String] = []
        var cycleMembers: Set<String> = []

        func renameChoice(target: String, sources: [String], destExists: Bool) -> String? {
            guard !destExists else { return nil }
            // A source differing from the target only by case must be the rename: while it
            // stands, the volume cannot create the target beside it, and merging it "into" the
            // target would move its files onto themselves. The case-step wins over file count.
            if let caseStep = sources.first(where: {
                $0 != target && $0.lowercased() == target.lowercased()
            }) { return caseStep }
            // The fewest moves that reach the shape: rename the source with the most files.
            return sources.max {
                let a = view.fileCount((memberPath as NSString).appendingPathComponent($0)) ?? 0
                let b = view.fileCount((memberPath as NSString).appendingPathComponent($1)) ?? 0
                // Tie broken lexicographically DESCENDING here so `max` lands on the first name.
                return (a, $1) < (b, $0)
            }
        }

        func vacancy(of name: String) -> Vacancy {
            if let cached = memo[name] { return cached }
            // A case-only rename occupies its own name: `forms → Forms` is one rename-dir on a
            // case-insensitive volume, so the name never blocks its own group.
            guard childSet.contains(name) else {
                // A FILE wearing the name (either case) occupies it as surely as a folder would,
                // and no mapping row can vacate a file — the rename would fail at apply, blamed
                // on drift that never happened. Checked before the folder-twin path because a
                // file can never be the case-step that steps through.
                if memberFileSet.contains(name.lowercased()) {
                    memo[name] = .fileTaken
                    return .fileTaken
                }
                // The exact name is absent, but on a case-insensitive volume a sibling differing
                // only by case occupies it just as surely. The one shape that steps through is
                // the case-step itself — the twin mapped onto this very name, whose single
                // rename occupies and vacates in one action. Everything else (kept, emptied by
                // a merge that leaves the directory, or renamed away on an ordering this
                // resolver does not track across case) is a clash to refuse, not guess through.
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
                // A vacancy cycle — every name in it is mapped onto the next. Mark the ring; the
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
            // `by` is the folder wearing this group's target name (it always is — a name is
            // vacated by the folder that carries it being renamed away). A case-only vacancy
            // (`forms` stepping up to `Forms`) never reaches here: the exact-cased name is not
            // in `childSet`, so it resolves `.free`.
            case .vacated(let by): group.vacatedBy = by
            case .taken(let by):
                return .failure(.targetTakenByCase(target: target, standing: by, member: member))
            case .fileTaken:
                return .failure(.targetTakenByFile(target: target, member: member))
            }
            resolved.append(group)
        }
        if !cycleMembers.isEmpty {
            // A ring is breakable only when every link is a pure rename — one source, no merge.
            let ringGroups = resolved.filter { cycleMembers.contains($0.target) }
            guard ringGroups.allSatisfy({ $0.sources.count == 1 && !$0.destExists }) else {
                return .failure(.unresolvableOrder(member: member))
            }
        }

        // Topological order on vacate-before-fill, stable by target name. A cycle picks its
        // lexicographically first group, renames that group's source to a temporary name up
        // front, and restores it at the end — the two-way swap of §5.4, generalised.
        resolved.sort { $0.target < $1.target }
        var pending = resolved
        var tempFinal: [RestructureManifest.Action] = []
        var vacatedNames: Set<String> = []
        var actions: [RestructureManifest.Action] = []
        // What remains of each DRAINED source — keyed by its path. A standing target that is
        // itself an earlier group's merge source (the drain-before-fill ordering guarantees the
        // drain ran first) must be read as the drain left it, not as the plan-time disk: its
        // files are gone (so no false collisions) and its whole-carried subfolders are gone
        // (so a later arrival with the same name lands whole instead of merging into nothing),
        // while a merged subfolder's SHELL remains and still occupies its name.
        var residues: [String: LandedContents] = [:]

        func emit(_ group: Group) -> PlanRefusal? {
            let targetPath = (memberPath as NSString).appendingPathComponent(group.target)
            let chosen = renameChoice(target: group.target, sources: group.sources,
                                      destExists: group.destExists)
            // The chosen rename is what CREATES the target directory (when it does not stand
            // yet), so it must run before any sibling's merge writes into it — sorted source
            // order put a merge first whenever the biggest source sorted after a sibling, and
            // every one of those moves failed at apply against the absent parent.
            if let chosen {
                let sourcePath = (memberPath as NSString).appendingPathComponent(chosen)
                actions.append(RestructureManifest.Action(
                    action: .renameDir, src: sourcePath, dst: targetPath,
                    evidence: "The mapping names \(chosen)/ as \(group.target)/ in the "
                        + "target shape; the rename is atomic and carries its files.",
                    filesCarried: view.fileCount(sourcePath) ?? 0))
                vacatedNames.insert(chosen)
            }
            // What the target holds as each merge source lands: the standing folder's contents,
            // or — when the chosen rename is what creates the target — the rename's own payload,
            // growing with every landing. Plan-time reads of the target alone were blind to
            // both, so the plan promised whole-folder carries whose destination its own rename
            // had just filled, and every one of them skipped at apply as "appeared since the
            // plan" — the reviewed plan could not land as reviewed.
            let chosenPath = chosen.map { (memberPath as NSString).appendingPathComponent($0) }
            var landed: LandedContents
            if group.destExists {
                landed = residues[targetPath] ?? LandedContents(of: targetPath, in: view)
            } else {
                landed = LandedContents(of: chosenPath, in: view)
            }
            for source in group.sources where source != chosen {
                let sourcePath = (memberPath as NSString).appendingPathComponent(source)
                var residue = LandedContents(of: nil, in: view)
                if let refusal = emitMerge(of: sourcePath, sourceName: source,
                                           into: targetPath, targetName: group.target,
                                           in: view, landed: &landed, residue: &residue,
                                           actions: &actions) {
                    return refusal
                }
                residues[sourcePath] = residue
            }
            return nil
        }

        while !pending.isEmpty {
            if let index = pending.firstIndex(where: { group in
                if let by = group.vacatedBy, !vacatedNames.contains(by) { return false }
                // Drain before fill, the merge half: a standing target that is itself another
                // pending group's SOURCE must be drained before anything merges into it — its
                // outbound moves were listed from the tree at plan time, and files arriving
                // first would trip the apply's own unlisted-veto on the very folder the plan
                // is emptying. (The rename half of this rule is `vacatedBy` above.)
                if group.destExists, pending.contains(where: { other in
                    other.target != group.target && other.sources.contains(group.target)
                }) { return false }
                return true
            }) {
                let group = pending.remove(at: index)
                if let refusal = emit(group) { return .failure(refusal) }
                continue
            }
            // Nothing runnable: the remaining groups form a ring. The temp-name break below is
            // only sound for a PURE-RENAME ring. The resolver pre-validates every ring it
            // detects, and mutual mappings always resolve as rename rings (each mapped-away
            // name vacates), so a non-rename stall is believed unreachable — but the
            // drain-before-fill rule above is a second stall source, and if a shape ever
            // reaches here impure, refusing beats temp-renaming a merge source and stranding
            // its files under a scratch name.
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
            // The ring group's whole emission IS the temp pair — nothing more to derive for it.
        }
        actions.append(contentsOf: tempFinal)

        // Keeps last: they run never, and read best as the plan's signature block.
        for row in mapping.rows where row.target == nil && childSet.contains(row.source) {
            actions.append(RestructureManifest.Action(
                action: .keep,
                src: (memberPath as NSString).appendingPathComponent(row.source),
                evidence: "Mapped to keep — the target shape has no slot for it, and it stays "
                    + "exactly where and as it stands."))
        }
        return .success(actions)
    }

    /// What the merge target holds at the moment a source lands — the plan's own running model
    /// of the destination, so a later source's derivation sees the chosen rename's payload and
    /// every earlier source's landings, not just the plan-time disk.
    private struct LandedContents {
        var files: Set<String>
        /// Occupied subfolder name → the plan-time path whose contents landed under it (the
        /// standing target's own subfolder, the chosen rename's, or an earlier source's carried
        /// folder). Presence is the occupancy test; the path is where a one-level-down merge
        /// reads that occupant's contents from.
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
    }

    /// `LandedContents` one level down — a separate flat type because the merge stops there
    /// (deeper same-name pairs are `keep`), so it needs no origins of its own.
    private struct LandedSubfolder {
        var files: Set<String>
        var subfolders: Set<String>
    }

    /// One source folder merged into the target: `move-file` per file, `move-dir` per subfolder,
    /// one level of same-name subfolder recursion, `keep` beyond that. Never a `move-dir` of the
    /// source onto the target. `landed` is the group's running model of the target — collisions
    /// and occupancy are judged against it, not against the plan-time disk alone. `residue`
    /// accumulates what remains of the SOURCE after the drain (merged subfolders leave shells;
    /// everything else leaves), for a later group whose standing target this source is.
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
            let collision = landed.files.contains(file)
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
            let subTarget = (targetPath as NSString).appendingPathComponent(subfolder)
            let actionsBefore = actions.count
            if let origin = landed.subfolderOrigins[subfolder] {
                // One level down by the same rules (§5.4's collision policy for subfolders),
                // against the occupant's contents wherever they stand at plan time, plus
                // whatever earlier sources already merged into it.
                var sub = landed.merged[subfolder] ?? LandedSubfolder(
                    files: Set(view.files(origin) ?? []),
                    subfolders: Set(view.childFolders(origin) ?? []))
                guard let subFiles = view.files(subSource) else {
                    return .unknownFiles(source: subSource)
                }
                var keptDeeper: Set<String> = []
                for file in subFiles.sorted() {
                    let collision = sub.files.contains(file)
                    actions.append(RestructureManifest.Action(
                        action: .moveFile,
                        src: (subSource as NSString).appendingPathComponent(file),
                        dst: (subTarget as NSString).appendingPathComponent(file),
                        evidence: "Merging \(subfolder)/ into \(subfolder)/ — the mapping "
                            + "sends both names to one folder.",
                        collisionExpected: collision ? true : nil))
                    sub.files.insert(file)
                }
                for deeper in (view.childFolders(subSource) ?? []).sorted() {
                    let deepSource = (subSource as NSString).appendingPathComponent(deeper)
                    if sub.files.contains(deeper) {
                        // A FILE wearing the folder's name on the target side — the carry would
                        // fail at apply against a destination the occupancy sets cannot see.
                        actions.append(RestructureManifest.Action(
                            action: .keep, src: deepSource,
                            evidence: "A file named \(deeper) stands where this folder would "
                                + "land — kept and reported rather than guessed at."))
                        keptDeeper.insert(deeper)
                    } else if !sub.subfolders.contains(deeper) {
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
                // An EMPTY same-name subfolder produces no file moves and no deeper rows, so
                // nothing in the manifest ever names it — and the apply's unlisted-file rule
                // then reads it as an item the plan never listed and vetoes the whole merge.
                // A listed `keep` is the honest record of what happens to it: nothing.
                if actions.count == actionsBefore {
                    actions.append(RestructureManifest.Action(
                        action: .keep, src: subSource,
                        evidence: "Both sides have \(subfolder)/ and this one is empty — there "
                            + "is nothing to move, so it is kept and reported."))
                }
                landed.merged[subfolder] = sub
                // The merge moved this subfolder's files but the DIRECTORY remains — a shell
                // at the source, still occupying its name (a later whole-carry to it would
                // skip at apply), holding only the deeper folders the merge kept.
                residue.subfolderOrigins[subfolder] = subSource
                residue.merged[subfolder] = LandedSubfolder(files: [], subfolders: keptDeeper)
            } else if landed.files.contains(subfolder) {
                // Same rule one level up: a FILE in the target wearing this subfolder's name.
                // `subfolderOrigins` is folder-shaped and cannot see it; without this check the
                // plan promised a whole-carry that always skipped at apply as false drift.
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

    /// A name no child is wearing — deterministic, so the manifest is reproducible.
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

/// The plan's cost, as a pure function of its actions — "8 renames · 12 moved · 92 carried ·
/// 5 kept" is derived, never pasted (§5.4: Fig. 24's numbers predate merges and are not the
/// number).
///
/// The ledger separates what a merge does from what a rename does: *files moved* counts
/// `move-file` rows, *files carried* sums the renames' `filesCarried`, and *folders emptied*
/// counts the distinct source folders the moves drained.
public struct RestructureLedger: Equatable, Sendable {
    public let foldersRenamed: Int
    public let filesCarried: Int
    public let filesMoved: Int
    public let foldersMovedWhole: Int
    public let foldersEmptied: Int
    public let foldersCreated: Int
    public let kept: Int
    public let collisionsKept: Int

    /// The source folders a manifest's moves drained, shallowest only — what the removal step is
    /// scoped to (§5.5: "folders the plan itself emptied"), and the ledger's *folders emptied*.
    /// Whether each is STILL empty is the removal sheet's re-probe, not this function's claim.
    public static func emptiedFolders(of manifest: RestructureManifest) -> [String] {
        var drained: Set<String> = []
        for action in manifest.actions
        where action.action == .moveFile || action.action == .moveDir {
            // A whole-folder relocation empties nothing: its source travels intact and its
            // PARENT — which is what the line below would otherwise record — keeps every other
            // child it had. Reading this off the path made the removal sheet offer `Work/` as a
            // folder the landing emptied, over the sibling that never moved.
            guard action.movesWholeFolder != true, let src = action.src else { continue }
            drained.insert((src as NSString).deletingLastPathComponent)
        }
        return drained.filter { path in
            !drained.contains { other in
                other != path && path.hasPrefix(other + "/")
            }
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
                // A whole-folder relocation carries its files exactly as a rename does, and the
                // ledger dropped them — so the plan that moves the MOST files reported none.
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
        // ONE rule, not a second copy of it. This used to re-derive the drained set inline "so
        // the init stays one pass", and the two then disagreed the moment a whole-folder
        // relocation existed: `emptiedFolders(of:)` learned to exclude it and this did not, so
        // the ledger counted an emptied folder the removal step correctly refused to offer.
        foldersEmptied = Self.emptiedFolders(of: manifest).count
        foldersCreated = created
        self.kept = kept
        collisionsKept = collisions
    }

    /// The one-line reading — counts that are zero stay out of the sentence, except the first
    /// three, which are the plan's size.
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
