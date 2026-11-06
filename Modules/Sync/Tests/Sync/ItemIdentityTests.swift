import Foundation
import Testing
@testable import Sync

/// Pins `ItemIdentity`, the drift check that `fileSizeSnapshot`'s `Int?` can't be: its nil means
/// directory, missing and unreadable alike, so an `if let` guard skips the check instead of
/// refusing. The two properties that matter: a directory gets a real identity, and an unreadable
/// item gets `.indeterminate`, never anything a caller could mistake for `.unchanged`.
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

        // The size snapshot on the same folder, for contrast.
        #expect(FileSyncManager.fileSizeSnapshot(at: folder, fileManager: FileManager.default) == nil,
                "the size snapshot answers nil for a directory — which is why the guard skipped")

        let identity = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)

        guard case .directory(_, let fileNumber) = identity else {
            Issue.record("expected a directory identity, got \(identity)")
            return
        }
        #expect(fileNumber != nil, "the real disk reports the folder's own number")
    }

    @Test func addingAFileToAFolderIsDrift() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentityDrift")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("one.txt"))

        let recorded = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged)

        // Files arrive in a copied folder between the copy and the undo, through Finder, which
        // never touches the undo stack.
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

    /// `attributesOfItem` doesn't follow links, so a symlink to a directory arrives as
    /// symbolicLink with the link's own small size. Folded into `.file` it would look like an
    /// ordinary small file and skip the child-count guard.
    @Test func aSymlinkToADirectoryIsNotMistakenForAFile() throws {
        let base = try makeCanonicalTempRoot(prefix: "IdentitySymlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: target.appendingPathComponent("one.txt"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let identity = ItemIdentity.snapshot(at: link, fileManager: FileManager.default)

        guard case .symlink = identity else {
            Issue.record("a symlink to a directory came back as \(identity)")
            return
        }
        // And it is not equal to a plain file of the same size and date, so a link swapped for a
        // file is drift rather than a match.
        if case .symlink(let size, let modified) = identity {
            #expect(ItemIdentity.compare(recorded: identity,
                                         current: .file(size: size, modified: modified)) == .changed)
        }
    }

    /// A trap: `compare` is equality-based, so two `.absent` sides answer `.unchanged` though
    /// neither was verified. Right for a path that was absent and still is; for a caller that
    /// recorded `.absent` by reading the wrong path (say, one an ancestor rename invalidated, as
    /// in `UndoDriftIdentityTests.undoOfANestedNormalizePassReversesTheChildRenameToo`), the guard
    /// silently switches itself off. Pinned so the behaviour is a decision, not an accident of
    /// `==`.
    @Test func twoUnverifiedAbsencesCompareUnchangedWhichIsTheTrap() {
        #expect(ItemIdentity.compare(recorded: .absent, current: .absent) == .unchanged)
        // An absence on ONE side only is drift, in both directions.
        #expect(ItemIdentity.compare(recorded: .absent, current: .file(size: 4, modified: nil)) == .changed)
        #expect(ItemIdentity.compare(recorded: .file(size: 4, modified: nil), current: .absent) == .changed)
    }

    @Test func indeterminateOnEitherSideIsIndeterminate() {
        let file = ItemIdentity.file(size: 10, modified: nil)
        #expect(ItemIdentity.compare(recorded: .indeterminate, current: file) == .indeterminate)
        #expect(ItemIdentity.compare(recorded: file, current: .indeterminate) == .indeterminate)
        #expect(ItemIdentity.compare(recorded: .indeterminate, current: .indeterminate) == .indeterminate)
    }

    /// A file replaced by a same-named directory is drift; an `Int?` comparison would read nil
    /// and skip.
    @Test func aFileReplacedByADirectoryIsDrift() {
        let recorded = ItemIdentity.file(size: 4, modified: nil)
        let current = ItemIdentity.directory(childNames: "", fileNumber: nil)
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

    /// The shallow identity's known limit: a change deep inside a subtree leaves the folder's own
    /// date and child count identical, so `snapshot` answers `.unchanged`. A caller that can't
    /// afford that records `deepSnapshot` (the copy-undo does);
    /// `DeepFolderIdentityTests.aDeepEditIsNoticedByTheDeepIdentityWhereTheShallowOneIsBlind`
    /// checks both depths on this fixture shape.
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
