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
    /// destination → one grouped ⌘Z → finalised counts → one log line. What it does NOT do yet
    /// is step 6 (re-derive the profile): that machinery is §5.5's, so until it lands the
    /// finding stays visible and the card says the survey has not caught up — §5.7's third
    /// sentence, not a borrowed one.
    public func applyScaffold(for finding: StructureFinding, now: Date = Date()) async
        -> ScaffoldOutcome {
        // §5.5 step 1, all three guards — this moves nothing, but it creates folders inside a
        // subtree those passes may be reading, and a refusal is a sentence while a race is a
        // debugging session.
        if isVerifyAllRunning {
            return ScaffoldOutcome(refusal: "Wait for Verify All to finish first.")
        }
        for (running, name): (Bool, String) in [
            (duplicateScanLifecycle.isRunning, "the duplicate scan"),
            (storageLensLifecycle.isRunning, "the storage scan"),
            (nameScanLifecycle.isRunning, "the name scan"),
            (filingScanLifecycle.isRunning, "a filing scan"),
            (filingSurveyLifecycle.isRunning, "a folder survey"),
            (automationDryRunLifecycle.isRunning, "an automations preview"),
        ] where running {
            return ScaffoldOutcome(refusal: "Wait for \(name) to finish first.")
        }
        if activeFileOperationsCount > 0 {
            return ScaffoldOutcome(refusal: "Wait for the current file operations to finish first.")
        }
        guard let store = restructureStore else {
            return ScaffoldOutcome(refusal: "No profile is loaded, so there is nothing to record "
                + "the landing against.")
        }
        // The ledger IS the safety contract: its record, inverse included, must be on disk
        // before the first operation. A store that cannot write (restructure.json exists but is
        // unreadable) would swallow that record silently, so the landing refuses for the same
        // reason the store refuses — better no folders than folders with no trace.
        guard !store.isUnreadable else {
            return ScaffoldOutcome(refusal: "restructure.json exists but could not be read, so "
                + "the landing's record could not be kept. Fix the file first — the landing "
                + "refuses rather than running unrecorded.")
        }
        guard let root = filingFolderProfile?.root else {
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

        // §5.5 step 2: the record, inverse included, is on disk BEFORE the first operation —
        // a crash mid-run leaves a reversible trace, not a mystery.
        store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: stamp, created: 0, skipped: 0))

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
}
