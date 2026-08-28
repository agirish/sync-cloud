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
        /// A vacancy cycle runs through a multi-source group — a mapping this contorted needs a
        /// person, not a heuristic.
        case unresolvableOrder(member: String)
        /// Two distinct target names collide case-insensitively (`Forms` and `forms`) — on the
        /// case-insensitive volumes this app runs against, both cannot exist side by side, and
        /// deriving operations toward them would fail at apply in a shape the plan promised away.
        case conflictingTargets(String, String)
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
    public static func manifest(family: String, members: [String],
                                mapping: RestructureMapping, kind: FindingKind,
                                in view: RestructureTreeView,
                                profileId: String, manifestId: String, createdAt: String,
                                note: String? = nil)
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
            family: family, kind: kind, note: note, mapping: mapping.rows, actions: actions))
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
        let rowBySource = Dictionary(uniqueKeysWithValues: mapping.rows.map { ($0.source, $0) })

        // The active rows this member can act on.
        let active = mapping.activeRows.filter { childSet.contains($0.source) }
        var groups: [String: [String]] = [:]
        for row in active { groups[row.target!, default: []].append(row.source) }

        // Resolve, per target name, whether it stands when its group runs — recursive because
        // "is `Forms` vacated?" depends on whether `Forms` is the chosen *rename* of its own
        // target group, which depends on whether THAT target stands. Memoised, with the path
        // stack doubling as the cycle detector.
        enum Vacancy { case free, vacated(by: String), standing }
        var memo: [String: Vacancy] = [:]
        var resolving: [String] = []
        var cycleMembers: Set<String> = []

        func renameChoice(target: String, sources: [String], destExists: Bool) -> String? {
            guard !destExists else { return nil }
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
            guard childSet.contains(name) else { return .free }
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
            case .standing: destExists = true
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

        func emit(_ group: Group) -> PlanRefusal? {
            let targetPath = (memberPath as NSString).appendingPathComponent(group.target)
            let chosen = renameChoice(target: group.target, sources: group.sources,
                                      destExists: group.destExists)
            for source in group.sources {
                let sourcePath = (memberPath as NSString).appendingPathComponent(source)
                if source == chosen {
                    actions.append(RestructureManifest.Action(
                        action: .renameDir, src: sourcePath, dst: targetPath,
                        evidence: "The mapping names \(source)/ as \(group.target)/ in the "
                            + "target shape; the rename is atomic and carries its files.",
                        filesCarried: view.fileCount(sourcePath) ?? 0))
                    vacatedNames.insert(source)
                } else {
                    if let refusal = emitMerge(of: sourcePath, sourceName: source,
                                               into: targetPath, targetName: group.target,
                                               in: view, actions: &actions) {
                        return refusal
                    }
                }
            }
            return nil
        }

        while !pending.isEmpty {
            if let index = pending.firstIndex(where: { group in
                guard let by = group.vacatedBy else { return true }
                return vacatedNames.contains(by)
            }) {
                let group = pending.remove(at: index)
                if let refusal = emit(group) { return .failure(refusal) }
                continue
            }
            // Nothing runnable: the remaining groups form a ring. Break it at the first one.
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

    /// One source folder merged into the target: `move-file` per file, `move-dir` per subfolder,
    /// one level of same-name subfolder recursion, `keep` beyond that. Never a `move-dir` of the
    /// source onto the target.
    private static func emitMerge(of sourcePath: String, sourceName: String,
                                  into targetPath: String, targetName: String,
                                  in view: RestructureTreeView,
                                  actions: inout [RestructureManifest.Action],
                                  depth: Int = 0) -> PlanRefusal? {
        guard let files = view.files(sourcePath) else {
            return .unknownFiles(source: sourcePath)
        }
        let targetFiles = view.files(targetPath).map(Set.init)
        for file in files.sorted() {
            let collision = targetFiles?.contains(file) == true
            actions.append(RestructureManifest.Action(
                action: .moveFile,
                src: (sourcePath as NSString).appendingPathComponent(file),
                dst: (targetPath as NSString).appendingPathComponent(file),
                evidence: "Merging \(sourceName)/ into \(targetName)/ — the mapping sends both "
                    + "names to one folder.",
                collisionExpected: collision ? true : nil))
        }
        let targetSubfolders = Set(view.childFolders(targetPath) ?? [])
        for subfolder in (view.childFolders(sourcePath) ?? []).sorted() {
            let subSource = (sourcePath as NSString).appendingPathComponent(subfolder)
            let subTarget = (targetPath as NSString).appendingPathComponent(subfolder)
            if !targetSubfolders.contains(subfolder) {
                actions.append(RestructureManifest.Action(
                    action: .moveDir, src: subSource, dst: subTarget,
                    evidence: "Carried whole into \(targetName)/ — the target has no "
                        + "\(subfolder)/ of its own."))
            } else if depth == 0 {
                // One level down by the same rules (§5.4's collision policy for subfolders).
                if let refusal = emitMerge(of: subSource, sourceName: subfolder,
                                           into: subTarget, targetName: subfolder,
                                           in: view, actions: &actions, depth: 1) {
                    return refusal
                }
            } else {
                actions.append(RestructureManifest.Action(
                    action: .keep, src: subSource,
                    evidence: "Both sides have \(subfolder)/ two levels down — deeper than the "
                        + "merge reaches, so it is kept and reported rather than guessed at."))
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

    public init(of manifest: RestructureManifest) {
        var renames = 0, carried = 0, moved = 0, movedWhole = 0, created = 0, kept = 0
        var collisions = 0
        var drained: Set<String> = []
        for action in manifest.actions {
            switch action.action {
            case .renameDir:
                renames += 1
                carried += action.filesCarried ?? 0
            case .moveFile:
                moved += 1
                if let src = action.src {
                    drained.insert((src as NSString).deletingLastPathComponent)
                }
                if action.collisionExpected == true || action.collidedInto != nil {
                    collisions += 1
                }
            case .moveDir:
                movedWhole += 1
                if let src = action.src {
                    drained.insert((src as NSString).deletingLastPathComponent)
                }
            case .createDir: created += 1
            case .keep: kept += 1
            case .removeEmptyDir: break
            }
        }
        // A one-level-down merge drains `s/d`, which sits inside the drained `s` — count the
        // shallowest only, because "folders emptied" answers how many mapping sources were.
        let shallow = drained.filter { path in
            !drained.contains { other in
                other != path && path.hasPrefix(other + "/")
            }
        }
        foldersRenamed = renames
        filesCarried = carried
        filesMoved = moved
        foldersMovedWhole = movedWhole
        foldersEmptied = shallow.count
        foldersCreated = created
        self.kept = kept
        collisionsKept = collisions
    }

    /// The one-line reading — counts that are zero stay out of the sentence, except the first
    /// pair, which is the plan's size.
    public var summary: String {
        var parts = [
            "\(foldersRenamed) rename\(foldersRenamed == 1 ? "" : "s")",
            "\(filesMoved) moved",
            "\(filesCarried) carried",
        ]
        if foldersMovedWhole > 0 { parts.append("\(foldersMovedWhole) folders carried whole") }
        if kept > 0 { parts.append("\(kept) kept") }
        if foldersCreated > 0 { parts.append("\(foldersCreated) created") }
        if collisionsKept > 0 {
            parts.append("\(collisionsKept) name collision\(collisionsKept == 1 ? "" : "s"), both kept")
        }
        return parts.joined(separator: " · ")
    }
}
