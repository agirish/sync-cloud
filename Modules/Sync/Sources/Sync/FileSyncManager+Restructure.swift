import Events
import Foundation

/// The backlog scaffold: the safest Restructure landing, `create-dir` and nothing else, so there
/// is nothing to undo but empty folders. Also the shared landing guards, the per-render disk
/// probes, and *Never suggest this again*.
@MainActor
extension FileSyncManager {

    /// What one scaffold landing did — or why it refused to start.
    public struct ScaffoldOutcome: Equatable, Sendable {
        /// Folders created, as profile-relative paths, in manifest order.
        public var created: [String] = []
        /// Folders the re-probe found already on disk: skipped and reported, never overwritten.
        /// Every claim is re-checked at the moment of the action.
        public var skipped: [String] = []
        /// The guard's sentence when the landing never started; nil when it ran.
        public var refusal: String?

        public init(created: [String] = [], skipped: [String] = [], refusal: String? = nil) {
            self.created = created
            self.skipped = skipped
            self.refusal = refusal
        }
    }

    /// The undo handlers' side of the landing flag. A session ⌘Z/⌘⇧Z group stays live on the
    /// stack while a landing suspends, and a replay fired then would race the landing's own moves
    /// and walks. Registration can't close that window (the group must exist on early returns),
    /// so the handlers check this when they fire and give up their turn. The group is consumed
    /// either way; the ledger's Undo This Reorganization… stays the durable way back, and the
    /// refusal is logged.
    func undoReplayBlockedByLanding(_ actionName: String) -> Bool {
        guard restructureLandingInProgress else { return false }
        Logger.shared.warning("Undo/Redo (\(actionName)) fired while a reorganisation is "
            + "landing — ignored; the ledger's Undo This Reorganization… is the durable way back")
        return true
    }

    /// The guard set shared by every Restructure landing (the scaffold, a plan apply and a ledger
    /// undo), which all move things inside subtrees the scans read: better a refusal than a race.
    /// Returns the sentence, or nil to proceed.
    func restructureLandingRefusal() -> String? {
        restructureLandingBlocker
    }

    /// What would refuse a landing or a ledger undo right now: the sentence, or nil. Read-only, so
    /// a surface can say so before it asks, rather than refusing a Yes the moment it is given.
    public var restructureLandingBlocker: String? {
        // First: the one hazard the counts below can't see. A landing holds this flag across its
        // whole run, including re-derive awaits with no file operation queued and no scan running.
        if restructureLandingInProgress {
            return "Another reorganization is landing right now — wait for it to finish first."
        }
        if isVerifyAllRunning {
            return "Wait for Verify All to finish first."
        }
        for (running, name): (Bool, String) in [
            (duplicateScanLifecycle.isRunning, "the duplicate scan"),
            (storageLensLifecycle.isRunning, "the storage scan"),
            (nameScanLifecycle.isRunning, "the name scan"),
            (filingScanLifecycle.isRunning, "a filing scan"),
            (filingSurveyLifecycle.isRunning, "a folder survey"),
            (automationDryRunLifecycle.isRunning, "an automations preview"),
        ] where running {
            return "Wait for \(name) to finish first."
        }
        if activeFileOperationsCount > 0 {
            return "Wait for the current file operations to finish first."
        }
        if restructureStore == nil {
            return "No profile is loaded, so there is nothing to record the landing against."
        }
        // The ledger is the safety contract: its record, inverse included, must be on disk before
        // the first operation. An unreadable restructure.json would swallow that record, so the
        // landing refuses: better nothing than moves with no trace.
        if restructureStore?.isUnreadable == true {
            return "restructure.json exists but could not be read, so the landing’s record "
                + "could not be kept. Fix the file first — the landing refuses rather than "
                + "running unrecorded."
        }
        guard let profile = filingFolderProfile else { return "No folder survey is loaded." }
        // A profile that doesn't say which folder it describes is refused, not guessed at. A file
        // without `root` decodes as `~`, so checking `root` would act under the home folder:
        // creating and moving there, and re-deriving all of `~`. Refresh and the document survey
        // refuse it too.
        if profile.recordedFolderPath == nil {
            return "The folder survey does not say which folder it describes, so there is no "
                + "telling where this would land. Give folder-profile.json an absolute “root” — "
                + "the landing refuses rather than guessing."
        }
        return nil
    }

    /// Creates the folders a backlog finding's vouched vocabulary expects, as one undoable landing
    /// with a ledger entry. In order: guards, the ledger entry with its inverse on disk, the
    /// creations (each re-probed), one grouped ⌘Z, final counts, one log line.
    ///
    /// It doesn't re-derive the profile, as `applyPlan` does: a fresh walk wouldn't reshape the
    /// finding around empty folders, so the finding stays and the card says the survey hasn't
    /// caught up.
    public func applyScaffold(for finding: StructureFinding, now: Date = Date()) async
        -> ScaffoldOutcome {
        if let refusal = restructureLandingRefusal() {
            return ScaffoldOutcome(refusal: refusal)
        }
        restructureLandingInProgress = true
        defer { restructureLandingInProgress = false }
        guard let store = restructureStore,
              let expandedRoot = filingFolderProfile?.recordedFolderPath else {
            return ScaffoldOutcome(refusal: "No folder survey is loaded.")
        }
        let stamp = FilingProfileStore.stamp(now)
        guard let manifest = RestructureScaffold.manifest(
            for: finding,
            profileId: filingProfileDirectoryId ?? filingFolderProfile?.profileId ?? "unknown",
            manifestId: "scaffold-\(stamp)-\((finding.subject as NSString).lastPathComponent)",
            createdAt: stamp) else {
            return ScaffoldOutcome(refusal: "This family vouches for no shared shape, so there "
                + "is nothing to scaffold — the files go to To File as they are.")
        }

        // A double-click mints the same second-resolution id twice, and two records under one id
        // would leave `updateApplied` finalising the wrong one. Lands once, as in applyPlan.
        guard !store.applied.contains(where: { $0.manifest.manifestId == manifest.manifestId })
        else {
            return ScaffoldOutcome(refusal: "This scaffold just landed (\(manifest.manifestId)) "
                + "— it runs once.")
        }

        // The record, inverse included, is on disk before the first operation, so a crash
        // mid-run leaves a reversible trace. A failed write refuses: never land unrecorded.
        guard store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: stamp, created: 0, skipped: 0))
        else {
            return ScaffoldOutcome(refusal: "The ledger could not be written, so nothing was "
                + "created — a scaffold only runs once its record is safely on disk.")
        }

        let fm = fileManager
        let targets = manifest.actions.compactMap(\.dst)
        let outcome: ScaffoldOutcome = await enqueueFileOperation {
            var out = ScaffoldOutcome()
            for relative in targets {
                let absolute = (expandedRoot as NSString).appendingPathComponent(relative)
                // Re-probe at the moment of the action: a folder that appeared since the plan is
                // skipped and reported, and the rest still lands.
                if fm.fileExists(atPath: absolute) {
                    out.skipped.append(relative)
                    continue
                }
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: absolute),
                                           withIntermediateDirectories: false, attributes: nil)
                    out.created.append(relative)
                } catch {
                    Logger.shared.error("Scaffold: could not create \(absolute): "
                                        + error.localizedDescription)
                    out.skipped.append(relative)
                }
            }
            return out
        }

        // One grouped ⌘Z for the whole landing, registered synchronously: no await may sit
        // between begin and end.
        if !outcome.created.isEmpty, let undo = undoManager {
            undo.beginUndoGrouping()
            for relative in outcome.created {
                let absolute = (expandedRoot as NSString).appendingPathComponent(relative)
                registerCreateFolderUndo(url: URL(fileURLWithPath: absolute), fileManager: fm)
            }
            undo.endUndoGrouping()
            undo.setActionName("Set Up \((finding.subject as NSString).lastPathComponent)")
        }

        // Finalise the ledger entry with what actually happened.
        store.updateApplied(manifestId: manifest.manifestId) {
            $0.created = outcome.created.count
            $0.skipped = outcome.skipped.count
        }

        // One log line, found later by grepping the manifest id.
        Logger.shared.info("Scaffold \(manifest.manifestId): \(finding.subject) — "
            + "\(outcome.created.count) folder(s) created, \(outcome.skipped.count) skipped")
        return outcome
    }

    // MARK: - The trend (proposal O16)

    /// Stamps the current survey's finding counts into the store, if it hasn't recorded this
    /// profile yet. Called when a profile is attached and when a landing derives one, never from
    /// a view body, where it would put a disk write behind every render.
    ///
    /// The store's dedupe (one point per `profileId`) is the real guard, so a second call for one
    /// profile is harmless; two unrelated places observe "the profile changed".
    public func stampStructureTrend(landing: Bool = false, now: Date = Date()) {
        guard let store = restructureStore, filingFolderProfile != nil else { return }
        let id = filingProfileDirectoryId ?? filingFolderProfile?.profileId ?? ""
        guard !id.isEmpty else { return }
        // Dedupe before counting: `structureFindings` runs the whole detector sweep on the main
        // actor (about 325 ms on 3,000 folders), and the launch call runs before the window
        // appears. A landing re-stamps an existing profile to upgrade its point, so it is exempt.
        if !landing, store.trend.contains(where: { $0.profileId == id }) { return }
        var counts: [String: Int] = [:]
        // Every finding, not `visibleStructureFindings`: hiding a card must not make the tree's
        // trend look better.
        for finding in structureFindings {
            counts[finding.kind.rawValue, default: 0] += 1
        }
        store.recordTrend(RestructureStore.TrendPoint(
            at: FilingProfileStore.stamp(now), profileId: id, countsByKind: counts,
            landing: landing))
    }

    /// Subjects whose scaffold landed and still stands: the one answer every surface reads. A
    /// record whose folders are all gone (a ⌘Z, or a hand-tidy) drops back to offering the
    /// scaffold; one that partly stands keeps the claim, since re-offering would re-create
    /// folders beside survivors.
    ///
    /// Asks the disk, not the ledger: a scaffold record's `undoneAt` is never set
    /// (`applyScaffold` records no `appliedUnderProfileId`), so the ledger can't tell.
    public func scaffoldedSubjects(now: Date = Date()) -> Set<String> {
        guard let root = filingFolderProfile?.root else { return [] }
        let applied = restructureStore?.applied ?? []
        let key = RestructureDiskProbeMemo.Key(
            owner: ObjectIdentifier(self), root: root,
            ledger: RestructureDiskProbeMemo.signature(of: applied))
        if let hit = RestructureDiskProbeMemo.scaffolded.value(for: key, now: now) { return hit }
        let expandedRoot = (root as NSString).expandingTildeInPath
        var subjects: Set<String> = []
        for record in applied where record.manifest.kind == .backlog {
            let created = record.manifest.actions.compactMap(\.dst)
            guard let first = created.first else { continue }
            let anyStanding = created.contains { relative in
                fileManager.fileExists(
                    atPath: (expandedRoot as NSString).appendingPathComponent(relative))
            }
            if anyStanding {
                subjects.insert((first as NSString).deletingLastPathComponent)
            }
        }
        RestructureDiskProbeMemo.scaffolded.store(subjects, for: key, now: now)
        return subjects
    }

    /// Whether any folder this landing emptied still stands on disk: the removal button's licence,
    /// and the ledger cards' `hasEmptiedFolders`. A disk probe, since `emptiedFolders(of:)` reads
    /// only the manifest and the button would outlive its landing. A view body runs it once per
    /// record per render, so it lives here beside the shared cache.
    public func emptiedFoldersStillStanding(of manifest: RestructureManifest,
                                            now: Date = Date()) -> Bool {
        guard let root = filingFolderProfile?.root else { return false }
        let key = RestructureDiskProbeMemo.Key(
            owner: ObjectIdentifier(self), root: root,
            ledger: RestructureDiskProbeMemo.signature(of: restructureStore?.applied ?? []))
        if let hit = RestructureDiskProbeMemo.standingEmpties.value(
            for: key, id: manifest.manifestId, now: now) {
            return hit
        }
        let expanded = (root as NSString).expandingTildeInPath
        let standing = RestructureLedger.emptiedFolders(of: manifest).contains { path in
            fileManager.fileExists(atPath: (expanded as NSString).appendingPathComponent(path))
        }
        RestructureDiskProbeMemo.standingEmpties.store(standing, for: key,
                                                       id: manifest.manifestId, now: now)
        return standing
    }
}

/// The one-entry caches in front of Restructure's two per-render disk probes,
/// `scaffoldedSubjects` and `emptiedFoldersStillStanding`. Only the disk can answer them, and a
/// SwiftUI `body` calls them on every publish, several times per render.
///
/// The ledger signature drops an entry at once on any change made through the store. Disk
/// changes can't be keyed, so entries also expire after ``window``: a ⌘Z that removes scaffolded
/// folders corrects the card within that window, not instantly.
///
/// Keyed on the manager's identity too, so one test's manager is never served another's answer.
/// One entry, not a map: a map keyed on object identity would outlive its objects.
@MainActor
enum RestructureDiskProbeMemo {

    /// How long a probe's answer is served before the disk is asked again: short enough that a ⌘Z
    /// shows by the next render a person notices, long enough that a burst of renders (a hover, a
    /// scroll, a resize) costs one probe.
    static let window: TimeInterval = 0.5

    struct Key: Equatable {
        let owner: ObjectIdentifier
        let root: String
        /// What the ledger looks like, or which manifest is being asked about.
        let ledger: String
    }

    /// The applied ledger reduced to what these probes read: which records exist, their action
    /// counts and undo state. One cheap pass, and it changes whenever anything they read does.
    static func signature(of applied: [RestructureStore.AppliedRecord]) -> String {
        applied.map { "\($0.manifest.manifestId):\($0.manifest.actions.count):"
            + "\($0.undoneAt ?? "-")" }.joined(separator: "|")
    }

    /// One remembered answer, valid while the key holds and the window hasn't run out. A clock
    /// gone backwards (a manual change, an NTP step) invalidates rather than serving forever.
    @MainActor
    final class Entry<Value> {
        private var key: Key?
        private var value: Value?
        private var at: Date?

        func value(for key: Key, now: Date) -> Value? {
            guard let stored = value, self.key == key, let at,
                  now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < window
            else { return nil }
            return stored
        }

        func store(_ value: Value, for key: Key, now: Date) {
            self.key = key
            self.value = value
            self.at = now
        }

        /// Drops whatever is held, so tests start from a known state.
        func clear() {
            key = nil
            value = nil
            at = nil
        }
    }

    /// The same, for a probe asked about many subjects under one key: the ledger cards ask once
    /// per record in one render, which would evict a one-slot cache every time. The map drops
    /// whole when the key changes or the window runs out, since all were probed on one tree.
    @MainActor
    final class MapEntry<Value> {
        private var key: Key?
        private var values: [String: Value] = [:]
        private var at: Date?

        private func isLive(_ key: Key, _ now: Date) -> Bool {
            guard self.key == key, let at else { return false }
            let age = now.timeIntervalSince(at)
            return age >= 0 && age < window
        }

        func value(for key: Key, id: String, now: Date) -> Value? {
            guard isLive(key, now) else { return nil }
            return values[id]
        }

        func store(_ value: Value, for key: Key, id: String, now: Date) {
            if !isLive(key, now) {
                self.key = key
                self.at = now
                values.removeAll(keepingCapacity: true)
            }
            values[id] = value
        }

        func clear() {
            key = nil
            values.removeAll()
            at = nil
        }
    }

    static let scaffolded = Entry<Set<String>>()
    static let standingEmpties = MapEntry<Bool>()
}

// MARK: - Never suggest this again

@MainActor
extension FileSyncManager {

    /// *Never suggest this again*, with a way back, so a mis-click can't hide a finding for good:
    /// one ⌘Z step and an undoable banner, and the lens's *Show them again*
    /// (``showHiddenStructureFindings(in:)``) for older ones.
    public func suppressStructureFinding(_ finding: StructureFinding) {
        guard let store = restructureStore else { return }
        let key = RestructureKey(finding)
        guard !store.isSuppressed(key) else { return }
        store.suppress(key)
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.unsuppressStructureFinding(finding, in: store)
        }
        undoManager?.setActionName("Never Suggest This Again")
        banner = .success("Hidden — Restructure won’t suggest this again.",
                          undoable: undoManager != nil)
    }

    /// ⌘Z for ``suppressStructureFinding(_:)``: in the store it was hidden in, and in the current
    /// store only when that one carries on from it. A landing or survey refresh swaps in a store
    /// that carries the hidden set across, so the key is cleared there too, moved through the same
    /// renames (``RestructureStore/carriedKey(_:from:)``).
    ///
    /// Never just whatever store is current: after a provider switch it is another profile's,
    /// where the same key is a different folder's finding. A store reopened on the same file
    /// replaces the captured one outright, so only the current one writes.
    func unsuppressStructureFinding(_ finding: StructureFinding, in store: RestructureStore) {
        let key = RestructureKey(finding)
        if let current = restructureStore, current !== store, current.isSameFile(as: store) {
            current.unsuppress(key)
        } else {
            // The captured object writes only while the app still reads it. Swapped out, it is a
            // stale snapshot, and `save` writes the whole store, which would erase a landing
            // recorded since into the same file. So its file is read afresh and one key cleared.
            if restructureStore === store {
                store.unsuppress(key)
            } else {
                RestructureStore(directory: store.directory, profileId: store.profileId)
                    .unsuppress(key)
            }
            if let current = restructureStore, current !== store,
               let carried = current.carriedKey(key, from: store) {
                current.unsuppress(carried)
            }
        }
        // The "Hidden … [Undo]" banner is stale once this runs (`invalidateUndoableBanner`).
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.suppressStructureFinding(finding)
        }
        undoManager?.setActionName("Never Suggest This Again")
    }
}

@MainActor
extension FileSyncManager {
    /// Today's findings *Never suggest this again* is hiding within `scope`: what the lens's
    /// *Show them again* counts and brings back. Scoped as the lens's rows are (inside the scope,
    /// or about an ancestor of it), so it never clears findings in other folders or stale keys.
    /// Drawn from the same findings as ``visibleStructureFindings``, duplicated taxonomy included,
    /// so every hidden finding has a way back.
    public func hiddenStructureFindings(in scope: OrganizeScope?) -> [StructureFinding] {
        guard let store = restructureStore, !store.suppressed.isEmpty else { return [] }
        let root = filingFolderProfile?.root ?? ""
        return StructureDetectors.grouped(structureFindings + duplicatedTaxonomyFindings).filter {
            store.isSuppressed(RestructureKey($0))
                && OrganizeScopeFilter.relation(of: $0, profileRoot: root, scope: scope) != .outside
        }
    }

    /// *Show them again*: brings back exactly the hidden findings in `scope`, says how many in a
    /// banner, and returns the count. Out-of-scope and stale keys stay hidden.
    @discardableResult
    public func showHiddenStructureFindings(in scope: OrganizeScope?) -> Int {
        let hidden = hiddenStructureFindings(in: scope)
        guard let store = restructureStore, !hidden.isEmpty else { return 0 }
        store.unsuppress(Set(hidden.map { RestructureKey($0) }))
        banner = .success(Self.shownAgainSentence(hidden.count))
        return hidden.count
    }

    nonisolated static func shownAgainSentence(_ count: Int) -> String {
        count == 1 ? "1 hidden finding is back."
            : "\(count.formatted()) hidden findings are back."
    }
}
