import Foundation
import Testing
@testable import Dashboard

/// The Details sidebar's computed folder size, and what it says about a folder it could not read.
///
/// Against the REAL filesystem on purpose. The behaviour under test is a property of
/// `FileManager.enumerator(at:)` — it returns a non-nil enumerator that yields zero entries for a
/// directory it cannot list — so a double would only be evidence about the double.
@Suite struct DetailsSidebarSizeTests {

    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailsSidebarSizeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// chmod 000 is a no-op for root, so the locked fixture would be readable and prove nothing.
    private var runningAsRoot: Bool { geteuid() == 0 }

    private func write(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func aReadableFolderReportsItsTotal() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder.appendingPathComponent("a.bin"), bytes: 4000)
        try write(folder.appendingPathComponent("b.bin"), bytes: 6000)

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        // The exact string is the formatter's business; that it is a real total, and carries no
        // "known to be short" marker, is this function's.
        let text = try #require(size)
        #expect(text.contains("10"), "10,000 bytes across two files: \(text)")
        #expect(!text.hasSuffix("+"))
    }

    /// A folder holding nothing really is zero bytes, and must keep saying so. Without this, a
    /// change that answered nil for every folder would satisfy the locked case below while
    /// destroying the ordinary one.
    @Test func aGenuinelyEmptyFolderIsZeroBytesNotUnknown() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        #expect(size != nil, "an empty folder has a known size — the sidebar must not show “--”")
        // "Zero KB" on this formatter; spelled through the formatter rather than hard-coded so
        // the assertion is about the total being zero, not about Foundation's wording.
        #expect(size == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    /// The defect: this walk totalled 0 bytes for a folder it could not open, and the sidebar
    /// printed that as the folder's size. nil is what the caller renders as "--", which is the
    /// honest answer for a size nobody could measure.
    @Test func anUnreadableFolderHasNoSizeRatherThanZeroBytes() async throws {
        guard !runningAsRoot else { return }
        let scratch = try makeScratch()
        let folder = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder.appendingPathComponent("big.bin"), bytes: 50_000)
        try chmod(folder, 0o000)
        defer {
            try? chmod(folder, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        // The premise, measured rather than assumed: 50 KB is in there and the enumerator is
        // non-nil and hands back nothing, so the `guard let … else { return nil }` never fired.
        let raw = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [])
        #expect(raw != nil, "the else-branch of `guard let enumerator` is dead on a real disk")
        #expect(raw?.allObjects.count == 0)

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        #expect(size == nil, "an unmeasurable folder must not report a size of zero")
    }

    /// The middle case: the folder opened, a subfolder inside it did not. The total is then a
    /// floor under the real one, and the "+" says so rather than presenting it as complete.
    @Test func aPartlyReadableFolderMarksItsTotalAsAFloor() async throws {
        guard !runningAsRoot else { return }
        let scratch = try makeScratch()
        let folder = scratch.appendingPathComponent("partial")
        let locked = folder.appendingPathComponent("locked-sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(folder.appendingPathComponent("seen.bin"), bytes: 8000)
        try write(locked.appendingPathComponent("unseen.bin"), bytes: 900_000)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        let size = try #require(await DetailsSidebar.computeDirectorySizeString(path: folder.path))

        #expect(size.hasSuffix("+"), "the withheld subtree makes this a floor, not a total: \(size)")
        #expect(!size.contains("900"), "nothing behind the locked subfolder was counted")
    }
}
