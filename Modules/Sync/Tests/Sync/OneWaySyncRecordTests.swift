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
        #expect(json["version"] as? Int == 1)
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
        json["version"] = 2
        let newer = try JSONSerialization.data(withJSONObject: json)
        #expect(OneWaySyncRecord.load(newer, on: OneWayWorld.binding) == .needsNewFirstRun(.unsupportedVersion(2)))

        json["version"] = 1
        json.removeValue(forKey: "files")
        let damaged = try JSONSerialization.data(withJSONObject: json)
        #expect(OneWaySyncRecord.load(damaged, on: OneWayWorld.binding) == .needsNewFirstRun(.unreadable))
    }
}
