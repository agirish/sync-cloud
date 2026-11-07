import Foundation
import Testing
@testable import Sync

/// Pins what `hashOutcome` decides from a file's single metadata read. The trap:
/// `fileExists(atPath:isDirectory:)` resolves a symlink before answering, while `attributesOfItem`
/// has lstat semantics and answers about the link itself. Every verdict must still come from
/// following the link, which is why the directory test below uses a symlink to a directory.
@Suite("Verifier metadata verdicts")
struct FileContentVerifierMetadataTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verifier-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A symlink to a DIRECTORY is unverifiable")
    func symlinkToDirectory() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link-to-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)

        // An outcome test, not a claim about which guard produces it. Making the directory check
        // read the link's own attributes does not fail this: `open(2)` on a directory succeeds, the
        // first read errors, and the verdict is unverifiable either way. The check is kept because
        // it reaches that verdict without opening anything.
        #expect(await FileContentVerifier.hashOutcome(filePath: link.path).hash == nil)
    }

    /// A file manager that reports a size other than the one on disk, standing in for the file
    /// being replaced between the metadata read and the open, a window that can't be staged
    /// deterministically.
    private final class SizeLyingFileManager: FileManaging, @unchecked Sendable {
        let inner = FileManager.default
        let inflateBy: Int
        init(inflateBy: Int) { self.inflateBy = inflateBy }

        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] {
            var attrs = try inner.attributesOfItem(atPath: p)
            if let size = (attrs[.size] as? NSNumber)?.intValue {
                attrs[.size] = NSNumber(value: size + inflateBy)
            }
            return attrs
        }

        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: p, isDirectory: d)
        }
        func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws {
            try inner.setAttributes(a, ofItemAtPath: p)
        }
        func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
        }
        func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
        func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: u, resultingItemURL: o)
        }
        func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
        func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
            try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                        options mask: FileManager.DirectoryEnumerationOptions,
                        errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        }
    }

    /// Also an outcome test. Removing the descriptor size check does not fail it: the read loop's
    /// `totalBytes == size` reaches the same verdict after reading the file. The check is an
    /// optimization that changes no outcome.
    @Test("A size that disagrees with the opened descriptor is unverifiable, not hashed anyway")
    func sizeDisagreementAtOpen() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shrinking.bin")
        try Data(repeating: 3, count: 2048).write(to: file)

        // Truthful manager: hashes.
        #expect(await FileContentVerifier.hashOutcome(filePath: file.path).hash != nil)
        // Manager reporting a larger file than the descriptor holds: refused.
        let lying = SizeLyingFileManager(inflateBy: 512)
        #expect(await FileContentVerifier.hashOutcome(filePath: file.path, fileManager: lying).hash == nil)
    }

    /// The mid-read coherence decision, tested as a pure function because its call site can only
    /// be reached by winning a race against a writer.
    ///
    /// Only one direction of the call site is covered: every successful hash runs this check and
    /// passes, so refusing coherent files would fail everywhere. No test can stage a same-size
    /// rewrite between the two `fstat`s, so the wiring's ability to catch one is argued, not
    /// demonstrated.
    @Test("Coherence: equal stats agree, a moved mtime or size does not, an absent stat abstains")
    func coherenceDecision() {
        func make(sec: Int, nsec: Int, size: Int) -> stat {
            var s = stat()
            s.st_mtimespec = timespec(tv_sec: sec, tv_nsec: nsec)
            s.st_size = off_t(size)
            return s
        }
        let base = make(sec: 1_700_000_000, nsec: 500, size: 4096)

        #expect(FileContentVerifier.snapshotIsCoherent(opened: base, closing: base))
        #expect(!FileContentVerifier.snapshotIsCoherent(
            opened: base, closing: make(sec: 1_700_000_001, nsec: 500, size: 4096)))
        // One nanosecond is enough: a same-size rewrite is what this exists to catch, and the byte
        // count can't see it.
        #expect(!FileContentVerifier.snapshotIsCoherent(
            opened: base, closing: make(sec: 1_700_000_000, nsec: 501, size: 4096)))
        #expect(!FileContentVerifier.snapshotIsCoherent(
            opened: base, closing: make(sec: 1_700_000_000, nsec: 500, size: 4097)))
        // An unanswered question is not evidence of change.
        #expect(FileContentVerifier.snapshotIsCoherent(opened: nil, closing: base))
        #expect(FileContentVerifier.snapshotIsCoherent(opened: base, closing: nil))
    }
}
