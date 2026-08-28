import Foundation
import Testing
@testable import Sync

/// The apply engine's own safety machinery, exercised in the direction that matters: the
/// verifier must FIND a seeded mismatch (every landing test asserts it found nothing), the
/// inverse-on-disk-first guard must refuse at its CALL SITES (the store helper alone is a
/// tested rule with no caller), a step-6 failure must be drivable for real, and a walk that
/// cannot see everything must never read as "empty".
@Suite struct RestructureApplyGuardTests {

    private static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apply-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The verifier, in the direction every landing test never takes

    /// `return []` from the verifier leaves every landing suite green — this is the test that
    /// goes red: a rename whose destination is missing and whose source survived produces both
    /// mismatch sentences, and a clean disk produces none.
    @Test func theVerifierNamesAMissingDestinationAndASurvivingSource() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Old"),
                               withIntermediateDirectories: true)
        let performed = [RestructureManifest.Action(action: .renameDir,
                                                    src: "Old", dst: "New", evidence: "e")]

        let broken = FileSyncManager.verifyRestructureLanding(performed, root: root.path, fm: fm)
        #expect(broken.contains { $0.contains("New") && $0.contains("missing") })
        #expect(broken.contains { $0.contains("Old") && $0.contains("still exists") })

        try fm.moveItem(at: root.appendingPathComponent("Old"),
                        to: root.appendingPathComponent("New"))
        #expect(FileSyncManager.verifyRestructureLanding(performed, root: root.path, fm: fm)
                    .isEmpty)
    }

    /// The two subtleties inside the verifier, each mutated: a case-only rename's source is
    /// never flagged (the destination answers `fileExists` for both spellings), and a collided
    /// move is verified at `collidedInto` — the name the file actually landed under — so
    /// deleting THAT file is what trips it.
    @Test func theVerifierExemptsCaseOnlyRenamesAndReadsCollidedInto() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Forms"),
                               withIntermediateDirectories: true)
        let caseOnly = [RestructureManifest.Action(action: .renameDir,
                                                   src: "forms", dst: "Forms", evidence: "e")]
        #expect(FileSyncManager.verifyRestructureLanding(caseOnly, root: root.path, fm: fm)
                    .isEmpty,
                "on a case-insensitive volume Forms answers for forms — flagging it would condemn every case-only rename")

        var collided = RestructureManifest.Action(
            action: .moveFile, src: "A/f.pdf", dst: "Forms/f.pdf", evidence: "e")
        collided.collidedInto = "Forms/f 2.pdf"
        try Data("x".utf8).write(to: root.appendingPathComponent("Forms/f 2.pdf"))
        #expect(FileSyncManager.verifyRestructureLanding([collided], root: root.path, fm: fm)
                    .isEmpty)
        try fm.removeItem(at: root.appendingPathComponent("Forms/f 2.pdf"))
        let missing = FileSyncManager.verifyRestructureLanding([collided], root: root.path,
                                                               fm: fm)
        #expect(missing.contains { $0.contains("f 2.pdf") && $0.contains("missing") },
                "the verifier must look where the collision landed, not where the plan aimed")
    }

    // MARK: - Inverse on disk first, at the call sites

    /// The engine refuses the WHOLE landing when the ledger write fails — tested at
    /// `applyPlan`, not at the store helper: reverting the `guard` to fire-and-forget is
    /// exactly the mutation this goes red under, and it is the mutation nothing else caught.
    @Test @MainActor func aFailedLedgerWriteRefusesThePlanLandingBeforeAnyMove() async throws {
        let world = try await RestructureApplyTests.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let storeDir = world.profiles.appendingPathComponent("t")
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: storeDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: storeDir.path)
        }

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal?.contains("nothing was moved") == true)
        #expect(FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/Federal Tax").path),
                "a landing with no on-disk inverse must not have touched the tree")
        #expect(world.manager.restructureStore?.applied.isEmpty == true)
    }

    /// The same call-site guard on the scaffold — the other landing that mints records.
    @Test @MainActor func aFailedLedgerWriteRefusesTheScaffoldLanding() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tree")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025"),
            withIntermediateDirectories: true)
        let profiles = base.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        manager.filingFolderProfile = FolderProfile(
            profileId: "t", root: root.path,
            folders: ["Health/Dental/2025": FolderProfileEntry(
                path: "Health/Dental/2025", role: nil, naming: nil, anchors: [],
                acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])],
            personTokens: [])
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: profiles.appendingPathComponent("t").path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: profiles.appendingPathComponent("t").path)
        }

        let finding = StructureFinding(kind: .backlog, family: "Health/Dental",
                                       subject: "Health/Dental/2025",
                                       detail: .backlog(scaffold: ["Claims"], looseFiles: 2))
        let outcome = await manager.applyScaffold(for: finding)
        #expect(outcome.refusal?.contains("The ledger could not be written") == true)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Claims").path),
                "an unrecorded scaffold must not have landed")
    }

    // MARK: - Step 6 failing for real

    /// The re-derive fails ON THE REAL PATH (the profiles root refuses the new directory), and
    /// the record left behind has the exact shape the chain machinery keys on: finalised
    /// (`summary` set, suffixed), un-repointed (`producedProfileId` nil) — and still offered by
    /// `undoableReorganisation`, anchored on the directory it was applied under. Every prior
    /// test of this shape built the record by hand; a drift between this branch and those
    /// hand-built records stayed green.
    @Test @MainActor func aStepSixFailureStillLandsFinalisedAndUndoable() async throws {
        let world = try await RestructureApplyTests.makeWorld()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: world.profiles.path)
            try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: world.profiles.path)

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil, "the moves landed; only the re-derive failed")
        #expect(outcome.surveyRefreshFailure != nil)
        #expect(outcome.producedProfileId == nil)

        let record = world.manager.restructureStore?.applied
            .first { $0.manifest.manifestId == world.manifest.manifestId }
        #expect(record?.summary?.hasSuffix("survey not refreshed") == true,
                "finalised WITH the failure named — what separates it from a crash-mid-apply record")
        #expect(record?.producedProfileId == nil)
        let offered = world.manager.restructureStore?
            .undoableReorganisation(currentProfileId: "t")
        #expect(offered?.manifest.manifestId == world.manifest.manifestId,
                "a re-derive-failed landing is anchored on the applied-under directory and stays undoable")
    }

    // MARK: - A walk that cannot see everything

    /// An unreadable directory is UNKNOWN, never empty: the count is nil, and the engine's
    /// `remove-empty-dir` keeps the folder with the truth — the old `return 0` default would
    /// have trashed a folder whose contents the walk never saw.
    @Test func anUnreadableFolderNeverReadsAsEmpty() throws {
        let root = try Self.scratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent("Sealed").path)
            try? FileManager.default.removeItem(at: root)
        }
        let sealed = root.appendingPathComponent("Sealed")
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sealed.appendingPathComponent("hidden-from-walk.pdf"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: sealed.path)

        #expect(FileSyncManager.visibleFileCount(atPath: sealed.path,
                                                 fm: FileManager.default) == nil)

        let removal = [RestructureManifest.Action(action: .removeEmptyDir,
                                                  src: "Sealed", evidence: "e")]
        let execution = FileSyncManager.executeRestructureActions(
            removal, root: root.path, fm: FileManager.default,
            vetoUnlistedSourceFolders: false)
        #expect(execution.removedEmpty == 0)
        #expect(execution.skipped.contains { $0.contains("could not be fully read") })
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: sealed.path)
        #expect(FileManager.default.fileExists(atPath: sealed.path), "kept, not trashed")
    }

    // MARK: - One landing at a time

    /// The guard set's first check: a landing already in flight refuses a second entry — the
    /// operation count cannot see the re-derive window, and a second landing through it
    /// records itself under a profile id the first is about to replace, wedging the chain.
    @Test @MainActor func aLandingInProgressRefusesASecondEntry() async throws {
        let world = try await RestructureApplyTests.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        world.manager.restructureLandingInProgress = true
        defer { world.manager.restructureLandingInProgress = false }
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal?.contains("Another reorganisation is landing") == true)
        #expect(world.manager.restructureStore?.applied.isEmpty == true)
    }

    /// A `FileManaging` that delegates everything to the real disk but PARKS the first
    /// `fileExists` probe on a gate — which holds a live landing open inside step 3, off the
    /// main actor, for as long as the test needs. The gate is entered on the operation queue,
    /// so the landing genuinely cannot finish until `release` is signalled.
    private final class GateFileManager: FileManaging, @unchecked Sendable {
        private let inner = FileManager.default
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var tripped = false

        private func gate() {
            // Only an OFF-MAIN probe may park: the landing's executor runs on the operation
            // queue, and a stray main-thread probe parking here would deadlock the test (main
            // would never reach `release.signal()`).
            guard !Thread.isMainThread else { return }
            lock.lock()
            let first = !tripped
            tripped = true
            lock.unlock()
            if first { entered.signal(); release.wait() }
        }

        func fileExists(atPath path: String) -> Bool {
            gate()
            return inner.fileExists(atPath: path)
        }
        func fileExists(atPath path: String,
                        isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func setAttributes(_ attributes: [FileAttributeKey: Any],
                           ofItemAtPath path: String) throws {
            try inner.setAttributes(attributes, ofItemAtPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                             attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url,
                                      withIntermediateDirectories: createIntermediates,
                                      attributes: attributes)
        }
        func copyItem(at srcURL: URL, to dstURL: URL) throws {
            try inner.copyItem(at: srcURL, to: dstURL)
        }
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        func trashItem(at url: URL,
                       resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
        func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL,
                         backupItemName: String) throws -> URL? {
            try inner.replaceItem(at: destinationURL, withItemAt: stagedURL,
                                  backupItemName: backupItemName)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                        options mask: FileManager.DirectoryEnumerationOptions,
                        errorHandler handler: ((URL, Error) -> Bool)?)
            -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask,
                             errorHandler: handler)
        }
    }

    /// The HOLD half, which the hand-set test above cannot see: delete the three
    /// `restructureLandingInProgress = true` assignments and it stays green, because it never
    /// runs a real landing. This one parks a live landing inside step 3 and proves the flag's
    /// own sentence answers a second entry — the sentence matters, because the operation count
    /// also refuses in this window, with different words; only the flag's sentence goes red
    /// when the assignments are reverted.
    @Test @MainActor func theFlagIsHeldAcrossALiveLanding() async throws {
        let gate = GateFileManager()
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Documents")
        let sourceDir = root.appendingPathComponent("Tax/2013/Federal Tax")
        try FileManager.default.createDirectory(at: sourceDir,
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sourceDir.appendingPathComponent("f.pdf"))
        let profiles = base.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager(fileManager: gate)
        manager.filingFolderProfile = FolderProfile(
            profileId: "t", root: root.path,
            folders: ["Tax": FolderProfileEntry(path: "Tax", role: nil, naming: nil,
                                                anchors: [], acceptsNewFiles: nil,
                                                fileCount: 0, subfolderCount: 1, axes: [:])],
            personTokens: [])
        manager.filingProfilesDirectory = profiles
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")
        let manifest = RestructureManifest(
            profileId: "t", manifestId: "gate-1", createdAt: "2026-08-28T15:00:00",
            family: "Tax", kind: .shape,
            actions: [.init(action: .renameDir, src: "Tax/2013/Federal Tax",
                            dst: "Tax/2013/Forms", evidence: "e")])

        let first = Task { await manager.applyPlan(manifest) }
        // The landing is parked once the executor's first probe reaches the gate — entered on
        // the operation queue. The bounded semaphore wait runs on a detached pool thread so
        // the main actor stays free for the landing to reach its own suspension.
        let arrived = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                done.resume(returning: gate.entered.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(arrived, "the landing never reached its first disk probe")
        #expect(manager.restructureLandingInProgress)

        let second = RestructureManifest(
            profileId: "t", manifestId: "gate-2", createdAt: "2026-08-28T15:00:01",
            family: "Tax", kind: .shape,
            actions: [.init(action: .renameDir, src: "Tax/2013/Federal Tax",
                            dst: "Tax/2013/Records", evidence: "e")])
        let refused = await manager.applyPlan(second)
        #expect(refused.refusal?.contains("Another reorganisation is landing") == true)

        gate.release.signal()
        _ = await first.value
        #expect(manager.restructureLandingInProgress == false,
                "the defer must clear the flag on the way out")
    }

    /// A removal landing registers no session undo of its own, so the ⌘Z stack's top would
    /// still be the PREVIOUS landing's group — replayed into folders the removal just trashed.
    /// The engine clears the stack instead; delete the `removeAllActions` branch and this goes
    /// red.
    @Test @MainActor func aRemovalLandingClearsTheSessionUndoStack() async throws {
        let world = try await RestructureApplyTests.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: world.root.appendingPathComponent("Tax/Emptied"),
            withIntermediateDirectories: true)
        let undo = UndoManager()
        undo.groupsByEvent = false   // no runloop turn in tests to close an implicit group
        world.manager.undoManager = undo
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: world.manager) { _ in }   // the previous landing's group
        undo.endUndoGrouping()
        #expect(undo.canUndo)

        let removal = RestructureManifest(
            profileId: "t", manifestId: "removal-test-1", createdAt: "2026-08-28T15:00:00",
            family: "Tax", kind: .deadWeight,
            actions: [.init(action: .removeEmptyDir, src: "Tax/Emptied", evidence: "e")])
        let outcome = await world.manager.applyPlan(removal)
        #expect(outcome.refusal == nil)
        #expect(outcome.removedEmpty == 1)
        #expect(!undo.canUndo,
                "⌘Z after a removal must not replay the previous landing's moves into folders the removal just trashed")
    }
}
