import EventsTestSupport
import Foundation
import Testing
@testable import Events
@testable import Sync

/// A pane copy, move or delete logs its failures grouped (`GroupedFailureLog`): one ERROR line per
/// kind, every item named in lines of at most 200, and the alert's own line not written beside
/// them, so the first failure isn't recorded twice. Every path carries a per-test tag, because the
/// capture also sees other suites' lines.
@Suite struct PaneFailureLogTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, true))
    }

    private static func names(_ tag: String, _ count: Int) -> [String] {
        (1...count).map { String(format: "\(tag)-%03d.txt", $0) }
    }

    /// The captured messages that mention `tag`.
    private func mine(_ log: LogCapture, _ tag: String) async -> [LogEntry] {
        await log.entries.filter { $0.message.contains(tag) }
    }

    /// A message without the ` | Location: …` tail every WARN and ERROR line carries.
    private static func bare(_ message: String) -> String {
        message.components(separatedBy: " | Location: ")[0]
    }

    /// 500 copies whose sources are gone: one kind, so one head line and three name lines
    /// (200, 200, 100), every path once, sorted; no line per item, and no alert line.
    @MainActor
    @Test func fiveHundredFailedCopiesAreAHeadLineAndThreeNameLines() async throws {
        let tag = "copy500-\(UUID().uuidString.prefix(8))"
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Not on the mock disk, so each copy throws: every item fails, the same way.
        let names = Self.names(tag, 500)
        let nodes = names.reversed().map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }

        let log = LogCapture()
        let copied = await manager.copyItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        let error = try #require(manager.currentError)
        #expect(error.title == "Copy Failed")
        #expect(error.message == "Couldn’t copy 500 items.")
        let lines = await mine(log, tag)
        #expect(lines.allSatisfy { $0.level == .error }, "\(lines.map(\.message))")
        let heads = lines.filter { $0.message.hasPrefix("Copy: 500 item(s) failed — ") }
        #expect(heads.count == 1, "\(lines.map { $0.message.prefix(120) })")
        // The first item is the first by name, whatever order the nodes came in.
        #expect(heads.first?.message.contains("first: /src/\(tag)-001.txt: ") == true)
        let nameLines = lines.filter { $0.message.hasPrefix("Copy: failed (") }
        #expect(nameLines.count == 3)
        #expect(nameLines.first?.message.contains(" 1–200 of 500: /src/\(tag)-001.txt, /src/\(tag)-002.txt,") == true)
        #expect(nameLines.last?.message.contains(" 401–500 of 500: ") == true)
        #expect(nameLines.last.map { Self.bare($0.message) }?.hasSuffix("/src/\(tag)-500.txt") == true)
        let named = nameLines.map(\.message).joined(separator: ", ")
        #expect(names.allSatisfy { named.components(separatedBy: "/src/\($0)").count == 2 }, "a name was dropped or repeated")
        #expect(lines.count == 4, "a line per item, or the alert's own line: \(lines.count)")
        #expect(await !log.holds(containing: "Copy Failed: Couldn’t copy 500 items"), "the alert's line was written beside the group")
    }

    /// Names in a group are sorted, and the group's first item is the first by name, so two runs
    /// of the same failures log the same lines whatever order the workers finished in.
    @Test func aGroupsNamesAreSortedWhateverOrderTheyFailedIn() throws {
        let full = { (path: String) in CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: path]) }
        let order = ["/d/c.txt", "/d/a.txt", "/d/b.txt"]
        let lines = GroupedFailureLog.lines("Copy", order.map { ItemError(URL(fileURLWithPath: $0), full($0)) })
        let again = GroupedFailureLog.lines("Copy", order.reversed().map { ItemError(URL(fileURLWithPath: $0), full($0)) })
        #expect(lines == again)
        try #require(lines.count == 2)
        #expect(lines[0].contains("first: /d/a.txt: "))
        #expect(lines[1].hasSuffix("): /d/a.txt, /d/b.txt, /d/c.txt"))
    }

    /// A `SyncError` isn't a `LocalizedError`, so its first description is its log description,
    /// never the generic "couldn’t be completed".
    @Test func aSyncErrorsFirstDescriptionIsItsOwnWords() throws {
        let refused = SyncError.trashNotPermitted(path: "/d/a.txt", reason: "denied")
        let head = try #require(GroupedFailureLog.lines("Delete", [ItemError(URL(fileURLWithPath: "/d/a.txt"), refused)]).first)
        #expect(head.contains("first: /d/a.txt: \(refused.logDescription)"), "\(head)")
        #expect(!head.contains("couldn’t be completed"))
    }

    /// A wrapped failure's cause keys its group: two permission refusals with different codes
    /// beneath the same `SyncError` are two groups, each head line naming its codes.
    @Test func aCauseSplitsTheGroupAndNamesItsCodes() throws {
        let cocoa = { (posix: Int32) in
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }
        let refused = { (path: String, posix: Int32) in
            ItemError(URL(fileURLWithPath: path), SyncError.trashNotPermitted(path: path, reason: "denied"),
                      cause: cocoa(posix))
        }
        let lines = GroupedFailureLog.lines("Delete", [refused("/d/a.txt", EPERM), refused("/d/b.txt", EACCES),
                                                       refused("/d/c.txt", EPERM)])
        let heads = lines.filter { $0.hasPrefix("Delete: ") && $0.contains(" item(s) failed — ") }
        try #require(heads.count == 2, "\(lines)")
        #expect(heads.contains { $0.hasPrefix("Delete: 2 item(s) failed — ")
                    && $0.contains("Not Allowed to Move to the Trash ← NSCocoaErrorDomain 513 ← NSPOSIXErrorDomain 1]; first: /d/a.txt: ") },
                "\(heads)")
        #expect(heads.contains { $0.hasPrefix("Delete: 1 item(s) failed — ")
                    && $0.contains("← NSCocoaErrorDomain 513 ← NSPOSIXErrorDomain 13]; first: /d/b.txt: ") },
                "\(heads)")
        // Without a cause the key is the error's own, as before.
        let plain = GroupedFailureLog.lines("Delete", [ItemError(name: "/d/a.txt", SyncError.trashNotPermitted(path: "/d/a.txt", reason: "denied"))])
        #expect(plain.first?.contains("Not Allowed to Move to the Trash]; first: ") == true, "\(plain)")
    }

    /// 500 busy items the Trash refuses are the run's count line and one group: a head line naming
    /// the code and three name lines, with no line per item beside them.
    @MainActor
    @Test func fiveHundredBusyDeletesAreOneGroupWithNoLinePerItem() async throws {
        let tag = "busy500-\(UUID().uuidString.prefix(8))"
        let manager = makeManager()
        var askedToDestroy = false
        manager.permanentDeleteConfirmer = { _ in askedToDestroy = true; return false }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let paths = Self.names(tag, 500).map { "/src/\($0)" }
        for path in paths {
            mockFM.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.trashErrorAlways = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))

        let log = LogCapture()
        let outcome = await manager.deleteItems(at: paths.reversed(), fileManager: mockFM)

        #expect(outcome.removed == 0)
        #expect(!askedToDestroy, "a busy item was offered the permanent delete")
        #expect(paths.allSatisfy { mockFM.virtualDisk[$0] != nil }, "a busy item was removed")
        #expect(await log.holds(.error, containing: "Delete: 500 of 500 item(s) couldn’t be moved to the Trash"))
        let lines = await mine(log, tag)
        #expect(lines.allSatisfy { $0.level == .error }, "\(lines.map { $0.message.prefix(120) })")
        let heads = lines.filter { $0.message.hasPrefix("Delete: 500 item(s) failed — ") }
        #expect(heads.count == 1, "\(lines.map { $0.message.prefix(120) })")
        #expect(heads.first?.message.contains("[NSPOSIXErrorDomain 16]; first: /src/\(tag)-001.txt: ") == true,
                "\(heads.map(\.message))")
        let nameLines = lines.filter { $0.message.hasPrefix("Delete: failed (") }
        #expect(nameLines.count == 3)
        let named = nameLines.map(\.message).joined(separator: ", ")
        #expect(paths.allSatisfy { named.contains($0) }, "a busy item went unnamed")
        #expect(lines.count == 4, "a line per item: \(lines.count) lines name these items")
    }

    /// A copy whose destination root is gone fails as a whole, named by the root it couldn't find.
    @MainActor
    @Test func aMissingDestinationRootIsNamedByTheRoot() async throws {
        let tag = "root-\(UUID().uuidString.prefix(8))"
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let log = LogCapture()
        _ = await manager.copyItems(nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
                                    toPath: "/gone-\(tag)", fileManager: mockFM)

        #expect(manager.currentError?.title == "Copy Failed")
        let named = await mine(log, tag).map { Self.bare($0.message) }
        #expect(named.contains { $0.hasPrefix("Copy: 1 item(s) failed — ") && $0.contains("first: /gone-\(tag): ") }, "\(named)")
        #expect(named.contains { $0.hasPrefix("Copy: failed (") && $0.hasSuffix("): /gone-\(tag)") }, "\(named)")
    }

    /// A delete logs every failure, not only the first the alert shows: 500 items that neither
    /// reach the Trash nor delete permanently are a count line, a head line and three name lines.
    @MainActor
    @Test func everyFailedDeleteIsLoggedNotOnlyTheFirst() async throws {
        let tag = "del500-\(UUID().uuidString.prefix(8))"
        let manager = makeManager()
        manager.permanentDeleteConfirmer = { _ in true }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let paths = Self.names(tag, 500).map { "/src/\($0)" }
        for path in paths {
            mockFM.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        // No Trash on this volume, and the confirmed permanent delete fails too.
        mockFM.shouldFailTrash = true
        mockFM.failRemovePathsOnce = Set(paths)

        let log = LogCapture()
        _ = await manager.deleteItems(at: paths.reversed(), fileManager: mockFM)

        #expect(manager.currentError != nil)
        #expect(await log.holds(.error, containing: "Delete: 500 of 500 item(s) couldn’t be moved to the Trash"))
        let lines = await mine(log, tag)
        #expect(lines.filter { $0.message.hasPrefix("Delete: 500 item(s) failed — ") }.count == 1,
                "\(lines.map { $0.message.prefix(120) })")
        let nameLines = lines.filter { $0.message.hasPrefix("Delete: failed (") }
        #expect(nameLines.count == 3)
        let named = nameLines.map(\.message).joined(separator: ", ")
        #expect(paths.allSatisfy { named.contains($0) }, "a failed delete went unlogged")
        #expect(lines.count == 4, "\(lines.count) lines name these items")
    }
}
