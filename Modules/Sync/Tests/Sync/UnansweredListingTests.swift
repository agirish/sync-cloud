import Foundation
import Testing
@testable import Sync

/// **Every listing asks a dataless folder through the reads, not just the two walks** — see
/// `FileSyncManager.DatalessFolderReads` and `FileManaging.listing(of:)`.
///
/// The walks were guarded first (`UnansweredFolderTests`). Everything else that lists a folder goes
/// through the shared `listing(of:)` / `childCount(of:)`, or did a bare `contentsOfDirectory`, and
/// each of those blocked on a folder whose cloud app is not running exactly as the walk did: the
/// destination picker's column and its search, the move undo's identity (on the MAIN actor), the
/// copy undo's deep identity, a folder merge, the filing renamer, Look for Names, Edit's file rail
/// and the filing card's item count.
///
/// The disk is `UnansweredFolderDisk`: one folder is dataless and listing it parks until the test
/// lets the provider answer. Each case holds the folder unanswered, asserts the caller came back
/// within a bound far below the park's own, and only then releases it.
@Suite struct UnansweredListingTests {

    /// One tree per test, under a root of its own — the registry is keyed by path, and parallel
    /// cases must not answer each other's folders.
    struct Shelf {
        let root: String
        var cloud: String { root + "/Cloud" }
        var unanswered: String { root + "/Cloud/Archive" }

        func disk(gate: ParkGate,
                  reads: FileSyncManager.DatalessFolderReads = .init(deadline: .milliseconds(250))) throws -> UnansweredFolderDisk {
            let mock = MockFileManager()
            for dir in ["", "/Cloud", "/Cloud/Archive", "/Cloud/Archive/Old Things", "/Cloud/Docs",
                        "/Cloud/Docs/Old Notes", "/People", "/People/Granny"] {
                try mock.createDirectory(at: URL(fileURLWithPath: root + dir), withIntermediateDirectories: true)
            }
            for file in ["/Cloud/Archive/old.txt", "/Cloud/Docs/b.txt", "/People/Granny/Granny Elder - 2015.pdf"] {
                mock.setStub(MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1], contents: nil),
                             at: root + file)
            }
            return UnansweredFolderDisk(inner: mock, unanswered: unanswered, gate: gate, reads: reads)
        }
    }

    /// Runs `body` where production runs these listings — off the main actor, on the pool.
    ///
    /// **"In time" is asserted as "while the provider is still parked", not against a clock.** The
    /// park lasts until the test releases it (or two minutes); a caller that asks through the reads
    /// returns after their deadline with the provider still parked, one that blocks on the provider
    /// returns only once the park ends. A wall-clock bound measured the machine instead: in a full
    /// FileExplorer run, cases that never park at all took 43 s.
    static func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached { body() }.value
    }

    /// Lets the provider answer and waits for the read it was holding to come back.
    static func release(_ gate: ParkGate, _ disk: UnansweredFolderDisk, _ path: String,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        gate.release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while disk.datalessFolderReads.isOutstanding(path), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!disk.datalessFolderReads.isOutstanding(path), "the late answer never came back",
                sourceLocation: sourceLocation)
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered",
                     sourceLocation: sourceLocation)
    }

    // MARK: - The shared listing

    /// **A listing of the folder comes back unanswered — unknown, not empty — and the provider is
    /// asked off the pool, once.** A second listing is refused at once rather than asking again.
    @Test(.parksAThread) func aListingOfAFolderThatNeverAnswersComesBackUnanswered() async throws {
        let shelf = Shelf(root: "/listing")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)
        let url = URL(fileURLWithPath: shelf.unanswered)

        let listing = await Self.offThePool { disk.listing(of: url) }
        #expect(gate.isParked, "the provider answered — this measured a folder that answered")
        #expect(listing.outcome == .unreadable)
        #expect(listing.isUnanswered, "an unanswered folder must say so, not pass as a locked one")
        #expect(listing.urls.isEmpty)
        #expect(disk.providerReads == 1)
        let queues = disk.providerReadQueues
        #expect(queues.allSatisfy { $0.contains("dataless-folder-reads") },
                "the provider was asked on \(queues), not on the reads' own queue")

        let again = await Self.offThePool { disk.listing(of: url) }
        #expect(again.isUnanswered)
        #expect(disk.providerReads == 1, "a second listing asked the provider again")

        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **A recursive listing steps around the folder.** The enumerator reads a folder's contents on
    /// the call after the one that yielded it, so without a `skipDescendants()` there it asks the
    /// provider inline. The folder's own entry is there; nothing under it is; it is named as the
    /// part withheld.
    @Test(.parksAThread) func aRecursiveListingStepsAroundAFolderThatNeverAnswers() async throws {
        let shelf = Shelf(root: "/recursive")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)
        let cloud = URL(fileURLWithPath: shelf.cloud)

        let listing = await Self.offThePool { disk.listing(of: cloud, options: []) }
        #expect(gate.isParked)
        #expect(listing.outcome == .listedWithUnreadableDescendants)
        #expect(listing.unreadableDescendants.map(\.path) == [shelf.unanswered])
        let paths = Set(listing.urls.map(\.path))
        #expect(paths.contains(shelf.unanswered), "the folder's own entry is real and was dropped")
        #expect(paths.contains(shelf.cloud + "/Docs/b.txt"), "the folder beside it was not walked")
        #expect(!paths.contains(shelf.unanswered + "/old.txt"), "listed inside a folder nobody read")

        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **A dataless folder whose provider answers is listed in full — the healthy case, and the
    /// one a read that asked through the reads ITSELF would break:** it would join its own read and
    /// wait out the deadline, so every dataless folder would come back unanswered. The deadline here
    /// is a minute, so that mistake shows as a wait, not as a pass.
    @Test(.parksAThread) func aDatalessFolderWhoseProviderAnswersIsListedInFull() async throws {
        let shelf = Shelf(root: "/answers")
        let gate = ParkGate()
        gate.release.signal()                       // the provider answers at once
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(60)))
        let cloud = URL(fileURLWithPath: shelf.cloud)

        let listing = await Self.offThePool { disk.listing(of: cloud, options: []) }
        #expect(listing.outcome == .listed)
        #expect(Set(listing.urls.map(\.path)).contains(shelf.unanswered + "/old.txt"),
                "the answered folder's contents are missing")
        #expect(disk.providerReads == 1)
        #expect(gate.didPark, "the provider was never asked — this measured a materialized folder")
        #expect(!gate.releasedByTimeout)
    }

    /// The same pair for a shallow listing of the folder itself.
    @Test(.parksAThread) func aDatalessFolderThatAnswersListsItsChildren() async throws {
        let shelf = Shelf(root: "/answers-shallow")
        let gate = ParkGate()
        gate.release.signal()
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(60)))

        let listing = await Self.offThePool { disk.listing(of: URL(fileURLWithPath: shelf.unanswered)) }
        #expect(listing.outcome == .listed)
        #expect(Set(listing.urls.map(\.lastPathComponent)) == ["Old Things", "old.txt"])
        #expect(gate.didPark)
    }

    /// **A count is a listing too** — the folder-replace warning's `childCount`. The folder itself
    /// is unreadable; a count of its parent counts around it and says it is a floor.
    @Test(.parksAThread) func aCountStepsAroundAFolderThatNeverAnswers() async throws {
        let shelf = Shelf(root: "/count")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let root = await Self.offThePool {
            disk.childCount(of: URL(fileURLWithPath: shelf.unanswered), options: [], cap: 100)
        }
        #expect(root == DirectoryChildCount(count: 0, outcome: .unreadable, isCapped: false))
        #expect(gate.isParked, "it came back only once the provider answered")

        let around = await Self.offThePool {
            disk.childCount(of: URL(fileURLWithPath: shelf.cloud), options: [], cap: 100)
        }
        // Archive, Docs, Docs/b.txt and Docs/Old Notes — and nothing from inside Archive.
        #expect(around == DirectoryChildCount(count: 4, outcome: .listedWithUnreadableDescendants, isCapped: false))
        #expect(disk.providerReads == 1)

        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// The control for the count: once the provider has answered, the folder is counted inside.
    @Test(.parksAThread) func aCountOfAFolderThatAnswersCountsItsContents() async throws {
        let shelf = Shelf(root: "/count-answers")
        let gate = ParkGate()
        gate.release.signal()
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(60)))

        let count = await Self.offThePool {
            disk.childCount(of: URL(fileURLWithPath: shelf.cloud), options: [], cap: 100)
        }
        #expect(count == DirectoryChildCount(count: 6, outcome: .listed, isCapped: false))
    }

    /// **What the guard reads off the real enumerator: every folder it yields is marked as one**,
    /// spelled absolutely (`childCount`) or relatively (`listing`). The recursive guards ask
    /// `isDataless` only of entries marked so — a folder that came back unmarked would be walked
    /// into, provider and all. Measured 2026-10-15 and pinned here, on the real disk.
    @Test func theRealEnumeratorMarksEveryFolderItYields() throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("a/f.txt"))
        for options: FileManager.DirectoryEnumerationOptions in [[], [.producesRelativePathURLs]] {
            let walk = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil, options: options))
            var seen = 0
            for case let entry as URL in walk {
                seen += 1
                var isDirectory: ObjCBool = false
                #expect(fm.fileExists(atPath: entry.path, isDirectory: &isDirectory))
                #expect(entry.hasDirectoryPath == isDirectory.boolValue,
                        "\(entry.relativePath) under options \(options.rawValue)")
            }
            #expect(seen == 3)
        }
    }

    // MARK: - Asking without holding a thread

    /// **`waitForContents` suspends; it does not block.** Run on an executor with ONE thread, a job
    /// queued behind it still runs while the provider is being asked — which a caller blocked on
    /// the answer would not let happen. The listing's own wait is the control: it does block.
    @Test(.parksAThread) func waitingForAFolderThatNeverAnswersHoldsNoThread() async throws {
        let shelf = Shelf(root: "/suspends")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(300)))
        let url = URL(fileURLWithPath: shelf.unanswered)

        let suspends = await OneThreadExecutor.letsAnotherJobRun(whileWaitingOn: gate) {
            await disk.waitForContents(of: url)
        }
        #expect(suspends.ranWhileWaiting, "the wait held the only thread it had")
        #expect(suspends.value, "the provider answered, and the wait did not say so")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// The control: the synchronous listing DOES hold its thread for the deadline — so the test
    /// above can tell the two apart, and is not passing because the executor runs everything.
    @Test(.parksAThread) func theSynchronousListingHoldsItsThreadForTheDeadline() async throws {
        let shelf = Shelf(root: "/blocks")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(300)))
        let url = URL(fileURLWithPath: shelf.unanswered)

        let blocks = await OneThreadExecutor.letsAnotherJobRun(whileWaitingOn: gate) {
            disk.listing(of: url).outcome
        }
        #expect(!blocks.ranWhileWaiting, "the harness cannot see a blocked thread")
        #expect(blocks.value == .listed, "the listing did not wait for the provider's answer")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    // MARK: - The destination picker

    @Test(.parksAThread) func thePickersColumnSaysCantBeReadRatherThanLoadingForever() async throws {
        let shelf = Shelf(root: "/picker")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let column = await Self.offThePool {
            DestinationBrowser.listSubfolders(of: shelf.unanswered, fileManager: disk)
        }
        #expect(column.outcome == .unreadable)
        #expect(gate.isParked, "it came back only once the provider answered")
        #expect(column.emptyMessage == "Can’t be read")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// The column load the picker actually runs suspends while the provider is asked.
    @Test(.parksAThread) func thePickersColumnLoadHoldsNoThreadWhileItAsks() async throws {
        let shelf = Shelf(root: "/picker-suspends")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate, reads: .init(deadline: .seconds(300)))

        let load = await OneThreadExecutor.letsAnotherJobRun(whileWaitingOn: gate) {
            await DestinationBrowser.listSubfoldersSuspending(of: shelf.unanswered, fileManager: disk)
        }
        #expect(load.ranWhileWaiting, "the column load held its thread while the provider was asked")
        #expect(load.value.folders.map(\.name) == ["Old Things"], "the answered folder was not listed")
        #expect(disk.providerReads == 1, "the listing after the ask asked the provider again")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **Search walks past the folder and says it could not look inside.** It finds the match
    /// beside it, never the one within, and its footnote says some folders could not be read.
    @Test(.parksAThread) func thePickersSearchWalksPastAFolderThatNeverAnswers() async throws {
        let shelf = Shelf(root: "/search")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let found = await Self.offThePool {
            DestinationBrowser.search("Old", under: shelf.root, fileManager: disk)
        }
        #expect(found.matches.map(\.path) == [shelf.cloud + "/Docs/Old Notes"])
        #expect(gate.isParked, "it came back only once the provider answered")
        #expect(found.skippedUnreadableDirectory, "the search claimed it looked everywhere")
        #expect(!found.stoppedEarly)
        try await Self.release(gate, disk, shelf.unanswered)
    }

    // MARK: - Undo's identities

    /// **The move undo takes its identity on the MAIN actor** — `registerMoveUndo` is synchronous,
    /// and Rename, Move and Filing all call it there. A folder that did not answer froze the app.
    @MainActor
    @Test(.parksAThread) func registeringAMoveOfAFolderThatNeverAnswersDoesNotFreezeTheMainActor() async throws {
        let shelf = Shelf(root: "/move-undo")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)
        let manager = FileSyncManager(fileManager: disk)

        manager.registerMoveUndo(items: [(from: URL(fileURLWithPath: shelf.root + "/Elsewhere"),
                                          to: URL(fileURLWithPath: shelf.unanswered), overwritten: nil)],
                                 actionName: "Move 1 Item", fileManager: disk)
        #expect(gate.isParked, "the main actor came back only once the provider answered")
        #expect(ItemIdentity.snapshot(at: URL(fileURLWithPath: shelf.unanswered), fileManager: disk) == .indeterminate,
                "a folder nobody could read has no identity to vouch for")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **The copy undo's deep identity walks the whole tree** — and a dataless folder anywhere in
    /// it stopped the walk. It refuses instead, naming the folder: a tree it could not read
    /// cannot vouch for an undo.
    @Test(.parksAThread) func aDeepIdentityRefusesAtAFolderThatNeverAnswers() async throws {
        let shelf = Shelf(root: "/deep-identity")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let identity = await Self.offThePool {
            ItemIdentity.deepSnapshotDetailingFailure(at: URL(fileURLWithPath: shelf.cloud), fileManager: disk)
        }
        #expect(identity.identity == .indeterminate)
        #expect(gate.isParked, "it came back only once the provider answered")
        #expect(identity.unreadableDescendant?.path == shelf.unanswered)
        try await Self.release(gate, disk, shelf.unanswered)
    }

    // MARK: - Folder merge

    /// **A merge cannot read the folder, and says why** — not "you don't have permission".
    @Test(.parksAThread) func aMergeOfAFolderThatNeverAnswersFailsAsUnanswered() async throws {
        let shelf = Shelf(root: "/merge")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let thrown = await Self.offThePool { () -> FileSyncManager.FileOperationError? in
            do {
                _ = try FileSyncManager.mergeChildren(of: URL(fileURLWithPath: shelf.unanswered), fileManager: disk)
                return nil
            } catch let error as FileSyncManager.FileOperationError {
                return error
            } catch {
                return nil
            }
        }
        #expect(thrown == .folderNotAnswered(folderName: "Archive"))
        #expect(gate.isParked, "it came back only once the provider answered")
        #expect(thrown?.errorDescription?.contains("didn’t answer") == true)
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **The collision alert's count does not ask the provider at all.** It has a second to count
    /// in before the alert opens; a dataless folder would spend five times that waiting. It gives
    /// up instead — the alert says its sentence without numbers.
    @Test(.parksAThread) func theMergePreviewGivesUpAtAFolderThatIsNotOnThisMac() async throws {
        let shelf = Shelf(root: "/merge-preview")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let preview = await Self.offThePool {
            FileSyncManager.folderMergePreview(source: URL(fileURLWithPath: shelf.unanswered),
                                               destination: URL(fileURLWithPath: shelf.cloud + "/Docs"),
                                               fileManager: disk)
        }
        #expect(preview == nil, "counted a folder whose contents are not on this Mac")
        #expect(disk.providerReads == 0, "the preview asked the provider before the alert could open")
        gate.release.signal()
    }

    /// The other half of that rule: a folder the preview cannot read at all ends the count too,
    /// instead of being skipped — a count that leaves it out is a number the app made up.
    @Test func theMergePreviewGivesUpAtAFolderItCannotRead() throws {
        let mock = MockFileManager()
        for dir in ["/mp/src/F", "/mp/src/F/Locked", "/mp/dst/F"] {
            try mock.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        for file in ["/mp/src/F/a.txt", "/mp/src/F/Locked/x.txt", "/mp/dst/F/a.txt"] {
            mock.setStub(MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1], contents: nil), at: file)
        }
        let src = URL(fileURLWithPath: "/mp/src/F"), dst = URL(fileURLWithPath: "/mp/dst/F")
        // Readable, the count is real: a.txt collides, nothing is only in the destination.
        #expect(FileSyncManager.folderMergePreview(source: src, destination: dst, fileManager: mock)
                == FolderMergePreview(destinationOnlyCount: 0, collidingCount: 1))
        mock.unlistableDirectories.insert("/mp/src/F/Locked")
        #expect(FileSyncManager.folderMergePreview(source: src, destination: dst, fileManager: mock) == nil,
                "counted around a folder it could not read")
    }

    // MARK: - Filing

    /// The renamer re-reads a destination before numbering into it; a folder that did not answer
    /// has no live contents to number against.
    @Test(.parksAThread) func theRenamersLiveReadOfAFolderThatNeverAnswersIsNil() async throws {
        let shelf = Shelf(root: "/rename")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)

        let files = await Self.offThePool {
            FileSyncManager.liveFiles(in: URL(fileURLWithPath: shelf.unanswered), fileManager: disk)
        }
        #expect(files == nil)
        #expect(gate.isParked, "it came back only once the provider answered")
        try await Self.release(gate, disk, shelf.unanswered)
    }

    /// **Look for Names skips the folder and reads the rest** — "a person's folder living on an
    /// evicted iCloud path is an ordinary state" is the scanner's own premise.
    @Test(.parksAThread) func lookForNamesSkipsAFolderThatNeverAnswers() async throws {
        let shelf = Shelf(root: "/people")
        let gate = ParkGate()
        let disk = try shelf.disk(gate: gate)
        let profile = PeopleNameScannerTests.profile(folders: [("Cloud/Archive", "Granny"),
                                                               ("People/Granny", "Granny")])

        let names = await Self.offThePool {
            PeopleNameScanner.fileNames(registry: PeopleNameScannerTests.household, profile: profile,
                                        root: URL(fileURLWithPath: shelf.root), fileManager: disk)
        }
        #expect(names["Cloud/Archive"] == nil)
        #expect(gate.isParked, "it came back only once the provider answered")
        #expect(names["People/Granny"] == ["Granny Elder - 2015.pdf"],
                "the folder that did not answer stopped the sweep reaching the one that did")
        try await Self.release(gate, disk, shelf.unanswered)
    }
}

/// A task executor with ONE thread, so whether an async call SUSPENDS or BLOCKS while it waits is
/// visible from outside: a job queued behind a suspended call runs; behind a blocked one it cannot.
final class OneThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "UnansweredListingTests.one-thread")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Runs `body` on a fresh one-thread executor and, once `gate` says the provider is being
    /// asked, queues a second job on the same thread. The provider answers only AFTER that job has
    /// had five seconds to run — so a blocked `body` keeps it out for the whole five, and a load
    /// spike cannot let `body` finish first and pass for one that suspended. No deadline is raced:
    /// give `body`'s reads one far longer than the test.
    static func letsAnotherJobRun<T: Sendable>(
        whileWaitingOn gate: ParkGate,
        _ body: @escaping @Sendable () async -> T
    ) async -> (ranWhileWaiting: Bool, value: T) {
        let executor = OneThreadExecutor()
        let finished = LockedBox(false)
        let waiting = Task(executorPreference: executor) { () -> T in
            let value = await body()
            finished.withLock { $0 = true }
            return value
        }
        await awaitSignal(gate.entered, timeout: 60, "the provider was never asked")
        let ran = DispatchSemaphore(value: 0)
        let sawItUnfinished = LockedBox(false)
        let probe = Task(executorPreference: executor) {
            let unfinished = !finished.withLock { $0 }
            sawItUnfinished.withLock { $0 = unfinished }
            ran.signal()
        }
        let ranInTime = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { done.resume(returning: ran.wait(timeout: .now() + 5) == .success) }
        }
        gate.release.signal()               // the provider answers, whichever way that went
        await probe.value
        let value = await waiting.value
        return (ranInTime && sawItUnfinished.withLock { $0 }, value)
    }
}
