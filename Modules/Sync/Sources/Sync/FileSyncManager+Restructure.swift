import Events
import Foundation

/// §5.2's backlog scaffold — the first Restructure landing, and deliberately the safest possible
/// one: `create-dir` and nothing else, no file moves, nothing to undo but empty folders. It
/// exists to prove the manifest, the ledger and ⌘Z on a real tree before anything destructive
/// does (ROADMAP_V5, Order item 2).
@MainActor
extension FileSyncManager {

    /// What one scaffold landing did — or why it refused to start.
    public struct ScaffoldOutcome: Equatable, Sendable {
        /// Folders created, as profile-relative paths, in manifest order.
        public var created: [String] = []
        /// Folders the re-probe found already on disk — skipped and reported, never overwritten
        /// (invariant 5: every claim re-derived at the moment of the action).
        public var skipped: [String] = []
        /// The guard's sentence when the landing never started; nil when it ran.
        public var refusal: String?

        public init(created: [String] = [], skipped: [String] = [], refusal: String? = nil) {
            self.created = created
            self.skipped = skipped
            self.refusal = refusal
        }
    }

    /// Creates the folders a backlog finding's vouched vocabulary expects, as one undoable
    /// landing with a ledger entry.
    ///
    /// The order inside is §5.5's, cut down to what a non-destructive landing needs:
    /// guards → ledger entry with the inverse on disk → the operations, re-probing each
    /// destination → one grouped ⌘Z → finalised counts → one log line. What it deliberately
    /// does NOT do is step 6 (re-derive the profile): `applyPlan` has that machinery now, but
    /// a scaffold creates empty folders a fresh walk would not re-shape the finding around, so
    /// the finding stays visible and the card says the survey has not caught up — §5.7's third
    /// sentence, not a borrowed one.
    /// §5.5 step 1's guard set, shared by every Restructure landing — the scaffold, a plan apply
    /// The undo handlers' side of the landing flag: a session ⌘Z/⌘⇧Z group stays LIVE on the
    /// stack while a landing suspends (apply arms its group at step 5, then awaits through the
    /// re-derive; the ledger inverse runs under groups armed by the landing it reverses), and a
    /// replay fired into that window races the landing's own moves and walks. The registration
    /// sites cannot close the window — the group must exist on the early-return paths — so the
    /// HANDLERS consult this at fire time and give up their turn. The group is consumed either
    /// way; the ledger's Undo This Reorganisation remains the durable way back, and the refusal
    /// is logged rather than silent.
    func undoReplayBlockedByLanding(_ actionName: String) -> Bool {
        guard restructureLandingInProgress else { return false }
        Logger.shared.warning("Undo/Redo (\(actionName)) fired while a reorganisation is "
            + "landing — ignored; the ledger's Undo This Reorganisation is the durable way back")
        return true
    }

    /// and a ledger undo all move things inside subtrees the scans read, and a refusal is a
    /// sentence while a race is a debugging session. Returns the sentence, or nil to proceed.
    func restructureLandingRefusal() -> String? {
        // First, because it is the one hazard the counts below cannot see: a landing holds this
        // flag across its whole run, including the re-derive awaits where no file operation is
        // queued and no scan is running.
        if restructureLandingInProgress {
            return "Another reorganisation is landing right now — wait for it to finish first."
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
        // The ledger IS the safety contract: its record, inverse included, must be on disk
        // before the first operation. A store that cannot write (restructure.json exists but is
        // unreadable) would swallow that record silently, so the landing refuses for the same
        // reason the store refuses — better nothing than moves with no trace.
        if restructureStore?.isUnreadable == true {
            return "restructure.json exists but could not be read, so the landing's record "
                + "could not be kept. Fix the file first — the landing refuses rather than "
                + "running unrecorded."
        }
        if filingFolderProfile?.root == nil {
            return "No folder survey is loaded."
        }
        return nil
    }

    public func applyScaffold(for finding: StructureFinding, now: Date = Date()) async
        -> ScaffoldOutcome {
        if let refusal = restructureLandingRefusal() {
            return ScaffoldOutcome(refusal: refusal)
        }
        restructureLandingInProgress = true
        defer { restructureLandingInProgress = false }
        guard let store = restructureStore, let root = filingFolderProfile?.root else {
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

        // A double-click mints the same second-resolution id twice, and two records under one
        // id leave `updateApplied` finalising the wrong one — the same landing-once rule as
        // applyPlan, refused with the same shape of sentence.
        guard !store.applied.contains(where: { $0.manifest.manifestId == manifest.manifestId })
        else {
            return ScaffoldOutcome(refusal: "This scaffold just landed (\(manifest.manifestId)) "
                + "— it runs once.")
        }

        // §5.5 step 2: the record, inverse included, is on disk BEFORE the first operation —
        // a crash mid-run leaves a reversible trace, not a mystery. Verified: a swallowed write
        // failure would land folders whose only record dies with the session.
        guard store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: stamp, created: 0, skipped: 0))
        else {
            return ScaffoldOutcome(refusal: "The ledger could not be written, so nothing was "
                + "created — a scaffold only runs once its record is safely on disk.")
        }

        let expandedRoot = (root as NSString).expandingTildeInPath
        let fm = fileManager
        let targets = manifest.actions.compactMap(\.dst)
        let outcome: ScaffoldOutcome = await enqueueFileOperation {
            var out = ScaffoldOutcome()
            for relative in targets {
                let absolute = (expandedRoot as NSString).appendingPathComponent(relative)
                // Re-probe at the moment of the action: a folder that has appeared since the
                // plan is skipped and reported, and the rest still lands (invariants 2 and 5).
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

        // One grouped ⌘Z for the whole landing, registered synchronously — no await may sit
        // between begin and end (the Duplicates rule), and none does: the creations above are
        // already on disk.
        if !outcome.created.isEmpty, let undo = undoManager {
            undo.beginUndoGrouping()
            for relative in outcome.created {
                let absolute = (expandedRoot as NSString).appendingPathComponent(relative)
                registerCreateFolderUndo(url: URL(fileURLWithPath: absolute))
            }
            undo.endUndoGrouping()
            undo.setActionName("Set Up \((finding.subject as NSString).lastPathComponent)")
        }

        // Finalise the ledger entry with what actually happened.
        store.updateApplied(manifestId: manifest.manifestId) {
            $0.created = outcome.created.count
            $0.skipped = outcome.skipped.count
        }

        // §5.5 step 8's log line — the truth of an apply gets found later by grepping the id.
        Logger.shared.info("Scaffold \(manifest.manifestId): \(finding.subject) — "
            + "\(outcome.created.count) folder(s) created, \(outcome.skipped.count) skipped")
        return outcome
    }

    // MARK: - The trend (proposal O16)

    /// Stamp the current survey's finding counts into the store, if it has not already recorded
    /// this profile.
    ///
    /// **Called at the two moments the survey can actually change** — when a profile is attached
    /// (launch, a fresh walk) and when a landing produces a derived one — never from a view body.
    /// `structureReport` is a cached pure function of the profile that Organize's overview reads
    /// on every render; stamping there would put a disk write behind a scroll, and would record
    /// the same survey once per memo drop.
    ///
    /// The store's own dedupe is the real guard (one point per `profileId`), so calling this
    /// twice for one profile is harmless — which matters, because "the profile changed" is
    /// observed in two places that do not know about each other.
    public func stampStructureTrend(landing: Bool = false, now: Date = Date()) {
        guard let store = restructureStore, filingFolderProfile != nil else { return }
        let id = filingProfileDirectoryId ?? filingFolderProfile?.profileId ?? ""
        guard !id.isEmpty else { return }
        // **The dedupe check BEFORE the counting, and this is not a micro-optimisation.**
        // Reading `structureFindings` runs the whole detector sweep — measured at 325 ms over
        // the reference profile's 3,013 folders, on the main actor. The launch call site sits in
        // `FilingArtifacts.attach`, before the window appears, and the store already holds a
        // point for a profile that has not changed since last launch — so counting first paid
        // a third of a second of launch latency on every launch to discover there was nothing
        // to record. A landing is the one case that legitimately re-stamps an existing profile,
        // to upgrade its point's cause, so it is exempt.
        if !landing, store.trend.contains(where: { $0.profileId == id }) { return }
        var counts: [String: Int] = [:]
        // Every finding the detectors produced, NOT `visibleStructureFindings`: a suppression is
        // a statement about what to show, and a trend that fell when the user hid a card would
        // answer "is the tree getting better?" with "did you look away?".
        for finding in structureFindings {
            counts[finding.kind.rawValue, default: 0] += 1
        }
        store.recordTrend(RestructureStore.TrendPoint(
            at: FilingProfileStore.stamp(now), profileId: id, countsByKind: counts,
            landing: landing))
    }

    /// Subjects whose scaffold landed **and still stands** — the one answer every surface reads.
    ///
    /// A record whose created folders are all gone (a ⌘Z, or a hand-tidy) no longer supports the
    /// "Scaffolded" claim, and the subject drops back to offering the scaffold; one that partially
    /// stands keeps it, because re-offering would re-create the survivors' siblings around folders
    /// that still exist.
    ///
    /// **Here rather than in the workspace, because there were two copies.** The Organize menu had
    /// its own ledger-only version filtered on `undoneAt` — and a scaffold record's `undoneAt` is
    /// never set, since `applyScaffold` records no `appliedUnderProfileId` and the ledger undo
    /// refuses a record without one. So that filter was inert and the two disagreed after a ⌘Z:
    /// the card correctly re-offered the scaffold while the menu item stayed greyed. The disk is
    /// the only thing that knows, so the disk is what both ask.
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

    /// Whether any folder this landing emptied **still stands on disk** — the removal button's
    /// licence, and the ledger cards' `hasEmptiedFolders`.
    ///
    /// Here rather than in the workspace for the reason ``scaffoldedSubjects(now:)`` gives: it is
    /// a disk probe that a view body runs, once per applied record per render, and it belongs
    /// where the caching can be shared. `emptiedFolders(of:)` is a pure function of the manifest,
    /// so on its own the button would outlive its own landing forever.
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

/// **The one-entry caches in front of Restructure's two per-render disk probes.**
///
/// `scaffoldedSubjects` and `emptiedFoldersStillStanding` both answer a question only the disk can
/// answer — a ⌘Z or a hand-tidy removes folders without touching the ledger, which is exactly why
/// they probe rather than read the manifest — and both are called from a SwiftUI `body`, which
/// re-runs on every publish this manager makes. The lens asked once, the overview asked again, and
/// the ledger cards asked once per applied record, all for a tree that had not moved.
///
/// **Two keys, and they answer different halves of "could this have changed".** The ledger
/// signature catches every change the app makes through the store — a landing, an undo record, a
/// re-derive's rekey — and drops the entry at once. The DISK half cannot be keyed on anything, so
/// it is bounded by time instead: an entry older than ``window`` is not served. A ⌘Z that removes
/// scaffolded folders therefore corrects the card on the first render after that window rather
/// than instantly. That is the deliberate trade, and it is a different thing from the defect the
/// probe exists to prevent, which was a card that stayed wrong **forever** because it read the
/// ledger instead of the disk.
///
/// Keyed on the manager's identity as well, so a second `FileSyncManager` (every test that builds
/// one) can never be served another's answer. One entry, not a dictionary: there is one manager in
/// the app, and an unbounded map keyed on object identity would outlive the objects in it.
@MainActor
enum RestructureDiskProbeMemo {

    /// How long a probe's answer is served before the disk is asked again.
    ///
    /// Short enough that a hand-tidy or a ⌘Z is reflected in the next render a person could
    /// notice, long enough that a burst of renders — a hover, a scroll, a window resize, any of
    /// the publishes this manager makes per second — costs one probe rather than dozens.
    static let window: TimeInterval = 0.5

    struct Key: Equatable {
        let owner: ObjectIdentifier
        let root: String
        /// What the ledger looks like, or which manifest is being asked about.
        let ledger: String
    }

    /// The applied ledger reduced to the things these probes read: which records exist, and what
    /// each one claims to have created or emptied. Cheap to build (one pass over the records'
    /// ids and counts) and it changes whenever anything the probes care about does.
    static func signature(of applied: [RestructureStore.AppliedRecord]) -> String {
        applied.map { "\($0.manifest.manifestId):\($0.manifest.actions.count):"
            + "\($0.undoneAt ?? "-")" }.joined(separator: "|")
    }

    /// One remembered answer, valid while the key holds and the window has not run out.
    ///
    /// A clock that has gone BACKWARDS (a manual time change, an NTP step) invalidates rather
    /// than serving forever: `now < at` is not a fresh entry, it is an unknown one.
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

        /// Drops whatever is held — the seam the tests use to start from a known state.
        func clear() {
            key = nil
            value = nil
            at = nil
        }
    }

    /// The same, for a probe asked about MANY subjects under one key.
    ///
    /// The ledger cards ask `emptiedFoldersStillStanding` once per applied record inside a single
    /// render, so a one-slot cache would be evicted by the next record and never hit. The map is
    /// dropped whole the moment the key changes or the window runs out — one lifetime for every
    /// entry in it, because they were all probed against the same tree.
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
