import Foundation
import Testing
@testable import Sync

/// Characterization ("golden") test for `DuplicateFinder.findGroups`. Unlike the focused tests, this
/// pins the ENTIRE grouping output of one broad fixture as a single snapshot string. Its job is to
/// catch COLLATERAL changes: any edit that alters grouping, keeper choice, reclaim bytes, ordering,
/// or the symlink handling flips the snapshot and must be consciously re-blessed. This directly
/// targets the class of regression that repeatedly slipped through — a fix that changed grouping as
/// a side effect while the narrow tests it shipped with stayed green (the DuplicateFinder symlink
/// signature broke three different ways across three rounds; each would have reddened this snapshot).
@Suite struct DuplicateFinderGoldenTests {

    private func file(_ path: String, size: Int = 100_000, symlink: Bool = false, modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: modified, fileSize: size, isSymbolicLink: symlink ? true : nil)
    }
    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    private func matchLabel(_ t: DuplicateMatchType) -> String {
        switch t {
        case .identical: return "identical"
        case .versions: return "versions"
        case .sameText: return "sameText"
        case .overlapping(let f): return "overlapping(\(String(format: "%.2f", f)))"
        }
    }

    /// Deterministic, human-readable serialization of the grouping result. `*` marks the keeper;
    /// `?` marks a copy whose content the scan could NOT fully verify (`contentUnverified` — an
    /// unknown-hash placeholder, or a folder with an unverified descendant), so a change to the
    /// unverified accounting flips the snapshot too.
    private func snapshot(_ groups: [DuplicateGroup]) -> String {
        groups.map { g in
            let copies = g.copies.map {
                "\($0.path)\($0.isRecommendedKeeper ? "*" : "")\($0.contentUnverified ? "?" : "")"
            }.joined(separator: ", ")
            return "\(matchLabel(g.matchType)) \"\(g.name)\" dir=\(g.isDirectory) reclaim=\(g.reclaimableBytes) [\(copies)]"
        }.joined(separator: "\n")
    }

    @Test func groupingSnapshotIsStable() {
        let tree = [
            // Two byte-identical FOLDERS → one folder group; their files are covered (no file groups).
            dir("/root/dupdir1", [file("/root/dupdir1/a.txt"), file("/root/dupdir1/b.txt")]),
            dir("/root/dupdir2", [file("/root/dupdir2/a.txt"), file("/root/dupdir2/b.txt")]),
            // Identical FILE across two NON-identical folders (unique siblings keep the folders apart).
            dir("/root/f1", [file("/root/f1/shared.bin"), file("/root/f1/only1.txt")]),
            dir("/root/f2", [file("/root/f2/shared.bin"), file("/root/f2/only2.txt")]),
            // A symlink whose target hashes like shared.bin — must be EXCLUDED (group stays 2 copies).
            dir("/root/link", [file("/root/link/shared.bin", symlink: true), file("/root/link/lonly.txt")]),
            // Folder WITH a symlink vs folder WITHOUT — must NOT group (b50f9dc regression class).
            dir("/root/withlink", [file("/root/withlink/data.txt"), file("/root/withlink/ln.pdf", symlink: true)]),
            dir("/root/nolink", [file("/root/nolink/data.txt")]),
            // Folder with a symlink vs folder with a REAL file of the same hash — must NOT group
            // (a24c326 regression class).
            dir("/root/hassym", [file("/root/hassym/doc.txt"), file("/root/hassym/att.pdf", symlink: true)]),
            dir("/root/hasreal", [file("/root/hasreal/doc.txt"), file("/root/hasreal/att.pdf")]),
            // Drifted VERSIONS pair — a stripped marker ("-final") on one member justifies the
            // group; the newer file is the keeper. Pins the versions path end-to-end so a change
            // to stem bucketing, the marker/same-parent justification, drift detection, or the
            // newest-keeper choice flips this snapshot.
            dir("/root/vers", [
                file("/root/vers/deck.pdf", size: 60_000, modified: Date(timeIntervalSince1970: 1_000_000)),
                file("/root/vers/deck-final.pdf", size: 70_000, modified: Date(timeIntervalSince1970: 2_000_000)),
            ]),
            // Same stem+ext, DIFFERENT parents, NO marker on either name — must NOT group as
            // versions (the IMG_0001-in-two-year-folders false positive). The marker on
            // "/2023/IMG_0001 copy.jpg" vouches ONLY for its own parent: the /2023 pair groups,
            // and the unrelated /2019 shot must never be pulled in (round-5 MAJOR — one marker
            // used to license the whole cross-folder stem bucket).
            dir("/root/2019", [file("/root/2019/IMG_0001.jpg", size: 50_000)]),
            dir("/root/2023", [
                file("/root/2023/IMG_0001.jpg", size: 51_000, modified: Date(timeIntervalSince1970: 2_000_000)),
                file("/root/2023/IMG_0001 copy.jpg", size: 52_000, modified: Date(timeIntervalSince1970: 1_000_000)),
            ]),
            // Two folders sharing a NAME and nothing else. They stand up no group at all: a name
            // match is not evidence of duplication, and this pair is the shape of the 115 sets in
            // his own tree that were (see the finder's folder pass).
            dir("/root/x/Projects", [file("/root/x/Projects/p1.txt")]),
            dir("/root/y/Projects", [file("/root/y/Projects/p2.txt")]),
            // Keeper heuristic discrimination: identical file where the ARCHIVE copy is BOTH newer
            // and shallower — depth and mtime each favor the archive copy, so only the archive
            // penalty can explain the docs copy winning keeper. (Unique siblings keep the parent
            // folders from grouping.)
            dir("/root/Archive", [
                file("/root/Archive/report.pdf", modified: Date(timeIntervalSince1970: 5_000_000)),
                file("/root/Archive/arch-only.txt"),
            ]),
            dir("/root/docs", [dir("/root/docs/sub", [
                file("/root/docs/sub/report.pdf", modified: Date(timeIntervalSince1970: 1_000_000)),
                file("/root/docs/sub/docs-only.txt"),
            ])]),
            // Versions keeper heuristic: the ARCHIVE-path copy ("backup" segment) is the NEWEST —
            // newestIndex must still keep the non-archive copy (a backup tool rewriting mtimes must
            // not make the backup the recommended keeper). Both names carry markers so the
            // cross-folder pair still groups under the marker-vouches-for-its-parent rule.
            dir("/root/work", [file("/root/work/plan-draft.key", modified: Date(timeIntervalSince1970: 1_000_000))]),
            dir("/root/backup", [file("/root/backup/plan-final.key", modified: Date(timeIntervalSince1970: 5_000_000))]),
            // Versions keeper vs TRANSIENT locations: the newest revision sits in Downloads —
            // unlike backup/archive, a transient-download location must NOT be penalized, so the
            // Downloads copy stays the keeper and the stale Documents copy is the one trashed.
            dir("/root/Documents", [file("/root/Documents/budget copy.xlsx", size: 55_000, modified: Date(timeIntervalSince1970: 1_000_000))]),
            dir("/root/Downloads", [file("/root/Downloads/budget-v2.xlsx", size: 56_000, modified: Date(timeIntervalSince1970: 2_000_000))]),
            // Two placeholder-hash members (marker + same parent — every OTHER versions signal
            // present): unknown content is not evidence of drift, so NO group may stand up.
            dir("/root/big", [file("/root/big/huge.mp4"), file("/root/big/huge copy.mp4")]),
            // One placeholder + only ONE real hash: still not two distinct real contents → no group.
            dir("/root/mix", [file("/root/mix/draft.docx"), file("/root/mix/draft-v2.docx")]),
            // A placeholder member RIDES ALONG in a versions group two real hashes justify — it is
            // carried (marked unverified), it just can't stand a group up by itself.
            dir("/root/ride", [
                file("/root/ride/memo.txt", modified: Date(timeIntervalSince1970: 1_000_000)),
                file("/root/ride/memo-v2.txt", modified: Date(timeIntervalSince1970: 2_000_000)),
                file("/root/ride/memo copy.txt", modified: Date(timeIntervalSince1970: 1_500_000)),
            ]),
        ]
        let hashes = [
            "/root/dupdir1/a.txt": "HA", "/root/dupdir1/b.txt": "HB",
            "/root/dupdir2/a.txt": "HA", "/root/dupdir2/b.txt": "HB",
            "/root/f1/shared.bin": "HS", "/root/f1/only1.txt": "U1",
            "/root/f2/shared.bin": "HS", "/root/f2/only2.txt": "U2",
            "/root/link/shared.bin": "HS", "/root/link/lonly.txt": "UL",   // symlink resolves to HS
            "/root/withlink/data.txt": "HD", "/root/withlink/ln.pdf": "HZ",
            "/root/nolink/data.txt": "HD",
            "/root/hassym/doc.txt": "HR", "/root/hassym/att.pdf": "HW",     // symlink resolves to HW
            "/root/hasreal/doc.txt": "HR", "/root/hasreal/att.pdf": "HW",
            "/root/vers/deck.pdf": "V1", "/root/vers/deck-final.pdf": "V2", // drifted versions
            "/root/2019/IMG_0001.jpg": "SA", "/root/2023/IMG_0001.jpg": "SB",
            "/root/2023/IMG_0001 copy.jpg": "SB2",
            "/root/x/Projects/p1.txt": "N1", "/root/y/Projects/p2.txt": "N2",
            "/root/Archive/report.pdf": "HK", "/root/docs/sub/report.pdf": "HK",
            "/root/Archive/arch-only.txt": "UA", "/root/docs/sub/docs-only.txt": "UD",
            "/root/work/plan-draft.key": "P1", "/root/backup/plan-final.key": "P2",
            "/root/Documents/budget copy.xlsx": "BG1", "/root/Downloads/budget-v2.xlsx": "BG2",
            "/root/big/huge.mp4": DuplicateFinder.unknownSignature(forPath: "/root/big/huge.mp4"),
            "/root/big/huge copy.mp4": DuplicateFinder.unknownSignature(forPath: "/root/big/huge copy.mp4"),
            "/root/mix/draft.docx": DuplicateFinder.unknownSignature(forPath: "/root/mix/draft.docx"),
            "/root/mix/draft-v2.docx": "R1",
            "/root/ride/memo.txt": "M1", "/root/ride/memo-v2.txt": "M2",
            "/root/ride/memo copy.txt": DuplicateFinder.unknownSignature(forPath: "/root/ride/memo copy.txt"),
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)

        // GOLDEN — captured, hand-verified correct, then pinned. Every line is load-bearing:
        //  · dupdir1 ≡ dupdir2 is the only identical FOLDER group (their files are covered, not
        //    re-grouped);
        //  · data.txt / doc.txt ARE file groups → withlink≠nolink and hassym≠hasreal, i.e. a folder
        //    with a symlink does NOT falsely group with one holding the real file / no file;
        //  · shared.bin has exactly 2 copies (f1, f2) — the /root/link symlink is excluded, not a 3rd;
        //  · report.pdf's keeper is the docs/sub copy even though the Archive copy is newer AND
        //    shallower — the archive-location penalty dominates depth and mtime;
        //  · the two Projects folders are NOT reported: sharing a folder name stands up no group,
        //    whatever the contents — the folder pass reports only `identical` trees and
        //    `overlapping` ones;
        //  · deck.pdf / plan.key / memo.txt / img_0001.jpg are the ONLY versions groups
        //    (marker-justified), and img_0001.jpg holds EXACTLY the two /root/2023 files — the
        //    marker on "IMG_0001 copy.jpg" vouches for its own parent only, so the unrelated
        //    /root/2019 shot never joins (and stays in no group at all);
        //  · plan.key's keeper is the /root/work copy even though the /root/backup copy is newer —
        //    newestIndex applies the archive penalty first — while budget.xlsx keeps the NEWER
        //    Downloads revision: transient-download locations are not penalized for a versions
        //    keeper (trashing the Downloads copy would lose the only copy of the new bytes);
        //  · memo.txt carries an unknown-hash member (memo copy.txt, marked `?`) that RIDES ALONG in
        //    a group two real hashes justify — while huge.mp4 (two placeholders, marker AND same
        //    parent) and draft.docx (one placeholder + only one real hash) stand up NO group:
        //    unknown content is never evidence of drift.
        // To re-bless after an INTENTIONAL behavior change: run, confirm the new grouping is correct,
        // and paste the new value.
        let expected = """
        identical "dupdir1" dir=true reclaim=200000 [/root/dupdir1*, /root/dupdir2]
        versions "memo.txt" dir=false reclaim=200000 [/root/ride/memo-v2.txt*, /root/ride/memo copy.txt?, /root/ride/memo.txt]
        identical "data.txt" dir=false reclaim=100000 [/root/nolink/data.txt*, /root/withlink/data.txt]
        identical "doc.txt" dir=false reclaim=100000 [/root/hasreal/doc.txt*, /root/hassym/doc.txt]
        versions "plan.key" dir=false reclaim=100000 [/root/work/plan-draft.key*, /root/backup/plan-final.key]
        identical "report.pdf" dir=false reclaim=100000 [/root/docs/sub/report.pdf*, /root/Archive/report.pdf]
        identical "shared.bin" dir=false reclaim=100000 [/root/f1/shared.bin*, /root/f2/shared.bin]
        versions "deck.pdf" dir=false reclaim=60000 [/root/vers/deck-final.pdf*, /root/vers/deck.pdf]
        versions "budget.xlsx" dir=false reclaim=55000 [/root/Downloads/budget-v2.xlsx*, /root/Documents/budget copy.xlsx]
        versions "img_0001.jpg" dir=false reclaim=52000 [/root/2023/IMG_0001.jpg*, /root/2023/IMG_0001 copy.jpg]
        """
        #expect(snapshot(groups) == expected)
    }

    // MARK: Skipped-count summary

    /// Pins the per-reason skip accounting behind `duplicateScanSkips` (`hashFilesCounting`): a
    /// mixed batch must report EXACTLY how many candidates were skipped over the size cap vs as
    /// cloud-only placeholders, hash everything else, and never let a skip masquerade as a hash.
    /// Guards the round-4 "count and surface what the duplicate scan skipped" surface: a change
    /// that drops a reason, double-counts, or starts hashing cloud-only files flips this.
    @Test func hashBatchOutcomeCountsSkipsByReason() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-skips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let small1 = dir.appendingPathComponent("a.txt")
        let small2 = dir.appendingPathComponent("b.txt")
        let big = dir.appendingPathComponent("big.bin")
        let cloud = dir.appendingPathComponent("cloud.txt")
        try Data(repeating: 0x41, count: 100).write(to: small1)
        try Data(repeating: 0x41, count: 100).write(to: small2)      // same bytes → same hash
        try Data(repeating: 0x42, count: 5000).write(to: big)        // over the injected 1000-byte cap
        try Data(repeating: 0x43, count: 100).write(to: cloud)       // flagged cloud-only via the seam

        // No cache: this pins the SKIP classification, and both knobs it varies are ones a cache
        // hit deliberately bypasses (the cache holds digests; the caps only decide whether
        // computing one is worth it). Sharing the session cache here would let a digest recorded
        // by another test's real-cap run answer for a file this test wants reported as too large.
        let outcome = await FileSyncManager.hashFilesCounting(
            [small1.path, small2.path, big.path, cloud.path],
            fileManager: FileManager.default,
            maxBytesToHash: 1000,
            isCloudOnly: { $0.hasSuffix("cloud.txt") },
            cache: nil
        )

        #expect(outcome.skippedTooLarge == 1)
        #expect(outcome.skippedCloudOnly == 1)
        #expect(outcome.hashes.count == 2)
        // The two identical small files hashed to the same real content hash — skips returned no hash.
        #expect(outcome.hashes[small1.path] != nil)
        #expect(outcome.hashes[small1.path] == outcome.hashes[small2.path])
        #expect(outcome.hashes[big.path] == nil && outcome.hashes[cloud.path] == nil)
        // And the public summary type the UI reads sums the same way.
        let skips = FileSyncManager.DuplicateScanSkips(tooLarge: outcome.skippedTooLarge,
                                                       cloudOnly: outcome.skippedCloudOnly)
        #expect(skips.total == 2)
    }
}
