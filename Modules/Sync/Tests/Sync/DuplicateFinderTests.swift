import Foundation
import Testing
@testable import Sync

@Suite struct DuplicateFinderTests {

    // MARK: Builders

    private func file(_ path: String, size: Int = 8192, modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: modified, fileSize: size)
    }
    private func dir(_ path: String, _ children: [FileNode], modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, modificationDate: modified)
    }

    // MARK: Identical files

    @Test func identicalFilesAcrossFoldersFormOneGroup() {
        // Parents differ (each has a unique file) so only report.pdf is the duplicate — otherwise
        // the two folders would themselves be identical and get reported at the folder level.
        let tree = [
            dir("/root/A", [file("/root/A/report.pdf"), file("/root/A/a-only.txt")]),
            dir("/root/B", [file("/root/B/report.pdf"), file("/root/B/b-only.txt")]),
        ]
        let hashes = [
            "/root/A/report.pdf": "H", "/root/B/report.pdf": "H",
            "/root/A/a-only.txt": "UA", "/root/B/b-only.txt": "UB",
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)

        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.matchType == .identical)
        #expect(g.isDirectory == false)
        #expect(g.copies.count == 2)
        #expect(g.reclaimableBytes == 8192)   // one redundant copy of 8 KB
        #expect(g.redundantCopies.first?.isFullyRedundant == true)
    }

    @Test func identicalFileInManyFoldersGroupsAll() {
        var children: [FileNode] = []
        var hashes: [String: String] = [:]
        for i in 0..<6 {
            let p = "/root/album\(i)/IMG_4821.HEIC"
            children.append(dir("/root/album\(i)", [file(p, size: 40_000)]))
            hashes[p] = "PHOTO"
        }
        let groups = DuplicateFinder.findGroups(tree: children, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].copies.count == 6)
        #expect(groups[0].reclaimableBytes == 40_000 * 5)  // keep one, reclaim five
    }

    // MARK: The "Folder 1" example — identical folder nested deep

    @Test func identicalFolderNestedDeepIsOneFolderGroupNoInnerFileGroups() {
        let rootFolder1 = dir("/root/Folder 1", [
            file("/root/Folder 1/a.txt", size: 1000),
            file("/root/Folder 1/b.txt", size: 2000),
        ])
        let nestedFolder1 = dir("/root/Folder 3", [
            dir("/root/Folder 3/Folder 4", [
                dir("/root/Folder 3/Folder 4/Folder 1", [
                    file("/root/Folder 3/Folder 4/Folder 1/a.txt", size: 1000),
                    file("/root/Folder 3/Folder 4/Folder 1/b.txt", size: 2000),
                ])
            ])
        ])
        let hashes = [
            "/root/Folder 1/a.txt": "HA", "/root/Folder 1/b.txt": "HB",
            "/root/Folder 3/Folder 4/Folder 1/a.txt": "HA",
            "/root/Folder 3/Folder 4/Folder 1/b.txt": "HB",
        ]

        let groups = DuplicateFinder.findGroups(tree: [rootFolder1, nestedFolder1], fileHashes: hashes)

        // Exactly one group — the folder — and no separate a.txt/b.txt file groups.
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.matchType == .identical)
        #expect(g.isDirectory)
        #expect(g.name == "Folder 1")
        #expect(g.keeper.path == "/root/Folder 1")            // shallowest wins
        #expect(g.reclaimableBytes == 3000)                   // the whole nested copy
        let redundant = g.redundantCopies.first
        #expect(redundant?.path == "/root/Folder 3/Folder 4/Folder 1")
        #expect(redundant?.isFullyRedundant == true)
        #expect(redundant?.itemCount == 2)
        #expect(g.recommendedRemovalPaths == ["/root/Folder 3/Folder 4/Folder 1"])
    }

    // MARK: Name-only folders

    @Test func sameNameDifferentContentsIsNameOnly() {
        let a = dir("/root/Screenshots", [
            file("/root/Screenshots/game1.png"), file("/root/Screenshots/game2.png"),
        ])
        let b = dir("/root/Work/Screenshots", [
            file("/root/Work/Screenshots/design1.png"), file("/root/Work/Screenshots/design2.png"),
        ])
        let hashes = [
            "/root/Screenshots/game1.png": "G1", "/root/Screenshots/game2.png": "G2",
            "/root/Work/Screenshots/design1.png": "D1", "/root/Work/Screenshots/design2.png": "D2",
        ]
        let groups = DuplicateFinder.findGroups(tree: [a, b], fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .nameOnly)
        #expect(groups[0].reclaimableBytes == 0)
        #expect(groups[0].isFullyResolvableByRemoval == false)
        #expect(groups[0].recommendedRemovalPaths.isEmpty)
    }

    // MARK: Overlapping folders

    @Test func overlappingFoldersReportSharedFractionAndUniqueCounts() {
        // Root copy is the more complete one (7 items), Work copy shares 5 and adds 1.
        let root = dir("/root/Invoices", [
            file("/root/Invoices/s1"), file("/root/Invoices/s2"), file("/root/Invoices/s3"),
            file("/root/Invoices/s4"), file("/root/Invoices/s5"),
            file("/root/Invoices/u1"), file("/root/Invoices/u2"),
        ])
        let work = dir("/root/Work/Invoices", [
            file("/root/Work/Invoices/s1"), file("/root/Work/Invoices/s2"), file("/root/Work/Invoices/s3"),
            file("/root/Work/Invoices/s4"), file("/root/Work/Invoices/s5"),
            file("/root/Work/Invoices/w1"),
        ])
        let hashes: [String: String] = [
            "/root/Invoices/s1": "S1", "/root/Invoices/s2": "S2", "/root/Invoices/s3": "S3",
            "/root/Invoices/s4": "S4", "/root/Invoices/s5": "S5",
            "/root/Invoices/u1": "U1", "/root/Invoices/u2": "U2",
            "/root/Work/Invoices/s1": "S1", "/root/Work/Invoices/s2": "S2", "/root/Work/Invoices/s3": "S3",
            "/root/Work/Invoices/s4": "S4", "/root/Work/Invoices/s5": "S5",
            "/root/Work/Invoices/w1": "W1",
        ]
        let groups = DuplicateFinder.findGroups(tree: [root, work], fileHashes: hashes)

        // One folder-level overlapping group — the 5 shared files are NOT re-reported.
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.matchType.kind == .overlapping)
        #expect(g.keeper.path == "/root/Invoices")          // more complete
        let folded = g.redundantCopies.first
        #expect(folded?.path == "/root/Work/Invoices")
        #expect(folded?.uniqueItemCount == 1)               // w1 is unique to the Work copy
    }

    // MARK: Versions

    @Test func driftedVersionsGroupKeepsNewest() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/Q3 Report.docx", size: 5000, modified: old),
                file("/root/Docs/Q3 Report (1).docx", size: 5200, modified: new),
            ])
        ]
        // Different content, so it's drift — not an exact-identical group.
        let hashes = [
            "/root/Docs/Q3 Report.docx": "V1",
            "/root/Docs/Q3 Report (1).docx": "V2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.matchType == .versions)
        #expect(g.keeper.path == "/root/Docs/Q3 Report (1).docx")  // newest
        #expect(g.reclaimableBytes == 5000)
    }

    @Test func identicalCopiesAreNotVersions() {
        // Same stem AND identical bytes → identical group, not a version group.
        let tree = [
            dir("/root", [
                file("/root/plan.key", size: 9000),
                file("/root/plan copy.key", size: 9000),
            ])
        ]
        let hashes = ["/root/plan.key": "SAME", "/root/plan copy.key": "SAME"]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .identical)
    }

    // MARK: Options

    @Test func tinyFilesBelowMinSizeAreIgnored() {
        // Parents differ (unique fillers), so the only candidate duplicate is the tiny `x` pair,
        // which is below minFileSize and must be ignored.
        let tree = [
            dir("/root/A", [file("/root/A/x", size: 10), file("/root/A/filler-a", size: 8192)]),
            dir("/root/B", [file("/root/B/x", size: 10), file("/root/B/filler-b", size: 8192)]),
        ]
        let hashes = [
            "/root/A/x": "H", "/root/B/x": "H",
            "/root/A/filler-a": "FA", "/root/B/filler-b": "FB",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes,
                                                options: .init(minFileSize: 4096))
        #expect(groups.isEmpty)
    }

    @Test func ignoredNamesAreSkipped() {
        let tree = [
            dir("/root/A", [dir("/root/A/node_modules", [file("/root/A/node_modules/lib.js")]),
                            file("/root/A/keep.txt")]),
            dir("/root/B", [dir("/root/B/node_modules", [file("/root/B/node_modules/lib.js")]),
                            file("/root/B/keep.txt")]),
        ]
        let hashes = [
            "/root/A/node_modules/lib.js": "LIB", "/root/B/node_modules/lib.js": "LIB",
            "/root/A/keep.txt": "KEEP", "/root/B/keep.txt": "KEEP",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        // A and B are identical *ignoring* node_modules → one identical-folder group; the
        // node_modules lib.js is never surfaced.
        #expect(groups.count == 1)
        #expect(groups[0].isDirectory)
        #expect(groups.allSatisfy { !$0.copies.contains { $0.path.contains("node_modules") } })
    }

    @Test func keeperAvoidsArchiveLocations() {
        // Distinct fillers keep the parents non-identical, so tax.pdf is a file-level duplicate.
        let tree = [
            dir("/root/Archive", [file("/root/Archive/tax.pdf", size: 6000), file("/root/Archive/z1", size: 5000)]),
            dir("/root/Current", [file("/root/Current/tax.pdf", size: 6000), file("/root/Current/z2", size: 5000)]),
        ]
        let hashes = [
            "/root/Archive/tax.pdf": "H", "/root/Current/tax.pdf": "H",
            "/root/Archive/z1": "Z1", "/root/Current/z2": "Z2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        // Same depth, but the Archive copy is penalized, so Current is the keeper.
        #expect(groups[0].keeper.path == "/root/Current/tax.pdf")
    }

    @Test func unhashedFilesAreNeverAssertedIdentical() {
        let tree = [
            dir("/root/A", [file("/root/A/x")]),
            dir("/root/B", [file("/root/B/x")]),
        ]
        // No hashes provided → identity unknown → no identical group.
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: [:])
        #expect(groups.allSatisfy { $0.matchType != .identical })
    }

    // MARK: versionStem unit coverage

    @Test func versionStemStripsMarkers() {
        #expect(DuplicateFinder.versionStem("Q3 Report (1).docx")?.stem == "q3 report")
        #expect(DuplicateFinder.versionStem("plan copy.key")?.stem == "plan")
        #expect(DuplicateFinder.versionStem("deck-final.pdf")?.stem == "deck")
        #expect(DuplicateFinder.versionStem("app_v3.zip")?.stem == "app")
        #expect(DuplicateFinder.versionStem("photo.png")?.ext == "png")
    }

    @Test func versionStemDoesNotOverStrip() {
        // No separator before the version token, or a bare number, must NOT be treated as a marker.
        #expect(DuplicateFinder.versionStem("v2024.txt")?.stem == "v2024")
        #expect(DuplicateFinder.versionStem("report-2.pdf")?.stem == "report-2")   // "-2" ≠ "-v2"/"-copy"
        #expect(DuplicateFinder.versionStem("copy.txt")?.stem == "copy")           // bare word
        // Parenthesized numbers DO strip — a burst like "beach (1)/(2)" collapses to one stem,
        // which is why versions are kept out of the blind batch (see isRecommendedForBatch).
        #expect(DuplicateFinder.versionStem("beach (2).jpg")?.stem == "beach")
    }

    @Test func batchEligibilityByMatchType() {
        func g(_ t: DuplicateMatchType) -> DuplicateGroup {
            let k = DuplicateCopy(id: "/a", name: "a", isDirectory: false, size: 1, itemCount: 1,
                                  modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
            let r = DuplicateCopy(id: "/b", name: "a", isDirectory: false, size: 1, itemCount: 1,
                                  modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: false)
            return DuplicateGroup(matchType: t, name: "a", isDirectory: false, copies: [k, r], reclaimableBytes: 1)
        }
        // Per-group removable: identical + versions. Blind batch: identical ONLY.
        #expect(g(.identical).isFullyResolvableByRemoval && g(.identical).isRecommendedForBatch)
        #expect(g(.versions).isFullyResolvableByRemoval && !g(.versions).isRecommendedForBatch)
        #expect(!g(.overlapping(sharedFraction: 0.9)).isFullyResolvableByRemoval)
        #expect(!g(.overlapping(sharedFraction: 0.9)).isRecommendedForBatch)
        #expect(!g(.nameOnly).isFullyResolvableByRemoval && !g(.nameOnly).isRecommendedForBatch)
    }
}
