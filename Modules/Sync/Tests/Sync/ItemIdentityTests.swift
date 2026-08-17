import Foundation
import Testing
@testable import Sync

/// The seam that replaces `fileSizeSnapshot`'s `Int?` — whose nil means "directory", "missing",
/// "unstatable" and "unreadable size" alike, and whose call sites then guard with `if let`, so the
/// unknown SKIPS the check instead of refusing.
///
/// Two properties carry the whole point and are asserted directly below: a directory produces a
/// real identity rather than nothing, and an unreadable item produces `.indeterminate` rather than
/// anything a caller could mistake for `.unchanged`.
@Suite struct ItemIdentityTests {

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    private var runningAsRoot: Bool { geteuid() == 0 }

    // MARK: What the old snapshot could not answer

    @Test func aDirectoryGetsARealIdentityWhereTheSizeSnapshotGaveNil() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityDir")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("one.txt"))

        // The snapshot this replaces, on the same folder, for the record.
        #expect(FileSyncManager.fileSizeSnapshot(at: folder, fileManager: FileManager.default) == nil,
                "the size snapshot answers nil for a directory — which is why the guard skipped")

        let identity = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)

        guard case .directory(_, let childCount) = identity else {
            Issue.record("expected a directory identity, got \(identity)")
            return
        }
        #expect(childCount == 1)
    }

    @Test func addingAFileToAFolderIsDrift() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityDrift")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("one.txt"))

        let recorded = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged)

        // The reported scenario: files arrive in a copied folder between the copy and the undo,
        // through Finder, which never touches the undo stack.
        try Data("b".utf8).write(to: folder.appendingPathComponent("two.txt"))

        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .changed)
    }

    @Test func aSameLengthEditIsDriftEvenThoughTheSizeIsIdentical() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentitySameSize")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("bill.txt")
        try Data("2025".utf8).write(to: file)

        let recorded = ItemIdentity.snapshot(at: file, fileManager: FileManager.default)

        // Same byte count, different content — the case a size-only guard waves through.
        try Data("2026".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: file.path)

        #expect(FileSyncManager.fileSizeSnapshot(at: file, fileManager: FileManager.default) == 4,
                "size alone cannot see this edit")
        #expect(recorded.drift(at: file, fileManager: FileManager.default) == .changed)
    }

    // MARK: The unknown is never silently an answer

    @Test func anUnreadableDirectoryIsIndeterminateNotUnchanged() throws {
        guard !runningAsRoot else { return }
        let base = try makeCanonicalTempRoot(prefix: "IdentityLocked")
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("one.txt"))
        let recorded = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)
        try chmod(folder, 0o000)
        defer {
            try? chmod(folder, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        #expect(ItemIdentity.snapshot(at: folder, fileManager: FileManager.default) == .indeterminate)
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .indeterminate,
                "an unreadable folder must not compare equal to the folder it used to be")
    }

    @Test func aMissingItemIsAbsentAndAbsenceIsDriftFromSomething() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityAbsent")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("gone.txt")
        try Data("a".utf8).write(to: file)
        let recorded = ItemIdentity.snapshot(at: file, fileManager: FileManager.default)

        try FileManager.default.removeItem(at: file)

        #expect(ItemIdentity.snapshot(at: file, fileManager: FileManager.default) == .absent)
        #expect(recorded.drift(at: file, fileManager: FileManager.default) == .changed)
    }

    @Test func indeterminateOnEitherSideIsIndeterminate() {
        let file = ItemIdentity.file(size: 10, modified: nil)
        #expect(ItemIdentity.compare(recorded: .indeterminate, current: file) == .indeterminate)
        #expect(ItemIdentity.compare(recorded: file, current: .indeterminate) == .indeterminate)
        #expect(ItemIdentity.compare(recorded: .indeterminate, current: .indeterminate) == .indeterminate)
    }

    /// A file replaced by a directory of the same name is drift, which an `Int?` comparison reads
    /// as nil-and-therefore-skip.
    @Test func aFileReplacedByADirectoryIsDrift() {
        let recorded = ItemIdentity.file(size: 4, modified: nil)
        let current = ItemIdentity.directory(modified: nil, childCount: 0)
        #expect(ItemIdentity.compare(recorded: recorded, current: current) == .changed)
    }

    @Test func anUntouchedItemDoesNotReadAsDrift() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityStable")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("stable.txt")
        try Data("hello".utf8).write(to: file)

        let recorded = ItemIdentity.snapshot(at: file, fileManager: FileManager.default)

        #expect(recorded.drift(at: file, fileManager: FileManager.default) == .unchanged)
    }

    /// The documented limit, asserted so it is a known position rather than an assumption: a change
    /// deep inside an untouched subtree leaves the folder's own date and child count identical, and
    /// this seam answers `.unchanged`. Any caller needing more has to walk the tree.
    @Test func aChangeDeepInsideASubtreeIsNotNoticed() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityDeep")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        let deep = folder.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: deep.appendingPathComponent("leaf.txt"))

        let recorded = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)
        try Data("after-and-longer".utf8).write(to: deep.appendingPathComponent("leaf.txt"))

        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged,
                "known limit: only the folder's own date and immediate child count are compared")
    }

    // MARK: Through the double

    @Test func anUnlistableFolderIsIndeterminateThroughTheMockToo() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/folder"), withIntermediateDirectories: true)
        fm.virtualDisk["/folder/one.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let recorded = ItemIdentity.snapshot(at: URL(fileURLWithPath: "/folder"), fileManager: fm)
        #expect(recorded != .indeterminate)

        fm.unlistableDirectories = ["/folder"]

        #expect(recorded.drift(at: URL(fileURLWithPath: "/folder"), fileManager: fm) == .indeterminate)
    }
}
