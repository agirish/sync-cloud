import Testing
import Foundation
import Events
@testable import Sync

/// The two things the merge path was still missing after the duplicates round hardened its
/// siblings.
///
/// **The undo group was held open across suspensions.** `mergeDuplicateGroup` opened one
/// `beginUndoGrouping` at its first registration and closed it after the whole loop — across the
/// planning walks, the queued copy operation, the drift re-walk and a `deleteItems` that can hold a
/// modal permanent-delete dialog. NSUndoManager grouping is manager-GLOBAL, so anything else
/// registering an undo in one of those windows nested inside the merge's step, and ⌘Z then reversed
/// more than the banner claimed — on the one duplicates path whose reversal DELETES files out of
/// the keeper.
///
/// **The trash had no removal gate.** `mergeSourceDrifted` ran before `deleteItems` was even
/// enqueued, so neither window the gate exists for was covered here: the serialized queue wait, and
/// the user-paced permanent-delete confirmation with nothing re-verified before the unrecoverable
/// branch.
///
/// A real `FileManager` subclass rather than the mock disk, for the reason `MergeCancelMidCopyTests`
/// documents: the merge hashes real bytes to plan, and only the `fileManager is FileManager` fast
/// path yields the sizes it plans from.
@Suite struct MergeUndoGroupingAndGateTests {

    /// A real `FileManager` whose Trash always refuses — the Trash-less volume, without needing one.
    private final class TrashlessVolume: FileManager, @unchecked Sendable {
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
    }

    /// A real `FileManager` whose trash holds the merge suspended until the test's main-actor
    /// sampler has provably taken a sample during the suspension — the rendezvous that replaced
    /// the `samples > 20` premise floor (flaky-tests.md, "The control that stops an absence being
    /// vacuous is itself load-dependent"). The old shape slept a fixed 0.3 s and the sampler
    /// counted its own wakeups, so the count was `merge_duration / actual_sleep_interval` and the
    /// denominator was the machine's: under CI load the same merge yielded 19–20 samples against
    /// a floor of 20, and the premise guard reddened runs in which nothing was wrong.
    ///
    /// Here the evidence is event-derived instead: `inTrash` is raised around the trash call, the
    /// sampler acknowledges seeing it, and the trash does not return until acknowledged — so "a
    /// sample was taken while the merge was suspended in the stretch the hazard lives across" is
    /// guaranteed by construction, not bet on scheduler throughput. Bounded by a deadline so a
    /// wedged sampler fails the test instead of hanging the pool thread; on an idle machine the
    /// 2 ms sampler acknowledges within one or two 10 ms checks, faster than the old fixed sleep.
    private final class SamplerObservedTrash: FileManager, @unchecked Sendable {
        let inTrash = LockedBox<Bool>(false)
        let sampledDuringTrash = LockedBox<Bool>(false)
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            inTrash.withLock { $0 = true }
            defer { inTrash.withLock { $0 = false } }
            let deadline = Date().addingTimeInterval(10)
            while !sampledDuringTrash.withLock({ $0 }) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try super.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
    }

    /// Records the file-mutating calls the undo makes, in order, so the ORDER of the merge's two
    /// undo registrations is observable. Real behaviour throughout — every override calls `super`.
    private final class OpRecorder: FileManager, @unchecked Sendable {
        let calls = LockedBox<[String]>([])
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            calls.withLock { $0.append("trash:\(url.lastPathComponent)") }
            try super.trashItem(at: url, resultingItemURL: resultingItemURL)
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
        var copies: [DuplicateCopy] = [
            DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 4000, itemCount: 1,
                          modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        ]
        var redundant: [URL] = []
        for (i, name) in redundantNames.enumerated() {
            let r = base.appendingPathComponent(name)
            try write(r.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
            try write(r.appendingPathComponent("unique\(i).txt"), bytes: 4000, fill: UInt8(0x60 + i))
            redundant.append(r)
            copies.append(DuplicateCopy(id: r.path, name: name, isDirectory: true, size: 8000, itemCount: 2,
                                        modificationDate: nil, uniqueItemCount: 1, depth: 0,
                                        isRecommendedKeeper: false))
        }
        return (keeper, redundant,
                DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                               isDirectory: true, copies: copies, reclaimableBytes: 4000))
    }

    // MARK: FINDING 1 — no undo group across a suspension

    /// **The invariant, stated the only way it can be observed: from the main actor.** A
    /// `beginUndoGrouping`/`endUndoGrouping` pair with no `await` between them cannot be seen open
    /// by any other main-actor task, because a synchronous stretch is not interleavable. So
    /// sampling `groupingLevel` from the main actor throughout the merge must never see it above
    /// zero — and if the merge ever again holds a group across an await, this catches it with the
    /// grouping still open.
    ///
    /// `groupsByEvent = false` so the sampler measures THIS code's grouping and not NSUndoManager's
    /// own per-event group, which opens on the first registration and would read 1 for reasons that
    /// have nothing to do with the hazard.
    @MainActor
    @Test func noUndoGroupIsEverOpenWhileTheMergeIsSuspended() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGrouping")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")) }
        let fixture = try makeGroup(base, redundantNames: [rName])

        let trash = SamplerObservedTrash()
        let manager = FileSyncManager(fileManager: trash)
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        manager.duplicateGroups = [fixture.group]

        let finished = LockedBox<Bool>(false)
        let merge = Task { @MainActor in
            let ok = await manager.mergeDuplicateGroup(fixture.group)
            finished.withLock { $0 = true }
            return ok
        }

        // Sample from the main actor for as long as the merge runs. Bounded by a deadline as well
        // as by the flag, so a wedged merge fails the test instead of hanging it. When a sample
        // lands while the trash holds the merge suspended, say so — that acknowledgement is what
        // releases the trash, and it is the premise the old wall-clock sample floor only bet on.
        var maxLevel = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !finished.withLock({ $0 }) && ContinuousClock.now < deadline {
            maxLevel = max(maxLevel, undo.groupingLevel)
            if trash.inTrash.withLock({ $0 }) {
                trash.sampledDuringTrash.withLock { $0 = true }
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let ok = await merge.value

        #expect(ok == true, "the merge did not complete, so the samples below describe nothing")
        #expect(trash.sampledDuringTrash.withLock { $0 },
                "no sample was taken while the merge was suspended in its trash operation — a zero reading below proves nothing")
        #expect(maxLevel == 0,
                "an undo group was open (level \(maxLevel)) while the merge was suspended — anything else registering an undo in that window nests into the merge's step")
        // The premise: this run really did suspend in the places the hazard lived — it copied and
        // it trashed.
        #expect(FileManager.default.fileExists(atPath: fixture.keeper.appendingPathComponent("unique0.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.redundant[0].path) == false)
    }

    /// The other direction, and what the grouping is FOR: a merge that folded two copies is still
    /// ONE ⌘Z. Without it, deleting the grouping outright would pass the test above.
    @MainActor
    @Test func oneUndoReversesAWholeTwoCopyMergeAndNothingElse() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeOneUndo")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = ["RedA-\(UUID().uuidString)", "RedB-\(UUID().uuidString)"]
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        defer { for n in names { try? FileManager.default.removeItem(at: trash.appendingPathComponent(n)) } }
        let fixture = try makeGroup(base, redundantNames: names)

        let manager = FileSyncManager(fileManager: FileManager.default)
        manager.undoManager = UndoManager()
        // An unrelated delete FIRST, so its step sits below the merge's on the stack.
        let bystander = base.appendingPathComponent("bystander.txt")
        try write(bystander, bytes: 10, fill: 0x41)
        await manager.deleteItems(at: [bystander.path], fileManager: FileManager.default)
        try #require(FileManager.default.fileExists(atPath: bystander.path) == false)
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
        // …and ONLY the merge: the unrelated delete before it is still undoable, not undone.
        #expect(FileManager.default.fileExists(atPath: bystander.path) == false,
                "one ⌘Z after the merge also reversed an unrelated earlier delete — the merge's step leaked beyond the merge")
        #expect(manager.undoManager?.canUndo == true,
                "the unrelated delete's own undo step disappeared with the merge's")
    }

    /// **The order inside that one step, which is a safety property and not a detail.** Undoing a
    /// merge does two opposite things: it puts the redundant copies back, and it DELETES the folded
    /// files out of the keeper. Whichever is registered last is popped first, so the registrations
    /// must run restore-first at undo time — if the restore fails (its location reoccupied, its
    /// Trash backup gone), the folded files must still be in the keeper rather than already
    /// deleted with the originals unrecoverable.
    ///
    /// **It takes two guarantees, and only one of them lives in this file's subject.** The
    /// registration order is set by the merge's synchronous tail; the order the two registrations'
    /// work actually REACHES THE DISK is set by `enqueueFileOperation`, which both handlers funnel
    /// through. That second half used to be a race — measured at ~1 inversion in 300 undos of this
    /// exact pair on an idle machine, which is why this test failed once in an integrated package
    /// run and never under `--filter`. `FileOperationQueueOrderTests` pins the queue half directly,
    /// at a trial count that can actually see a 1-in-300 defect; this test is the end-to-end one.
    ///
    /// This is also the pin on the `restoreUndoHandback` itself: without it `deleteItems` registers
    /// the restore where it happens — BEFORE the merge's copy-undo — and the ⌘Z then removes from
    /// the keeper first. (Verified as a mutation: disabling the handback flips the two indices
    /// below and nothing else in this suite notices, because NSUndoManager's own per-event group
    /// makes both shapes reverse in one press.)
    @MainActor
    @Test func undoingAMergePutsTheCopiesBackBeforeItRemovesAnythingFromTheKeeper() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoOrder")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Red-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")) }
        let fixture = try makeGroup(base, redundantNames: [rName])

        let recorder = OpRecorder()
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
    }

    // MARK: FINDING 2 — the merge's trash is gated

    /// **The headline.** The user leaves the permanent-delete confirmation open, something rewrites
    /// the redundant copy in that window, and the merge must NOT destroy it: what is about to be
    /// removed unrecoverably is no longer the folder whose every file the fold proved was in the
    /// keeper. Red before the gate — the merge called `deleteItems` with none, so nothing looked
    /// at the copy again after the dialog closed.
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
            // The user's own pace, and what it costs: while the sheet was up, something wrote a
            // new file into the copy. Nothing has verified it since the fold.
            try? Data(repeating: 0x7A, count: 512)
                .write(to: redundant.appendingPathComponent("arrived-while-you-decided.txt"))
            confirmed.withLock { $0 += 1 }
            return true
        }

        // Windowed: "at the last check before removal" is written by SEVEN call sites, three of
        // which do not contain "no longer", and this suite's own siblings write them too. A
        // last-match read over a per-process log picks whichever ran most recently — which is how
        // this passed under one full-suite ordering and failed under another AND in isolation.
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
        // ...and filtered to THIS fixture's own temp root. The window bounds time, not authorship:
        // in a parallel run another suite's refusal lands inside it and wins the last-match. `base`
        // carries a per-test UUID and appears in every path the refusal names, so it identifies the
        // writer. Neither assertion below is circular on it — they read the wording and the copy's
        // name, not the root.
        let line = mine.last { $0.contains("at the last check before removal") && $0.contains(base.path) }
        #expect(line?.contains(rName) == true,
                "the gate's refusal was not logged with the copy it kept: “\(line ?? "nil")”")
    }

    // MARK: The merge gate's own verdicts

    @MainActor
    @Test func theMergeGateRefusesACopyThatChangedSinceItWasPlanned() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateUnit")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)

        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        let fold = FileSyncManager.MergeFoldRecord(name: "Red", url: redundant, plannedSnapshot: planned, keeperDestinations: [])

        // The control first, so a gate that refuses everything cannot pass this.
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

    /// The keeper is the other half of the merge's claim: every byte the copy is being trashed for
    /// now lives there. A keeper that left its scanned location turns the copy back into the only
    /// instance, so the gate refuses even though the copy itself never moved.
    @MainActor
    @Test func theMergeGateRefusesEveryFoldWhenTheKeeperLeftItsScannedLocation() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateKeeper")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        let fold = FileSyncManager.MergeFoldRecord(name: "Red", url: redundant, plannedSnapshot: planned, keeperDestinations: [])

        try FileManager.default.removeItem(at: fixture.keeper)
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [redundant.path],
                "the copy was cleared for the Trash with the keeper gone — the folded files are provably nowhere")
    }

    /// Fail CLOSED, the same rule the duplicates gate now follows: a path this gate cannot
    /// attribute to a fold has been re-verified by nothing at all.
    @MainActor
    @Test func theMergeGateRefusesAPathItCannotAttributeToAFold() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateStray")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        let fold = FileSyncManager.MergeFoldRecord(name: "Red", url: redundant, plannedSnapshot: planned, keeperDestinations: [])

        let stray = base.appendingPathComponent("stray.txt").path
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path, stray], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [stray], "a path belonging to no fold was waved through unverified: \(refused)")
    }

    /// The gate must recognize a fold however the caller spelled its path — `deleteItems` feeds the
    /// post-confirmation pass URL round-tripped strings. Same contract as
    /// `RemovalGatePathMatchingTests` pins for the duplicates gate, on the merge's own.
    @MainActor
    @Test func theMergeGateVerifiesAFoldGivenInAnotherSpelling() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateSpelling")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        let fold = FileSyncManager.MergeFoldRecord(name: "Red", url: redundant, plannedSnapshot: planned, keeperDestinations: [])
        try Data(repeating: 0x01, count: 32).write(to: redundant.appendingPathComponent("new.txt"))

        let spelled = redundant.path + "/"
        let refused = await manager.refuseDriftedMergeSources(
            [spelled], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [spelled],
                "a drifted fold asked about in a trailing-slash spelling was not verified: \(refused)")
    }

    // MARK: The keeper-side half of the claim — the destinations the fold actually produced

    /// **The gate's keeper check was a directory-entry check and nothing more.** `keeperStillExists`
    /// is `fileExists(keeper.path) && !copyDriftedInPlace(keeper)`, and `copyDriftedInPlace` returns
    /// false unconditionally for a directory — a merge keeper is always a folder, so the whole
    /// verdict degenerated to "something is still mounted at this path". Measured: an emptied-in-place
    /// keeper produced `refused=[]` and the redundant copy was trashed anyway.
    ///
    /// What the merge knows and was not using: every destination URL its own copy loop wrote, plus
    /// the keeper-side paths `planMerge` matched for the files it SKIPPED as already present. Those
    /// two sets together ARE "every byte this copy is being trashed for now lives in the keeper" —
    /// so both are stat'ed here, and a missing one refuses the fold.
    ///
    /// Trash-less, because that is where the window ends in an unrecoverable delete of the last
    /// instance: the user leaves the confirmation open, something empties the keeper, and without
    /// this check the copy is destroyed outright.
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
            // The keeper is still a folder at its scanned path — only the file the fold just put
            // there is gone. That is exactly what the old check could not see.
            try? FileManager.default.removeItem(at: fixture.keeper.appendingPathComponent("unique0.txt"))
            confirmed.withLock { $0 += 1 }
            return true
        }

        // Windowed: "at the last check before removal" is written by SEVEN call sites, three of
        // which do not contain "no longer", and this suite's own siblings write them too. A
        // last-match read over a per-process log picks whichever ran most recently — which is how
        // this passed under one full-suite ordering and failed under another AND in isolation.
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
        // ...and filtered to THIS fixture's own temp root. The window bounds time, not authorship:
        // in a parallel run another suite's refusal lands inside it and wins the last-match. `base`
        // carries a per-test UUID and appears in every path the refusal names, so it identifies the
        // writer. Neither assertion below is circular on it — they read the wording and the copy's
        // name, not the root.
        let line = mine.last { $0.contains("at the last check before removal") && $0.contains(base.path) }
        #expect(line?.contains("no longer") == true,
                "the keeper-side refusal was not logged: “\(line ?? "nil")”")
    }

    /// The wiring pin for the SKIPPED half, end to end: `unique0.txt` (the file the fold copied)
    /// stays put, and `shared.txt` — which `planMerge` never copied because the keeper already had
    /// it — is removed from the keeper while the confirmation is open. Only a fold record carrying
    /// `plan.vouchedKeeperPaths` can see this; a record built from the copy loop's destinations
    /// alone waves it through.
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
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        // As if the fold had run: the unique file now also lives in the keeper.
        let landed = fixture.keeper.appendingPathComponent("unique0.txt")
        try Data(repeating: 0x60, count: 4000).write(to: landed)
        let fold = FileSyncManager.MergeFoldRecord(
            name: "Red", url: redundant, plannedSnapshot: planned,
            keeperDestinations: [landed.path, fixture.keeper.appendingPathComponent("shared.txt").path])

        // Control first, so a gate that refuses everything cannot pass the pin below.
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

    /// **The skipped half is checked too, and that is a decision worth stating.** A file `planMerge`
    /// never copied — because the keeper provably already had those exact bytes at that exact
    /// relative path — is still part of what the copy is being trashed for. If the keeper's own
    /// instance disappears between the plan and the trash, the redundant copy holds the last one.
    @MainActor
    @Test func theMergeGateRefusesAFoldWhoseAlreadyPresentKeeperFileWentAway() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeGateSkipped")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try makeGroup(base, redundantNames: ["Red"])
        let redundant = fixture.redundant[0]
        let manager = FileSyncManager(fileManager: FileManager.default)
        let planned = FileSyncManager.fileSnapshotsByRelativePath(
            await FileSyncManager.buildTree(url: redundant, sortOption: .name,
                                            fileManager: FileManager.default, maxDepth: nil))
        let shared = fixture.keeper.appendingPathComponent("shared.txt")
        let fold = FileSyncManager.MergeFoldRecord(
            name: "Red", url: redundant, plannedSnapshot: planned, keeperDestinations: [shared.path])

        try FileManager.default.removeItem(at: shared)
        let refused = await manager.refuseDriftedMergeSources(
            [redundant.path], group: fixture.group, folds: [fold],
            refusals: FileSyncManager.MergeRemovalRefusals())

        #expect(refused == [redundant.path],
                "the copy was cleared for the Trash although the keeper's own instance of a plan-skipped file is gone: \(refused)")
    }

    /// `planMerge` must hand the caller the keeper-side path it vouched with, for BOTH skip
    /// branches — the same-relative-path hash match and the retry-idempotence match, whose keeper
    /// file carries a DIFFERENT name. Without the second, a retry's fold is trashed on the strength
    /// of bytes nothing re-checked.
    @Test func planMergeReportsTheKeeperPathsItVouchedWith() async throws {
        let base = try makeCanonicalTempRoot(prefix: "PlanMergeVouched")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("K")
        let redundant = base.appendingPathComponent("R")
        // (a) same content at the same relative path → skipped, vouched by K/same.txt
        try write(keeper.appendingPathComponent("same.txt"), bytes: 700, fill: 0x41)
        try write(redundant.appendingPathComponent("same.txt"), bytes: 700, fill: 0x41)
        // (b) the retry-idempotence skip: the NAME is taken by different content, and the bytes
        //     live in that folder under the uniquified name a previous run minted.
        try write(keeper.appendingPathComponent("dup.txt"), bytes: 300, fill: 0x42)
        try write(keeper.appendingPathComponent("dup 2.txt"), bytes: 900, fill: 0x43)
        try write(redundant.appendingPathComponent("dup.txt"), bytes: 900, fill: 0x43)
        // (c) a genuinely unique file → copied, so it is NOT vouched for here
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
