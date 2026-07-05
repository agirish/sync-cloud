import Testing
import Foundation
@testable import Sync

/// Coverage for FileContentVerifier, the SHA-256 checksum layer behind the "Verify with checksum"
/// flows (GUI verify buttons and the CLI --verify option). It reads real bytes via
/// `Data(contentsOf:)` and guards on directory / missing / oversize / partial-read, so these tests
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
