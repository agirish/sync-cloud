import Foundation
import Testing
@testable import Sync

/// The disk-walk scan starts reading without waiting for the main actor. A main-actor hop before
/// the walk (even just to read a `let`) queues it behind whatever the main actor is doing, usually
/// rendering the tree just published, and the DEBUG `walk` figure, timed after the hop, hides it.
@Suite struct ColdScanStartsOffTheMainActorTests {

    /// Blocks the calling thread until `semaphore` is signalled or `timeout` runs out. Synchronous
    /// on purpose: called from the main actor, it is the hold, so it can't be `awaitSignal`.
    private static func block(theCallingThreadUntil semaphore: DispatchSemaphore,
                              timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }

    /// Holds the main actor, by blocking its thread, from when the scan detaches its walk until the
    /// walk reaches the file manager. A walk that needs the main actor first can't get there, and
    /// the wait runs out. `Task.immediate` runs the scan synchronously to its first suspension and
    /// returns without releasing the main actor, so no hop can slip in before the hold.
    ///
    /// **Red, it holds the main thread for the whole ten seconds**, and every main-actor test waits
    /// with it, so a time-bounded wait elsewhere can go red in the same run: read this one first.
    /// Green, the hold lasts until the walk gets a pool thread, which at suite start can take
    /// seconds of other tests' budgets (`docs/flaky-tests.md`, "Every gate parks at once, on the
    /// pool their releases need").
    @MainActor
    @Test func theColdWalkReachesTheDiskWhileTheMainActorIsHeld() async throws {
        let fm = MockFileManager()
        for dir in ["/left", "/right"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        fm.virtualDisk["/left/only-here.txt"] = .init(isDirectory: false, attributes: nil, contents: nil)
        let reachedTheDisk = DispatchSemaphore(value: 0)
        fm.onEnumerate = { _ in reachedTheDisk.signal() }
        let m = FileSyncManager(fileManager: fm)
        let left = CloudProvider(id: "L", displayName: "L", imageName: "", rootPath: "/left", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "", rootPath: "/right", type: .dropBox)
        #expect(m.prefetchedTrees.isEmpty, "premise: nothing is cached, so the scan walks the disk")

        let scan = Task.immediate {
            await m.scanDirectories(left: left, leftPath: "/left", right: right, rightPath: "/right")
        }
        // Nothing suspends between `isScanning` going up and the walk detaching, so the walk was
        // handed off before the scan handed back. Or the scan already finished: awaiting a done
        // task doesn't suspend, so if the main thread is descheduled after each detach, the scan
        // runs to its end inside `Task.immediate`. That never released the main actor either, so
        // it passes; an enqueued scan is neither.
        #expect(m.isScanning || m.hasScanned, "premise: the scan ran into executeScan before handing back")
        let reached = Self.block(theCallingThreadUntil: reachedTheDisk, timeout: 10)
        await scan.value

        #expect(reached == .success, "the cold walk waited for the main actor before reading the disk")
        #expect(m.hasScanned)
        #expect(m.rawDifferences.map(\.relativePath) == ["only-here.txt"])
    }
}
