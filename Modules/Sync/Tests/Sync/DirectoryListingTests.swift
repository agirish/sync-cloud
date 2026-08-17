import Foundation
import Testing
@testable import Sync

/// The seam that keeps "could not be listed" apart from "listed, and it is empty".
///
/// Most of these run against the REAL filesystem on purpose. The whole reason the seam exists is a
/// behaviour of the real `FileManager` — a non-nil enumerator that yields zero entries for a
/// directory it cannot read — and a mock is only evidence about the mock. The mock cases at the
/// bottom exist to prove the double is faithful to what the real one was measured doing, so that
/// tests written against it in other suites are not passing vacuously.
@Suite struct DirectoryListingTests {

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// chmod 000 is a no-op for root (it can read anything), so these fixtures prove nothing there.
    private var runningAsRoot: Bool { geteuid() == 0 }

    private func makeDir(_ url: URL, files: Int = 0) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data("x".utf8).write(to: url.appendingPathComponent("f\(i).txt"))
        }
    }

    // MARK: The distinction itself, on a real disk

    @Test func anEmptyDirectoryIsListedAndSaysSo() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListEmpty")
        defer { try? FileManager.default.removeItem(at: base) }
        let empty = base.appendingPathComponent("empty")
        try makeDir(empty)

        let listing = FileManager.default.listing(of: empty)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.isEmpty)
        #expect(listing.isComplete)
    }

    @Test func aPopulatedDirectoryComesBackComplete() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListFull")
        defer { try? FileManager.default.removeItem(at: base) }
        let full = base.appendingPathComponent("full")
        try makeDir(full, files: 3)

        let listing = FileManager.default.listing(of: full)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.count == 3)
    }

    /// The finding this seam was built for. Before it, this directory and the empty one above were
    /// the same value — which is how a folder-replace confirmation could say "0 items will be
    /// removed" about a folder whose contents it was about to remove.
    @Test func anUnreadableDirectoryIsNotReportedAsEmpty() throws {
        guard !runningAsRoot else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListLocked")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        // The idiom this replaces, measured in place: the guard's else-branch never fires, and the
        // enumerator hands back nothing. Anything reading that as "empty" is reading a failure.
        let rawEnumerator = FileManager.default.enumerator(at: locked, includingPropertiesForKeys: nil,
                                                           options: [], errorHandler: nil)
        #expect(rawEnumerator != nil, "the else-branch of `guard let enumerator` is dead on a real disk")
        #expect(rawEnumerator?.allObjects.count == 0)

        let listing = FileManager.default.listing(of: locked)

        #expect(listing.outcome == .unreadable)
        #expect(!listing.isComplete)
        #expect(listing.urls.isEmpty, "urls is empty here, but it is not evidence of emptiness")
    }

    @Test func aDirectoryThatDoesNotExistIsUnreadableRatherThanEmpty() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListGone")
        defer { try? FileManager.default.removeItem(at: base) }

        let listing = FileManager.default.listing(of: base.appendingPathComponent("never-created"))

        #expect(listing.outcome == .unreadable)
    }

    // MARK: Partial answers

    @Test func aReadableRootWithALockedSubtreeIsPartialNotComplete() throws {
        guard !runningAsRoot else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListPartial")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 1)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 4)
        try chmod(sub, 0o000)
        defer {
            try? chmod(sub, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: root, options: [])

        #expect(listing.outcome == .listedWithUnreadableDescendants)
        #expect(!listing.isComplete)
        #expect(listing.urls.count == 2, "the locked subdirectory is still yielded as an entry")
        #expect(listing.unreadableDescendants.count == 1)
        #expect(listing.unreadableDescendants.first?.lastPathComponent == "locked-sub")
    }

    /// A shallow listing never descends, so the same fixture is a complete answer to a narrower
    /// question. This pins the default `options:` as part of the contract rather than a detail.
    @Test func aShallowListingOfThatSameTreeIsComplete() throws {
        guard !runningAsRoot else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListShallow")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 1)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 4)
        try chmod(sub, 0o000)
        defer {
            try? chmod(sub, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: root)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.count == 2)
        #expect(listing.unreadableDescendants.isEmpty)
    }

    // MARK: The spelling of the root must not change the answer

    /// The reason the root-failure decision is made on the entry count and not by comparing the
    /// reported URL to the asked-for one: measured, `/var/…` asked comes back reported as
    /// `/private/var/…`, and `standardizedFileURL` does not close that gap. Each spelling below is
    /// the same locked directory and must give the same verdict.
    @Test func everySpellingOfALockedRootIsStillUnreadable() throws {
        guard !runningAsRoot else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListSpelling")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 2)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: locked)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let spellings: [(String, URL)] = [
            ("plain", locked),
            ("trailing slash", URL(fileURLWithPath: locked.path + "/")),
            ("dot segment", base.appendingPathComponent("./locked")),
            ("via symlink", link),
        ]
        for (name, url) in spellings {
            #expect(FileManager.default.listing(of: url).outcome == .unreadable,
                    "\(name) spelling of a locked directory read as something other than unreadable")
        }
    }

    // MARK: The double is faithful to the real thing

    @Test func theMockModelsAnUnlistableDirectoryTheWayTheRealOneBehaves() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/locked"), withIntermediateDirectories: true)
        fm.virtualDisk["/locked/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.unlistableDirectories = ["/locked"]

        // Faithful means non-nil-and-empty, not nil: a mock returning nil would make the dead
        // `guard let … else` branch look tested while it stays dead in production.
        let raw = fm.enumerator(at: URL(fileURLWithPath: "/locked"), includingPropertiesForKeys: nil,
                                options: [], errorHandler: nil)
        #expect(raw != nil)
        #expect(raw?.allObjects.count == 0)

        #expect(fm.listing(of: URL(fileURLWithPath: "/locked")).outcome == .unreadable)
    }

    @Test func theMockSeparatesAnEmptyDirectoryFromAnUnlistableOne() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/locked"), withIntermediateDirectories: true)
        fm.unlistableDirectories = ["/locked"]

        #expect(fm.listing(of: URL(fileURLWithPath: "/empty")).outcome == .listed)
        #expect(fm.listing(of: URL(fileURLWithPath: "/locked")).outcome == .unreadable)
    }

    @Test func theMockReportsAnUnlistableDescendantAsAPartialAnswer() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/root"), withIntermediateDirectories: true)
        fm.virtualDisk["/root/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        try fm.createDirectory(at: URL(fileURLWithPath: "/root/sub"), withIntermediateDirectories: true)
        fm.virtualDisk["/root/sub/hidden.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.unlistableDirectories = ["/root/sub"]

        let listing = fm.listing(of: URL(fileURLWithPath: "/root"), options: [])

        #expect(listing.outcome == .listedWithUnreadableDescendants)
        #expect(listing.unreadableDescendants.map(\.path) == ["/root/sub"])
        #expect(!listing.urls.contains { $0.path == "/root/sub/hidden.txt" },
                "contents of an unlistable directory must not leak into the listing")
    }
}
