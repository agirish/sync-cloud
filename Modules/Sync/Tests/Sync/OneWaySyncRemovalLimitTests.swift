import Foundation
import Testing
@testable import Sync

/// The removal limit: in any 24 hours, in one folder more than 25 files deleted, moved out or
/// replaced, or more than 10% of its files deleted or moved out when that is also more than 5; or
/// more than 50 across all folders. Each file counts once.
@Suite struct OneWaySyncRemovalLimitTests {
    typealias Change = OneWaySyncRemovalWindow.Change
    static let now: Int64 = 1_790_100_000

    static func changes(_ count: Int, folder: UInt64 = 1, kind: Change.Kind, from first: UInt64 = 1, seenAt: Int64 = now) -> [Change] {
        (0..<UInt64(count)).map { Change(file: first + $0, folder: folder, kind: kind, seenAt: seenAt) }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var kind: Change.Kind
        var count: Int
        var folderFiles: Int
        var over: Bool
    }

    static let oneFolder: [Case] = [
        Case(testDescription: "25 replaced in a large folder", kind: .replaced, count: 25, folderFiles: 1000, over: false),
        Case(testDescription: "26 replaced in a large folder", kind: .replaced, count: 26, folderFiles: 1000, over: true),
        Case(testDescription: "25 deleted in a large folder", kind: .deletedOrMovedOut, count: 25, folderFiles: 1000, over: false),
        Case(testDescription: "26 deleted in a large folder", kind: .deletedOrMovedOut, count: 26, folderFiles: 1000, over: true),
        Case(testDescription: "5 of 50 deleted: 10%, and not more than 5", kind: .deletedOrMovedOut, count: 5, folderFiles: 50, over: false),
        Case(testDescription: "6 of 50 deleted: 12%, and more than 5", kind: .deletedOrMovedOut, count: 6, folderFiles: 50, over: true),
        Case(testDescription: "5 of 20 deleted: 25%, but not more than 5", kind: .deletedOrMovedOut, count: 5, folderFiles: 20, over: false),
        Case(testDescription: "6 of 60 deleted: exactly 10%", kind: .deletedOrMovedOut, count: 6, folderFiles: 60, over: false),
        Case(testDescription: "7 of 60 deleted: over 10%", kind: .deletedOrMovedOut, count: 7, folderFiles: 60, over: true),
        Case(testDescription: "6 of 50 replaced: the percentage counts only removals", kind: .replaced, count: 6, folderFiles: 50, over: false),
    ]

    @Test(arguments: oneFolder)
    func inOneFolder(_ row: Case) {
        let verdict = OneWaySyncRemovalWindow().verdict(
            adding: Self.changes(row.count, kind: row.kind), folderFileCounts: [1: row.folderFiles], now: Self.now)
        #expect(verdict.overFolders == (row.over ? [1] : []))
        #expect(!verdict.overAcrossFolders)
    }

    @Test(arguments: [(50, false), (51, true)])
    func acrossFolders(_ total: Int, _ over: Bool) {
        // 17 + 17 + 16 or 17: under each folder's own limit, in folders of 1,000.
        let counts = [17, 17, total - 34]
        var changes: [Change] = []
        for (index, count) in counts.enumerated() {
            changes += Self.changes(count, folder: UInt64(index + 1), kind: .deletedOrMovedOut, from: UInt64(index * 100 + 1))
        }
        let verdict = OneWaySyncRemovalWindow().verdict(adding: changes, folderFileCounts: [1: 1000, 2: 1000, 3: 1000], now: Self.now)
        #expect(verdict.overFolders.isEmpty)
        #expect(verdict.acrossCount == total)
        #expect(verdict.overAcrossFolders == over)
    }

    @Test func eachFileCountsOnce() {
        let replaced = Self.changes(26, kind: .replaced)
        let again = Self.changes(26, kind: .deletedOrMovedOut)
        let verdict = OneWaySyncRemovalWindow(changes: replaced).verdict(adding: again, folderFileCounts: [1: 10_000], now: Self.now)
        #expect(verdict.acrossCount == 26)
        #expect(verdict.overFolders == [1])

        let twentyFive = OneWaySyncRemovalWindow(changes: Self.changes(25, kind: .replaced))
            .verdict(adding: Self.changes(25, kind: .deletedOrMovedOut), folderFileCounts: [1: 10_000], now: Self.now)
        #expect(twentyFive.overFolders.isEmpty)
    }

    @Test func theWindowRollsOver24Hours() {
        let fresh = Self.changes(20, kind: .replaced, seenAt: Self.now - 24 * 3600 + 1)
        let stale = Self.changes(20, kind: .replaced, seenAt: Self.now - 24 * 3600)
        let pass = Self.changes(6, kind: .replaced, from: 100)
        #expect(OneWaySyncRemovalWindow(changes: fresh).verdict(adding: pass, folderFileCounts: [1: 1000], now: Self.now).overFolders == [1])
        #expect(OneWaySyncRemovalWindow(changes: stale).verdict(adding: pass, folderFileCounts: [1: 1000], now: Self.now).overFolders.isEmpty)
        #expect(OneWaySyncRemovalWindow(changes: fresh + stale).current(at: Self.now).changes == fresh)
    }

    @Test func aClockMovedBackwardsStartsAFreshWindow() {
        let window = OneWaySyncRemovalWindow(changes: Self.changes(25, kind: .replaced, seenAt: Self.now + 60))
        #expect(window.current(at: Self.now).changes.isEmpty)
        #expect(window.verdict(adding: Self.changes(6, kind: .replaced, from: 100), folderFileCounts: [1: 1000], now: Self.now).overFolders.isEmpty)
    }

    @Test func theWindowIsSaved() throws {
        let window = OneWaySyncRemovalWindow(changes: Self.changes(3, kind: .deletedOrMovedOut))
        let data = try JSONEncoder().encode(window)
        #expect(try JSONDecoder().decode(OneWaySyncRemovalWindow.self, from: data) == window)
    }
}

/// The removal limit as the planner applies it: over the limit in one folder, its removals and
/// replacements wait and additions continue; over 50 across folders, the whole sync stops.
@Suite struct OneWaySyncPlannedRemovalLimitTests {

    static func files(_ folder: String, _ count: Int) -> [String] {
        (1...count).map { String(format: "%@/f%03d.pdf", folder, $0) }
    }

    static let edit = OneWayWorld.t0.addingTimeInterval(3600)

    @Test(arguments: [(25, false), (26, true)])
    func replacementsInOneFolder(_ edits: Int, _ over: Bool) {
        var world = OneWayWorld(files: Self.files("Finance", 300))
        for path in Self.files("Finance", edits) { world.edit(.iCloud, path) }
        world.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 5000, hash: "n"))
        let plan = world.plan(now: Self.edit)

        let replaces = plan.actions.filter { if case .replace = $0 { return true } else { return false } }
        #expect(replaces.count == (over ? 0 : edits))
        #expect(plan.waitReasons == (over ? Array(repeating: .overRemovalLimit, count: edits) : []))
        #expect(plan.actions.last == .copy(from: "Finance/new.pdf", to: "Finance/new.pdf", needsDownload: false))
        #expect(plan.window.changes.count == (over ? 0 : edits))
        #expect(plan.stop == nil)
    }

    @Test(arguments: [(5, false), (6, true)])
    func deletionsAsAShareOfTheFolder(_ deletions: Int, _ over: Bool) {
        var world = OneWayWorld(files: Self.files("Finance", 50))
        for path in Self.files("Finance", deletions) {
            world.delete(.iCloud, path)
            world.setGoneSince(path, OneWayWorld.t0)
        }
        let plan = world.plan()
        let removals = plan.actions.filter { if case .moveToRemoved = $0 { return true } else { return false } }
        #expect(removals.count == (over ? 0 : deletions))
        #expect(plan.waitReasons == (over ? Array(repeating: .overRemovalLimit, count: deletions) : []))
    }

    @Test(arguments: [(16, false), (17, true)])
    func acrossFolders(_ inLast: Int, _ over: Bool) {
        let folders = ["Finance", "Health", "Legal"]
        var world = OneWayWorld(folders: folders, files: folders.flatMap { Self.files($0, 100) })
        for (index, folder) in folders.enumerated() {
            for path in Self.files(folder, index == 2 ? inLast : 17) { world.edit(.iCloud, path) }
        }
        world.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 5000, hash: "n"))
        let plan = world.plan(now: Self.edit)
        let total = 34 + inLast
        // Stopped, nothing at all is left to apply, not even an addition.
        #expect(plan.steps.count == (over ? 0 : total + 1))
        #expect(plan.stop == (over ? .overRemovalLimitAcrossFolders(count: total) : nil))
        #expect(plan.waitReasons == (over ? Array(repeating: .overRemovalLimitAcrossFolders, count: total) : []))
        #expect(plan.window.changes.count == (over ? 0 : total))
    }

    @Test func confirmedChangesGoAheadAndDoNotCount() {
        var world = OneWayWorld(files: Self.files("Finance", 300))
        for path in Self.files("Finance", 26) { world.edit(.iCloud, path) }
        let plan = world.plan(now: Self.edit, confirmed: Set(1...26))
        #expect(plan.actions.count == 26)
        #expect(plan.waits.isEmpty)
        #expect(plan.window.changes.isEmpty)
    }

    @Test func tagOnlyChangesDoNotCount() {
        var world = OneWayWorld(files: Self.files("Finance", 300))
        for path in Self.files("Finance", 30) { world.update(.iCloud, path) { $0.tags = ["Red"] } }
        let plan = world.plan(now: Self.edit)
        #expect(plan.actions.count == 30)
        #expect(plan.waits.isEmpty)
        #expect(plan.window.changes.isEmpty)
    }

    @Test func earlierChangesInTheWindowCount() {
        var world = OneWayWorld(files: Self.files("Finance", 300))
        for path in Self.files("Finance", 6) { world.edit(.iCloud, path) }
        let now = Int64(Self.edit.timeIntervalSince1970)
        let earlier = OneWaySyncRemovalWindow(changes: (100..<120).map {
            OneWaySyncRemovalWindow.Change(file: $0, folder: 1001, kind: .replaced, seenAt: now - 3600)
        })
        #expect(world.plan(now: Self.edit, window: earlier).waitReasons == Array(repeating: .overRemovalLimit, count: 6))
        #expect(world.plan(now: Self.edit.addingTimeInterval(24 * 3600), window: earlier).waits.isEmpty)
    }

    @Test func aMoveIntoAWaitingRemovalsNameWaitsWithIt() {
        var world = OneWayWorld(files: Self.files("Finance", 300))
        for path in Self.files("Finance", 26) { world.edit(.iCloud, path) }
        // f300 moved over f299: f299's removal waits with the rest, so the move does too.
        world.delete(.iCloud, "Finance/f299.pdf")
        world.setGoneSince("Finance/f299.pdf", OneWayWorld.t0)
        world.rename(.iCloud, "Finance/f300.pdf", to: "Finance/f299.pdf")
        let plan = world.plan(now: Self.edit)
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons.filter { $0 == .overRemovalLimit }.count == 27)
        #expect(plan.waitReasons.last == .waitingForRemovalOf("Finance/f299.pdf"))
    }
}
