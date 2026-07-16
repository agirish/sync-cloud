import Testing
import Foundation
@testable import Sync

/// Coverage for FileContentVerifier, the SHA-256 checksum layer behind the "Verify with checksum"
/// flows (GUI verify buttons and the CLI --verify option). It stream-reads real bytes via
/// `FileHandle` and guards on directory / missing / oversize / partial-read, so these tests
/// exercise it against real files in a temp directory rather than the virtual mock disk.
@Suite struct FileContentVerifierTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileContentVerifierTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func testSha256HexMatchesKnownDigest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        // Well-known SHA-256("abc").
        let hex = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func testSha256HexNilForDirectoryAndMissing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Directory -> nil (guarded before any read).
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.path) == nil)
        // Missing path -> nil.
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.appendingPathComponent("nope").path) == nil)
    }

    @Test func testFilesHaveSameContentTrueForIdenticalBytes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data("identical payload".utf8).write(to: a)
        try Data("identical payload".utf8).write(to: b)

        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: a.path, rightPath: b.path) == true)
    }

    @Test func testFilesHaveSameContentFalseForDifferingBytesOfEqualSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Same byte length, different content: proves it compares hashes, not sizes.
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data("aaaaaa".utf8).write(to: a)
        try Data("bbbbbb".utf8).write(to: b)

        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: a.path, rightPath: b.path) == false)
    }

    /// A symlinked file must verify against its target's bytes: `attributesOfItem` lstats the
    /// link itself (its "size" is the destination-path byte count) while the FileHandle read
    /// follows the link, so without resolving, every symlink came out "Could not verify".
    @Test func testSymlinkedFileVerifiesAgainstTargetContent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.bin")
        try Data("symlinked payload".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let linkHex = await FileContentVerifier.sha256Hex(filePath: link.path)
        let targetHex = await FileContentVerifier.sha256Hex(filePath: target.path)
        #expect(linkHex != nil)
        #expect(linkHex == targetHex)
        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: link.path, rightPath: target.path) == true)

        // A link whose target vanished stays conservative: nil, never a bogus verify.
        try FileManager.default.removeItem(at: target)
        #expect(await FileContentVerifier.sha256Hex(filePath: link.path) == nil)
        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: link.path, rightPath: link.path) == nil)
    }

    // MARK: Classified outcomes (hashOutcome)

    @Test func hashOutcomeClassifiesTooLargeDistinctFromUnreadable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let big = dir.appendingPathComponent("big.bin")
        try Data(repeating: 0x42, count: 4096).write(to: big)

        // Over the (injected) cap → skippedTooLarge, and never read.
        #expect(await FileContentVerifier.hashOutcome(filePath: big.path, maxBytes: 1000) == .skippedTooLarge)
        // Under the cap → hashed, agreeing with sha256Hex.
        let expected = await FileContentVerifier.sha256Hex(filePath: big.path)
        #expect(await FileContentVerifier.hashOutcome(filePath: big.path) == .hashed(expected!))
        // Directory / missing → unverifiable (not a size skip).
        #expect(await FileContentVerifier.hashOutcome(filePath: dir.path) == .unverifiable)
        #expect(await FileContentVerifier.hashOutcome(filePath: dir.appendingPathComponent("nope").path) == .unverifiable)
    }

    @Test func hashOutcomeSkipsCloudOnlyFilesWithoutOpeningThem() async throws {
        // A dataless placeholder can't be fabricated in tests (SF_DATALESS is provider-set), so
        // the decision seam is injected: a file flagged cloud-only must be skipped BEFORE any
        // read — hashing it would force the provider to download the whole file.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("placeholder.bin")
        try Data(repeating: 7, count: 512).write(to: f)

        let outcome = await FileContentVerifier.hashOutcome(filePath: f.path, isCloudOnly: { _ in true })
        #expect(outcome == .skippedCloudOnly)

        // Same file, not flagged → hashed normally (the default seam returns false for real
        // local files, so this also mirrors production behavior on materialized content).
        let local = await FileContentVerifier.hashOutcome(filePath: f.path, isCloudOnly: { _ in false })
        #expect(local.hash != nil)
        let production = await FileContentVerifier.hashOutcome(filePath: f.path)
        #expect(production == local)
    }

    @Test func cloudOnlyOutranksTooLargeForADatalessOversizeFile() async throws {
        // Round-5: the size guard ran before the dataless check, so a cloud-only file over the
        // hash cap counted as skippedTooLarge — and Tidy's per-reason note told the user to
        // raise the cap when the actual remedy is "download it". A dataless file must classify
        // as cloud-only whatever its size (and still without a single byte read).
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("huge-placeholder.bin")
        try Data(repeating: 7, count: 4096).write(to: f)   // over the injected 1000-byte cap

        let outcome = await FileContentVerifier.hashOutcome(filePath: f.path, maxBytes: 1000,
                                                            isCloudOnly: { _ in true })
        #expect(outcome == .skippedCloudOnly)

        // The same oversize file NOT flagged cloud-only still classifies as too large.
        let local = await FileContentVerifier.hashOutcome(filePath: f.path, maxBytes: 1000,
                                                          isCloudOnly: { _ in false })
        #expect(local == .skippedTooLarge)
    }

    @Test func cachedHashStillWinsOverTheCloudOnlySkip() async throws {
        // A file hashed while local and since evicted to cloud-only: the cache key (path, mtime,
        // size) still matches — eviction doesn't change content — so the stored digest is
        // returned without a read instead of degrading to a skip.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("evicted.bin")
        try Data(repeating: 3, count: 256).write(to: f)

        let cache = ContentHashCache()
        let first = await FileContentVerifier.hashOutcome(filePath: f.path, cache: cache,
                                                          isCloudOnly: { _ in false })
        let hex = try #require(first.hash)

        let evicted = await FileContentVerifier.hashOutcome(filePath: f.path, cache: cache,
                                                            isCloudOnly: { _ in true })
        #expect(evicted == .hashed(hex))
        // Without the cache the same call skips as cloud-only.
        let uncached = await FileContentVerifier.hashOutcome(filePath: f.path,
                                                             isCloudOnly: { _ in true })
        #expect(uncached == .skippedCloudOnly)
    }

    @Test func cloudOnlyCheckSeesTheResolvedSymlinkTarget() async throws {
        // The file a symlink would OPEN is its target — that's the path whose dataless flag
        // matters. The seam must receive the resolved path, not the link's own.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.bin")
        try Data(repeating: 9, count: 128).write(to: target)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let checked = LockedBox<[String]>([])
        _ = await FileContentVerifier.hashOutcome(filePath: link.path, isCloudOnly: { path in
            checked.withLock { $0.append(path) }
            return false
        })
        let resolvedTarget = (target.path as NSString).resolvingSymlinksInPath
        #expect(checked.withLock { $0 } == [resolvedTarget])
    }

    @Test func sha256HexStillCollapsesEveryNonHashToNil() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 64).write(to: f)
        // The classic API is a thin wrapper over hashOutcome — same digest, nil for a directory.
        #expect(await FileContentVerifier.sha256Hex(filePath: f.path) != nil)
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.path) == nil)
    }

    @Test func testFilesHaveSameContentNilWhenEitherSideUnhashable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: file)

        // Right side is a directory -> unhashable -> the nil short-circuits the whole comparison.
        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: file.path, rightPath: dir.path) == nil)
        // Left side missing -> nil.
        let missing = dir.appendingPathComponent("gone.txt").path
        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: missing, rightPath: file.path) == nil)
    }
}
