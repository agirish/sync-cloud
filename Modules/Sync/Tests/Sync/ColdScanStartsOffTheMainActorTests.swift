import Foundation
import Testing
@testable import Sync

/// **The disk-walk scan starts reading without waiting for the main actor.**
///
/// Its detached walk opened with `await MainActor.run { self.fileManager }` — a hop to read a
/// `let` — so it queued behind whatever the main actor was doing, typically rendering the tree just
/// published: a median ~60 ms on his log, 830 ms once. The walk's clock started after the hop, so
/// the DEBUG `walk` figure never showed the wait.
@Suite struct ColdScanStartsOffTheMainActorTests {

    /// Blocks the calling thread until `semaphore` is signalled or `timeout` runs out. Synchronous on
    /// purpose: called from the main actor it is the hold, which is why it cannot be `awaitSignal`.
    private static func block(theCallingThreadUntil semaphore: DispatchSemaphore,
                              timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }

    /// Holds the main actor — by blocking its thread — from the moment the scan has detached its walk
    /// until the walk reaches the file manager. A walk that needs the main actor first cannot get
    /// there, and the wait runs out instead.
    ///
    /// `Task.immediate` is what makes the hold airtight: it runs the scan synchronously up to its
    /// first suspension — the await on the detached walk — and returns here without ever releasing
    /// the main actor, so there is no window in which a hop could slip through before the hold.
    ///
    /// **Red, it holds the main thread for the whole ten seconds**, and every main-actor test in the
    /// run waits with it — so a time-bounded wait elsewhere can go red in the same run. Read this
    /// one first. Green, the hold lasts as long as the walk takes to start: normally no time at
    /// all, but the walk needs a pool thread, so at suite start, where every gate can park at once
    /// on the pool (docs/flaky-tests.md), the hold can stretch to seconds and spend other main-actor
    /// tests' wall-clock budgets with it.
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
        // Nothing suspends between `isScanning` going up and the walk detaching, so this is the
        // walk having been handed off before the scan handed back.
        #expect(m.isScanning, "premise: the scan ran into executeScan before handing back")
        let reached = Self.block(theCallingThreadUntil: reachedTheDisk, timeout: 10)
        await scan.value

        #expect(reached == .success, "the cold walk waited for the main actor before reading the disk")
        #expect(m.hasScanned)
        #expect(m.rawDifferences.map(\.relativePath) == ["only-here.txt"])
    }
}
