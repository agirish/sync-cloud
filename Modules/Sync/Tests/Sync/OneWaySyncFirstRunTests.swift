import Foundation
import Testing
@testable import Sync

/// CZ: on a first run, a file with the same name on both sides is the same file. Same contents are
/// adopted; different contents go by which is newer; the same second, or a future date, waits.
/// A Dropbox file of identical contents under another name is renamed to match.
@Suite struct OneWaySyncFirstRunTests {
    static let t0 = OneWayWorld.t0
    static let now = OneWayWorld.t0.addingTimeInterval(3600)

    func world(iCloud: [OneWaySyncItem], dropbox: [OneWaySyncItem], firstRun: Bool = true) -> OneWayWorld {
        var world = OneWayWorld(firstRun: firstRun)
        iCloud.forEach { world.add(.iCloud, $0) }
        dropbox.forEach { world.add(.dropbox, $0) }
        return world
    }

    static func file(_ path: String, id: UInt64, size: Int64 = 5000, at seconds: TimeInterval = 0, hash: String?) -> OneWaySyncItem {
        OneWayWorld.file(path, id: id, size: size, modified: t0.addingTimeInterval(seconds), hash: hash)
    }

    @Test func sameNameSameContentsIsAdopted() {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/a.pdf", id: 101, at: -86_400, hash: "x")]).plan(now: Self.now)
        #expect(plan.actions == [.adopt(iCloudPath: "Finance/a.pdf", dropboxPath: "Finance/a.pdf")])
        #expect(plan.waits.isEmpty)
    }

    @Test func sameNameInAnotherCaseIsAdoptedAndRenamedInPlace() {
        let plan = world(
            iCloud: [Self.file("Finance/Tax.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/tax.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.actions == [
            .moveInDropbox(from: "Finance/tax.pdf", to: "Finance/Tax.pdf"),
            .adopt(iCloudPath: "Finance/Tax.pdf", dropboxPath: "Finance/Tax.pdf"),
        ])
    }

    @Test func sameNameInAnotherUnicodeFormIsAdoptedWithNoRename() {
        let plan = world(
            iCloud: [Self.file("Finance/caf\u{00E9}.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/cafe\u{0301}.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.actions.count == 1)
        guard case .adopt(_, let dropboxPath) = plan.actions.first else {
            Issue.record("expected an adopt, got \(plan.actions)")
            return
        }
        #expect(Array(dropboxPath.utf8) == Array("Finance/cafe\u{0301}.pdf".utf8))
    }

    struct Dated: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var iCloudSeconds: TimeInterval
        var dropboxSeconds: TimeInterval
        var actions: [OneWaySyncAction]
        var waits: [OneWaySyncWaitReason]
    }

    static let dated: [Dated] = [
        Dated(testDescription: "iCloud newer: replaced, Dropbox's version kept",
              iCloudSeconds: 120, dropboxSeconds: 60,
              actions: [.replace(dropboxPath: "Finance/a.pdf", with: "Finance/a.pdf", needsDownload: false, previousIsDropboxEdit: true)],
              waits: []),
        Dated(testDescription: "Dropbox newer: waits",
              iCloudSeconds: 60, dropboxSeconds: 120, actions: [], waits: [.dropboxNewerOnFirstRun]),
        Dated(testDescription: "the same second: unclear, waits",
              iCloudSeconds: 60.2, dropboxSeconds: 60.7, actions: [], waits: [.sameDateOnFirstRun]),
        Dated(testDescription: "iCloud's date in the future: unclear, waits",
              iCloudSeconds: 7200, dropboxSeconds: 60, actions: [], waits: [.futureDateOnFirstRun]),
        Dated(testDescription: "Dropbox's date in the future: unclear, waits",
              iCloudSeconds: 60, dropboxSeconds: 7200, actions: [], waits: [.futureDateOnFirstRun]),
    ]

    @Test(arguments: dated)
    func differentContentsGoByWhichIsNewer(_ row: Dated) {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, size: 5000, at: row.iCloudSeconds, hash: "mine")],
            dropbox: [Self.file("Finance/a.pdf", id: 101, size: 6000, at: row.dropboxSeconds, hash: "theirs")]
        ).plan(now: Self.now)
        #expect(plan.actions == row.actions)
        #expect(plan.waitReasons == row.waits)
        // A first run is confirmed by the user's Start: nothing in it counts toward the limit.
        #expect(plan.window.changes.isEmpty)
    }

    @Test func sameSizeWithContentsUnreadWaitsQuietlyAndAsksForThem() {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, hash: nil)],
            dropbox: [Self.file("Finance/a.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.contentsNotRead])
        #expect(!OneWaySyncWaitReason.contentsNotRead.needsYou)
        #expect(plan.iCloudContentsToRead == ["Finance/a.pdf"])
        #expect(plan.dropboxContentsToRead.isEmpty)

        // Neither read: never assumed equal.
        let neither = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, hash: nil)],
            dropbox: [Self.file("Finance/a.pdf", id: 101, hash: nil)]).plan(now: Self.now)
        #expect(neither.actions.isEmpty)
        #expect(neither.waitReasons == [.contentsNotRead])
        #expect(neither.dropboxContentsToRead == ["Finance/a.pdf"])
    }

    @Test func nothingInAFirstRunFolderCountsTowardTheLimit() {
        var world = OneWayWorld(files: ["Finance/a.pdf"], firstRun: true)
        world.edit(.iCloud, "Finance/a.pdf")
        let plan = world.plan(now: Self.now)
        #expect(plan.actions == [.replace(dropboxPath: "Finance/a.pdf", with: "Finance/a.pdf", needsDownload: false, previousIsDropboxEdit: false)])
        #expect(plan.window.changes.isEmpty)
    }

    @Test func extensionCaseDoesNotChangeTheType() {
        let plan = world(
            iCloud: [Self.file("Finance/a.PDF", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/b.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.matches.pairs.map(\.basis) == [.contents])
    }

    @Test func identicalContentsUnderAnotherNameIsRenamedToMatch() {
        let plan = world(
            iCloud: [Self.file("Finance/Tax 2025.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/tax-2025.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.matches.pairs.map(\.basis) == [.contents])
        #expect(plan.actions == [
            .moveInDropbox(from: "Finance/tax-2025.pdf", to: "Finance/Tax 2025.pdf"),
            .adopt(iCloudPath: "Finance/Tax 2025.pdf", dropboxPath: "Finance/Tax 2025.pdf"),
        ])
        #expect(plan.dropboxOnly.isEmpty)
    }

    @Test func aRenameToMatchThatWaitsAdoptsNothing() {
        // X.pdf is too small to pair by contents and takes the name x.pdf needs in Dropbox.
        let plan = world(
            iCloud: [Self.file("Finance/x.pdf", id: 1, hash: "x"), Self.file("Finance/X.pdf", id: 2, size: 500, hash: "small")],
            dropbox: [Self.file("Finance/y.pdf", id: 101, hash: "x")]).plan(now: Self.now)
        #expect(plan.matches.pairs.map(\.basis) == [.contents])
        #expect(plan.actions == [.copy(from: "Finance/X.pdf", to: "Finance/X.pdf", needsDownload: false)])
        #expect(plan.waitReasons == [.nameTaken("Finance/X.pdf")])
    }

    @Test func sameSizeDifferentContentsGoByWhichIsNewer() {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, at: 120, hash: "mine")],
            dropbox: [Self.file("Finance/a.pdf", id: 101, at: 60, hash: "theirs")]).plan(now: Self.now)
        #expect(plan.actions == [.replace(dropboxPath: "Finance/a.pdf", with: "Finance/a.pdf", needsDownload: false, previousIsDropboxEdit: true)])
    }

    struct Unpaired: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var iCloud: [OneWaySyncItem]
        var dropbox: [OneWaySyncItem]
        var firstRun = true
    }

    static let unpaired: [Unpaired] = [
        Unpaired(testDescription: "1 KB or less",
                 iCloud: [file("Finance/a.pdf", id: 1, size: 1024, hash: "x")],
                 dropbox: [file("Finance/b.pdf", id: 101, size: 1024, hash: "x")]),
        Unpaired(testDescription: "contents differ",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: "x")],
                 dropbox: [file("Finance/b.pdf", id: 101, hash: "y")]),
        Unpaired(testDescription: "contents not read",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: nil)],
                 dropbox: [file("Finance/b.pdf", id: 101, hash: nil)]),
        Unpaired(testDescription: "another type",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: "x")],
                 dropbox: [file("Finance/b.txt", id: 101, hash: "x")]),
        Unpaired(testDescription: "size and type not unique in Dropbox",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: "x")],
                 dropbox: [file("Finance/b.pdf", id: 101, hash: "x"), file("Finance/c.pdf", id: 102, hash: "z")]),
        Unpaired(testDescription: "size and type not unique in iCloud",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: "x"), file("Finance/c.pdf", id: 2, hash: "z")],
                 dropbox: [file("Finance/b.pdf", id: 101, hash: "x")]),
        Unpaired(testDescription: "not a first run",
                 iCloud: [file("Finance/a.pdf", id: 1, hash: "x")],
                 dropbox: [file("Finance/b.pdf", id: 101, hash: "x")],
                 firstRun: false),
    ]

    @Test(arguments: unpaired)
    func identicalContentsArePairedOnlyWhenNothingElseCouldMatch(_ row: Unpaired) {
        let plan = world(iCloud: row.iCloud, dropbox: row.dropbox, firstRun: row.firstRun).plan(now: Self.now)
        #expect(plan.matches.pairs.isEmpty)
        #expect(plan.actions == row.iCloud.map { .copy(from: $0.path, to: $0.path, needsDownload: false) })
        #expect(plan.dropboxOnly == row.dropbox.map(\.path))
    }

    @Test func identicalContentsAreNotRenamedOntoATakenName() {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/b.pdf", id: 101, hash: "x"), OneWayWorld.folder("Finance/A.PDF", inode: 7)]
        ).plan(now: Self.now)
        #expect(plan.matches.pairs.isEmpty)
        #expect(plan.waitReasons == [.nameTaken("Finance/A.PDF")])
    }

    @Test func dropboxOnlyFilesAreLeftAlone() {
        let plan = world(
            iCloud: [Self.file("Finance/a.pdf", id: 1, hash: "x")],
            dropbox: [Self.file("Finance/a.pdf", id: 101, hash: "x"), Self.file("Finance/old.doc", id: 102, size: 10, hash: "o")]
        ).plan(now: Self.now)
        #expect(plan.actions == [.adopt(iCloudPath: "Finance/a.pdf", dropboxPath: "Finance/a.pdf")])
        #expect(plan.dropboxOnly == ["Finance/old.doc"])
    }
}
