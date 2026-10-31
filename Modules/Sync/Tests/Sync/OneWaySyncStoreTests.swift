import Foundation
import Testing
@testable import Sync

/// A scratch folder per test, removed after: nothing here touches iCloud, Dropbox or the real
/// Application Support.
final class OneWayScratch {
    let url: URL

    init(_ name: String = #function) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneWaySync-\(name.prefix(40))-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // A test may leave a folder read-only to make a write fail.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    var store: OneWaySyncStore { OneWaySyncStore(directory: url.appendingPathComponent("One-Way Sync")) }

    func names(in folder: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? store.directory).path)) ?? []).sorted()
    }
}

/// The record, the state beside it, and the files you stopped syncing, as saved in Application
/// Support: versioned, written whole, tied to this Mac, the accounts and the disk.
@Suite struct OneWaySyncStoreTests {

    static let state = OneWaySyncSavedState(
        settings: OneWaySyncSettings(whenDeletedRenamedOrMoved: .askMe, whenEdited: .useICloud),
        window: OneWaySyncRemovalWindow(changes: [.init(file: 7, folder: 1001, kind: .replaced, seenAt: 1_790_000_000)]),
        pausedSince: 1_790_000_500, lastSyncAt: 1_790_000_400, knownUnsyncedFolders: ["Work"], confirmed: [3, 9])

    @Test func aSavedRecordComesBackWithItsFirstRunAndState() throws {
        let scratch = OneWayScratch()
        let store = scratch.store
        let record = OneWaySyncRecordTests.record
        let firstRun = try store.startFirstRun(record, state: Self.state)

        #expect(store.loadRecord(on: OneWayWorld.binding) == .ready(record, firstRun: firstRun, state: Self.state))
        // The engine's own reader takes the same file: the first run's key beside the record's
        // is ignored, and the bytes are still sorted.
        let data = try Data(contentsOf: store.recordURL)
        #expect(OneWaySyncRecord.load(data, on: OneWayWorld.binding) == .ready(record))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["firstRun"] as? String == firstRun.uuidString)
        // Nothing but the two files: no temporary file left behind.
        #expect(scratch.names() == ["record.json", "state.json"])
    }

    @Test func aSyncKeepsTheFirstRunAndANewFirstRunReplacesIt() throws {
        let store = OneWayScratch().store
        var record = OneWaySyncRecordTests.record
        let first = try store.startFirstRun(record, state: Self.state)
        record.nextKey += 5
        try store.saveRecord(record, firstRun: first)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .ready(record, firstRun: first, state: Self.state))

        let second = try store.startFirstRun(record, state: Self.state)
        #expect(second != first)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .ready(record, firstRun: second, state: Self.state))
    }

    @Test(arguments: [
        OneWaySyncNewFirstRunReason.otherMac, .otherICloudAccount, .otherDropboxAccount, .otherDisk,
    ])
    func aRecordFromAnotherMacAccountOrDiskNeedsANewFirstRun(_ reason: OneWaySyncNewFirstRunReason) throws {
        let field: WritableKeyPath<OneWaySyncBinding, String>
        switch reason {
        case .otherMac: field = \.hardwareID
        case .otherICloudAccount: field = \.iCloudAccount
        case .otherDropboxAccount: field = \.dropboxAccountFolder
        default: field = \.dataVolumeUUID
        }
        let store = OneWayScratch().store
        let firstRun = try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        var other = OneWayWorld.binding
        other[keyPath: field] = "elsewhere"
        #expect(store.loadRecord(on: other) == .needsNewFirstRun(reason))
        // It was never run on its own: the record on disk is untouched.
        #expect(store.loadRecord(on: OneWayWorld.binding) == .ready(OneWaySyncRecordTests.record, firstRun: firstRun, state: Self.state))
        // A value this Mac can't read just now (iCloud signed out) confirms nothing either way:
        // the sync waits, and no first run is asked for.
        other[keyPath: field] = ""
        #expect(store.loadRecord(on: other) == .cannotConfirm(reason))
    }

    /// A first run cut short never leaves the old record beside the new state, which would read
    /// as ready: here the state's write fails after the old record went.
    @Test func aFirstRunCutShortLeavesNoOldRecordToRun() throws {
        let store = OneWayScratch().store
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        try FileManager.default.removeItem(at: store.stateURL)
        // A folder where the state goes: its write can't land.
        try FileManager.default.createDirectory(at: store.stateURL.appendingPathComponent("x"), withIntermediateDirectories: true)
        var newer = OneWaySyncRecordTests.record
        newer.nextKey += 1
        #expect(throws: (any Error).self) { try store.startFirstRun(newer, state: OneWaySyncSavedState()) }
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.noRecord))
    }

    @Test func aRecordWithoutItsStateIsSyncDataLost() throws {
        let store = OneWayScratch().store
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.noRecord))

        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        try FileManager.default.removeItem(at: store.stateURL)
        // Not the defaults: Pause would read as running.
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))

        try Data("{".utf8).write(to: store.stateURL)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))
    }

    @Test func aDamagedOrNewerRecordNeedsANewFirstRun() throws {
        let store = OneWayScratch().store
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.recordURL)) as! [String: Any]
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: store.recordURL)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unsupportedVersion(2)))

        json["version"] = 1
        json["firstRun"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: store.recordURL)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))

        try Data("garbage".utf8).write(to: store.recordURL)
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))
    }

    @Test func aRecordThatCantBeOpenedIsUnreadableNotMissing() throws {
        let store = OneWayScratch().store
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.recordURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.recordURL.path) }
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))
    }

    @Test func pauseAndTheSettingsSurviveAQuit() throws {
        let store = OneWayScratch().store
        #expect(store.loadState() == .ready(OneWaySyncSavedState()))
        try store.saveState(Self.state)
        // A second store on the same folder is the next launch.
        #expect(OneWaySyncStore(directory: store.directory).loadState() == .ready(Self.state))

        try Data("{\"version\":2}".utf8).write(to: store.stateURL)
        #expect(store.loadState() == .unreadable)
    }

    @Test func filesYouStoppedSyncingOutliveTheRecord() throws {
        let store = OneWayScratch().store
        #expect(store.loadExclusions() == .ready(OneWaySyncExclusions()))
        let exclusions = OneWaySyncExclusions(files: [
            OneWaySyncExclusion(iCloudPath: "Legal/POA.pdf", dropboxPath: "Legal/POA.pdf", iCloudID: 4, dropboxID: 10_004,
                                stoppedAt: 1_790_000_000),
        ])
        try store.saveExclusions(exclusions)
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        try store.removeRecord()
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        #expect(store.loadExclusions() == .ready(exclusions))

        try Data("[]".utf8).write(to: store.exclusionsURL)
        // Unreadable never reads as none: that would sync the file the user held back.
        #expect(store.loadExclusions() == .unreadable)
    }

    @Test func turnOffRemovesTheRecordAndState() throws {
        let scratch = OneWayScratch()
        let store = scratch.store
        try store.startFirstRun(OneWaySyncRecordTests.record, state: Self.state)
        try store.removeRecord()
        #expect(store.loadRecord(on: OneWayWorld.binding) == .needsNewFirstRun(.noRecord))
        #expect(scratch.names() == [])
        // Twice is fine.
        try store.removeRecord()
    }

    /// A write that fails leaves the old file whole: the folder can't take the temporary file.
    @Test func aFailedWriteLeavesTheOldFile() throws {
        let scratch = OneWayScratch()
        let store = scratch.store
        try store.saveState(Self.state)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path) }
        #expect(throws: (any Error).self) { try store.saveState(OneWaySyncSavedState()) }
        #expect(store.loadState() == .ready(Self.state))
    }

    @Test func thisMacsBindingIsRead() {
        let binding = OneWaySyncBinding.current(dropboxAccountFolder: "/Users/me/Library/CloudStorage/Dropbox")
        // IOPlatformUUID and the Data volume are there on every Mac; the iCloud account only
        // while signed in, so it isn't asserted.
        #expect(UUID(uuidString: binding.hardwareID) != nil)
        #expect(UUID(uuidString: binding.dataVolumeUUID) != nil)
        #expect(binding.dropboxAccountFolder == "/Users/me/Library/CloudStorage/Dropbox")
        #expect(binding.iCloudAccount.isEmpty || binding.iCloudAccount.count == 64)
        // Read twice, the same: a binding that changed between launches would ask for a new
        // first run every time.
        #expect(OneWaySyncBinding.current(dropboxAccountFolder: binding.dropboxAccountFolder) == binding)
    }
}
