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

    @Test func symlinkIsNotGroupedWithItsInTreeTarget() {
        // The walk resolves a symlink's size/content to its target, so a link and its in-tree
        // target hash identically. They must NOT group as duplicates: trashing the real target
        // would leave a dangling link as the "kept" copy. The finder excludes symlinks outright.
        let link = FileNode(id: "/root/Current/report.pdf", name: "report.pdf", isDirectory: false,
                            modificationDate: nil, fileSize: 8192, isSymbolicLink: true)
        let tree = [
            dir("/root/Current", [link, file("/root/Current/c-only.txt")]),
            dir("/root/Archive", [file("/root/Archive/report.pdf"), file("/root/Archive/a-only.txt")]),
        ]
        let hashes = [
            "/root/Current/report.pdf": "H", "/root/Archive/report.pdf": "H",
            "/root/Current/c-only.txt": "UC", "/root/Archive/a-only.txt": "UA",
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.isEmpty)   // the symlink is excluded, so the real file has no duplicate
    }

    @Test func aFolderWithASymlinkIsNotIdenticalToOneWithARealFileOfTheSameName() {
        // A file-symlink's parent-signature contribution must not collide with a REAL file of the
        // same name+hash: folder A {real.txt, link.pdf→L} and folder C {real.txt, real link.pdf(L)}
        // are NOT identical (one entry is a link, the other a real file). If they grouped, accepting
        // could trash C — the folder holding the only real copy — keeping A's dangling link.
        let link = FileNode(id: "/root/A/link.pdf", name: "link.pdf", isDirectory: false,
                            modificationDate: nil, fileSize: 8192, isSymbolicLink: true)
        let tree = [
            dir("/root/A", [file("/root/A/real.txt"), link]),
            dir("/root/C", [file("/root/C/real.txt"), file("/root/C/link.pdf")]),
        ]
        // The link resolves to the same content the real link.pdf has (hash L).
        let hashes = [
            "/root/A/real.txt": "H", "/root/C/real.txt": "H",
            "/root/A/link.pdf": "L", "/root/C/link.pdf": "L",
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.contains { $0.isDirectory })   // A and C are NOT identical folders
    }

    @Test func aFolderWithASymlinkIsNotIdenticalToOneWithout() {
        // Excluding a symlink from the dedup buckets must NOT drop it from its PARENT folder's
        // signature: folder A {real.txt, link} and folder B {real.txt} differ (A has an extra
        // entry), so they must NOT be reported as identical duplicate folders.
        let link = FileNode(id: "/root/A/link.pdf", name: "link.pdf", isDirectory: false,
                            modificationDate: nil, fileSize: 8192, isSymbolicLink: true)
        let tree = [
            dir("/root/A", [file("/root/A/real.txt"), link]),
            dir("/root/B", [file("/root/B/real.txt")]),
        ]
        // link.pdf resolves to a hashed target; real.txt is identical across A and B.
        let hashes = [
            "/root/A/real.txt": "H", "/root/B/real.txt": "H", "/root/A/link.pdf": "L",
        ]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        // The folders are NOT reported as identical (A carries an extra symlink) — the bug was that
        // dropping the symlink made A's signature equal B's and grouped them.
        #expect(!groups.contains { $0.isDirectory })
        // The genuinely-identical real.txt still surfaces as a file duplicate (unchanged behavior).
        #expect(groups.contains { !$0.isDirectory && $0.name == "real.txt" })
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

    @Test func aThirdCopyElsewhereNeverRecommendsGuttingTheKeptFolder() {
        // Docs/F1 and Archive/F1 are byte-identical folders, so Docs/F1 is kept and Archive/F1 is
        // recommended for removal. a.txt ALSO has a third copy at a SHALLOWER path, which is what
        // makes this the failing shape: the file pass saw {Docs/F1/a.txt, X/a.txt} — Archive's copy
        // is covered by the folder group, the keeper's copy was not — and the keeper heuristic
        // prefers the shallower X/a.txt, putting Docs/F1/a.txt on the removal list. One "Apply
        // recommended" then trashed Archive/F1 *and* removed a file from inside Docs/F1, the folder
        // the same batch had just called an intact copy.
        let f1 = dir("/root/Docs/Sub/F1", [
            file("/root/Docs/Sub/F1/a.txt", size: 8192),
            file("/root/Docs/Sub/F1/b.txt", size: 9000),
        ])
        let f2 = dir("/root/Archive/Sub/F1", [
            file("/root/Archive/Sub/F1/a.txt", size: 8192),
            file("/root/Archive/Sub/F1/b.txt", size: 9000),
        ])
        let x = dir("/root/Alpha", [file("/root/Alpha/a.txt", size: 8192), file("/root/Alpha/x-only.txt", size: 8192)])
        let hashes = [
            "/root/Docs/Sub/F1/a.txt": "HA", "/root/Docs/Sub/F1/b.txt": "HB",
            "/root/Archive/Sub/F1/a.txt": "HA", "/root/Archive/Sub/F1/b.txt": "HB",
            "/root/Alpha/a.txt": "HA", "/root/Alpha/x-only.txt": "HX",
        ]

        let groups = DuplicateFinder.findGroups(tree: [f1, f2, x], fileHashes: hashes)

        let folderGroup = groups.first { $0.isDirectory }
        #expect(folderGroup?.keeper.path == "/root/Docs/Sub/F1")
        // Nothing anywhere may recommend removing content of the kept folder.
        let allRemovals = groups.flatMap { $0.recommendedRemovalPaths }
        #expect(!allRemovals.contains { $0.hasPrefix("/root/Docs/Sub/F1/") })

        // The third copy is still discoverable and still removable — protection pins which side of
        // the group the kept folder's file sits on, it does not hide the duplicate.
        let fileGroup = groups.first { !$0.isDirectory }
        #expect(fileGroup?.keeper.path == "/root/Docs/Sub/F1/a.txt")
        #expect(fileGroup?.recommendedRemovalPaths == ["/root/Alpha/a.txt"])
    }

    @Test func twoFilesInsideTheSameKeptFolderNeverRecommendRemovingEachOther() {
        // Both members of the file group live inside kept folders, so neither can be offered for
        // removal and the group has nothing left to recommend — it must not fall back to trashing
        // one of them.
        let f1 = dir("/root/F1", [file("/root/F1/a.txt", size: 8192), file("/root/F1/dup.txt", size: 8192)])
        let f2 = dir("/root/Archive/F1", [
            file("/root/Archive/F1/a.txt", size: 8192),
            file("/root/Archive/F1/dup.txt", size: 8192),
        ])
        let hashes = [
            "/root/F1/a.txt": "HA", "/root/F1/dup.txt": "HA",
            "/root/Archive/F1/a.txt": "HA", "/root/Archive/F1/dup.txt": "HA",
        ]

        let groups = DuplicateFinder.findGroups(tree: [f1, f2], fileHashes: hashes)

        let allRemovals = groups.flatMap { $0.recommendedRemovalPaths }
        #expect(!allRemovals.contains { $0.hasPrefix("/root/F1/") })
        // The redundant folder copy is still recommended, as before.
        #expect(allRemovals.contains("/root/Archive/F1"))
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

    @Test func sameNameInDifferentFoldersWithoutMarkersIsNotVersions() {
        // Two unrelated camera shots that happen to share a name because both cameras count from
        // IMG_0001 — different folders, different bytes, NO version marker on either name. Grouping
        // them as "versions" would recommend trashing a unique photo.
        let tree = [
            dir("/root/2019", [file("/root/2019/IMG_0001.jpg", size: 50_000)]),
            dir("/root/2023", [file("/root/2023/IMG_0001.jpg", size: 60_000)]),
        ]
        let hashes = [
            "/root/2019/IMG_0001.jpg": "SHOT-A",
            "/root/2023/IMG_0001.jpg": "SHOT-B",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.isEmpty)
    }

    @Test func sameDocNameAcrossClientFoldersIsNotVersions() {
        // ClientA/invoice.pdf and ClientB/invoice.pdf are two different invoices, not versions of
        // one document. Unique siblings keep the parents from grouping at the folder level.
        let tree = [
            dir("/root/ClientA", [file("/root/ClientA/invoice.pdf", size: 9000),
                                  file("/root/ClientA/a-notes.txt", size: 8192)]),
            dir("/root/ClientB", [file("/root/ClientB/invoice.pdf", size: 9500),
                                  file("/root/ClientB/b-notes.txt", size: 8192)]),
        ]
        let hashes = [
            "/root/ClientA/invoice.pdf": "INV-A", "/root/ClientB/invoice.pdf": "INV-B",
            "/root/ClientA/a-notes.txt": "NA", "/root/ClientB/b-notes.txt": "NB",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.contains { $0.matchType == .versions })
        #expect(groups.isEmpty)
    }

    @Test func markeredVersionsAcrossDifferentFoldersGroupOnlyMarkeredMembers() {
        // Marker-bearing names group even across folders: "report copy.pdf" and "report-v2.pdf"
        // both carry evidence of being versions of the same document, wherever they now live.
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Docs", [file("/root/Docs/report-v2.pdf", size: 9000, modified: new),
                               file("/root/Docs/d-only.txt", size: 8192)]),
            dir("/root/Desktop", [file("/root/Desktop/report copy.pdf", size: 8800, modified: old),
                                  file("/root/Desktop/k-only.txt", size: 8192)]),
        ]
        let hashes = [
            "/root/Docs/report-v2.pdf": "R1", "/root/Desktop/report copy.pdf": "R2",
            "/root/Docs/d-only.txt": "D", "/root/Desktop/k-only.txt": "K",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .versions)
        #expect(groups[0].keeper.path == "/root/Docs/report-v2.pdf")   // newest
    }

    @Test func crossFolderMarkerDoesNotLicenseUnmarkedMembersInOtherFolders() {
        // The round-5 MAJOR: one marker in a cross-folder stem bucket must not vouch for the
        // whole bucket. "/2023/IMG_0001 copy.jpg" is evidence someone duplicated the IMG_0001.jpg
        // NEXT TO IT — not that /2019/IMG_0001.jpg (an unrelated shot that shares the name only
        // because cameras count from IMG_0001) is a version of either. Grouping all three would
        // recommend trashing the unique 2019 photo.
        let tree = [
            dir("/root/2023", [
                file("/root/2023/IMG_0001.jpg", size: 51_000, modified: Date(timeIntervalSince1970: 2_000_000)),
                file("/root/2023/IMG_0001 copy.jpg", size: 52_000, modified: Date(timeIntervalSince1970: 1_000_000)),
            ]),
            dir("/root/2019", [file("/root/2019/IMG_0001.jpg", size: 50_000)]),
        ]
        let hashes = [
            "/root/2023/IMG_0001.jpg": "SHOT-B",
            "/root/2023/IMG_0001 copy.jpg": "SHOT-B2",
            "/root/2019/IMG_0001.jpg": "SHOT-A",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .versions)
        // Only the marker-bearer and its same-parent sibling; the 2019 shot never joins.
        #expect(Set(groups[0].copies.map(\.path)) ==
                ["/root/2023/IMG_0001.jpg", "/root/2023/IMG_0001 copy.jpg"])
        #expect(!groups[0].recommendedRemovalPaths.contains("/root/2019/IMG_0001.jpg"))
    }

    @Test func hardLinkedEntriesLeaveDuplicateCandidacyEntirely() {
        // A directory entry is not the bytes: with the single-path copy model, EVERY offer
        // about a hard-linked file is a lie — trashing one link frees nothing (a sibling
        // entry, in or out of the scan, keeps the blocks), and a "resolved" group leaves the
        // duplicate content on disk. Multi-link files are dropped before ANY pass; a per-pass
        // collapse protected `identical` but un-claimed the links for `versions`.
        let multiLink: Set<String> = ["/root/Docs/a.bin", "/root/Docs/b.bin"]

        // Links beside a real independent copy: no truthful offer exists → no group. (The old
        // collapse grouped keeper + one link and claimed the link's bytes reclaimable — a
        // Time-Machine-shaped no-op trash.)
        let withRealCopy = DuplicateFinder.findGroups(
            tree: [dir("/root/Docs", [file("/root/Docs/a.bin", size: 50_000),
                                      file("/root/Docs/b.bin", size: 50_000),
                                      file("/root/Docs/c.bin", size: 50_000)])],
            fileHashes: ["/root/Docs/a.bin": "H", "/root/Docs/b.bin": "H", "/root/Docs/c.bin": "H"],
            multiLinkPaths: multiLink)
        #expect(!withRealCopy.contains { $0.matchType == .identical })

        // The versions pass is protected by the SAME drop: linked "report.pdf"/"report
        // copy.pdf" (one inode) plus a real drifted v2 must not form a versions group that
        // recommends trashing a link and counts its bytes as reclaimable.
        let versionsShape = DuplicateFinder.findGroups(
            tree: [dir("/root/Docs", [file("/root/Docs/report.pdf", size: 50_000),
                                      file("/root/Docs/report copy.pdf", size: 50_000),
                                      file("/root/Docs/report v2.pdf", size: 51_000)])],
            fileHashes: ["/root/Docs/report.pdf": "H", "/root/Docs/report copy.pdf": "H",
                         "/root/Docs/report v2.pdf": "G"],
            multiLinkPaths: ["/root/Docs/report.pdf", "/root/Docs/report copy.pdf"])
        #expect(!versionsShape.contains { g in
            g.copies.contains { $0.path.contains("report.pdf") || $0.path.contains("report copy.pdf") }
        })

        // No link-count metadata → prior behavior exactly (distinct files, both group).
        let unknown = DuplicateFinder.findGroups(
            tree: [dir("/root/Docs", [file("/root/Docs/a.bin", size: 50_000),
                                      file("/root/Docs/b.bin", size: 50_000)])],
            fileHashes: ["/root/Docs/a.bin": "H", "/root/Docs/b.bin": "H"])
        #expect(unknown.contains { $0.matchType == .identical })
    }

    @Test func independentMarkerClustersInDifferentFoldersNeverPoolUnmarkedOriginals() {
        // Markers in TWO different folders are two independent duplication events (ClientA
        // duplicated its report; ClientB duplicated its own), not one document's history.
        // Pooling both folders' plain files into one group made the newest file anywhere the
        // keeper and recommended trashing the OTHER folder's unmarked original — an unrelated
        // document. Only the marker-bearers may group cross-folder (their names carry their
        // own evidence); each folder's unmarked report.pdf must never ride along.
        let tree = [
            dir("/root/ClientA", [
                file("/root/ClientA/report.pdf", size: 9_000, modified: Date(timeIntervalSince1970: 1_500_000)),
                file("/root/ClientA/report copy.pdf", size: 9_100, modified: Date(timeIntervalSince1970: 1_000_000)),
            ]),
            dir("/root/ClientB", [
                file("/root/ClientB/report.pdf", size: 9_500, modified: Date(timeIntervalSince1970: 2_500_000)),
                file("/root/ClientB/report copy 2.pdf", size: 9_600, modified: Date(timeIntervalSince1970: 2_000_000)),
            ]),
        ]
        let hashes = [
            "/root/ClientA/report.pdf": "A", "/root/ClientA/report copy.pdf": "A2",
            "/root/ClientB/report.pdf": "B", "/root/ClientB/report copy 2.pdf": "B2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        // One group PER folder, each pairing the marked copy with ITS OWN original — never a
        // cross-folder mix that would let ClientB's newer file adjudicate ClientA's history.
        let versions = groups.filter { $0.matchType == .versions }
        #expect(versions.count == 2)
        for g in versions {
            let parents = Set(g.copies.map { ($0.path as NSString).deletingLastPathComponent })
            #expect(parents.count == 1)   // no group spans folders
        }
        // Each folder's original is the newest there → keeper; only the marked copies are
        // recommended for removal.
        let removals = Set(groups.flatMap(\.recommendedRemovalPaths))
        #expect(removals == ["/root/ClientA/report copy.pdf", "/root/ClientB/report copy 2.pdf"])
    }

    @Test func bearersOfHashStarvedClustersStillPoolCrossFolder() {
        // A marker folder with same-stem company forms a per-folder cluster — but when that
        // cluster can't prove drift (its companions are unknown-hash: too large, cloud-only),
        // the guard kills it, and the bearer must FALL THROUGH to the cross-folder pool
        // rather than silently vanish: its marked name still carries its own evidence, and a
        // lone bearer elsewhere may prove the drift the home folder couldn't.
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/report copy.pdf", size: 9_000, modified: old),
                file("/root/Docs/report.pdf", size: 9_100, modified: old),   // unknown hash
            ]),
            dir("/root/Desktop", [
                file("/root/Desktop/report copy 2.pdf", size: 9_200, modified: new),
                file("/root/Desktop/d-notes.txt", size: 8_192),
            ]),
        ]
        let hashes = [   // Docs/report.pdf deliberately absent → no real signature
            "/root/Docs/report copy.pdf": "A",
            "/root/Desktop/report copy 2.pdf": "B",
            "/root/Desktop/d-notes.txt": "N",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        let versions = groups.filter { $0.matchType == .versions }
        #expect(versions.count == 1)
        #expect(Set(versions[0].copies.map(\.path)) ==
                ["/root/Docs/report copy.pdf", "/root/Desktop/report copy 2.pdf"])
        // The unknown-hash original never rides along with the cross-folder pool.
        #expect(!versions[0].copies.contains { $0.path == "/root/Docs/report.pdf" })
    }

    @Test func multiParentBucketKeepsEachBearersOwnOriginalInItsGroup() {
        // The refinement's other half: when one folder holds a true original + marked copy and
        // ANOTHER folder holds a lone marked copy, the same-parent pair must still group
        // (round-5 semantics per folder) — dropping the original there would let "keep newest"
        // adjudicate among stale marked copies with the real newest revision invisible. The
        // lone bearer has no same-stem company and pools with no one → stays ungrouped.
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/report.pdf", size: 9_000, modified: Date(timeIntervalSince1970: 3_000_000)),
                file("/root/Docs/report v2.pdf", size: 9_100, modified: Date(timeIntervalSince1970: 2_000_000)),
            ]),
            dir("/root/Desktop", [
                file("/root/Desktop/report copy 2.pdf", size: 9_600, modified: Date(timeIntervalSince1970: 1_000_000)),
                file("/root/Desktop/desk-notes.txt", size: 8_192),
            ]),
        ]
        let hashes = [
            "/root/Docs/report.pdf": "R3", "/root/Docs/report v2.pdf": "R2",
            "/root/Desktop/report copy 2.pdf": "R1", "/root/Desktop/desk-notes.txt": "N",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        let versions = groups.filter { $0.matchType == .versions }
        #expect(versions.count == 1)
        #expect(Set(versions[0].copies.map(\.path)) ==
                ["/root/Docs/report.pdf", "/root/Docs/report v2.pdf"])
        #expect(versions[0].keeper.path == "/root/Docs/report.pdf")   // the newest IS the original
        #expect(!groups.flatMap(\.recommendedRemovalPaths).contains("/root/Desktop/report copy 2.pdf"))
    }

    @Test func unmarkedCrossFolderMemberNeverSuppliesTheDriftEvidence() {
        // The excluded member's hash must not count as "distinct real contents": here the two
        // same-parent members are byte-identical (already claimed by the identical pass), so no
        // versions group may ride on the excluded cross-folder file's differing hash.
        let tree = [
            dir("/root/2023", [
                file("/root/2023/IMG_0002.jpg", size: 51_000),
                file("/root/2023/IMG_0002 copy.jpg", size: 51_000),
            ]),
            dir("/root/2019", [file("/root/2019/IMG_0002.jpg", size: 50_000)]),
        ]
        let hashes = [
            "/root/2023/IMG_0002.jpg": "SAME",
            "/root/2023/IMG_0002 copy.jpg": "SAME",
            "/root/2019/IMG_0002.jpg": "OTHER",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        if case .identical = groups[0].matchType {} else {
            Issue.record("expected the same-parent pair to stay an identical group, got \(groups[0].matchType)")
        }
        #expect(!groups.contains { $0.copies.contains { $0.path == "/root/2019/IMG_0002.jpg" } })
    }

    @Test func unknownHashPlaceholdersAreNotEvidenceOfVersionDrift() {
        // Two byte-identical files too large to hash get per-path "u:" placeholder signatures.
        // Placeholders are unique by construction, so counting them as distinct contents would
        // claim drift between files that may be identical — they must never stand up a group.
        let tree = [
            dir("/root/Movies", [
                file("/root/Movies/trip.mp4", size: 500_000),
                file("/root/Movies/trip copy.mp4", size: 500_000),
            ])
        ]
        let hashes = [
            "/root/Movies/trip.mp4": DuplicateFinder.unknownSignature(forPath: "/root/Movies/trip.mp4"),
            "/root/Movies/trip copy.mp4": DuplicateFinder.unknownSignature(forPath: "/root/Movies/trip copy.mp4"),
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.contains { $0.matchType == .versions })
    }

    @Test func oneRealHashPlusUnknownIsNotVersionDrift() {
        // Drift needs two distinct REAL contents; one known hash and one unknown proves nothing.
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/plan.key", size: 9000),
                file("/root/Docs/plan copy.key", size: 500_000),
            ])
        ]
        let hashes = [
            "/root/Docs/plan.key": "H1",
            "/root/Docs/plan copy.key": DuplicateFinder.unknownSignature(forPath: "/root/Docs/plan copy.key"),
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.contains { $0.matchType == .versions })
    }

    @Test func unknownMemberRidesAlongWhenRealDriftExists() {
        // Two distinct real hashes justify the group; the unhashable third member is included
        // (it shares the stem and a marker) rather than silently dropped.
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/deck.key", size: 9000, modified: old),
                file("/root/Docs/deck copy.key", size: 9500, modified: new),
                file("/root/Docs/deck copy 2.key", size: 500_000, modified: old),
            ])
        ]
        let hashes = [
            "/root/Docs/deck.key": "H1",
            "/root/Docs/deck copy.key": "H2",
            "/root/Docs/deck copy 2.key": DuplicateFinder.unknownSignature(forPath: "/root/Docs/deck copy 2.key"),
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .versions)
        #expect(groups[0].copies.count == 3)
        // The unhashable member is flagged so the UI can caveat the group's content claim.
        #expect(groups[0].copies.first { $0.path.hasSuffix("deck copy 2.key") }?.contentUnverified == true)
        #expect(groups[0].copies.filter { $0.contentUnverified }.count == 1)
    }

    @Test func versionsKeeperAvoidsArchiveLocationEvenWhenNewest() {
        // A backup tool rewrote the archived copy last — mtime alone would crown it the keeper
        // and recommend trashing the working copy. Archive-like locations are penalized first,
        // exactly as in chooseKeeper. (Both names carry markers: a cross-folder member joins a
        // versions group only on its own marker.)
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Docs", [file("/root/Docs/deck-v1.pdf", size: 9000, modified: old),
                               file("/root/Docs/d-only.txt", size: 8192)]),
            dir("/root/Backups", [file("/root/Backups/deck-final.pdf", size: 9500, modified: new),
                                  file("/root/Backups/b-only.txt", size: 8192)]),
        ]
        let hashes = [
            "/root/Docs/deck-v1.pdf": "D1", "/root/Backups/deck-final.pdf": "D2",
            "/root/Docs/d-only.txt": "U1", "/root/Backups/b-only.txt": "U2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .versions)
        #expect(groups[0].keeper.path == "/root/Docs/deck-v1.pdf")
    }

    @Test func versionsKeeperDoesNotPenalizeTransientDownloadLocations() {
        // The newest revision of a drifted document routinely sits in Downloads (just saved from
        // mail/browser) — penalizing "downloads" like an archive recommended keeping the STALE
        // Documents copy and trashing the only copy of the new content. Only true archive/backup/
        // trash segments may demote a versions keeper. Exercises newestIndex directly with the
        // round-5 scenario: Documents/report.pdf (old) vs Downloads/report-v2.pdf (new, differs).
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        func info(_ path: String, modified: Date, hash: String) -> DuplicateFinder.NodeInfo {
            DuplicateFinder.NodeInfo(path: path, name: (path as NSString).lastPathComponent,
                                     isDirectory: false, size: 9000, itemCount: 1,
                                     modificationDate: modified, depth: 1,
                                     signature: hash, contentHashes: [hash])
        }
        let members = [
            info("/root/Documents/report.pdf", modified: old, hash: "R-OLD"),
            info("/root/Downloads/report-v2.pdf", modified: new, hash: "R-NEW"),
        ]
        #expect(DuplicateFinder.newestIndex(members) == 1)   // the Downloads copy IS the newest

        // A true backup location still loses even when newest — the trimmed set keeps that pin.
        let backup = [
            info("/root/Documents/report.pdf", modified: old, hash: "R-OLD"),
            info("/root/Backups/report-v2.pdf", modified: new, hash: "R-NEW"),
        ]
        #expect(DuplicateFinder.newestIndex(backup) == 0)
    }

    @Test func versionsGroupKeepsNewestRevisionSittingInDownloads() {
        // End-to-end: a marker-bearing pair across Documents/Downloads must recommend keeping
        // the newer Downloads revision, not the stale Documents copy.
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Documents", [file("/root/Documents/budget copy.xlsx", size: 9000, modified: old)]),
            dir("/root/Downloads", [file("/root/Downloads/budget-v2.xlsx", size: 9500, modified: new)]),
        ]
        let hashes = [
            "/root/Documents/budget copy.xlsx": "B1",
            "/root/Downloads/budget-v2.xlsx": "B2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups[0].matchType == .versions)
        #expect(groups[0].keeper.path == "/root/Downloads/budget-v2.xlsx")
        #expect(groups[0].recommendedRemovalPaths == ["/root/Documents/budget copy.xlsx"])
    }

    @Test func hasVersionMarkerDetectsStrippedMarkersOnly() {
        #expect(DuplicateFinder.hasVersionMarker("Q3 Report (1).docx"))
        #expect(DuplicateFinder.hasVersionMarker("plan copy.key"))
        #expect(DuplicateFinder.hasVersionMarker("deck-final.pdf"))
        #expect(!DuplicateFinder.hasVersionMarker("IMG_0001.jpg"))
        #expect(!DuplicateFinder.hasVersionMarker("invoice.pdf"))
        #expect(!DuplicateFinder.hasVersionMarker("Report.PDF"))   // case alone is not a marker
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

    @Test func optionsFromDefaultsFallsBackThenReadsOverrides() {
        let suite = "DuplicatesOptTest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        let fallback = DuplicateFinderOptions.fromDefaults(d)   // nothing set → code defaults
        #expect(fallback.minFileSize == 4096)
        #expect(fallback.overlapThreshold == 0.7)
        #expect(fallback.detectVersions == true)
        #expect(fallback.detectSameText == true)

        d.set(102_400, forKey: DuplicateFinderOptions.DefaultsKey.minFileSize)
        d.set(0.9, forKey: DuplicateFinderOptions.DefaultsKey.overlapThreshold)
        d.set(false, forKey: DuplicateFinderOptions.DefaultsKey.detectVersions)
        // The Settings toggle writes this key and nothing else reads it. Left out of this test,
        // the switch would have been inert with every other test still green — a new option is
        // invisible to a fixture that only ever starts from the defaults.
        d.set(false, forKey: DuplicateFinderOptions.DefaultsKey.detectSameText)
        let overridden = DuplicateFinderOptions.fromDefaults(d)
        #expect(overridden.minFileSize == 102_400)
        #expect(overridden.overlapThreshold == 0.9)
        #expect(overridden.detectVersions == false)
        #expect(overridden.detectSameText == false)
    }

    @Test func nestedSameNameFoldersDoNotFormAGroup() {
        // /X/Data contains a nested /X/Data/old/Data whose file is a subset — the inner folder is
        // PART of the outer's content, not a separate copy. Grouping them would let a merge trash
        // a piece of the keeper. They must not be paired in one group.
        let inner = dir("/X/Data/old/Data", [file("/X/Data/old/Data/a.txt", size: 5000)])
        let old = dir("/X/Data/old", [inner])
        let outer = dir("/X/Data", [file("/X/Data/a.txt", size: 5000), file("/X/Data/b.txt", size: 6000), old])
        let hashes = [
            "/X/Data/a.txt": "HA", "/X/Data/b.txt": "HB",
            "/X/Data/old/Data/a.txt": "HA",
        ]
        let groups = DuplicateFinder.findGroups(tree: [outer], fileHashes: hashes)
        #expect(!groups.contains { g in
            let paths = Set(g.copies.map { $0.path })
            return paths.contains("/X/Data") && paths.contains("/X/Data/old/Data")
        })
    }

    // MARK: - `keeper` and `redundantCopies` must never name the same copy

    private static func copy(_ path: String, keeper: Bool, depth: Int = 2) -> DuplicateCopy {
        DuplicateCopy(id: path, name: "x", isDirectory: false, size: 100, itemCount: 1,
                      modificationDate: nil, uniqueItemCount: 0, depth: depth,
                      isRecommendedKeeper: keeper)
    }

    /// **A group with nothing flagged used to report its own keeper as redundant.**
    ///
    /// `keeper` falls back to `copies[0]` when no copy carries the flag — a fallback that exists
    /// because `init` is public — while `redundantCopies` filtered on the flag alone and so
    /// returned every copy, that one included. The consumers of that list drive "Move to Trash",
    /// which makes the disagreement every copy of a file going to the Trash together with the one
    /// meant to survive.
    ///
    /// No production route builds such a group today (the finder flags `idx == 0`,
    /// `choosingKeeper` refuses an unknown id, `removingRedundantCopy` re-promotes). This pins the
    /// two accessors to each other so a route that ever does cannot make them disagree.
    @Test func aGroupWithNoFlaggedKeeperDoesNotListItsKeeperAsRedundant() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [Self.copy("/a/x", keeper: false),
                                        Self.copy("/b/x", keeper: false)],
                               reclaimableBytes: 100)
        #expect(g.keeper.id == "/a/x", "fixture: the fallback keeper is the first copy")
        #expect(!g.redundantCopies.contains { $0.id == g.keeper.id },
                "the group's own keeper is on the list of copies to remove")
        #expect(g.redundantCopies.map(\.id) == ["/b/x"])
    }

    /// The ordinary case is untouched — the fix must not change what a well-formed group removes.
    @Test func aNormalGroupsRedundantListIsUnchanged() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [Self.copy("/a/x", keeper: true),
                                        Self.copy("/b/x", keeper: false),
                                        Self.copy("/c/x", keeper: false)],
                               reclaimableBytes: 200)
        #expect(g.keeper.id == "/a/x")
        #expect(g.redundantCopies.map(\.id) == ["/b/x", "/c/x"])
    }

    /// The invariant broken the other way: TWO flagged copies. Both stay off the redundant list,
    /// because the filter keeps the flag test as well as the id test — removing fewer copies is
    /// the right direction for a list that feeds a trash.
    @Test func aGroupWithTwoFlaggedKeepersRemovesNeitherOfThem() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [Self.copy("/a/x", keeper: true),
                                        Self.copy("/b/x", keeper: true),
                                        Self.copy("/c/x", keeper: false)],
                               reclaimableBytes: 100)
        #expect(g.redundantCopies.map(\.id) == ["/c/x"])
    }

    /// An empty group has nothing to remove, and asking must not trap. (`keeper` itself still
    /// traps on one, deliberately — see its doc.)
    @Test func anEmptyGroupHasNoRedundantCopies() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [], reclaimableBytes: 0)
        #expect(g.redundantCopies.isEmpty)
    }

    @Test func choosingKeeperRecomputesRemovalForIdentical() {
        let a = DuplicateCopy(id: "/a/x", name: "x", isDirectory: false, size: 100, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 2, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/b/x", name: "x", isDirectory: false, size: 100, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 2, isRecommendedKeeper: false)
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false, copies: [a, b], reclaimableBytes: 100)

        let g2 = g.choosingKeeper("/b/x")
        #expect(g2.keeper.id == "/b/x")
        #expect(g2.recommendedRemovalPaths == ["/a/x"])   // the other copy now gets trashed
        #expect(g2.reclaimableBytes == 100)
        #expect(g2.id == g.id)                            // list/expansion identity preserved
    }

    @Test func choosingKeeperIsNoOpForOverlapping() {
        let a = DuplicateCopy(id: "/a", name: "Inv", isDirectory: true, size: 100, itemCount: 5,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/b", name: "Inv", isDirectory: true, size: 90, itemCount: 4,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let g = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.9), name: "Inv", isDirectory: true,
                               copies: [a, b], reclaimableBytes: 80)
        #expect(g.allowsKeeperChoice == false)
        #expect(g.choosingKeeper("/b").keeper.id == "/a")   // unchanged — overlap needs hashes
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

    private func copy(_ id: String, size: Int, depth: Int, keeper: Bool, unique: Int = 0,
                      protected: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: id, name: (id as NSString).lastPathComponent, isDirectory: true, size: size,
                      itemCount: 1, modificationDate: nil, uniqueItemCount: unique, depth: depth,
                      isRecommendedKeeper: keeper, isProtectedFromRemoval: protected)
    }

    // MARK: Reclaimable bytes must match what removal will actually take

    /// `recommendedRemovalPaths` filters protected copies; the reclaim figure did not. Re-aiming
    /// the keeper is precisely the move that puts a protected copy on the redundant side, so the
    /// card promised bytes back from a file its own "Move to Trash" would never touch.
    @Test func choosingAKeeperDoesNotCountProtectedBytesAsReclaimable() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [copy("/kept/F1/x", size: 100, depth: 1, keeper: true, protected: true),
                                        copy("/b/x", size: 100, depth: 1, keeper: false),
                                        copy("/c/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 200)

        let reAimed = g.choosingKeeper("/b/x")
        #expect(reAimed.recommendedRemovalPaths == ["/c/x"],
                "the protected copy stays off the removal list")
        #expect(reAimed.reclaimableBytes == 100,
                "so its bytes must stay out of the reclaim figure too")
    }

    /// The same rule on the out-of-band removal path, which recomputes from the survivors.
    @Test func removingACopyDoesNotCountProtectedBytesAsReclaimable() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [copy("/a/x", size: 100, depth: 0, keeper: true),
                                        copy("/kept/F1/x", size: 100, depth: 1, keeper: false, protected: true),
                                        copy("/c/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 100)

        let g2 = g.removingRedundantCopy(atPath: "/c/x")!
        #expect(g2.recommendedRemovalPaths.isEmpty)
        #expect(g2.reclaimableBytes == 0)
    }

    /// Mutation guard for both of the above: an unprotected copy in the same position must still
    /// count, or the fix would read as "reclaim is always zero".
    @Test func anUnprotectedRedundantCopyStillCountsAsReclaimable() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [copy("/a/x", size: 100, depth: 0, keeper: true),
                                        copy("/b/x", size: 100, depth: 1, keeper: false),
                                        copy("/c/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 200)
        #expect(g.choosingKeeper("/b/x").reclaimableBytes == 200)
        #expect(g.removingRedundantCopy(atPath: "/c/x")!.reclaimableBytes == 100)
    }

    @Test func removingLastRedundantResolvesGroupToNil() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: true,
                               copies: [copy("/a/x", size: 100, depth: 2, keeper: true),
                                        copy("/b/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 100)
        #expect(g.removingRedundantCopy(atPath: "/b/x") == nil)   // only the keeper would remain
    }

    @Test func removingOneOfManyRecomputesIdenticalReclaim() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: true,
                               copies: [copy("/a/x", size: 100, depth: 0, keeper: true),
                                        copy("/b/x", size: 100, depth: 1, keeper: false),
                                        copy("/c/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 200)
        let g2 = g.removingRedundantCopy(atPath: "/b/x")!
        #expect(g2.copies.count == 2)
        #expect(g2.keeper.id == "/a/x")
        #expect(g2.reclaimableBytes == 100)                       // one remaining redundant copy
        #expect(g2.recommendedRemovalPaths == ["/c/x"])
        #expect(g2.id == g.id)                                    // list identity preserved
    }

    @Test func removingOneOverlappingCopyDropsItsSharedBytes() {
        let g = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Inv", isDirectory: true,
                               copies: [copy("/a", size: 100, depth: 0, keeper: true),
                                        copy("/b", size: 90, depth: 1, keeper: false, unique: 1),
                                        copy("/c", size: 80, depth: 2, keeper: false, unique: 2)],
                               reclaimableBytes: 85)   // 90*0.5 + 80*0.5
        let g2 = g.removingRedundantCopy(atPath: "/b")!
        #expect(g2.copies.count == 2)
        #expect(g2.reclaimableBytes == 40)             // 85 - round(90*0.5)
        if case .overlapping(let f) = g2.matchType { #expect(f == 0.5) } else { Issue.record("match type changed") }
    }

    @Test func removingTheKeeperPromotesShallowestSurvivor() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: true,
                               copies: [copy("/a/x", size: 100, depth: 0, keeper: true),
                                        copy("/b/x", size: 100, depth: 1, keeper: false),
                                        copy("/c/x", size: 100, depth: 2, keeper: false)],
                               reclaimableBytes: 200)
        let g2 = g.removingRedundantCopy(atPath: "/a/x")!   // not expected from Compare, but must stay honest
        #expect(g2.keeper.id == "/b/x")                     // shallowest survivor promoted
        #expect(g2.reclaimableBytes == 100)
    }

    @Test func removingUnknownPathIsANoOp() {
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: true,
                               copies: [copy("/a/x", size: 100, depth: 0, keeper: true),
                                        copy("/b/x", size: 100, depth: 1, keeper: false)],
                               reclaimableBytes: 100)
        #expect(g.removingRedundantCopy(atPath: "/nope")! == g)
    }


    // MARK: Folder-keeper protection must not distort the groups it protects

    @Test func versionsStillKeepTheNewestWhenAProtectedFileIsInTheCluster() {
        // Protection originally chose the keeper from the PROTECTED subset using the pass's own
        // rule. For versions that rule is "newest", and the card says so out loud ("Keep newest,
        // Trash older") — so picking the newest of a subset silently inverted the promise: the
        // keeper became an older file inside the kept folder and the genuinely newest copy was
        // recommended for the Trash. The keeper is now the real newest; protection only removes
        // protected files from the removable side.
        //
        // Three marker bearers in three folders, which is what pools them into ONE cluster.
        let oldest = Date(timeIntervalSince1970: 100_000_000)
        let middle = Date(timeIntervalSince1970: 500_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let f1 = dir("/root/Docs/F1", [
            file("/root/Docs/F1/report copy 2.pdf", size: 8192, modified: middle),
            file("/root/Docs/F1/keep.txt", size: 9000),
        ])
        let f2 = dir("/root/Archive/F1", [
            file("/root/Archive/F1/report copy 2.pdf", size: 8192, modified: middle),
            file("/root/Archive/F1/keep.txt", size: 9000),
        ])
        let work = dir("/root/Work", [file("/root/Work/report copy.pdf", size: 8192, modified: newest)])
        let beta = dir("/root/Beta", [file("/root/Beta/report copy 3.pdf", size: 8192, modified: oldest)])
        let hashes = [
            "/root/Docs/F1/report copy 2.pdf": "HV1", "/root/Docs/F1/keep.txt": "HK",
            "/root/Archive/F1/report copy 2.pdf": "HV1", "/root/Archive/F1/keep.txt": "HK",
            "/root/Work/report copy.pdf": "HV2",
            "/root/Beta/report copy 3.pdf": "HV3",
        ]

        let groups = DuplicateFinder.findGroups(tree: [f1, f2, work, beta], fileHashes: hashes)

        let versions = groups.first { $0.matchType == .versions }
        #expect(versions?.keeper.path == "/root/Work/report copy.pdf", "the keeper must be the real newest")
        let removals = groups.flatMap { $0.recommendedRemovalPaths }
        #expect(!removals.contains("/root/Work/report copy.pdf"),
                "the newest file must never be recommended for removal")
        #expect(!removals.contains { $0.hasPrefix("/root/Docs/F1/") })
    }

    @Test func aFileDroppedByProtectionDoesNotReappearAsAVersion() {
        // The identical pass marks what it has accounted for so the versions pass skips it. It was
        // marking only the copies that SURVIVED protection, so a protected file dropped from an
        // identical group became eligible again and resurfaced in a versions group the identical
        // pass had always suppressed.
        //
        // Dates make the NON-marker file the identical group's keeper, so the marker bearer is the
        // one protection drops — the member that can go on to form a version cluster.
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Date(timeIntervalSince1970: 100_000_000)
        let f1 = dir("/root/Docs/F1", [
            file("/root/Docs/F1/report.pdf", size: 8192, modified: newer),
            file("/root/Docs/F1/report copy.pdf", size: 8192, modified: older),
        ])
        let f2 = dir("/root/Archive/F1", [
            file("/root/Archive/F1/report.pdf", size: 8192, modified: newer),
            file("/root/Archive/F1/report copy.pdf", size: 8192, modified: older),
        ])
        let alpha = dir("/root/Alpha", [file("/root/Alpha/report.pdf", size: 8192, modified: older)])
        let other = dir("/root/Other", [file("/root/Other/report copy 2.pdf", size: 8192, modified: older)])
        let hashes = [
            "/root/Docs/F1/report.pdf": "HA", "/root/Docs/F1/report copy.pdf": "HA",
            "/root/Archive/F1/report.pdf": "HA", "/root/Archive/F1/report copy.pdf": "HA",
            "/root/Alpha/report.pdf": "HA",
            "/root/Other/report copy 2.pdf": "HB",
        ]

        let groups = DuplicateFinder.findGroups(tree: [f1, f2, alpha, other], fileHashes: hashes)

        #expect(!groups.contains { $0.matchType == .versions },
                "a file the identical pass accounted for must not resurface as a version")
        #expect(!groups.flatMap { $0.recommendedRemovalPaths }.contains { $0.hasPrefix("/root/Docs/F1/") })
    }

    @Test func reAimingTheKeeperCannotPutAProtectedFileBackOnTheRemovalList() {
        // The invariant used to last exactly as long as the DEFAULT keeper: `choosingKeeper`
        // relabels copies by id alone, so one click on the other copy put the kept folder's own
        // file straight back onto the removal list.
        let f1 = dir("/root/Docs/Sub/F1", [
            file("/root/Docs/Sub/F1/a.txt", size: 8192),
            file("/root/Docs/Sub/F1/b.txt", size: 9000),
        ])
        let f2 = dir("/root/Archive/Sub/F1", [
            file("/root/Archive/Sub/F1/a.txt", size: 8192),
            file("/root/Archive/Sub/F1/b.txt", size: 9000),
        ])
        let alpha = dir("/root/Alpha", [file("/root/Alpha/a.txt", size: 8192), file("/root/Alpha/x.txt", size: 8192)])
        let hashes = [
            "/root/Docs/Sub/F1/a.txt": "HA", "/root/Docs/Sub/F1/b.txt": "HB",
            "/root/Archive/Sub/F1/a.txt": "HA", "/root/Archive/Sub/F1/b.txt": "HB",
            "/root/Alpha/a.txt": "HA", "/root/Alpha/x.txt": "HX",
        ]

        let groups = DuplicateFinder.findGroups(tree: [f1, f2, alpha], fileHashes: hashes)
        let fileGroup = groups.first { !$0.isDirectory && $0.name == "a.txt" }
        let reAimed = fileGroup?.choosingKeeper("/root/Alpha/a.txt")

        #expect(reAimed?.keeper.path == "/root/Alpha/a.txt", "the user's choice is still honoured")
        #expect(reAimed?.recommendedRemovalPaths == [],
                "but the kept folder's file is still not offered for removal")
    }
}
