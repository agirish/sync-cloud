import Foundation
import Testing
@testable import Sync

/// What the Missing lens remembers: the changes a choice makes, their home in the survey's ledger,
/// and the manager's walk that reads names and applies them.
@Suite struct MissingChoicesTests {

    typealias Month = MissingStatements.Month
    typealias Choices = MissingStatements.Choices

    static func m(_ year: Int, _ month: Int) -> Month { Month(year: year, month: month) }
    static let power = "Home/Utilities/Power"

    static func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Changing choices

    @Test func aMovedFolderKeepsWhatWasDecidedAboutItsAccounts() {
        let choices = Choices(hidden: ["Home/Utilities/Power", "Home/Utilities/PowerCo"],
                              stopped: ["Home/Utilities/Power/Old": Self.m(2026, 1)],
                              notExpected: ["Home/Utilities": [Self.m(2025, 3)], "Finance/Bank": [Self.m(2024, 1)]],
                              counted: ["Home/Utilities/Power": [Self.m(2024, 4)]], firstChecked: Self.m(2026, 11))
        let moved = choices.rekeyed(from: "Home/Utilities/Power", to: "Home/Bills/Electric")
        // The folder itself and what is below it move; a sibling sharing its prefix does not.
        #expect(moved.hidden == ["Home/Bills/Electric", "Home/Utilities/PowerCo"])
        #expect(moved.stopped == ["Home/Bills/Electric/Old": Self.m(2026, 1)])
        #expect(moved.counted == ["Home/Bills/Electric": [Self.m(2024, 4)]])
        // A folder above it, and one elsewhere, are untouched.
        #expect(moved.notExpected == choices.notExpected)
        #expect(moved.firstChecked == Self.m(2026, 11))
    }

    @Test func aGapsMonthsGoOffTheCountAndComeBack() {
        var choices = Choices()
        choices.setExpected(false, months: [Self.m(2025, 3), Self.m(2025, 4)], in: Self.power)
        #expect(choices.notExpected == [Self.power: [Self.m(2025, 3), Self.m(2025, 4)]])
        choices.setExpected(true, months: [Self.m(2025, 3)], in: Self.power)
        #expect(choices.notExpected == [Self.power: [Self.m(2025, 4)]])
        choices.setExpected(true, months: [Self.m(2025, 4)], in: Self.power)
        // Nothing left is no entry, so an untouched ledger and a restored one are the same bytes.
        #expect(choices.isEmpty)
        choices.setCounted(true, months: [Self.m(2024, 4)], in: Self.power)
        #expect(choices.counted == [Self.power: [Self.m(2024, 4)]])
        choices.setCounted(false, months: [Self.m(2024, 4)], in: Self.power)
        #expect(choices.isEmpty)
    }

    @Test func stoppingAndStartingAnAccount() throws {
        let paths = MissingStatementsTests.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 1))
        let tracked = try MissingStatementsTests.account(paths, Self.power)
        var choices = Choices()
        choices.setTracking(false, for: tracked, from: Self.m(2026, 11))
        // Stopped at the statement it had then, so a newer one starts it again by itself.
        #expect(choices.stopped == [Self.power: Self.m(2026, 1)])
        let stopped = try MissingStatementsTests.account(paths, Self.power, choices: choices)
        choices.setTracking(true, for: stopped, from: Self.m(2026, 11))
        #expect(choices.isEmpty)

        // A quiet account is started from the month the user said so.
        let old = MissingStatementsTests.monthly(Self.power, Self.m(2022, 1), Self.m(2025, 3))
        let quiet = try MissingStatementsTests.account(old, Self.power)
        choices.setTracking(true, for: quiet, from: Self.m(2026, 11))
        #expect(choices.started == [Self.power: Self.m(2026, 11)])
        let started = try MissingStatementsTests.account(old, Self.power, choices: choices)
        #expect(started.tracking == .tracked)
        choices.setTracking(false, for: started, from: Self.m(2026, 11))
        #expect(choices.isEmpty)
    }

    @Test func anAccountCarriesTheMonthsItHasForTheStrip() throws {
        let broker = "Finance/Brokerage/Account 0003"
        let paths = MissingStatementsTests.monthly(broker, Self.m(2023, 1), Self.m(2023, 12))
            + MissingStatementsTests.every(3, broker, Self.m(2025, 3), Self.m(2026, 9), length: 3)
            + ["\(broker)/2024/0. Summary 2024.pdf"]
        let account = try MissingStatementsTests.account(paths, broker)
        // A range covers each of its months; a summary-only year covers none and is named apart.
        #expect(account.filed.count == 12 + 21)
        #expect(account.filed.contains(Self.m(2025, 2)))
        #expect(!account.filed.contains(Self.m(2024, 6)))
        #expect(account.summaryOnlyYears == [2024])
    }

    // MARK: The ledger

    @MainActor
    @Test func theLedgerKeepsChoicesAndWritesNothingForNone() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "Finance"))
        #expect(!String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("missing"))

        #expect(store.updateMissing("hid Power") { $0.hidden.insert(Self.power) })
        // A change that changes nothing is not a write.
        #expect(!store.updateMissing("hid Power again") { $0.hidden.insert(Self.power) })
        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.missing == Choices(hidden: [Self.power]))
        #expect(reread.isSuppressed(RestructureKey(kind: .shape, path: "Finance")))

        // Back to nothing decided: the section leaves the file.
        reread.updateMissing("showed Power") { $0.hidden.remove(Self.power) }
        #expect(!String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("missing"))
    }

    @MainActor
    @Test func aLandingsRenamesMoveTheChoicesWithTheFolder() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestructureStore(directory: dir, profileId: "p")
        store.updateMissing("hid Power") { $0.hidden.insert(Self.power) }
        store.rekey(renames: [(from: "Home/Utilities", to: "Home/Bills")])
        #expect(RestructureStore(directory: dir, profileId: "p").missing.hidden == ["Home/Bills/Power"])
    }

    // MARK: The manager's walk

    @Test func aTreeBecomesRelativePathsAndUnlistedFoldersAreNamed() {
        func file(_ name: String) -> FileNode { FileNode(id: "/x/" + name, name: name, isDirectory: false) }
        func folder(_ name: String, _ children: [FileNode], unexplored: Bool = false) -> FileNode {
            FileNode(id: "/x/" + name, name: name, isDirectory: true, children: children, isUnexplored: unexplored ? true : nil)
        }
        let tree = [folder("Home", [folder("Power", [folder("2026", [file("1. Jan 2026.pdf")]), file("note.txt")]),
                                   folder("Slow", [], unexplored: true)]),
                    file("top.pdf")]
        let walk = FileSyncManager.missingStatementPaths(in: tree)
        #expect(walk.paths == ["Home/Power/2026/1. Jan 2026.pdf", "Home/Power/note.txt", "top.pdf"])
        // A folder the walk could not list is unknown, never empty.
        #expect(walk.notChecked == ["Home/Slow"])
    }

    @MainActor
    @Test func theManagerWalksReportsAndRecomputesUnderNewChoices() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in MissingStatementsTests.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)]) {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let manager = FileSyncManager()
        #expect(manager.missingReport == nil)
        await manager.findMissingStatements(root: root, choices: .init(), now: MissingStatementsTests.now, calendar: MissingStatementsTests.utc)
        #expect(manager.missingReport?.counted == 1)
        #expect(manager.missingReport?.accounts.map(\.path) == [Self.power])
        #expect(manager.missingRoot == root)
        #expect(manager.missingLifecycle.hasCompleted)
        #expect(!manager.isFindingMissingStatements)

        // New choices need no second walk: remove the folder, and the answer still changes.
        try FileManager.default.removeItem(at: root)
        manager.applyMissingChoices(Choices(hidden: [Self.power]), now: MissingStatementsTests.now, calendar: MissingStatementsTests.utc)
        #expect(manager.missingReport?.counted == 0)
        #expect(manager.missingReport?.accounts.first?.isHidden == true)

        // No survey, so nothing is kept and a change is refused rather than half made.
        #expect(!manager.missingChoicesAreKept)
        manager.changeMissingChoices(actionName: "Hide Account", message: "x") { $0.hidden.insert("A") }
        #expect(manager.missingReport?.accounts.first?.isHidden == true)

        manager.clearMissingStatements()
        #expect(manager.missingReport == nil)
        #expect(manager.missingRoot == nil)
        #expect(!manager.missingLifecycle.hasCompleted)
    }

    @MainActor
    @Test func aChoiceIsSavedAppliedAndUndone() async throws {
        let root = try Self.scratch()
        let profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        for path in MissingStatementsTests.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)]) {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let manager = FileSyncManager()
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        manager.filingFolderProfile = FolderProfile(profileId: "p", root: root.path, folders: [:], personTokens: [])
        let store = RestructureStore(directory: profiles, profileId: "p")
        manager.restructureStore = store
        // The ledger's choices apply to its own surveyed folder and to no other.
        #expect(manager.missingChoices(for: root) == Choices())
        store.updateMissing("counted") { $0.counted["X"] = [Self.m(2024, 1)] }
        #expect(manager.missingChoices(for: root).counted == ["X": [Self.m(2024, 1)]])
        #expect(manager.missingChoices(for: profiles) == Choices())

        await manager.findMissingStatements(root: root, choices: manager.missingChoices(for: root),
                                            now: MissingStatementsTests.now, calendar: MissingStatementsTests.utc)
        #expect(manager.missingChoicesAreKept)
        // The first check is dated once, in the ledger.
        #expect(store.missing.firstChecked == Self.m(2026, 11))
        #expect(manager.missingReport?.counted == 1)

        undo.beginUndoGrouping()
        manager.changeMissingChoices(actionName: "Not Expected", message: "Mar 2025 is off the count.") {
            $0.setExpected(false, months: [Self.m(2025, 3)], in: Self.power)
        }
        undo.endUndoGrouping()
        #expect(manager.missingReport?.counted == 0)
        #expect(RestructureStore(directory: profiles, profileId: "p").missing.notExpected == [Self.power: [Self.m(2025, 3)]])
        #expect(undo.undoActionName == "Not Expected")

        undo.undo()
        #expect(manager.missingReport?.counted == 1)
        #expect(RestructureStore(directory: profiles, profileId: "p").missing.notExpected.isEmpty)
        undo.redo()
        #expect(manager.missingReport?.counted == 0)
    }
}
