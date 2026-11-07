import Testing
import Foundation
import Events
@testable import Sync

/// Two safety rules for the duplicate merge.
///
/// No undo group is held open across a suspension. NSUndoManager grouping is manager-global, so a
/// group left open across the planning walks, the queued copy, the drift re-walk or a
/// `deleteItems` holding a permanent-delete dialog would swallow any other undo registered in that
/// window, and ⌘Z would reverse more than the banner claims, on a path whose reversal deletes files
/// out of the keeper.
///
/// The trash is gated: the copies are re-verified after the serialized queue wait and the
/// user-paced permanent-delete confirmation, before the unrecoverable branch.
///
/// A real `FileManager` subclass rather than the mock disk: the merge hashes real bytes to plan,
/// and only the `fileManager is FileManager` fast path yields the sizes it plans from.
@Suite struct MergeUndoGroupingAndGateTests {

    /// A real `FileManager` whose Trash always refuses: a Trash-less volume without needing one.
    private final class TrashlessVolume: FileManager, @unchecked Sendable {
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
    }

    /// A real `FileManager` whose trash holds the merge suspended until a main-actor reading has
    /// been taken during the suspension. A premise floor on sample counts would depend on the
    /// machine's throughput, and a polled rendezvous on a sampling loop getting a turn in time ("The
    /// control that stops an absence being vacuous is itself load-dependent" in
    /// `docs/flaky-tests.md`).
    ///
    /// So the trash asks for the reading itself: it puts one main-actor observation on the main
    /// queue and waits on the semaphore that observation signals. That depends only on the main
    /// queue running one runnable block, not on a `Task.sleep` wake-up or the sampling loop being
    /// alive. `DispatchQueue.main` is the main actor's executor, so the block sees what another
    /// main-actor task would; `inTrash` stops a late block counting as an in-window reading.
    ///
    /// Bounded, so a wedged observer fails the test instead of hanging its thread, and the expiry
    /// records itself as `ParkGate.releasedByTimeout` does, so "never observed" and "observed after
    /// the window" stay distinct. The thread it blocks is a cooperative-pool one (the merge reaches
    /// this through `enqueueFileOperation`'s `Task.detached`), hence `.parksAThread`.
    private final class SamplerObservedTrash: FileManager, @unchecked Sendable {
        /// Where the trash really goes, once the rendezvous below is over.
        let trash: ScratchTrash
        init(trash: ScratchTrash) {
            self.trash = trash
            super.init()
        }
        /// Reads the observed quantity from the main actor. Installed by the test before the merge
        /// starts and run from the main queue while this call holds the merge suspended.
        let readLevel = LockedBox<(@MainActor () -> Int)?>(nil)
        let inTrash = LockedBox<Bool>(false)
        /// The reading taken inside the suspension, or `nil` if none was. The reading itself is the
        /// evidence: a separate "sampled" flag could stay true for a block that read nothing,
        /// which is the vacuous pass this rendezvous prevents.
        let levelDuringTrash = LockedBox<Int?>(nil)
        /// True if the rendezvous gave up instead of being signalled by its observation.
        let rendezvousExpired = LockedBox<Bool>(false)
        private let sampled = DispatchSemaphore(value: 0)

        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            inTrash.withLock { $0 = true }
            defer { inTrash.withLock { $0 = false } }
            DispatchQueue.main.async { [self] in
                let reading = MainActor.assumeIsolated { readLevel.withLock { $0 }?() }
                // `inTrash` keeps a block that ran late (after the bound expired and the trash
                // moved on) from being recorded as an in-window reading.
                if let reading, inTrash.withLock({ $0 }) {
                    levelDuringTrash.withLock { $0 = reading }
                }
                sampled.signal()
            }
            if sampled.wait(timeout: .now() + 10) == .timedOut {
                rendezvousExpired.withLock { $0 = true }
            }
            try trash.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
    }

    /// Records the file-mutating calls the undo makes, in order, so the order of the merge's two
    /// undo registrations is observable. Every override calls `super`, except the trash, which goes
    /// to the test's own.
    private final class OpRecorder: FileManager, @unchecked Sendable {
        let calls = LockedBox<[String]>([])
        let trash: ScratchTrash
        init(trash: ScratchTrash) {
            self.trash = trash
            super.init()
        }
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            calls.withLock { $0.append("trash:\(url.lastPathComponent)") }
            try trash.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
        override func moveItem(at src: URL, to dst: URL) throws {
            calls.withLock { $0.append("move:\(dst.lastPathComponent)") }
            try super.moveItem(at: src, to: dst)
        }
        override func removeItem(at url: URL) throws {
            calls.withLock { $0.append("remove:\(url.lastPathComponent)") }
            try super.removeItem(at: url)
        }
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// The overlapping group the merge folds: a keeper, and `redundantNames.count` redundant copies
    /// that each share one file with it and hold one unique file of their own.
    private func makeGroup(_ base: URL, redundantNames: [String]) throws -> (keeper: URL, redundant: [URL], group: DuplicateGroup) {
        let keeper = base.appendingPathComponent("Keeper")
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        var copies: [DuplicateCopy] = [.stub(keeper.path, keeper: true, isDirectory: true, size: 4000)]
        var redundant: [URL] = []
        for (i, name) in redundantNames.enumerated() {
            let r = base.appendingPathComponent(name)
            try write(r.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
            try write(r.appendingPathComponent("unique\(i).txt"), bytes: 4000, fill: UInt8(0x60 + i))
            redundant.append(r)
            copies.append(.stub(r.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1))
        }
        return (keeper, redundant, .stub(copies, matchType: .overlapping(sharedFraction: 0.5), reclaimable: 4000))
    }

    // MARK: FINDING 1 — no undo group across a suspension

    /// The invariant, observed the only way it can be: from the main actor. A
    /// `beginUndoGrouping`/`endUndoGrouping` pair with no `await` between them can't be seen open by
    /// another main-actor task, so sampling `groupingLevel` throughout the merge must never see it
    /// above zero. A merge that holds a group across an await is caught with the group still open.
    ///
    /// `groupsByEvent = false` so the sampler measures this code's grouping, not NSUndoManager's own
    /// per-event group, which opens on the first registration and would read 1 regardless.
    @MainActor
    @Test(.parksAThread) func noUndoGroupIsEverOpenWhileTheMergeIsSuspended() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGrouping")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let fixture = try makeGroup(base, redundantNames: [rName])

        let trash = SamplerObservedTrash(trash: ScratchTrash(in: base))
        let manager = FileSyncManager(fileManager: trash)
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        manager.duplicateGroups = [fixture.group]
        // Installed before the merge starts: the trash asks for this reading from the main queue
        // while it holds the merge suspended, and the result is the premise's evidence.
        trash.readLevel.withLock { $0 = { @MainActor in undo.groupingLevel } }
        // What the sampling loop accumulates over the whole merge, boxed so the two observers can
        // share one reading.
        let maxLevel = LockedBox<Int>(0)

        let finished = LockedBox<Bool>(false)
        let merge = Task { @MainActor in
            let ok = await manager.mergeDuplicateGroup(fixture.group)
            finished.withLock { $0 = true }
            return ok
        }

        // Sample from the main actor for as long as the merge runs, so the invariant is checked
        // across the whole merge, not only in the window the trash holds open. Bounded so a wedged
        // merge fails instead of hanging. The premise doesn't depend on this loop: it is signalled
        // by the trash's own observation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !finished.withLock({ $0 }) && ContinuousClock.now < deadline {
            maxLevel.withLock { $0 = max($0, undo.groupingLevel) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let ok = await merge.value
        let duringTrash = trash.levelDuringTrash.withLock { $0 }
        let level = max(maxLevel.withLock { $0 }, duringTrash ?? 0)

        #expect(ok == true, "the merge did not complete, so the samples below describe nothing")
        #expect(trash.rendezvousExpired.withLock({ $0 }) == false,
                "the trash gave up waiting for its main-actor observation — whatever is below was not read under the merge's suspension")
        #expect(duringTrash != nil,
                "no reading was taken while the merge was suspended in its trash operation — a zero level below proves nothing")
        #expect(level == 0,
                "an undo group was open (level \(level)) while the merge was suspended — anything else registering an undo in that window nests into the merge's step")
        // The premise: this run suspended where the hazard lives; it copied and it trashed.
        #expect(FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique0.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.redundant[0].path) == false)
        #expect(trash.trash.names == [rName],
                "the redundant copy left the disk but never reached the test's own Trash")
    }

    /// The other direction, and what the grouping is for: a merge that folded two copies is still
    /// one ⌘Z. Deleting the grouping outright would pass the test above but fail this.
    @MainActor
    @Test func oneUndoReversesAWholeTwoCopyMergeAndNothingElse() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeOneUndo")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = ["RedA-\(UUID().uuidString)", "RedB-\(UUID().uuidString)"]
        let fixture = try makeGroup(base, redundantNames: names)

        let trash = ScratchTrash(in: base)
        let manager = FileSyncManager(fileManager: trash)
        manager.undoManager = UndoManager()
        // An unrelated delete first, so its step sits below the merge's on the stack.
        let bystander = base.appendingPathComponent("bystander.txt")
        try write(bystander, bytes: 10, fill: 0x41)
        await manager.deleteItems(at: [bystander.path], fileManager: trash)
        try #require(FileManager.default.fileExists(atPath: bystander.path) == false)
        #expect(trash.names == ["bystander.txt"],
                "the delete left the disk but never reached the test's own Trash")
        await closeTheUndoEventGroup(manager.undoManager)

        manager.duplicateGroups = [fixture.group]
        let ok = await manager.mergeDuplicateGroup(fixture.group)
        try #require(ok == true)
        for r in fixture.redundant {
            try #require(FileManager.default.fileExists(atPath: r.path) == false)
        }
        #expect(manager.undoManager?.undoActionName == "Merge Keeper",
                "the merge's step is named after its last registration rather than after the merge: “\(manager.undoManager?.undoActionName ?? "nil")”")
        await closeTheUndoEventGroup(manager.undoManager)

        manager.undoManager?.undo()
        await waitUntil("one undo restores both redundant copies") {
            fixture.redundant.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        await waitUntil("one undo removes both folded files from the keeper") {
            !FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique0.txt").path)
                && !FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique1.txt").path)
        }
        await waitUntil("the undo's operations drain") { manager.activeFileOperationsCount == 0 }
        // …and only the merge: the unrelated delete before it is still undoable, not undone.
        #expect(FileManager.default.fileExists(atPath: bystander.path) == false,
                "one ⌘Z after the merge also reversed an unrelated earlier delete — the merge's step leaked beyond the merge")
        #expect(manager.undoManager?.canUndo == true,
                "the unrelated delete's own undo step disappeared with the merge's")
    }

    /// The order inside that one step is a safety property. Undoing a merge puts the redundant
    /// copies back and deletes the folded files out of the keeper. The last registration pops
    /// first, so undo must run restore-first: if the restore fails (its location reoccupied, its
    /// Trash backup gone), the folded files must still be in the keeper, not already deleted with
    /// the originals unrecoverable.
    ///
    /// Two guarantees make it: the merge's synchronous tail sets the registration order, and
    /// `enqueueFileOperation`, which both handlers go through, keeps that order on disk. The queue
    /// half is pinned by `FileOperationQueueOrderTests` at a trial count that can see a rare
    /// inversion; this is the end-to-end test.
    ///
    /// It also pins `restoreUndoHandback`: disabling the handback must make this fail, since
    /// `deleteItems` would then register the restore before the merge's copy-undo. Nothing else in
    /// the suite notices, because NSUndoManager's per-event group reverses both shapes in one press.
    @MainActor
    @Test func undoingAMergePutsTheCopiesBackBeforeItRemovesAnythingFromTheKeeper() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoOrder")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Red-\(UUID().uuidString)"
        let fixture = try makeGroup(base, redundantNames: [rName])

        let recorder = OpRecorder(trash: ScratchTrash(in: base))
        let manager = FileSyncManager(fileManager: recorder)
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [fixture.group]
        try #require(await manager.mergeDuplicateGroup(fixture.group) == true)
        recorder.calls.withLock { $0.removeAll() }
        await closeTheUndoEventGroup(manager.undoManager)

        manager.undoManager?.undo()
        await waitUntil("the undo restores the copy") {
            FileManager.default.fileExists(atPath: fixture.redundant[0].path)
        }
        await waitUntil("the undo removes the folded file from the keeper") {
            !FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique0.txt").path)
        }
        await waitUntil("the undo's operations drain") { manager.activeFileOperationsCount == 0 }

        let calls = recorder.calls.withLock { $0 }
        let restoredAt = try #require(calls.firstIndex { $0.contains(rName) },
                                      "the undo never touched the redundant copy: \(calls)")
        let removedAt = try #require(calls.firstIndex { $0.contains("unique0.txt") },
                                     "the undo never removed the folded file: \(calls)")
        #expect(restoredAt < removedAt,
                "the ⌘Z deleted the folded file out of the keeper BEFORE restoring the original — a failed restore then leaves neither: \(calls)")
        #expect(recorder.trash.names == ["unique0.txt"],
                "the folded file the undo removed never reached the test's own Trash")
    }

    // MARK: FINDING 2 — the merge's trash is gated

    /// The user leaves the permanent-delete confirmation open, something rewrites the redundant copy
    /// in that window, and the merge must not destroy it: what would be removed unrecoverably is no
    /// longer the folder the fold proved was all in the keeper. Without the gate, nothing looks at
    /// the copy again after the dialog closes.
    @MainActor
    @Test func aCopyThatDriftsWhileTheConfirmationIsOpenIsNotPermanentlyDeleted() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateConfirm")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let fixture = try makeGroup(base, redundantNames: [rName])
        let redundant = fixture.redundant[0]

        let manager = FileSyncManager(fileManager: TrashlessVolume())
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [fixture.group]
        let confirmed = LockedBox<Int>(0)
        manager.permanentDeleteConfirmer = { _ in
            // The user's own pace, and its cost: while the sheet is up, something writes a new
            // file into the copy, unverified since the fold.
            try? Data(repeating: 0x7A, count: 512)
                .write(to: redundant.appendingPathComponent("arrived-while-you-decided.txt"))
            confirmed.withLock { $0 += 1 }
            return true
        }

        // Windowed: "at the last check before removal" is written by seven call sites, three
        // without "no longer", and this suite's siblings write them too, so a last-match read over
        // the whole process log would depend on test order.
        let tag = UUID().uuidString
        var ok = true
        let mine = try await logLines(tag: tag) {
            ok = await manager.mergeDuplicateGroup(fixture.group)
        }

        #expect(confirmed.withLock { $0 } == 1, "the run never reached the permanent-delete confirmation")
        #expect(FileManager.default.fileExists(atPath: redundant.path),
                "the copy was destroyed unrecoverably after drifting while the confirmation was open")
        #expect(FileManager.default.fileExists(
            atPath: redundant.appendingPathComponent("arrived-while-you-decided.txt").path),
                "the file written during the dialog is gone — it was destroyed with the folder")
        #expect(ok == false, "the merge claimed success over a copy it refused to remove")
        #expect(manager.banner?.message.contains("changed since it was scanned") == true,
                "the refusal was not surfaced: “\(manager.banner?.message ?? "nil")”")
        // …and filtered to this fixture's temp root. The window bounds time, not authorship: in a
        // parallel run another suite's refusal can land inside it. `base` carries a per-test UUID
        // and appears in every path the refusal names. Neither assertion below is circular on it;
        // they read the wording and the copy's name.
        let line = mine.last { $0.contains("at the last check before removal") && $0.contains(base.path) }
        #expect(line?.contains(rName) == true,
                "the gate's refusal was not logged with the copy it kept: “\(line ?? "nil")”")
    }

    // MARK: The merge gate's own verdicts

    /// The fold record for the copy "Red" at `redundant`, planned from what is on disk now.
    private func plannedFold(_ redundant: URL, keeperDestinations: [String] = []) async -> FileSyncManager.MergeFoldRecord {
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        return FileSyncManager.MergeFoldRecord(name: "Red", url: redundant, plannedSnapshot: planned,
                                               keeperDestinations: keeperDestinations)
    }

    @MainActor
    @Test func theMergeGateRefusesACopyThatChangedSinceItWasPlanned() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateUnit")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let fold = await plannedFold(redundant)

        // The control first, so a gate that refuses everything can't pass this.
        let clean = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())
        #expect(clean.isEmpty, "an unchanged copy was refused — the fixture makes the pin below vacuous")

        try Data(repeating: 0x01, count: 32).write(to: redundant.appendingPathComponent("new.txt"))
        let refusals = FileSyncManager.MergeRemovalRefusals()
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold], refusals: refusals)

        #expect(refused == [redundant.path],
                "a copy that gained a file after the plan was not refused: \(refused)")
        #expect(refusals.all == ["Red"])
    }

    /// The keeper is the other half of the merge's claim: every byte the copy is trashed for now
    /// lives there. A keeper gone from its scanned location makes the copy the only instance again,
    /// so the gate refuses even though the copy itself never moved.
    @MainActor
    @Test func theMergeGateRefusesEveryFoldWhenTheKeeperLeftItsScannedLocation() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateKeeper")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let fold = await plannedFold(redundant)

        try FileManager.default.removeItem(at: fixture.keeper)
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [redundant.path],
                "the copy was cleared for the Trash with the keeper gone — the folded files are provably nowhere")
    }

    /// Fail closed, as the duplicates gate does: a path the gate can't attribute to a fold has been
    /// re-verified by nothing.
    @MainActor
    @Test func theMergeGateRefusesAPathItCannotAttributeToAFold() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateStray")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let fold = await plannedFold(redundant)

        let stray = base.appendingPathComponent("stray.txt").path
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path, stray], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [stray], "a path belonging to no fold was waved through unverified: \(refused)")
    }

    /// The gate must recognize a fold however its path is spelled: `deleteItems` feeds the
    /// post-confirmation pass URL round-tripped strings. The same contract
    /// `RemovalGatePathMatchingTests` pins for the duplicates gate.
    @MainActor
    @Test func theMergeGateVerifiesAFoldGivenInAnotherSpelling() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateSpelling")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let fold = await plannedFold(redundant)
        try Data(repeating: 0x01, count: 32).write(to: redundant.appendingPathComponent("new.txt"))

        let spelled = redundant.path + "/"
        let refused = await manager.refuseDriftedMergeSources(
            [spelled], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [spelled],
                "a drifted fold asked about in a trailing-slash spelling was not verified: \(refused)")
    }

    // MARK: The keeper-side half of the claim — the destinations the fold actually produced

    /// The keeper check must look at the files, not just the directory entry. A merge keeper is
    /// always a folder, and `copyDriftedInPlace` returns false for a directory, so
    /// `fileExists(keeper.path) && !copyDriftedInPlace(keeper)` alone only proves something is still
    /// at the path: an emptied keeper would pass and the copy would be trashed.
    ///
    /// The merge knows every destination its copy loop wrote, plus the keeper paths `planMerge`
    /// matched for the files it skipped as already present. Together those are "every byte this
    /// copy is trashed for now lives in the keeper", so both are stat'ed, and a missing one refuses.
    ///
    /// Trash-less, because there the window ends in an unrecoverable delete of the last instance:
    /// the user leaves the confirmation open, something empties the keeper, and the copy is gone.
    @MainActor
    @Test func aFoldIsRefusedWhenTheKeeperNoLongerHoldsTheFilesItFolded() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateDest")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let fixture = try makeGroup(base, redundantNames: [rName])
        let redundant = fixture.redundant[0]

        let manager = FileSyncManager(fileManager: TrashlessVolume())
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [fixture.group]
        let confirmed = LockedBox<Int>(0)
        manager.permanentDeleteConfirmer = { _ in
            // The keeper is still a folder at its scanned path; only the file the fold just put
            // there is gone. A directory-entry check alone can't see that.
            try? FileManager.default.removeItem(at: fixture.keeper.appendingPathComponent("unique0.txt"))
            confirmed.withLock { $0 += 1 }
            return true
        }

        // Windowed: "at the last check before removal" is written by seven call sites, three
        // without "no longer", and this suite's siblings write them too, so a last-match read over
        // the whole process log would depend on test order.
        let tag = UUID().uuidString
        var ok = true
        let mine = try await logLines(tag: tag) {
            ok = await manager.mergeDuplicateGroup(fixture.group)
        }

        #expect(confirmed.withLock { $0 } == 1, "the run never reached the permanent-delete confirmation")
        #expect(FileManager.default.fileExists(atPath: fixture.keeper.path),
                "the fixture removed the keeper itself — the pin would then be about the path check, not this one")
        #expect(FileManager.default.fileExists(atPath: redundant.path),
                "the copy was destroyed unrecoverably while the keeper no longer held what was folded into it")
        #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent("unique0.txt").path),
                "the only remaining instance of the folded file is gone")
        #expect(ok == false, "the merge claimed success over a copy it refused to remove")
        // …and filtered to this fixture's temp root. The window bounds time, not authorship: in a
        // parallel run another suite's refusal can land inside it. `base` carries a per-test UUID
        // and appears in every path the refusal names. Neither assertion below is circular on it;
        // they read the wording and the copy's name.
        let line = mine.last { $0.contains("at the last check before removal") && $0.contains(base.path) }
        #expect(line?.contains("no longer") == true,
                "the keeper-side refusal was not logged: “\(line ?? "nil")”")
    }

    /// The skipped half, end to end: `unique0.txt` (which the fold copied) stays put, and
    /// `shared.txt`, which `planMerge` never copied because the keeper already had it, is removed
    /// from the keeper while the confirmation is open. Only a fold record carrying
    /// `plan.vouchedKeeperPaths` can see this; the copy loop's destinations alone would miss it.
    @MainActor
    @Test func aFoldIsRefusedWhenTheKeeperLosesAFileThePlanSkipped() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateVouch")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let fixture = try makeGroup(base, redundantNames: [rName])
        let redundant = fixture.redundant[0]

        let manager = FileSyncManager(fileManager: TrashlessVolume())
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [fixture.group]
        manager.permanentDeleteConfirmer = { _ in
            try? FileManager.default.removeItem(at: fixture.keeper.appendingPathComponent("shared.txt"))
            return true
        }

        let ok = await manager.mergeDuplicateGroup(fixture.group)

        #expect(FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique0.txt").path),
                "the fixture removed the COPIED file too — the pin would then not be about the skipped half")
        #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent("shared.txt").path),
                "the last instance of a file the plan skipped was destroyed with the copy")
        #expect(ok == false, "the merge claimed success over a copy it refused to remove")
    }

    /// The unit form, on the file the copy loop wrote.
    @MainActor
    @Test func theMergeGateRefusesAFoldWhoseCopiedDestinationIsGone() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateDestUnit")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        // As if the fold had run: the unique file now also lives in the keeper.
        let landed = fixture.keeper.appendingPathComponent("unique0.txt")
        try Data(repeating: 0x60, count: 4000).write(to: landed)
        let fold = await plannedFold(redundant, keeperDestinations: [
            landed.path, fixture.keeper.appendingPathComponent("shared.txt").path])

        // Control first, so a gate that refuses everything can't pass the pin below.
        let clean = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())
        #expect(clean.isEmpty, "an intact fold was refused — the pin below would be vacuous")

        try FileManager.default.removeItem(at: landed)
        let refusals = FileSyncManager.MergeRemovalRefusals()
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold], refusals: refusals)

        #expect(refused == [redundant.path],
                "the copy was cleared for the Trash with the file it was trashed FOR gone from the keeper: \(refused)")
        #expect(refusals.all.count == 1)
    }

    /// The skipped half is checked too. A file `planMerge` never copied, because the keeper already
    /// had those bytes at that relative path, is still part of what the copy is trashed for: if the
    /// keeper's instance disappears between plan and trash, the redundant copy holds the last one.
    @MainActor
    @Test func theMergeGateRefusesAFoldWhoseAlreadyPresentKeeperFileWentAway() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateSkipped")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let shared = fixture.keeper.appendingPathComponent("shared.txt")
        let fold = await plannedFold(redundant, keeperDestinations: [shared.path])

        try FileManager.default.removeItem(at: shared)
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [redundant.path],
                "the copy was cleared for the Trash although the keeper's own instance of a plan-skipped file is gone: \(refused)")
    }

    /// `planMerge` must report the keeper path it vouched with for both skip branches: the
    /// same-relative-path hash match and the retry-idempotence match, whose keeper file has a
    /// different name. Without the second, a retry's fold is trashed on bytes nothing re-checked.
    @Test func planMergeReportsTheKeeperPathsItVouchedWith() async throws {
        let base = try makeCanonicalTempRoot(prefix: "PlanMergeVouched")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("K")
        let redundant = base.appendingPathComponent("R")
        // (a) same content at the same relative path → skipped, vouched by K/same.txt
        try write(keeper.appendingPathComponent("same.txt"), bytes: 700, fill: 0x41)
        try write(redundant.appendingPathComponent("same.txt"), bytes: 700, fill: 0x41)
        // (b) the retry-idempotence skip: the name is taken by different content, and the bytes
        //     live in that folder under the uniquified name a previous run minted.
        try write(keeper.appendingPathComponent("dup.txt"), bytes: 300, fill: 0x42)
        try write(keeper.appendingPathComponent("dup 2.txt"), bytes: 900, fill: 0x43)
        try write(redundant.appendingPathComponent("dup.txt"), bytes: 900, fill: 0x43)
        // (c) a unique file → copied, so it is not vouched for here
        try write(redundant.appendingPathComponent("new.txt"), bytes: 500, fill: 0x44)

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper,
                                                   fileManager: FileManager.default, cache: nil)

        #expect(plan.steps.map { $0.src.lastPathComponent } == ["new.txt"],
                "the fixture did not exercise both skip branches: \(plan.steps.map { $0.src.lastPathComponent })")
        #expect(Set(plan.vouchedKeeperPaths) == [keeper.appendingPathComponent("same.txt").path,
                                                 keeper.appendingPathComponent("dup 2.txt").path],
                "planMerge did not report the keeper paths its skips rested on: \(plan.vouchedKeeperPaths)")
    }
}
