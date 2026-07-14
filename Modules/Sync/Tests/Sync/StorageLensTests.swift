import Foundation
import Testing
@testable import Sync

@Suite struct StorageLensTests {

    // MARK: Builders

    private func file(_ path: String, size: Int = 8192, modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: modified, fileSize: size)
    }
    private func dir(_ path: String, _ children: [FileNode], isUnexplored: Bool? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, isUnexplored: isUnexplored)
    }

    /// A fixed clock so age-based lists are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: Folder rollup

    @Test func folderRollupSumsRecursively() {
        // A directory's size is the sum of every leaf file beneath it, at any depth. The
        // directory's own inode size is never counted (files carry all the bytes).
        let tree = [
            dir("/root/Photos", [
                file("/root/Photos/a.jpg", size: 1000),
                dir("/root/Photos/2023", [
                    file("/root/Photos/2023/b.jpg", size: 2000),
                    file("/root/Photos/2023/c.jpg", size: 3000),
                ]),
            ]),
        ]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        #expect(report.totalBytes == 6000)
        #expect(report.treemap.count == 1)
        #expect(report.treemap[0].name == "Photos")
        #expect(report.treemap[0].bytes == 6000)
        #expect(report.treemap[0].path == "/root/Photos")
    }

    @Test func unexploredSubtreeExcludedFromRollup() {
        // An unexplored directory's empty `children` is a walk artifact, not an observation — it
        // must contribute nothing to the rollup rather than a false zero *or* a guessed size.
        let tree = [
            dir("/root/Known", [file("/root/Known/x.bin", size: 5000)]),
            dir("/root/Capped", [], isUnexplored: true),   // children not walked
        ]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        #expect(report.totalBytes == 5000)
        // The unexplored (0-byte) folder is filtered out of the treemap entirely.
        #expect(report.treemap.count == 1)
        #expect(report.treemap[0].name == "Known")
        #expect(report.treemap[0].bytes == 5000)
    }

    @Test func unexploredNestedFilesDoNotCount() {
        // Files stranded under an unexplored ancestor are invisible to the leaf collector too.
        let tree = [
            dir("/root/A", [
                file("/root/A/real.dat", size: 100),
                dir("/root/A/Capped", [file("/root/A/Capped/ghost.dat", size: 9_999_999)], isUnexplored: true),
            ]),
        ]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        #expect(report.totalBytes == 100)
        #expect(report.largest.count == 1)
        #expect(report.largest[0].path == "/root/A/real.dat")
    }

    // MARK: Largest

    @Test func largestSortedDescAndCappedAtTopN() {
        var children: [FileNode] = []
        for i in 0..<30 {
            children.append(file("/root/f\(i).bin", size: (i + 1) * 1000))
        }
        let tree = [dir("/root", children)]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now, options: .init(topN: 20))
        #expect(report.largest.count == 20)                 // capped
        #expect(report.largest.first?.bytes == 30_000)      // biggest first
        #expect(report.largest.last?.bytes == 11_000)       // 20th biggest (30,29,...,11)
        // Strictly descending.
        for i in 1..<report.largest.count {
            #expect(report.largest[i - 1].bytes >= report.largest[i].bytes)
        }
    }

    @Test func largestSkipsZeroByteFiles() {
        let tree = [dir("/root", [
            file("/root/empty.txt", size: 0),
            file("/root/small.txt", size: 10),
        ])]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        #expect(report.largest.map(\.path) == ["/root/small.txt"])
    }

    // MARK: Stale

    @Test func staleFiltersByAgeUsingInjectedNow() {
        let tree = [dir("/root", [
            file("/root/fresh.txt", size: 100, modified: daysAgo(30)),     // recent — not stale
            file("/root/old.txt", size: 100, modified: daysAgo(400)),      // > 365 days — stale
            file("/root/ancient.txt", size: 100, modified: daysAgo(800)),  // stale, older still
            file("/root/undated.txt", size: 100, modified: nil),           // no date — excluded
        ])]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now, options: .init(staleThresholdDays: 365))
        // Oldest first, only the two dated files past the threshold.
        #expect(report.stale.map(\.path) == ["/root/ancient.txt", "/root/old.txt"])
    }

    @Test func staleCappedAtTopN() {
        var children: [FileNode] = []
        for i in 0..<25 {
            children.append(file("/root/old\(i).txt", size: 100, modified: daysAgo(500 + i)))
        }
        let tree = [dir("/root", children)]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now, options: .init(topN: 20))
        #expect(report.stale.count == 20)
    }

    // MARK: Reclaim candidates

    @Test func reclaimCandidatesRequireBothSizeAndStaleness() {
        let big = 200_000_000, small = 1_000
        let tree = [dir("/root", [
            file("/root/big-old.mov", size: big, modified: daysAgo(300)),      // big + stale → candidate
            file("/root/big-fresh.mov", size: big, modified: daysAgo(10)),     // big but recent → no
            file("/root/small-old.txt", size: small, modified: daysAgo(300)),  // stale but tiny → no
            file("/root/big-undated.mov", size: big, modified: nil),           // big but no date → no
        ])]
        let report = StorageLensAnalyzer.analyze(
            tree: tree, now: now,
            options: .init(reclaimStaleDays: 180, minReclaimBytes: 100_000_000)
        )
        #expect(report.reclaimCandidates.map(\.path) == ["/root/big-old.mov"])
    }

    @Test func reclaimCandidatesSortedByBytesDesc() {
        let tree = [dir("/root", [
            file("/root/a.mov", size: 150_000_000, modified: daysAgo(300)),
            file("/root/b.mov", size: 500_000_000, modified: daysAgo(300)),
            file("/root/c.mov", size: 300_000_000, modified: daysAgo(300)),
        ])]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        #expect(report.reclaimCandidates.map(\.path) == ["/root/b.mov", "/root/c.mov", "/root/a.mov"])
    }

    // MARK: Empty

    @Test func emptyTreeYieldsEmptyReport() {
        let report = StorageLensAnalyzer.analyze(tree: [], now: now)
        #expect(report.totalBytes == 0)
        #expect(report.treemap.isEmpty)
        #expect(report.largest.isEmpty)
        #expect(report.stale.isEmpty)
        #expect(report.reclaimCandidates.isEmpty)
    }

    // MARK: Treemap folding + loose files

    @Test func treemapFoldsBeyondBucketsIntoOther() {
        // Ten top-level folders of descending size; with 8 buckets the smallest two fold into "Other".
        var top: [FileNode] = []
        for i in 0..<10 {
            let size = (10 - i) * 1000   // folder0 = 10k … folder9 = 1k
            top.append(dir("/root/folder\(i)", [file("/root/folder\(i)/x.bin", size: size)]))
        }
        let report = StorageLensAnalyzer.analyze(tree: top, now: now, options: .init(treemapBuckets: 8))
        #expect(report.treemap.count == 9)                       // 8 kept + Other
        #expect(report.treemap.last?.name == "Other")
        #expect(report.treemap.last?.path == "")
        // Other = the two smallest folders (2k + 1k).
        #expect(report.treemap.last?.bytes == 3000)
        // The kept eight are the largest, in descending order (folder0=10k … folder7=3k).
        #expect(report.treemap[0].bytes == 10_000)
        #expect(report.treemap[7].bytes == 3000)
    }

    @Test func treemapBucketsLooseTopLevelFilesUnderFiles() {
        let tree: [FileNode] = [
            dir("/root/Docs", [file("/root/Docs/a.pdf", size: 4000)]),
            file("/root/loose1.txt", size: 1000),
            file("/root/loose2.txt", size: 2000),
        ]
        let report = StorageLensAnalyzer.analyze(tree: tree, now: now)
        // "Files" bucket aggregates the two loose top-level files (3000), under Docs (4000).
        #expect(report.treemap.map(\.name) == ["Docs", "Files"])
        #expect(report.treemap.first(where: { $0.name == "Files" })?.bytes == 3000)
        #expect(report.treemap.first(where: { $0.name == "Files" })?.path == "")
    }
}
