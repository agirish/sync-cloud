import Foundation
import Testing
@testable import Sync

/// **The read-layer half of ``FilingSurveyStore/CorpusRead``.**
///
/// The type exists so a caller about to write over learned state can tell "never surveyed" from
/// "on disk and could not be read". `corpusRead` reached `.unreadable` only through a DECODE
/// failure, so every way a file can be present and unopenable — mode 000, an ACL, an I/O error, a
/// symlink whose target is gone — answered `.absent`, and the survey's refusal (which is correct
/// and byte-preserving) never ran. `absent` starts from an empty corpus, merges this pass into
/// nothing and writes the result over `filing-memory.json`; the fingerprint moves with those bytes
/// and up to 50,000 paid verdicts stop being reachable.
///
/// The probe is `attributesOfItem` rather than `fileExists` for the reason the four sibling stores
/// give: `fileExists` follows symlinks and answers false for one pointing at an unmounted volume,
/// and an atomic write then replaces the link itself.
@Suite struct FilingCorpusReadTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corpusread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        return dir
    }

    /// chmod 000 is a no-op for root, so the fixture below distinguishes nothing there. Recorded as
    /// an issue rather than silently returning, which would report a vacuous PASS.
    private func skippedBecauseRoot(_ fixture: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard geteuid() == 0 else { return false }
        Issue.record("""
            Skipped “\(fixture)”: running as root (euid 0), where chmod 000 does not restrict \
            access. It proves nothing on this runner.
            """, sourceLocation: sourceLocation)
        return true
    }

    @Test func aCorpusThatCannotBeOpenedIsUnreadableNotAbsent() throws {
        if skippedBecauseRoot("aCorpusThatCannotBeOpenedIsUnreadableNotAbsent") { return }
        let dir = try makeDir()
        let url = FilingSurveyStore.corpusURL(id: "t", in: dir)
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? fm.removeItem(at: dir)
        }
        try Data(#"{"profileId":"t","salt":"ab","documents":{}}"#.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        // The premise: it really is unopenable, or this asserts nothing.
        #expect((try? Data(contentsOf: url)) == nil, "fixture: the corpus was still readable")

        guard case .unreadable = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("""
                a present-but-unopenable corpus answered absent — the survey will start from an \
                empty corpus and write the result over the memory
                """)
            return
        }
    }

    /// A symlink whose target is gone. `Data(contentsOf:)` fails and `fileExists` — which follows
    /// the link — answers **false**, so only `attributesOfItem` sees the directory entry that an
    /// atomic write would replace.
    @Test func aDanglingSymlinkCorpusIsUnreadableNotAbsent() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingSurveyStore.corpusURL(id: "t", in: dir)
        let target = dir.appendingPathComponent("t/gone.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        try FileManager.default.removeItem(at: target)

        // The premise, measured: this is exactly the case `fileExists` cannot see.
        #expect((try? Data(contentsOf: url)) == nil, "fixture: the link still resolved")
        #expect(FileManager.default.fileExists(atPath: url.path) == false,
                "fixture: fileExists no longer follows the link, so it would have caught this")

        guard case .unreadable = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("a dangling-symlink corpus answered absent")
            return
        }
    }

    /// The other direction, so the probe cannot become "nothing is ever absent": a directory with
    /// no corpus in it is absent, and a first survey reads the whole tree.
    @Test func aTrulyMissingCorpusIsStillAbsent() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .absent = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("a tree that has never been surveyed must survey from scratch")
            return
        }
    }

    /// And a corpus that is there and parses still loads.
    @Test func aGoodCorpusStillLoads() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"profileId":"t","salt":"ab","documents":{}}"#.utf8)
            .write(to: FilingSurveyStore.corpusURL(id: "t", in: dir))
        guard case .loaded(let corpus) = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("a readable corpus stopped loading"); return
        }
        #expect(corpus.salt == "ab")
    }

    /// The shared probe behind the memory's refusal, on the case only `attributesOfItem` sees.
    ///
    /// Its own test because the corpus tests exercise `corpusRead`, not this helper, and a probe
    /// that quietly regressed to `fileExists` would leave `filing-memory.json` — reached through
    /// a link whose target is gone — reading as absent and being atomically replaced.
    @Test func theSharedProbeSeesADanglingSymlink() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("t/filing-memory.json")
        let target = dir.appendingPathComponent("t/gone.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.removeItem(at: target)

        #expect(FileManager.default.fileExists(atPath: link.path) == false,
                "fixture: fileExists stopped following the link, so it would have caught this")
        #expect(FilingProfileStore.isPresentButUnreadable(at: link),
                """
                the probe folded back to fileExists — the link is still a directory entry, and an \
                atomic write replaces it
                """)
        #expect(FilingProfileStore.isPresentButUnreadable(
            at: dir.appendingPathComponent("t/nothing-here.json")) == false,
                "a genuinely missing artifact was called unreadable")
    }
}
