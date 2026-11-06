import Testing
import Foundation
@testable import Sync

/// A folder reached twice under one walk root is counted once. iCloud Drive's container holds
/// hidden `Desktop` and `Documents` symlinks back into `~`, and the walk substitutes the real
/// folders, which carry the real path and `isSymbolicLink == false`. Under a `~` scan the folder
/// appears twice with one id, which an `isSymbolicLink` check can't see: Storage over-reports by
/// its whole size and Duplicates offers to Trash `~/Documents` as a copy of itself. The guards ask
/// `FileNode.isCoveredElsewhere` instead.
@Suite struct CoveredElsewhereTests {

    static let home = "/H"
    static let doc = home + "/Documents/report.pdf"
    static let size = 5_000_000

    /// `~/Documents` present twice: directly, and substituted inside the container. Both copies
    /// carry the real ids; only the second is marked.
    static func doubledTree(marked: Bool) -> [FileNode] {
        func documents() -> FileNode {
            FileNode(id: home + "/Documents", name: "Documents", isDirectory: true,
                     children: [FileNode(id: doc, name: "report.pdf", isDirectory: false,
                                         modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                         fileSize: size, isSymbolicLink: false)],
                     isSymbolicLink: false)
        }
        var viaContainer = documents()
        if marked { viaContainer.isCoveredElsewhere = true }
        return [documents(),
                FileNode(id: home + "/Library", name: "Library", isDirectory: true, children: [
                    FileNode(id: home + "/Library/CloudDocs", name: "CloudDocs", isDirectory: true,
                             children: [viaContainer], isSymbolicLink: false)
                ], isSymbolicLink: false)]
    }

    // MARK: Storage

    /// Unmarked, the total doubles; marked, it is right. Asserted as a pair because a
    /// `collectLeaves` that skipped the container entirely would pass the second assertion while
    /// being wrong for a scan rooted at the container.
    @Test func storageCountsADoubleReachedFolderOnce() {
        let unmarked = StorageLensAnalyzer.analyze(tree: Self.doubledTree(marked: false), now: Date())
        #expect(unmarked.totalBytes == Self.size * 2,
                "premise: without the mark the total really does double — otherwise this test proves nothing")

        let marked = StorageLensAnalyzer.analyze(tree: Self.doubledTree(marked: true), now: Date())
        #expect(marked.totalBytes == Self.size,
                "Storage still counts the double-reached copy: \(marked.totalBytes) for one \(Self.size)-byte file")
    }

    /// The rolled-up size a treemap area draws must agree, and it is a separate code path.
    @Test func theRolledUpSizeSkipsItToo() {
        let library = Self.doubledTree(marked: true)[1]
        #expect(StorageLensAnalyzer.rolledUpBytes(library) == 0,
                "the container's branch still rolls up bytes that its shorter route already counted")
        #expect(StorageLensAnalyzer.rolledUpBytes(Self.doubledTree(marked: false)[1]) == Self.size,
                "premise: unmarked, that branch really does roll up the bytes")
    }

    // MARK: Duplicates

    /// The data-loss case: unmarked, the finder builds an `identical` group whose two copies are
    /// the same path and recommends trashing it, the user's real Documents folder.
    @Test func duplicatesDoesNotPairADoubleReachedFolderWithItself() {
        let hashes = [Self.doc: "hash-A"]
        let unmarked = DuplicateFinder.findGroups(tree: Self.doubledTree(marked: false), fileHashes: hashes)
        #expect(!unmarked.isEmpty, "premise: unmarked, the finder really does group it")
        #expect(unmarked.contains { Set($0.copies.map(\.path)).count < $0.copies.count },
                "premise: that group really does hold one path twice")

        let marked = DuplicateFinder.findGroups(tree: Self.doubledTree(marked: true), fileHashes: hashes)
        for group in marked {
            #expect(Set(group.copies.map(\.path)).count == group.copies.count,
                    "a group still holds the same path twice: \(group.copies.map(\.path))")
        }
        #expect(marked.allSatisfy { !$0.recommendedRemovalPaths.contains(Self.home + "/Documents") },
                "Duplicates still offers to Trash the real Documents folder")
    }
}
