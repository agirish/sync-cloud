import Foundation
import Testing
@testable import Dashboard

/// The Details sidebar's computed folder size, and what it says about a folder it couldn't read.
/// Against the real filesystem on purpose: the behaviour rests on `FileManager.enumerator(at:)`
/// returning a non-nil enumerator that yields nothing for a directory it can't list, and a double
/// would only prove things about the double.
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

    /// chmod 000 is a no-op for root, so a locked fixture would be readable and prove nothing.
    /// Records an issue rather than plainly returning: a bare `return` reports the test as passed,
    /// so on a root runner the locked-directory fixtures would go green silently.
    private func skippedBecauseRoot(_ fixture: String, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard geteuid() == 0 else { return false }
        Issue.record("""
            Skipped “\(fixture)”: running as root (euid 0), where chmod 000 does not restrict \
            access, so this fixture cannot tell an unreadable folder from a readable one. It \
            proves nothing on this runner — treat the suite as not having covered it.
            """, sourceLocation: sourceLocation)
        return true
    }

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

        // The exact string is the formatter's business; this checks it is a real total with no
        // "known to be short" marker.
        let text = try #require(size)
        #expect(text.contains("10"), "10,000 bytes across two files: \(text)")
        #expect(!text.hasSuffix("+"))
    }

    /// An empty folder really is zero bytes and must say so; otherwise answering nil for every
    /// folder would satisfy the locked case below.
    @Test func aGenuinelyEmptyFolderIsZeroBytesNotUnknown() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        #expect(size != nil, "an empty folder has a known size — the sidebar must not show “--”")
        // Spelled through the formatter, not hard-coded, so this asserts a zero total rather than
        // Foundation's wording.
        #expect(size == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    /// A folder the walk can't open has no size, not zero bytes. nil renders as "--", the honest
    /// answer for a size nobody could measure.
    @Test func anUnreadableFolderHasNoSizeRatherThanZeroBytes() async throws {
        guard !skippedBecauseRoot("anUnreadableFolderHasNoSizeRatherThanZeroBytes") else { return }
        let scratch = try makeScratch()
        let folder = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder.appendingPathComponent("big.bin"), bytes: 50_000)
        try chmod(folder, 0o000)
        defer {
            try? chmod(folder, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        // The premise: 50 KB is in there, yet the enumerator is non-nil and yields nothing, so a
        // `guard let … else { return nil }` alone never fires.
        let raw = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [])
        #expect(raw != nil, "the else-branch of `guard let enumerator` is dead on a real disk")
        #expect(raw?.allObjects.count == 0)

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        #expect(size == nil, "an unmeasurable folder must not report a size of zero")
    }

    /// A folder whose only content is an unreadable subtree must not read "Zero KB+". It walks as
    /// `.listedWithUnreadableDescendants` with zero bytes, and "+" on zero states nothing.
    @Test func aFolderWhoseOnlyContentIsUnreadableDoesNotReportZeroKilobytesPlus() async throws {
        guard !skippedBecauseRoot("aFolderWhoseOnlyContentIsUnreadableDoesNotReportZeroKilobytesPlus") else { return }
        let scratch = try makeScratch()
        let folder = scratch.appendingPathComponent("hollow")
        let locked = folder.appendingPathComponent("locked-sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(locked.appendingPathComponent("unseen.bin"), bytes: 900_000)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        let size = await DetailsSidebar.computeDirectorySizeString(path: folder.path)

        #expect(size == nil, "no honest number here; the caller renders nil as “--”")
    }

    /// The other half: a partial walk that measured something still reports it as a floor, with the
    /// "+", or nil for every partial folder would satisfy the test above.
    @Test func aPartialWalkThatMeasuredSomethingStillReportsItAsAFloor() async throws {
        guard !skippedBecauseRoot("aPartialWalkThatMeasuredSomethingStillReportsItAsAFloor") else { return }
        let scratch = try makeScratch()
        let folder = scratch.appendingPathComponent("partial-nonzero")
        let locked = folder.appendingPathComponent("locked-sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(folder.appendingPathComponent("seen.bin"), bytes: 12_000)
        try write(locked.appendingPathComponent("unseen.bin"), bytes: 900_000)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        let size = try #require(await DetailsSidebar.computeDirectorySizeString(path: folder.path),
                                "12 KB was measured — the folder is not unanswerable")
        #expect(size.hasSuffix("+"), "the withheld subtree makes this a floor, not a total: \(size)")
        #expect(size.hasPrefix("12"), "the bytes it did see, not a floor of nothing: \(size)")
    }

    // MARK: A symlinked folder is not an unreadable one

    /// `enumerator(at:)` doesn't traverse a symlinked directory: it comes back non-nil, yields zero
    /// entries and fires the error handler with the link's URL, the same signature that means
    /// `.unreadable`. Without handling, a folder Finder sizes fine would show "--".
    @Test func aSymlinkedFolderIsSizedRatherThanCalledUnreadable() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let real = scratch.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write(real.appendingPathComponent("a.bin"), bytes: 4000)
        try write(real.appendingPathComponent("b.bin"), bytes: 6000)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The premise: through the link, the URL-based enumerator sees nothing and complains.
        final class Seen: @unchecked Sendable { var failures = 0 }
        let seen = Seen()
        let raw = FileManager.default.enumerator(
            at: link, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in seen.failures += 1; return true })
        #expect(raw != nil, "non-nil, as everywhere else in this file")
        #expect(raw?.allObjects.count == 0, "zero entries through a link to a folder holding two")
        #expect(seen.failures > 0, "…and it reports a failure, which is what made it look unreadable")

        // The control: asked directly, the same tree sizes fine, so the fixture can't pass on a
        // tree that is empty for some other reason.
        let direct = try #require(await DetailsSidebar.computeDirectorySizeString(path: real.path))
        #expect(direct.contains("10"), "the control: \(direct)")

        let throughLink = try #require(
            await DetailsSidebar.computeDirectorySizeString(path: link.path),
            "a symlinked folder must be sized, not rendered as “--”")
        #expect(throughLink == direct,
                "the link and its target are the same folder: \(throughLink) vs \(direct)")
        #expect(!throughLink.hasSuffix("+"), "nothing was withheld — this is a complete total")
    }

    /// The other direction: a link to a locked folder is still `.unreadable`, or a retry that fires
    /// unconditionally and reports zero for locked folders behind links would pass.
    @Test func aLinkToALockedFolderIsStillUnreadable() async throws {
        guard !skippedBecauseRoot("aLinkToALockedFolderIsStillUnreadable") else { return }
        let scratch = try makeScratch()
        let locked = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(locked.appendingPathComponent("secret.bin"), bytes: 8000)
        let openFolder = scratch.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: openFolder, withIntermediateDirectories: true)
        try write(openFolder.appendingPathComponent("plain.bin"), bytes: 8000)

        let lockedLink = scratch.appendingPathComponent("locked-link")
        let openLink = scratch.appendingPathComponent("open-link")
        try FileManager.default.createSymbolicLink(at: lockedLink, withDestinationURL: locked)
        try FileManager.default.createSymbolicLink(at: openLink, withDestinationURL: openFolder)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }

        // Same shape, byte count and kind of link; only the permission differs, so the two
        // answers can't both come from a fallback.
        let throughOpen = await DetailsSidebar.computeDirectorySizeString(path: openLink.path)
        let throughLocked = await DetailsSidebar.computeDirectorySizeString(path: lockedLink.path)

        let open = try #require(throughOpen, "a link to a readable folder must be sized")
        #expect(open.contains("8"), "the readable link's real total: \(open)")
        #expect(throughLocked == nil,
                "a link to a locked folder has no honest size — got \(throughLocked ?? "nil")")
        // If these ever agree, one of the two branches has stopped deciding anything.
        #expect(throughOpen != throughLocked)
    }

    /// A broken or self-referential link gets no size: `traversableTarget` refuses both. A third
    /// link to a real folder is the control, or a function that stopped measuring would pass.
    @Test func aBrokenOrSelfReferentialLinkHasNoSize() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let broken = scratch.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: scratch.appendingPathComponent("nowhere"))
        let loop = scratch.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)

        let real = scratch.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write(real.appendingPathComponent("a.bin"), bytes: 4096)
        let sound = scratch.appendingPathComponent("sound")
        try FileManager.default.createSymbolicLink(at: sound, withDestinationURL: real)

        let brokenSize = await DetailsSidebar.computeDirectorySizeString(path: broken.path)
        let loopSize = await DetailsSidebar.computeDirectorySizeString(path: loop.path)
        let soundSize = await DetailsSidebar.computeDirectorySizeString(path: sound.path)

        #expect(brokenSize == nil, "a link to nowhere has no size — got \(brokenSize ?? "nil")")
        #expect(loopSize == nil, "a link to itself has no size — got \(loopSize ?? "nil")")
        // The control. If this is nil too, the two above prove nothing about links.
        let measured = try #require(soundSize, "a link to a readable folder must be sized")
        #expect(measured.contains("4"), "the control link's real total: \(measured)")
    }
}
