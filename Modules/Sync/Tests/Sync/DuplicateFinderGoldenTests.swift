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
        case .nameOnly: return "nameOnly"
        case .overlapping(let f): return "overlapping(\(String(format: "%.2f", f)))"
        }
    }

    /// Deterministic, human-readable serialization of the grouping result. `*` marks the keeper.
    private func snapshot(_ groups: [DuplicateGroup]) -> String {
        groups.map { g in
            let copies = g.copies.map { "\($0.path)\($0.isRecommendedKeeper ? "*" : "")" }.joined(separator: ", ")
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
            // versions (the IMG_0001-in-two-year-folders false positive).
            dir("/root/2019", [file("/root/2019/IMG_0001.jpg", size: 50_000)]),
            dir("/root/2023", [file("/root/2023/IMG_0001.jpg", size: 51_000)]),
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
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)

        // GOLDEN — captured, hand-verified correct, then pinned. Every line is load-bearing:
        //  · dupdir1 ≡ dupdir2 is the only FOLDER group (their files are covered, not re-grouped);
        //  · data.txt / doc.txt ARE file groups → withlink≠nolink and hassym≠hasreal, i.e. a folder
        //    with a symlink does NOT falsely group with one holding the real file / no file;
        //  · shared.bin has exactly 2 copies (f1, f2) — the /root/link symlink is excluded, not a 3rd;
        //  · deck.pdf is the ONLY versions group (marker-justified, newest kept) — the two
        //    IMG_0001.jpg files (same stem, different parents, no marker) form NO group at all.
        // To re-bless after an INTENTIONAL behavior change: run, confirm the new grouping is correct,
        // and paste the new value.
        let expected = """
        identical "dupdir1" dir=true reclaim=200000 [/root/dupdir1*, /root/dupdir2]
        identical "data.txt" dir=false reclaim=100000 [/root/nolink/data.txt*, /root/withlink/data.txt]
        identical "doc.txt" dir=false reclaim=100000 [/root/hasreal/doc.txt*, /root/hassym/doc.txt]
        identical "shared.bin" dir=false reclaim=100000 [/root/f1/shared.bin*, /root/f2/shared.bin]
        versions "deck.pdf" dir=false reclaim=60000 [/root/vers/deck-final.pdf*, /root/vers/deck.pdf]
        """
        #expect(snapshot(groups) == expected)
    }
}
