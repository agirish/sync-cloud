import Foundation
import Testing
@testable import Sync

/// One process writes, and one Mac: the lock in Application Support, the launch gate, and the
/// marker in Dropbox — here a scratch folder standing in for the Dropbox parent.
@Suite struct OneWaySyncWritersTests {

    // MARK: One process

    @Test func onlyOneHolderAtATime() throws {
        let scratch = OneWayScratch()
        let url = scratch.store.lockURL
        let first = try OneWaySyncProcessLock.acquire(at: url).get()
        // A second open of the file is refused like another process would be: `flock` locks
        // belong to the open file, not the process.
        #expect(throws: OneWaySyncProcessLock.Refusal.heldByAnotherProcess(pid: getpid())) {
            try OneWaySyncProcessLock.acquire(at: url).get()
        }
        first.release()
        let second = try OneWaySyncProcessLock.acquire(at: url).get()
        second.release()
    }

    @Test func aFreedLockIsReleased() throws {
        let url = OneWayScratch().store.lockURL
        do { _ = try OneWaySyncProcessLock.acquire(at: url).get() }
        #expect(throws: Never.self) { try OneWaySyncProcessLock.acquire(at: url).get() }
    }

    /// The kernel lets the lock go with the process, however it ends: a killed holder leaves
    /// nothing to clear.
    @Test func aKilledHolderLeavesNoLock() async throws {
        let url = OneWayScratch().store.lockURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-I", "-c", """
            import fcntl, os, sys, time
            f = open(sys.argv[1], "a+"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(60)
            """, url.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        // Wait for the child to say it holds the lock, for 30 s at most, on `DispatchQueue.global`
        // rather than the cooperative pool: a child that never prints fails the test rather than
        // hanging it.
        let said = Reported()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            said.append(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self))
            read.signal()
        }
        let heard = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { done.resume(returning: read.wait(timeout: .now() + 30) == .success) }
        }
        try #require(heard, "the holder never said it held the lock")
        try #require(said.messages.first?.hasPrefix("held") == true)

        guard case .failure(.heldByAnotherProcess) = OneWaySyncProcessLock.acquire(at: url) else {
            Issue.record("the lock wasn't refused while another process held it")
            return
        }
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        #expect(throws: Never.self) { try OneWaySyncProcessLock.acquire(at: url).get() }
    }

    @Test func aLockThatCantBeOpenedSaysSo() throws {
        let scratch = OneWayScratch()
        let blocker = scratch.url.appendingPathComponent("file")
        try Data().write(to: blocker)
        guard case .failure(.cannotOpen) = OneWaySyncProcessLock.acquire(at: blocker.appendingPathComponent("sync.lock")) else {
            Issue.record("a lock under a file opened")
            return
        }
    }

    @Test func theSyncNeverStartsUnderATestRunner() {
        // This process is one.
        #expect(OneWaySyncLaunchGate.refusalForThisProcess() == .testRunner)
        let app = "/Applications/SyncCloud.app"
        #expect(OneWaySyncLaunchGate.refusal(bundlePath: app, executable: "SyncCloud", environment: [:], xcTestLoaded: false) == nil)
        #expect(OneWaySyncLaunchGate.refusal(bundlePath: app, executable: "swiftpm-testing-helper", environment: [:], xcTestLoaded: false) == .testRunner)
        #expect(OneWaySyncLaunchGate.refusal(bundlePath: app, executable: "xctest", environment: [:], xcTestLoaded: false) == .testRunner)
        #expect(OneWaySyncLaunchGate.refusal(bundlePath: app, executable: "SyncCloud", environment: [:], xcTestLoaded: true) == .testRunner)
        for key in ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"] {
            #expect(OneWaySyncLaunchGate.refusal(bundlePath: app, executable: "SyncCloud", environment: [key: "x"],
                                                 xcTestLoaded: false) == .testRunner)
        }
    }

    @Test(arguments: [
        "/Users/me/Library/Developer/Xcode/DerivedData/SyncCloud-abc/Build/Products/Release/SyncCloud.app",
        "/Users/me/Projects/SyncCloud/.claude/worktrees/x/build/SyncCloud.app",
        "/Applications/Utilities/SyncCloud.app",
        "/Users/me/Applications/SyncCloud.app",
        "/private/var/folders/xy/T/AppTranslocation/1234/d/SyncCloud.app",
        "/Applications/../tmp/SyncCloud.app",
        "/Applications",
    ])
    func theSyncNeverStartsFromACopyOutsideApplications(_ path: String) {
        #expect(OneWaySyncLaunchGate.refusal(bundlePath: path, executable: "SyncCloud", environment: [:], xcTestLoaded: false)
                == .outsideApplications(bundlePath: path))
    }

    // MARK: One Mac

    static let thisMac = OneWaySyncMacMarker(hardwareID: "HW-1", macName: "Studio", claimedAt: 1_790_000_000, lastSyncAt: 1_790_000_600)
    static let otherMac = OneWaySyncMacMarker(hardwareID: "HW-2", macName: "Air", claimedAt: 1_790_000_000, lastSyncAt: 1_790_000_900)

    @Test func theMarkerNamesWhichMacSyncs() throws {
        let scratch = OneWayScratch()
        let marker = OneWaySyncMarkerFile(folder: scratch.url)
        #expect(marker.check(hardwareID: "HW-1") == .missing)
        try marker.write(Self.thisMac)
        #expect(marker.check(hardwareID: "HW-1") == .thisMac(Self.thisMac))
        #expect(marker.check(hardwareID: "HW-2") == .otherMac(Self.thisMac))
        // A Mac whose own ID couldn't be read is never the one named.
        #expect(marker.check(hardwareID: "") == .otherMac(Self.thisMac))
        // A dot file, alone in the folder: nothing temporary left behind.
        #expect(scratch.names(in: scratch.url) == [".SyncCloud One-Way Sync.json"])
        #expect(!OneWaySyncMarkerFile.fileName.hasPrefix(".SyncCloud-"))
    }

    @Test func aConflictedCopyOfTheMarkerStopsEveryMac() throws {
        let scratch = OneWayScratch()
        let marker = OneWaySyncMarkerFile(folder: scratch.url)
        try marker.write(Self.thisMac)
        let copy = ".SyncCloud One-Way Sync (Air’s conflicted copy 2026-10-30).json"
        try OneWaySyncStore.encode(Self.otherMac).write(to: scratch.url.appendingPathComponent(copy))
        // Something else that says "conflict" isn't one.
        try Data().write(to: scratch.url.appendingPathComponent("Notes (conflicted copy).txt"))
        #expect(marker.check(hardwareID: "HW-1") == .conflicted([copy]))
        #expect(marker.check(hardwareID: "HW-2") == .conflicted([copy]))

        // Sync From This Mac Instead.
        try marker.claim(Self.otherMac)
        #expect(marker.check(hardwareID: "HW-2") == .thisMac(Self.otherMac))
        #expect(scratch.names(in: scratch.url) == [".SyncCloud One-Way Sync.json", "Notes (conflicted copy).txt"])
    }

    @Test func aMarkerThisBuildCantReadNamesNoMac() throws {
        let scratch = OneWayScratch()
        let marker = OneWaySyncMarkerFile(folder: scratch.url)
        for bytes in ["nonsense", #"{"version":2,"hardwareID":"HW-1","macName":"x","claimedAt":1}"#,
                      #"{"version":1,"hardwareID":"","macName":"x","claimedAt":1}"#] {
            try Data(bytes.utf8).write(to: marker.url)
            #expect(marker.check(hardwareID: "HW-1") == .unreadable)
        }
        try marker.remove()
        #expect(marker.check(hardwareID: "HW-1") == .missing)
    }

    // MARK: Starting

    static let firstRun = UUID()
    static let ready = OneWaySyncSavedRecord.ready(OneWaySyncRecordTests.record, firstRun: firstRun, state: OneWaySyncSavedState())

    @Test func aSyncStartsOnlyWithEverythingInPlace() throws {
        let scratch = OneWayScratch()
        let lock = try OneWaySyncProcessLock.acquire(at: scratch.store.lockURL)
        defer { (try? lock.get())?.release() }
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: Self.ready, marker: .thisMac(Self.thisMac))
                == .ready(OneWaySyncRecordTests.record, firstRun: Self.firstRun, state: OneWaySyncSavedState()))
    }

    @Test func aMarkerThatCantBeReadNowWaitsRatherThanAskingForAFirstRun() throws {
        let scratch = OneWayScratch()
        let gone = OneWaySyncMarkerFile(folder: scratch.url.appendingPathComponent("Dropbox gone"))
        #expect(gone.check(hardwareID: "HW-1") == .cannotRead)
        let marker = OneWaySyncMarkerFile(folder: scratch.url)
        try marker.write(Self.thisMac)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.url.path) }
        #expect(marker.check(hardwareID: "HW-1") == .cannotRead)

        let lock = try OneWaySyncProcessLock.acquire(at: scratch.store.lockURL)
        defer { (try? lock.get())?.release() }
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: Self.ready, marker: .cannotRead) == .markerUnavailable)
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: .cannotConfirm(.otherICloudAccount),
                                              marker: .thisMac(Self.thisMac)) == .cannotConfirm(.otherICloudAccount))
    }

    @Test func whatStopsASyncFirstIsWhatItSays() throws {
        let scratch = OneWayScratch()
        let lock = try OneWaySyncProcessLock.acquire(at: scratch.store.lockURL)
        defer { (try? lock.get())?.release() }
        let ok = OneWaySyncMarkerCheck.thisMac(Self.thisMac)
        let held = Result<OneWaySyncProcessLock, OneWaySyncProcessLock.Refusal>.failure(.heldByAnotherProcess(pid: 42))
        #expect(OneWaySyncStartCheck.evaluate(refusal: .testRunner, lock: held, record: Self.ready, marker: ok) == .refused(.testRunner))
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: held, record: Self.ready, marker: ok) == .anotherProcessSyncs(pid: 42))
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: .failure(.cannotOpen(errno: EACCES)), record: Self.ready, marker: ok)
                == .lockUnavailable(errno: EACCES))
        // Another Mac's claim, even over a record that would also need a new first run.
        let lost = OneWaySyncSavedRecord.needsNewFirstRun(.otherMac)
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: lost, marker: .otherMac(Self.otherMac))
                == .otherMacSyncs(Self.otherMac))
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: lost, marker: .conflicted(["x"])) == .twoMacsClaim(["x"]))
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: lost, marker: ok) == .needsNewFirstRun(.otherMac))
        // A missing marker beside a good record: never a first run on its own.
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: Self.ready, marker: .missing) == .needsNewFirstRun(.noMarker))
        #expect(OneWaySyncStartCheck.evaluate(refusal: nil, lock: lock, record: Self.ready, marker: .unreadable) == .needsNewFirstRun(.unreadable))
    }
}
