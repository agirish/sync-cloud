import Foundation
import CryptoKit
import Testing
@testable import Sync

/// Replays the fingerprint over a real document tree and measures it — the check that decided this
/// feature's rules, kept so it can be re-run rather than re-derived.
///
/// **Off unless one of two environment variables is set.** Not `.enabled(if: fileExists)`: CI's
/// runner is this Mac as this user, so a path test would happily find the real tree there and spend
/// a minute of every CI run parsing it. An environment variable nothing but a deliberate invocation
/// sets is what actually keeps it off.
///
///     SYNCCLOUD_FINGERPRINT_REPLAY_ROOT=~/Documents swift test --filter CorpusReplay
///
/// **`SYNCCLOUD_FINGERPRINT_REPLAY_LIST` takes a newline-delimited path list instead of walking**,
/// and it exists because the walk is the fragile half. On the tree this was measured against,
/// `FileManager.enumerator` blocked indefinitely in `open()` on one subtree mid-session — zero CPU,
/// no error, nothing to time out against — while opening and reading those same documents by path
/// stayed fine. That is a file-provider condition rather than anything the fingerprint does, but a
/// measurement harness that can be stopped by it is a measurement that does not get taken.
///
/// **Ground truth is byte-identity, which is the only label the tree carries for free.** Two files
/// with the same SHA-256 are the same document, no argument. That gives recall a hard, unarguable
/// assertion: a byte-identical pair whose fingerprints DISAGREE is a defect in the rules, and the
/// count must be zero. It gives precision nothing directly — a pair the fingerprint matches and the
/// bytes do not is either a find or a false claim, and only reading them says which — so the run
/// prints those groups for the audit rather than asserting a number it cannot know.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SYNCCLOUD_FINGERPRINT_REPLAY_ROOT"] != nil
                    || ProcessInfo.processInfo.environment["SYNCCLOUD_FINGERPRINT_REPLAY_LIST"] != nil))
struct ContentFingerprintCorpusReplayTests {

    private static func expanded(_ name: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[name], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
    }

    private static var root: URL? { expanded("SYNCCLOUD_FINGERPRINT_REPLAY_ROOT") }
    private static var list: URL? { expanded("SYNCCLOUD_FINGERPRINT_REPLAY_LIST") }

    private struct Document {
        let path: String
        let size: Int
        var sha256: String?
        var digest: String?
    }

    /// The documents to replay over: every fingerprintable file under the root, or the lines of the
    /// path list. Sizes come from `lstat`, so a symlink is dropped rather than followed.
    private func documentPaths() -> [(path: String, size: Int)] {
        var candidates: [String] = []
        if let list = Self.list, let text = try? String(contentsOf: list, encoding: .utf8) {
            candidates = text.split(separator: "\n").map(String.init)
        } else if let root = Self.root {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) {
                for case let url as URL in e { candidates.append(url.path) }
            }
        }
        var out: [(String, Int)] = []
        for path in candidates where ContentFingerprint.canFingerprint(path: path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue else { continue }
            out.append((path, size))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private func sha256(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test func theFingerprintNeverSplitsAByteIdenticalPair() async throws {
        let source = Self.list?.path ?? Self.root?.path ?? ""
        let found = documentPaths()
        try #require(!found.isEmpty, "no documents from \(source)")
        var documents = found.map { Document(path: $0.path, size: $0.size) }
        // Byte hashes for the size-colliding files only — that is where byte-identical pairs can
        // be, and hashing the whole tree buys nothing.
        var bySize: [Int: [Int]] = [:]
        for (i, d) in documents.enumerated() { bySize[d.size, default: []].append(i) }
        for indices in bySize.values where indices.count > 1 {
            for i in indices { documents[i].sha256 = sha256(documents[i].path) }
        }
        // Fingerprints for everything, through the shipped reader.
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func schedule(_ i: Int) {
                let path = documents[i].path
                group.addTask { (i, await PDFTextExtractor.fingerprint(path)) }
            }
            while next < min(6, documents.count) { schedule(next); next += 1 }
            for await (i, digest) in group {
                documents[i].digest = digest
                if next < documents.count { schedule(next); next += 1 }
            }
        }

        // RECALL, against the only free ground truth there is.
        var agreed = 0, disagreed = 0, declined = 0
        var disagreements: [String] = []
        for indices in bySize.values where indices.count > 1 {
            for a in indices {
                for b in indices where b > a {
                    guard let ha = documents[a].sha256, ha == documents[b].sha256 else { continue }
                    guard let da = documents[a].digest, let db = documents[b].digest else {
                        declined += 1; continue
                    }
                    if da == db { agreed += 1 } else {
                        disagreed += 1
                        disagreements.append("\(documents[a].path)\n    vs \(documents[b].path)")
                    }
                }
            }
        }

        // What it adds: fingerprint-equal groups the byte hash could not have produced.
        var byDigest: [String: [Int]] = [:]
        for (i, d) in documents.enumerated() {
            if let digest = d.digest { byDigest[digest, default: []].append(i) }
        }
        let novel = byDigest.values.filter { indices in
            indices.count > 1
                && Set(indices.map { documents[$0].sha256 ?? documents[$0].path }).count > 1
        }
        let spanningSizes = novel.filter { Set($0.map { documents[$0].size }).count > 1 }
        let withFingerprint = documents.filter { $0.digest != nil }.count

        print("""

        ── fingerprint replay over \(source)
           documents                      \(documents.count)
           produced a fingerprint         \(withFingerprint) \
        (\(documents.count - withFingerprint) said too little)
           byte-identical pairs           \(agreed + disagreed + declined)
             fingerprints agree           \(agreed)
             fingerprints DISAGREE        \(disagreed)
             declined (no fingerprint)    \(declined)
           groups the bytes cannot see    \(novel.count)
             spanning more than one size  \(spanningSizes.count) \
        (a size pre-filter would miss these)

        """)
        for group in novel.sorted(by: { documents[$0[0]].path < documents[$1[0]].path }) {
            print("   • " + group.map { documents[$0].path }.sorted().joined(separator: "\n     "))
        }

        if disagreed > 0 {
            print("byte-identical pairs the fingerprint called different:")
            for d in disagreements { print("  " + d) }
        }
        #expect(disagreed == 0)
        #expect(novel.count > 0, "the pass found nothing the byte hash had not already found")
    }
}
