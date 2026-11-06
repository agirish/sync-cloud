import Foundation
import Testing
@testable import Sync

/// The record is versioned and tied to this Mac, both accounts and the disk; anything else means a
/// new first run, which only the user starts.
@Suite struct OneWaySyncRecordTests {

    static var record: OneWaySyncRecord {
        var world = OneWayWorld(subfolders: ["Finance/Receipts"], files: ["Finance/a.pdf", "Finance/Receipts/x.pdf"])
        world.record.iCloudParent = OneWaySyncParentRecord(path: "/Users/me/Documents", link: "/Users/me/Documents", linkTarget: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents")
        world.record.files[0].tags = ["Red", "Taxes"]
        world.record.files[0].iCloudGoneSince = 1_790_000_100
        world.record.removed = [OneWaySyncRemovedFile(file: world.record.files[1], removedPath: "SyncCloud Removed/x.pdf")]
        return world.record
    }

    @Test func roundTripsThroughItsStoredForm() throws {
        let record = Self.record
        let data = try record.encoded()
        #expect(OneWaySyncRecord.load(data, on: OneWayWorld.binding) == .ready(record))
        // Sorted keys: an unchanged record writes the same bytes.
        #expect(try record.encoded() == data)
    }

    @Test func storesDatesAsWholeSeconds() throws {
        let json = try JSONSerialization.jsonObject(with: Self.record.encoded()) as! [String: Any]
        let file = (json["files"] as! [[String: Any]])[0]
        #expect(file["modified"] as? Int == Int(OneWayWorld.t0.timeIntervalSince1970))
        #expect(json["version"] as? Int == 3)
    }

    /// Version 1, without change times or refused files: read as this version with neither, so the
    /// first pass takes each file's change time as it finds it.
    @Test func aVersion1RecordReadsWithNoChangeTimesAndNothingRefused() throws {
        var record = Self.record
        record.files[0].changed = 1_790_000_000_123_456_789
        record.refused = [OneWaySyncRefusedFile(
            iCloudPath: "Finance/desktop.ini", iCloudID: 9, size: 10, modified: 1_790_000_000, changed: nil,
            dropboxPath: "Finance/desktop.ini", record: nil, why: "excluded", refusedAt: 1_790_000_000)]
        var json = try JSONSerialization.jsonObject(with: record.encoded()) as! [String: Any]
        json["version"] = 1
        json.removeValue(forKey: "refused")
        var files = json["files"] as! [[String: Any]]
        for index in files.indices { files[index].removeValue(forKey: "changed") }
        json["files"] = files
        let v1 = try JSONSerialization.data(withJSONObject: json)

        guard case .ready(let read) = OneWaySyncRecord.load(v1, on: OneWayWorld.binding) else {
            Issue.record("a version 1 record didn't read")
            return
        }
        #expect(read.version == OneWaySyncRecord.currentVersion)
        #expect(read.refused.isEmpty)
        #expect(read.files.map(\.changed) == [nil, nil])
        #expect(read.files.map(\.iCloudPath) == Self.record.files.map(\.iCloudPath))
        // Written back as this version, change times and refusals round-trip.
        #expect(OneWaySyncRecord.load(try record.encoded(), on: OneWayWorld.binding) == .ready(record))
    }

    @Test(arguments: [
        OneWaySyncNewFirstRunReason.otherMac, .otherICloudAccount, .otherDropboxAccount, .otherDisk,
    ])
    func aMismatchNeedsANewFirstRun(_ reason: OneWaySyncNewFirstRunReason) throws {
        let field: WritableKeyPath<OneWaySyncBinding, String>
        switch reason {
        case .otherMac: field = \.hardwareID
        case .otherICloudAccount: field = \.iCloudAccount
        case .otherDropboxAccount: field = \.dropboxAccountFolder
        default: field = \.dataVolumeUUID
        }
        let data = try Self.record.encoded()
        var other = OneWayWorld.binding
        other[keyPath: field] = "something else"
        #expect(OneWaySyncRecord.load(data, on: other) == .needsNewFirstRun(reason))
        // A value that couldn't be read confirms nothing.
        other[keyPath: field] = ""
        #expect(OneWaySyncRecord.load(data, on: other) == .needsNewFirstRun(reason))
    }

    @Test func aMissingOrUnusableRecordNeedsANewFirstRun() throws {
        #expect(OneWaySyncRecord.load(nil, on: OneWayWorld.binding) == .needsNewFirstRun(.noRecord))
        #expect(OneWaySyncRecord.load(Data("not json".utf8), on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))

        var json = try JSONSerialization.jsonObject(with: Self.record.encoded()) as! [String: Any]
        json["version"] = 4
        let newer = try JSONSerialization.data(withJSONObject: json)
        #expect(OneWaySyncRecord.load(newer, on: OneWayWorld.binding) == .needsNewFirstRun(.unsupportedVersion(4)))

        // A version 2 record (without Dropbox's own dates and pending uploads) still reads.
        json["version"] = 2
        json.removeValue(forKey: "pendingUploads")
        let older = try JSONSerialization.data(withJSONObject: json)
        guard case .ready(let read) = OneWaySyncRecord.load(older, on: OneWayWorld.binding) else {
            Issue.record("a version 2 record didn’t read"); return
        }
        #expect(read.version == OneWaySyncRecord.currentVersion)
        #expect(read.pendingUploads.isEmpty)

        json["version"] = 3
        json.removeValue(forKey: "files")
        let damaged = try JSONSerialization.data(withJSONObject: json)
        #expect(OneWaySyncRecord.load(damaged, on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))
    }
}
