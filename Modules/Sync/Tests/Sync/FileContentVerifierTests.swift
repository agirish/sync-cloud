import Testing
import Foundation
import CryptoKit
@testable import Sync

/// Coverage for FileContentVerifier, the SHA-256 checksum layer behind the "Verify with checksum"
/// flows (GUI verify buttons and the CLI --verify option). It stream-reads real bytes via
/// `FileHandle` and guards on directory / missing / cloud-only / partial-read, so these tests
/// exercise it against real files in a temp directory rather than the virtual mock disk.
@Suite struct FileContentVerifierTests {


    @Test func testSha256HexMatchesKnownDigest() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        // Well-known SHA-256("abc").
        let hex = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func testSha256HexNilForDirectoryAndMissing() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Directory -> nil (guarded before any read).
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.path) == nil)
        // Missing path -> nil.
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.appendingPathComponent("nope").path) == nil)
    }

    @Test func testFilesHaveSameContentTrueForIdenticalBytes() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data("identical payload".utf8).write(to: a)
        try Data("identical payload".utf8).write(to: b)

        #expect(await FileContentVerifier.filesHaveSameContent(leftPath: a.path, rightPath: b.path) == true)
    }

    @Test func testFilesHaveSameContentFalseForDifferingBytesOfEqualSize() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
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
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
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

    /// A sparse file: `size` bytes of zeros, holding no disk blocks, with `bytes` written at their
    /// offsets. Lets a test hash a file past the old 100 MB cap without writing 100 MB.
    private func sparseFile(at url: URL, size: Int, bytes: [Int: UInt8]) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
        for (offset, byte) in bytes {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data([byte]))
        }
    }

    /// One byte past the old 100 MB cap, which used to answer `skippedTooLarge` without a read. The
    /// expected digest is from Python's `hashlib` over the same bytes — an implementation that is
    /// not this one — and the marked bytes sit either side of the first 4 MB chunk boundary and on
    /// the very last byte, the one the old cap excluded, so a lost or doubled chunk changes it.
    @Test func aFileJustOverTheOldCapIsHashedWhole() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = 4 * 1024 * 1024
        let size = 100 * 1024 * 1024 + 1
        let f = dir.appendingPathComponent("over-the-old-cap.bin")
        try sparseFile(at: f, size: size, bytes: [0: 1, chunk - 1: 2, chunk: 3, size - 1: 4])

        let outcome = await FileContentVerifier.hashOutcome(filePath: f.path, isCloudOnly: { _ in false })
        #expect(outcome == .hashed("8a50adce3382a87a511b8d0d17a304eb9445d39c9b70910be5b6e7fafba0e773"))
    }

    /// A directory and a missing path are `.unverifiable` — a skip the duplicate scan counts — and
    /// not `.cancelled`, which it does not.
    @Test func aDirectoryAndAMissingPathAreUnverifiableNotCancelled() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await FileContentVerifier.hashOutcome(filePath: dir.path) == .unverifiable)
        #expect(await FileContentVerifier.hashOutcome(filePath: dir.appendingPathComponent("nope").path)
                == .unverifiable)
    }

    /// The first side that cannot be hashed stops the other: the answer is nil either way. The
    /// left is missing and fails at once; the right's first check waits — bounded — to be
    /// cancelled. Without the stop it waits out its bound and the file is read whole and cached.
    @Test func aPairWithAnUnhashableSideStopsReadingTheOther() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let right = dir.appendingPathComponent("long.bin")
        try sparseFile(at: right, size: 5 * 4 * 1024 * 1024, bytes: [0: 1])
        let cache = ContentHashCache()

        let waited = LockedBox(false)
        let same = await FileContentVerifier.filesHaveSameContent(
            leftPath: dir.appendingPathComponent("missing").path, rightPath: right.path, cache: cache,
            isCancelled: {
                // Only the first check waits, so a failing run costs one bound, not one per chunk.
                if !waited.withLock({ let first = !$0; $0 = true; return first }) { return false }
                let deadline = Date().addingTimeInterval(10)
                while !Task.isCancelled && Date() < deadline { usleep(1000) }
                return false
            })
        #expect(same == nil)
        // The cache is the witness: unstopped, the right side is read to the end and stored. Not
        // whether its check saw the cancel — the cancel can land before the right side's first
        // check, which then never asks; either way it must not have been read whole.
        #expect(await cache.count == 0)
    }

    /// `filesHaveSameContent` hands its `isCancelled` to both reads: a stop answers nil, asks the
    /// check, and caches nothing — what Verify All's Stop rests on.
    @Test func filesHaveSameContentPassesItsStopToBothReads() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 64).write(to: a)
        try Data(repeating: 1, count: 64).write(to: b)
        let cache = ContentHashCache()
        let asked = LockedBox(0)
        let same = await FileContentVerifier.filesHaveSameContent(
            leftPath: a.path, rightPath: b.path, cache: cache,
            isCancelled: { asked.withLock { $0 += 1 }; return true })
        #expect(same == nil)
        // At least one read asked. Not exactly two: the first `.cancelled` stops its sibling, which
        // may then see its own task cancelled before it gets to ask.
        #expect(asked.withLock { $0 } >= 1)
        #expect(await cache.count == 0)
        // The control: the same pair, not stopped, is identical — and BOTH reads ask. A 64-byte
        // file asks three times (before the open, before its one chunk, before the end), so one
        // side alone would answer three.
        let askedUnstopped = LockedBox(0)
        #expect(await FileContentVerifier.filesHaveSameContent(
            leftPath: a.path, rightPath: b.path,
            isCancelled: { askedUnstopped.withLock { $0 += 1 }; return false }) == true)
        #expect(askedUnstopped.withLock { $0 } == 6)
    }

    private static let chunk = 4 * 1024 * 1024
    static let chunkBoundarySizes: [Int] = [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk + 3]

    /// The streamed digest equals a one-shot SHA-256 of the same bytes at every size that meets a
    /// chunk boundary — the sizes where a streaming loop drops or repeats bytes. These are the
    /// digests the hasher gave under the old cap too: what changed is which files reach the loop.
    @Test(arguments: Self.chunkBoundarySizes)
    func streamedDigestMatchesAOneShotDigest(size: Int) async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let f = dir.appendingPathComponent("f.bin")
        try bytes.write(to: f)

        let expected = HexEncoding.string(SHA256.hash(data: bytes))
        #expect(await FileContentVerifier.hashOutcome(filePath: f.path, isCloudOnly: { _ in false })
                == .hashed(expected))
    }

    /// `isCancelled` is asked before the open and before every chunk; once it says yes, the read
    /// stops there and answers `.cancelled`, caching nothing. Three answers on a five-chunk file:
    /// the open, chunk one, then stop — so the count proves it stopped mid-file, not at the end.
    @Test func aCancelledCheckStopsMidFileAndCachesNothing() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("long.bin")
        try sparseFile(at: f, size: 5 * 4 * 1024 * 1024, bytes: [0: 1])

        let asked = LockedBox(0)
        let cache = ContentHashCache()
        let outcome = await FileContentVerifier.hashOutcome(
            filePath: f.path, cache: cache, isCloudOnly: { _ in false },
            isCancelled: { asked.withLock { $0 += 1; return $0 >= 3 } })
        #expect(outcome == .cancelled)
        #expect(asked.withLock { $0 } == 3)
        #expect(await cache.count == 0)
        // The same file, not cancelled, hashes — so `.cancelled` came from the stop, not the file.
        #expect(await FileContentVerifier.hashOutcome(filePath: f.path, cache: cache,
                                                      isCloudOnly: { _ in false }).hash != nil)
    }

    /// Cancelling the CALLING task reaches the read, though it runs on a detached task that does
    /// not inherit cancellation. Deterministic: the task is cancelled from inside its own second
    /// chunk check, and the next check must see it through the forwarded cancellation alone — the
    /// closure keeps answering no. Without the forwarding the whole file is hashed.
    @Test func cancellingTheCallerStopsTheReadAtTheNextChunk() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("long.bin")
        try sparseFile(at: f, size: 5 * 4 * 1024 * 1024, bytes: [0: 1])

        let caller = LockedBox<Task<FileContentVerifier.HashOutcome, Never>?>(nil)
        let asked = LockedBox(0)
        // Held until the box holds the task, so the second check always has a task to cancel.
        let (ready, go) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in ready { break }
            return await FileContentVerifier.hashOutcome(filePath: f.path, isCloudOnly: { _ in false },
                                                         isCancelled: {
                if asked.withLock({ $0 += 1; return $0 }) == 2 { caller.withLock { $0?.cancel() } }
                return false
            })
        }
        caller.withLock { $0 = task }
        go.yield()
        go.finish()
        #expect(await task.value == .cancelled)
        #expect(asked.withLock { $0 } == 2)
    }

    // MARK: Edge samples (the duplicate scan's pre-check)

    /// Equal ends give equal samples whatever the middle holds; a different first or last byte
    /// gives a different one. The sample proves difference only — which is why the middle case is
    /// the one that must come out EQUAL.
    @Test func anEdgeSampleSeesBothEndsAndNotTheMiddle() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 2 * FileContentVerifier.edgeSampleBytes + 4096
        func sample(_ name: String, _ bytes: [Int: UInt8]) async throws -> String? {
            let f = dir.appendingPathComponent(name)
            try sparseFile(at: f, size: size, bytes: bytes)
            return await FileContentVerifier.edgeSample(filePath: f.path, size: size, isCloudOnly: { _ in false })
        }
        let plain = try #require(try await sample("plain", [:]))
        #expect(try await sample("middle", [size / 2: 1]) == plain)
        #expect(try await sample("first", [0: 1]) != plain)
        #expect(try await sample("last", [size - 1: 1]) != plain)
    }

    /// Every case where no sample can be taken answers nil — unknown, never "different": a
    /// cloud-only file, a size that is not the file's, a missing file.
    @Test func anEdgeSampleIsNilWhenItCannotBeTaken() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.bin")
        try Data(repeating: 5, count: 3000).write(to: f)

        // The seam is asked about the path as given — as ``hashOutcome`` asks — and not a
        // resolved one, which turns a temp directory's `/private/var/…` into `/var/…`.
        let asked = LockedBox<[String]>([])
        #expect(await FileContentVerifier.edgeSample(filePath: f.path, size: 3000, isCloudOnly: { path in
            asked.withLock { $0.append(path) }
            return false
        }) != nil)
        #expect(asked.withLock { $0 } == [f.path])
        #expect(await FileContentVerifier.edgeSample(filePath: f.path, size: 3000, isCloudOnly: { _ in true }) == nil)
        #expect(await FileContentVerifier.edgeSample(filePath: f.path, size: 2999, isCloudOnly: { _ in false }) == nil)
        #expect(await FileContentVerifier.edgeSample(filePath: dir.appendingPathComponent("nope").path,
                                                     size: 3000, isCloudOnly: { _ in false }) == nil)
    }

    @Test func hashOutcomeSkipsCloudOnlyFilesWithoutOpeningThem() async throws {
        // A dataless placeholder can't be fabricated in tests (SF_DATALESS is provider-set), so
        // the decision seam is injected: a file flagged cloud-only must be skipped BEFORE any
        // read — hashing it would force the provider to download the whole file.
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
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

    @Test func cachedHashStillWinsOverTheCloudOnlySkip() async throws {
        // A file hashed while local and since evicted to cloud-only: the cache key (path, mtime,
        // size) still matches — eviction doesn't change content — so the stored digest is
        // returned without a read instead of degrading to a skip.
        let dir = try makeCanonicalTempRoot(prefix: "SyncTest")
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
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
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
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 64).write(to: f)
        // The classic API is a thin wrapper over hashOutcome — same digest, nil for a directory.
        #expect(await FileContentVerifier.sha256Hex(filePath: f.path) != nil)
        #expect(await FileContentVerifier.sha256Hex(filePath: dir.path) == nil)
    }

    @Test func testFilesHaveSameContentNilWhenEitherSideUnhashable() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FileContentVerifierTest")
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
