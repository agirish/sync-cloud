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

    /// A package: a directory the walk reports with a package type identifier.
    private func package(_ path: String, _ children: [FileNode],
                         kind: String = "com.apple.iwork.keynote.key", modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, modificationDate: modified, kind: kind)
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
        // The folders are NOT reported as identical (A carries an extra symlink); dropping the
        // symlink from the signature would make A's equal B's and group them.
        #expect(!groups.contains { $0.isDirectory })
        // The genuinely identical real.txt still surfaces as a file duplicate.
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
        // recommended for removal. a.txt also has a third copy at a shallower path, so the file
        // pass sees {Docs/F1/a.txt, Alpha/a.txt} and the keeper heuristic prefers Alpha's. Unless the
        // kept folder's file is protected, one "Apply recommended" would trash Archive/F1 and also
        // remove a file from Docs/F1, the folder the same batch called an intact copy.
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
        // The redundant folder copy is still recommended.
        #expect(allRemovals.contains("/root/Archive/F1"))
    }

    // MARK: Name-only folders

    /// Same name and nothing in common is not a finding. Names like `2020`, `Archive` or `Payslips`
    /// repeat under every subject in a real tree, sharing no file; reporting them would fill the
    /// Duplicates lens with cards that have nothing to reclaim.
    @Test func sameNameAloneNeverMakesAFolderGroup() {
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
        #expect(DuplicateFinder.findGroups(tree: [a, b], fileHashes: hashes).isEmpty)
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

    /// A one-item `Visa` folder buried in a petition's supporting documents, holding one file that
    /// also lives in a large top-level `Visa`. Measured one-sidedly it is "100% shared"; over the
    /// larger side it is 1/6 here, and not a folder finding at all. It is a different subject that
    /// happens to hold one of the same documents, not a copy to merge.
    @Test func aTinyFolderWhollyInsideABigOneIsNotAMerge() {
        let big = dir("/root/Visa", (1...6).map { file("/root/Visa/d\($0).pdf") })
        let small = dir("/root/Petition/Supporting/Visa", [
            file("/root/Petition/Supporting/Visa/d1.pdf"),
        ])
        var hashes: [String: String] = [:]
        for i in 1...6 { hashes["/root/Visa/d\(i).pdf"] = "D\(i)" }
        // The one file it holds is one of the big folder's — 100% of the small side.
        hashes["/root/Petition/Supporting/Visa/d1.pdf"] = "D1"

        let groups = DuplicateFinder.findGroups(tree: [big, small], fileHashes: hashes)
        #expect(!groups.contains { $0.isDirectory },
                "a folder holding one of another folder's six files is not that folder")

        // The document itself is still found, which makes the drop safe: the folder pass marked
        // nothing covered, so the shared file surfaces as the file duplicate it is.
        let files = groups.filter { !$0.isDirectory }
        #expect(files.count == 1)
        #expect(files[0].matchType.kind == .identical)
        #expect(Set(files[0].copies.map(\.path))
                == ["/root/Visa/d1.pdf", "/root/Petition/Supporting/Visa/d1.pdf"])
    }

    /// The positive control for the gate: two folders that really are versions of each other clear
    /// it comfortably, and the fraction the card shows is the mutual one.
    @Test func twoFoldersThatAreMostlyEachOtherStillMerge() {
        let a = dir("/root/Invoices", (1...5).map { file("/root/Invoices/s\($0)") }
                    + [file("/root/Invoices/u1")])
        let b = dir("/root/Work/Invoices", (1...5).map { file("/root/Work/Invoices/s\($0)") })
        var hashes: [String: String] = ["/root/Invoices/u1": "U1"]
        for i in 1...5 {
            hashes["/root/Invoices/s\(i)"] = "S\(i)"
            hashes["/root/Work/Invoices/s\(i)"] = "S\(i)"
        }
        let groups = DuplicateFinder.findGroups(tree: [a, b], fileHashes: hashes)
        let folder = try! #require(groups.first { $0.isDirectory })
        guard case .overlapping(let fraction) = folder.matchType else {
            Issue.record("expected an overlapping group, got \(folder.matchType)")
            return
        }
        // Five shared over the larger side's six, not five over the smaller side's five.
        #expect(abs(fraction - 5.0 / 6.0) < 0.001,
                "the reported fraction is the mutual one, which is what makes it a claim about BOTH")
    }

    /// A real twin must not be lost to the company it keeps: a genuine six-against-six `Form W-2`
    /// pair, plus folders of one file that merely share the name. Averaging them would drop the
    /// whole set under the threshold, twin included. The gate is per copy, so the group is the
    /// real versions of each other and the subsets don't join.
    @Test func aGenuineTwinSurvivesTheSubsetsThatShareItsName() {
        let names = (1...6).map { "f\($0).pdf" }
        // The keeper carries one document the twin does not, so the pair is an OVERLAP rather than
        // an identical tree — which is the path under test. Six of its seven are shared: 0.857.
        let keeper = dir("/root/A/Form W-2",
                         names.map { file("/root/A/Form W-2/\($0)") }
                         + [file("/root/A/Form W-2/only-here.pdf")])
        let twin = dir("/root/B/Form W-2", names.map { file("/root/B/Form W-2/\($0)") })
        // Two folders that share the name and exactly one of the six documents.
        let sub1 = dir("/root/C/Form W-2", [file("/root/C/Form W-2/f1.pdf")])
        let sub2 = dir("/root/D/Form W-2", [file("/root/D/Form W-2/f1.pdf")])
        var hashes: [String: String] = [:]
        for (i, n) in names.enumerated() {
            hashes["/root/A/Form W-2/\(n)"] = "H\(i)"
            hashes["/root/B/Form W-2/\(n)"] = "H\(i)"
        }
        hashes["/root/A/Form W-2/only-here.pdf"] = "UNIQUE"
        hashes["/root/C/Form W-2/f1.pdf"] = "H0"
        hashes["/root/D/Form W-2/f1.pdf"] = "H0"

        let groups = DuplicateFinder.findGroups(tree: [keeper, twin, sub1, sub2], fileHashes: hashes)
        let folder = try! #require(groups.first { $0.isDirectory },
                                   "the six-against-six pair is a real finding and must survive")
        #expect(folder.matchType.kind == .overlapping)
        #expect(Set(folder.copies.map(\.path)) == ["/root/A/Form W-2", "/root/B/Form W-2"],
                "the group is the twin only — the one-file folders never joined")
        guard case .overlapping(let fraction) = folder.matchType else { return }
        #expect(abs(fraction - 6.0 / 7.0) < 0.001,
                "the figure is the twin's own, not an average dragged down by the subsets")

        // The subsets are not lost; they find each other. C and D hold the same single document,
        // so they are byte-identical trees and get a group of their own.
        let subsetGroup = try! #require(groups.first {
            $0.copies.contains { $0.path.hasPrefix("/root/C") }
        })
        #expect(subsetGroup.matchType.kind == .identical)
        #expect(Set(subsetGroup.copies.map(\.path)) == ["/root/C/Form W-2", "/root/D/Form W-2"])
        #expect(groups.count == 2, "and nothing else is reported")

        // Known gap: C's copy of `f1.pdf` is also in the keeper, and no group says so.
        // `coveredRoots` suppresses the inner files of a grouped folder pair so they aren't
        // reported twice, and that suppression is blind to copies outside the pair.
    }

    // MARK: Versions

    @Test func driftedVersionsGroupKeepsNewest() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        // A "-v2", not a " (1)": a download counter alone stands up no versions group
        // (`aDownloadCounterAloneIsNotVersions` below).
        let tree = [
            dir("/root/Docs", [
                file("/root/Docs/Q3 Report.docx", size: 5000, modified: old),
                file("/root/Docs/Q3 Report-v2.docx", size: 5200, modified: new),
            ])
        ]
        // Different content, so it's drift — not an exact-identical group.
        let hashes = [
            "/root/Docs/Q3 Report.docx": "V1",
            "/root/Docs/Q3 Report-v2.docx": "V2",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.matchType == .versions)
        #expect(g.keeper.path == "/root/Docs/Q3 Report-v2.docx")  // newest
        #expect(g.reclaimableBytes == 5000)
    }

    /// A counter never joins a versions group by name (his call). Months of downloaded
    /// `invoice (n).pdf` beside one `invoice copy.pdf` must not form one versions group off the
    /// copy's marker, or "Keep newest" trashes the bills. Counter-only members leave the cluster:
    /// the copy groups with its unmarked original alone, and with none left there is no group.
    /// Matching contents still group them, through the identical pass.
    @Test func counterOnlyMembersNeverJoinAVersionsGroup() {
        let day = 86_400.0
        var files = [file("/root/Downloads/invoice.pdf", size: 40_000,
                          modified: Date(timeIntervalSince1970: 1_000_000))]
        var hashes = ["/root/Downloads/invoice.pdf": "BILL0"]
        for n in 1...5 {
            let path = "/root/Downloads/invoice (\(n)).pdf"
            files.append(file(path, size: 40_000 + n * 100,
                              modified: Date(timeIntervalSince1970: 1_000_000 + Double(n) * 30 * day)))
            hashes[path] = "BILL\(n)"
        }
        files.append(file("/root/Downloads/invoice copy.pdf", size: 40_050,
                          modified: Date(timeIntervalSince1970: 1_000_000 + 200 * day)))
        hashes["/root/Downloads/invoice copy.pdf"] = "COPY"

        let versions = DuplicateFinder.findGroups(tree: [dir("/root/Downloads", files)],
                                                  fileHashes: hashes)
            .filter { $0.matchType == .versions }
        #expect(versions.count == 1)
        #expect(Set(versions.first?.copies.map(\.path) ?? [])
                == ["/root/Downloads/invoice.pdf", "/root/Downloads/invoice copy.pdf"],
                "a downloaded bill joined a versions group: \(versions.map { $0.copies.map(\.path) })")

        // Without the original, the copy has no one left to be a version of.
        let orphaned = files.filter { $0.name != "invoice.pdf" }
        #expect(!DuplicateFinder.findGroups(tree: [dir("/root/Downloads", orphaned)], fileHashes: hashes)
                    .contains { $0.matchType == .versions })
    }

    /// A download counter alone is not evidence of versions. A browser appends " (1)", " (2)" when
    /// the name exists, and a site names every bill the same, so "Keep newest, Trash older" would
    /// trash bills. Different bytes behind a counter are distinct documents as often as revisions,
    /// so no group, in one folder or pooled. A real marker beside the counter still stands one up,
    /// and a re-download with the same bytes is still an identical group.
    @Test func aDownloadCounterAloneIsNotVersions() {
        let jan = Date(timeIntervalSince1970: 1_000_000)
        let feb = Date(timeIntervalSince1970: 3_600_000)
        let mar = Date(timeIntervalSince1970: 6_200_000)
        let bills = [
            dir("/root/Downloads", [
                file("/root/Downloads/invoice.pdf", size: 41_000, modified: jan),
                file("/root/Downloads/invoice (1).pdf", size: 43_000, modified: feb),
                file("/root/Downloads/invoice (2).pdf", size: 42_000, modified: mar),
            ])
        ]
        let differ = ["/root/Downloads/invoice.pdf": "JAN", "/root/Downloads/invoice (1).pdf": "FEB",
                      "/root/Downloads/invoice (2).pdf": "MAR"]
        #expect(DuplicateFinder.findGroups(tree: bills, fileHashes: differ).isEmpty,
                "three bills under one counter-suffixed name were grouped")

        // Counters across folders (the lone-bearer pool) — the same answer.
        let pooled = [
            dir("/root/A", [file("/root/A/statement (1).pdf", size: 9_000, modified: jan),
                            file("/root/A/a-notes.txt", size: 8_192)]),
            dir("/root/B", [file("/root/B/statement (2).pdf", size: 9_500, modified: feb),
                            file("/root/B/b-notes.txt", size: 8_192)]),
        ]
        let pooledHashes = ["/root/A/statement (1).pdf": "S1", "/root/B/statement (2).pdf": "S2",
                            "/root/A/a-notes.txt": "NA", "/root/B/b-notes.txt": "NB"]
        #expect(!DuplicateFinder.findGroups(tree: pooled, fileHashes: pooledHashes)
                    .contains { $0.matchType == .versions })

        // A deliberate marker in the cluster still makes it versions, of the marked members and
        // the unmarked original. The counter-suffixed member stays out.
        let marked = [
            dir("/root/Docs", [
                file("/root/Docs/plan.pdf", size: 9_000, modified: jan),
                file("/root/Docs/plan (1).pdf", size: 9_100, modified: feb),
                file("/root/Docs/plan-final.pdf", size: 9_200, modified: mar),
            ])
        ]
        let markedHashes = ["/root/Docs/plan.pdf": "P1", "/root/Docs/plan (1).pdf": "P2",
                            "/root/Docs/plan-final.pdf": "P3"]
        let versions = DuplicateFinder.findGroups(tree: marked, fileHashes: markedHashes)
            .filter { $0.matchType == .versions }
        #expect(versions.count == 1)
        #expect(Set(versions.first?.copies.map(\.path) ?? [])
                == ["/root/Docs/plan.pdf", "/root/Docs/plan-final.pdf"])

        // And the same bytes behind a counter are still found — by the identical pass.
        let same = ["/root/Downloads/invoice.pdf": "ONE", "/root/Downloads/invoice (1).pdf": "ONE",
                    "/root/Downloads/invoice (2).pdf": "MAR"]
        let groups = DuplicateFinder.findGroups(tree: bills, fileHashes: same)
        #expect(groups.count == 1)
        if case .identical = groups.first?.matchType {} else {
            Issue.record("a re-download with identical bytes was not grouped: \(groups.map(\.matchType))")
        }
    }

    /// A counter under another marker is still a counter. `statement (1) copy.xlsx` is a copy of the
    /// second downloaded bill, not a version of the first; if its " copy" let it join
    /// `statement.xlsx`, "Keep newest" would trash a bill. Any name whose stem needed a counter
    /// stripped stays out. The control: a plain `statement copy.xlsx` still groups.
    @Test func aCounterBesideAnotherMarkerIsStillACounter() {
        let jan = Date(timeIntervalSince1970: 1_000_000)
        let feb = Date(timeIntervalSince1970: 3_600_000)
        let mar = Date(timeIntervalSince1970: 6_200_000)
        func bills(_ third: String) -> [FileNode] {
            [dir("/root/Downloads", [
                file("/root/Downloads/statement.xlsx", size: 9_000, modified: jan),
                file("/root/Downloads/statement (1).xlsx", size: 9_100, modified: feb),
                file("/root/Downloads/\(third)", size: 9_200, modified: mar),
            ])]
        }
        func hashes(_ third: String) -> [String: String] {
            ["/root/Downloads/statement.xlsx": "JAN", "/root/Downloads/statement (1).xlsx": "FEB",
             "/root/Downloads/\(third)": "FEB-EDITED"]
        }
        let counterCopy = "statement (1) copy.xlsx"
        let grouped = DuplicateFinder.findGroups(tree: bills(counterCopy), fileHashes: hashes(counterCopy))
            .filter { $0.matchType == .versions }
        #expect(grouped.isEmpty, "a copy of a downloaded bill joined a versions group: \(grouped.map { $0.copies.map(\.path) })")

        let plainCopy = "statement copy.xlsx"
        let control = DuplicateFinder.findGroups(tree: bills(plainCopy), fileHashes: hashes(plainCopy))
            .filter { $0.matchType == .versions }
        #expect(control.count == 1)
        #expect(Set(control.first?.copies.map(\.path) ?? [])
                == ["/root/Downloads/statement.xlsx", "/root/Downloads/statement copy.xlsx"])
    }

    /// A counter name is dropped before the bucket is clustered, not after. Left in, its hash would
    /// "prove" folder A's drift (`report.pdf` has no hash), so A would stand as a cluster, then be
    /// too small once the counter was filtered, and `report copy.pdf` would vanish with it. Without
    /// the counter, A can't prove drift, so its marked copy falls through to the cross-folder pool
    /// beside B's lone `report final.pdf`.
    @Test func aCounterNameDoesNotDecideHowTheBucketClusters() {
        let tree = [
            dir("/root/A", [
                file("/root/A/report.pdf", size: 9_000),
                file("/root/A/report (1).pdf", size: 9_100),
                file("/root/A/report copy.pdf", size: 9_200),
            ]),
            dir("/root/B", [file("/root/B/report final.pdf", size: 9_300)]),
        ]
        // `report.pdf` has no hash: too large, or cloud-only.
        let hashes = ["/root/A/report (1).pdf": "R1", "/root/A/report copy.pdf": "RC",
                      "/root/B/report final.pdf": "RF"]
        let versions = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
            .filter { $0.matchType == .versions }
        #expect(versions.count == 1, "groups: \(versions.map { $0.copies.map(\.path) })")
        #expect(Set(versions.first?.copies.map(\.path) ?? [])
                == ["/root/A/report copy.pdf", "/root/B/report final.pdf"])
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
        // One marker in a cross-folder stem bucket must not vouch for the whole bucket.
        // "/2023/IMG_0001 copy.jpg" is evidence someone duplicated the IMG_0001.jpg NEXT TO IT, not
        // that /2019/IMG_0001.jpg (an unrelated shot sharing the name because cameras count from
        // IMG_0001) is a version of either. Grouping all three would recommend trashing the unique
        // 2019 photo.
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
        // A directory entry is not the bytes: with the single-path copy model, every offer about a
        // hard-linked file is false. Trashing one link frees nothing (a sibling entry keeps the
        // blocks), and a "resolved" group leaves the content on disk. Multi-link files are dropped
        // before any pass, so no pass (`versions` included) can claim them.
        let multiLink: Set<String> = ["/root/Docs/a.bin", "/root/Docs/b.bin"]

        // Links beside a real independent copy: no truthful offer exists → no group. Grouping the
        // keeper with one link would claim the link's bytes reclaimable when trashing frees none.
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

        // No link-count metadata → ordinary behaviour (distinct files, both group).
        let unknown = DuplicateFinder.findGroups(
            tree: [dir("/root/Docs", [file("/root/Docs/a.bin", size: 50_000),
                                      file("/root/Docs/b.bin", size: 50_000)])],
            fileHashes: ["/root/Docs/a.bin": "H", "/root/Docs/b.bin": "H"])
        #expect(unknown.contains { $0.matchType == .identical })
    }

    @Test func independentMarkerClustersInDifferentFoldersNeverPoolUnmarkedOriginals() {
        // Markers in TWO different folders are two independent duplication events (ClientA
        // duplicated its report; ClientB duplicated its own), not one document's history.
        // Pooling both folders' plain files would make the newest file anywhere the keeper and
        // recommend trashing the OTHER folder's unmarked original, an unrelated document. Only
        // the marker-bearers may group cross-folder (their names carry their own evidence);
        // each folder's unmarked report.pdf must never ride along.
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
        // The other half: when one folder holds a true original + marked copy and ANOTHER folder
        // holds a lone marked copy, the same-parent pair must still group. Dropping the original
        // would let "keep newest" choose among stale marked copies with the real newest revision
        // invisible. The lone bearer has no same-stem company and pools with no one → ungrouped.
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
        // mail/browser); penalizing "downloads" like an archive would keep the STALE Documents
        // copy and trash the only copy of the new content. Only true archive/backup/trash
        // segments may demote a versions keeper. Exercises newestIndex directly:
        // Documents/report.pdf (old) vs Downloads/report-v2.pdf (new, differs).
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

        // A true backup location still loses even when newest.
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

    @Test func aSkippedToolingTreeLeavesItsFolderUnidentified() {
        // Both node_modules hold the same lib.js — but the walk never looks inside one, so it
        // cannot know that. A and B are NOT asserted identical; keep.txt is still found as the
        // file duplicate it is, and nothing inside node_modules is ever surfaced.
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
        #expect(groups.count == 1)
        #expect(groups.first?.isDirectory == false)
        #expect(groups.first?.copies.map(\.path).sorted() == ["/root/A/keep.txt", "/root/B/keep.txt"])
        #expect(groups.allSatisfy { !$0.copies.contains { $0.path.contains("node_modules") } })
    }

    /// A repository and a ZIP of its working tree hold the same files; only the repository holds
    /// `.git`. The archive penalty makes the repository the copy a folder group would trash.
    ///
    /// This pins the folder: no folder group forms, so the repository is never offered for removal
    /// whole. The files inside are not protected: the archive penalty still recommends removing its
    /// tracked `a.txt` and `b.txt`. The last assertion says so, so changing either is deliberate.
    @Test func aRepositoryFolderIsNeverOfferedAsAFolderCopyOfItsWorkingTree() {
        let tree = [
            dir("/root/Archive/proj", [
                dir("/root/Archive/proj/.git", [file("/root/Archive/proj/.git/HEAD", size: 23)]),
                file("/root/Archive/proj/a.txt"), file("/root/Archive/proj/b.txt"),
            ]),
            dir("/root/Work/proj", [file("/root/Work/proj/a.txt"), file("/root/Work/proj/b.txt")]),
        ]
        let hashes = [
            "/root/Archive/proj/a.txt": "A", "/root/Work/proj/a.txt": "A",
            "/root/Archive/proj/b.txt": "B", "/root/Work/proj/b.txt": "B",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.isEmpty)   // the files themselves are still duplicates
        #expect(groups.allSatisfy { !$0.isDirectory })
        #expect(groups.allSatisfy { !$0.recommendedRemovalPaths.contains("/root/Archive/proj") })
        // The file level, stated rather than implied: both file groups still recommend the
        // repository's own tracked copy.
        let removals = Set(groups.flatMap(\.recommendedRemovalPaths))
        #expect(removals == ["/root/Archive/proj/a.txt", "/root/Archive/proj/b.txt"],
                "removals: \(removals.sorted())")
    }

    /// The same pair, but the repository is the one a same-name OVERLAP group would fold away:
    /// the ZIP side has one extra file, so the two are not identical even before `.git`.
    @Test func aRepositoryIsNeverFoldedAwayAsAnOverlappingCopy() {
        let tree = [
            dir("/root/Archive/proj", [
                dir("/root/Archive/proj/.git", [file("/root/Archive/proj/.git/HEAD", size: 23)]),
                file("/root/Archive/proj/a.txt"), file("/root/Archive/proj/b.txt"),
                file("/root/Archive/proj/c.txt"),
            ]),
            dir("/root/Work/proj", [file("/root/Work/proj/a.txt"), file("/root/Work/proj/b.txt"),
                                    file("/root/Work/proj/c.txt"), file("/root/Work/proj/d.txt")]),
        ]
        let hashes = [
            "/root/Archive/proj/a.txt": "A", "/root/Work/proj/a.txt": "A",
            "/root/Archive/proj/b.txt": "B", "/root/Work/proj/b.txt": "B",
            "/root/Archive/proj/c.txt": "C", "/root/Work/proj/c.txt": "C",
            "/root/Work/proj/d.txt": "D",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.allSatisfy { !$0.isDirectory })
        #expect(groups.allSatisfy { !$0.recommendedRemovalPaths.contains("/root/Archive/proj") })
    }

    /// OS noise is still noise: a `.DS_Store` on one side only does not stop two folders being
    /// the identical copies they are.
    @Test func finderDroppingsDoNotBlockAnIdenticalFolder() {
        let tree = [
            dir("/root/A", [file("/root/A/.DS_Store", size: 6148), file("/root/A/keep.txt")]),
            dir("/root/B", [file("/root/B/keep.txt")]),
        ]
        let hashes = ["/root/A/keep.txt": "KEEP", "/root/B/keep.txt": "KEEP",
                      "/root/A/.DS_Store": "DS"]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups.first?.isDirectory == true)
    }

    /// One Apply recommended acts on every group at once, so no group may recommend
    /// removing the folder that holds another group's keeper. `Pics`, `P/Sub` and `Q/Sub` are
    /// identical, and `P` and `Q` hold nothing but `Sub` — so `P` and `Q` are identical too. The
    /// dates make the first group keep `P/Sub` and, left alone, the second keep `Q`.
    @Test func noGroupRemovesTheFolderHoldingAnotherGroupsKeeper() {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        func sub(_ base: String, modified: Date) -> FileNode {
            dir(base, [file(base + "/a.jpg"), file(base + "/b.jpg")], modified: modified)
        }
        let tree = [
            dir("/root/Downloads", [sub("/root/Downloads/Pics", modified: new)]),
            dir("/root/Work", [
                dir("/root/Work/A", [dir("/root/Work/A/P", [sub("/root/Work/A/P/Sub", modified: new)], modified: old)]),
                dir("/root/Work/B", [dir("/root/Work/B/Q", [sub("/root/Work/B/Q/Sub", modified: old)], modified: new)]),
            ]),
        ]
        var hashes: [String: String] = [:]
        for base in ["/root/Downloads/Pics", "/root/Work/A/P/Sub", "/root/Work/B/Q/Sub"] {
            hashes[base + "/a.jpg"] = "A"; hashes[base + "/b.jpg"] = "B"
        }
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        let removed = groups.flatMap(\.recommendedRemovalPaths)
        // The premise: the first group did keep `P/Sub`, so the fixture reaches the hazard.
        #expect(groups.contains { $0.keeper.path == "/root/Work/A/P/Sub" })
        let copies = ["/root/Downloads/Pics", "/root/Work/A/P/Sub", "/root/Work/B/Q/Sub"]
        let survivors = copies.filter { copy in
            !removed.contains { copy == $0 || copy.hasPrefix($0 + "/") }
        }
        #expect(!survivors.isEmpty, "every copy is on the batch's removal list: \(removed.sorted())")
        // A folder holding a kept folder is never a copy to remove, even after a keeper re-pick.
        let holder = groups.flatMap(\.copies).first { $0.path == "/root/Work/A/P" }
        #expect(holder == nil || holder?.isProtectedFromRemoval == true)
    }

    /// The mirror of the above: a later group must not hollow out a folder an earlier group
    /// keeps. `X` and `Z` are identical and `X` is kept; `W/inner` matches `X/inner`, and is the
    /// newer of the two at the same depth, so left alone the inner group would trash `X/inner`.
    @Test func noGroupRemovesAPieceOfAnotherGroupsKeeper() {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        func inner(_ base: String, modified: Date) -> FileNode {
            dir(base + "/inner", [file(base + "/inner/a.jpg"), file(base + "/inner/b.jpg")], modified: modified)
        }
        let tree = [
            dir("/root/X", [inner("/root/X", modified: old), file("/root/X/e.txt")], modified: new),
            dir("/root/Z", [inner("/root/Z", modified: old), file("/root/Z/e.txt")], modified: old),
            // Same depth as `X/inner`, so the newer date — not depth — decides the keeper.
            dir("/root/W", [inner("/root/W", modified: new)]),
        ]
        var hashes: [String: String] = [:]
        for base in ["/root/X/inner", "/root/Z/inner", "/root/W/inner"] {
            hashes[base + "/a.jpg"] = "A"; hashes[base + "/b.jpg"] = "B"
        }
        hashes["/root/X/e.txt"] = "E"; hashes["/root/Z/e.txt"] = "E"
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.contains { $0.keeper.path == "/root/X" })
        let removed = groups.flatMap(\.recommendedRemovalPaths)
        #expect(!removed.contains("/root/X/inner"), "removal list: \(removed.sorted())")
    }

    // MARK: Packages (FR1)

    /// Two versions of a deck share their photo. The photo is part of each document, not a file
    /// beside it — trashing one copy breaks a deck — so no group ever names anything inside one.
    @Test func nothingInsideAPackageIsEverACandidate() {
        let tree = [
            dir("/root/Talks", [
                package("/root/Talks/v1.key", [file("/root/Talks/v1.key/Index.zip", size: 9000),
                                               dir("/root/Talks/v1.key/Data", [file("/root/Talks/v1.key/Data/photo.jpg")])]),
                package("/root/Talks/v2.key", [file("/root/Talks/v2.key/Index.zip", size: 9100),
                                               dir("/root/Talks/v2.key/Data", [file("/root/Talks/v2.key/Data/photo.jpg")])]),
            ]),
            dir("/root/Photos", [
                package("/root/Photos/Lib.photoslibrary", [dir("/root/Photos/Lib.photoslibrary/originals",
                    [file("/root/Photos/Lib.photoslibrary/originals/IMG_1.jpeg")])], kind: "com.apple.photos.library"),
                file("/root/Photos/IMG_1.jpeg"),
            ]),
        ]
        let hashes = [
            "/root/Talks/v1.key/Index.zip": "I1", "/root/Talks/v2.key/Index.zip": "I2",
            "/root/Talks/v1.key/Data/photo.jpg": "P", "/root/Talks/v2.key/Data/photo.jpg": "P",
            "/root/Photos/Lib.photoslibrary/originals/IMG_1.jpeg": "O", "/root/Photos/IMG_1.jpeg": "O",
        ]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        let named = groups.flatMap(\.copies).map(\.path)
        #expect(!named.contains { $0.contains(".key/") || $0.contains(".photoslibrary/") },
                "a group named a piece of a document: \(named.sorted())")
    }

    /// The whole document is still fair game: two byte-identical decks are a duplicate pair, and
    /// trashing one removes a complete document the other still holds.
    @Test func twoIdenticalPackagesAreOneGroup() {
        let tree = [
            dir("/root/A", [package("/root/A/Deck.key", [file("/root/A/Deck.key/Index.zip")]), file("/root/A/a.txt")]),
            dir("/root/B", [package("/root/B/Deck.key", [file("/root/B/Deck.key/Index.zip")]), file("/root/B/b.txt")]),
        ]
        let hashes = ["/root/A/Deck.key/Index.zip": "I", "/root/B/Deck.key/Index.zip": "I",
                      "/root/A/a.txt": "X", "/root/B/b.txt": "Y"]
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.count == 1)
        #expect(groups.first?.copies.map(\.path).sorted() == ["/root/A/Deck.key", "/root/B/Deck.key"])
    }

    /// Same-named folders that only overlap are merged file by file — and a merge through a
    /// package folds one document's insides into the other. Neither a package nor a folder
    /// holding one is ever the copy folded away.
    @Test func aFolderHoldingAPackageIsNeverFoldedAway() {
        // Seven shared documents of nine, so the pair clears the 0.7 overlap threshold — without
        // that, no group could form and this would pass with the guard removed.
        let shared = ["a", "b", "c", "d", "e", "f", "g"]
        func talks(_ base: String, extra: [String]) -> FileNode {
            dir(base, [package(base + "/Deck.key", [file(base + "/Deck.key/Index.zip")])]
                + (shared + extra).map { file(base + "/\($0).pdf") })
        }
        let tree = [talks("/root/Archive/Talks", extra: []),
                    talks("/root/Work/Talks", extra: ["h"])]
        var hashes = ["/root/Archive/Talks/Deck.key/Index.zip": "OLD",
                      "/root/Work/Talks/Deck.key/Index.zip": "NEW",
                      "/root/Work/Talks/h.pdf": "H"]
        for name in shared {
            hashes["/root/Archive/Talks/\(name).pdf"] = name.uppercased()
            hashes["/root/Work/Talks/\(name).pdf"] = name.uppercased()
        }
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(!groups.contains { if case .overlapping = $0.matchType { return true }; return false })
        #expect(groups.allSatisfy { !$0.recommendedRemovalPaths.contains("/root/Archive/Talks") })
    }

    /// A same-named copy holding a folder the walk did not read is never folded away: the merge
    /// would trash the unread folder as though it were empty.
    @Test func aCopyWithAnUnreadFolderIsNeverFoldedAway() {
        let shared = ["a", "b", "c", "d", "e", "f", "g"]
        var locked = dir("/root/Archive/Talks/Locked", [])
        locked.isUnexplored = true
        let tree = [
            dir("/root/Archive/Talks", [locked] + shared.map { file("/root/Archive/Talks/\($0).pdf") }),
            dir("/root/Work/Talks", (shared + ["h"]).map { file("/root/Work/Talks/\($0).pdf") }),
        ]
        var hashes = ["/root/Work/Talks/h.pdf": "H"]
        for name in shared {
            hashes["/root/Archive/Talks/\(name).pdf"] = name.uppercased()
            hashes["/root/Work/Talks/\(name).pdf"] = name.uppercased()
        }
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes)
        #expect(groups.allSatisfy { !$0.recommendedRemovalPaths.contains("/root/Archive/Talks") })
        #expect(!groups.contains { if case .overlapping = $0.matchType { return true }; return false })
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
        // The Settings toggle writes this key. Left out here, the switch could go inert with every
        // other test green, since fixtures start from the defaults.
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
        .stub(path, keeper: keeper, name: "x", size: 100, depth: depth)
    }

    /// A group with nothing flagged must not list its own keeper as redundant. `keeper` falls back
    /// to `copies[0]` when no copy carries the flag (`init` is public); filtering
    /// `redundantCopies` on the flag alone would include it, and that list drives "Move to Trash",
    /// so every copy would go, the survivor included. No production route builds such a group
    /// today; this keeps the two accessors in step for one that ever does.
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

    /// The ordinary case: a well-formed group removes exactly its unflagged copies.
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
        let g = DuplicateGroup.stub([Self.copy("/a/x", keeper: true), Self.copy("/b/x", keeper: false)])

        let g2 = g.choosingKeeper("/b/x")
        #expect(g2.keeper.id == "/b/x")
        #expect(g2.recommendedRemovalPaths == ["/a/x"])   // the other copy now gets trashed
        #expect(g2.reclaimableBytes == 100)
        #expect(g2.id == g.id)                            // list/expansion identity preserved
    }

    @Test func choosingKeeperIsNoOpForOverlapping() {
        let g = DuplicateGroup.stub(
            [.stub("/a", keeper: true, name: "Inv", isDirectory: true, size: 100, itemCount: 5),
             .stub("/b", keeper: false, name: "Inv", isDirectory: true, size: 90, itemCount: 4, unique: 1, depth: 1)],
            matchType: .overlapping(sharedFraction: 0.9), reclaimable: 80)
        #expect(g.allowsKeeperChoice == false)
        #expect(g.choosingKeeper("/b").keeper.id == "/a")   // unchanged — overlap needs hashes
    }

    @Test func batchEligibilityByMatchType() {
        func g(_ t: DuplicateMatchType) -> DuplicateGroup {
            .stub([.stub("/a", keeper: true, name: "a", size: 1), .stub("/b", keeper: false, name: "a", size: 1)],
                  matchType: t)
        }
        // Per-group removable: identical + versions. Blind batch: identical ONLY.
        #expect(g(.identical).isFullyResolvableByRemoval && g(.identical).isRecommendedForBatch)
        #expect(g(.versions).isFullyResolvableByRemoval && !g(.versions).isRecommendedForBatch)
        #expect(!g(.overlapping(sharedFraction: 0.9)).isFullyResolvableByRemoval)
        #expect(!g(.overlapping(sharedFraction: 0.9)).isRecommendedForBatch)
    }

    private func copy(_ id: String, size: Int, depth: Int, keeper: Bool, unique: Int = 0,
                      protected: Bool = false) -> DuplicateCopy {
        .stub(id, keeper: keeper, isDirectory: true, size: size, unique: unique, depth: depth, protected: protected)
    }

    // MARK: Reclaimable bytes must match what removal will actually take

    /// The reclaim figure skips protected copies, as `recommendedRemovalPaths` does. Re-aiming the
    /// keeper is what puts a protected copy on the redundant side, and the card must not promise
    /// bytes back from a file its own "Move to Trash" never touches.
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

    /// The control for both of the above: an unprotected copy in the same position still counts,
    /// so a reclaim that is always zero fails.
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
        // The keeper is the real newest; protection only takes protected files off the removable
        // side. Choosing the newest of the protected subset would break the card's "Keep newest,
        // Trash older": an older file in the kept folder would win and the real newest go to the
        // Trash.
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
        // The identical pass marks everything it accounted for, protected copies included, so the
        // versions pass skips it. Marking only the copies that survive protection would let a
        // dropped protected file resurface in a versions group.
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
        // The invariant must outlive the default keeper: `choosingKeeper` relabels copies by id, so
        // without the protected flag one click on the other copy would put the kept folder's own
        // file back on the removal list.
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
