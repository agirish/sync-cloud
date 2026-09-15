import Testing
import Foundation
@testable import Sync

/// RD23: Merge as the answer to a folder collision. Real disk throughout — a merge's claims are
/// about what is left in two trees, and the mock's enumerator is not the one production lists with.
@Suite struct FolderMergeTests {

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Every entry under `root` that is not a folder, as relative paths.
    private func files(_ root: URL) -> [String] {
        (FileManager.default.subpaths(atPath: root.path) ?? []).filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    /// Records every prompt, answering folders with `folderAnswer` and each child by file name.
    @MainActor
    private final class Prompts {
        var top: [FileCollision] = []
        var children: [FileCollision] = []
    }

    @MainActor
    private func manager(prompts: Prompts, folderAnswer: CollisionResolution = .merge,
                         childAnswers: [String: (CollisionResolution, Bool)] = [:]) -> FileSyncManager {
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.collisionResolver = { collision in
            prompts.top.append(collision)
            return folderAnswer
        }
        m.bulkCollisionResolver = { collision in
            prompts.children.append(collision)
            let (answer, all) = childAnswers[collision.fileName] ?? (.skip, false)
            return (answer, all)
        }
        return m
    }

    /// src/Reports and dst/Reports overlapping on `a.txt` and `sub/c.txt`, each holding things the
    /// other does not, and a `.DS_Store` in both.
    private func fixture(_ root: URL) throws -> (src: URL, dst: URL) {
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try write("new a", src.appendingPathComponent("a.txt"))
        try write("new b", src.appendingPathComponent("b.txt"))
        try write("new c", src.appendingPathComponent("sub/c.txt"))
        try write("new d", src.appendingPathComponent("sub/deep/d.txt"))
        try write("src view", src.appendingPathComponent(".DS_Store"))
        try write("old a", dst.appendingPathComponent("a.txt"))
        try write("only here", dst.appendingPathComponent("only.txt"))
        try write("old c", dst.appendingPathComponent("sub/c.txt"))
        try write("keep me", dst.appendingPathComponent("sub/keep.txt"))
        try write("dst view", dst.appendingPathComponent(".DS_Store"))
        return (src, dst)
    }

    @MainActor
    @Test func aCopyMergeKeepsWhatWasThereAddsWhatWasNotAndAsksOnlyAboutFilesInBoth() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let (src, dst) = try fixture(root)
        let prompts = Prompts()
        let m = manager(prompts: prompts, childAnswers: ["a.txt": (.replace, false), "c.txt": (.skip, false)])
        let node = FileNode(id: src.path, name: "Reports", isDirectory: true)
        let transferred = await m.copyItems(nodes: [node], toPath: dst.deletingLastPathComponent().path)

        // The folder prompt offered Merge, with the counts its sentence needs: only.txt and
        // sub/keep.txt are only in the destination; a.txt and sub/c.txt are in both.
        let top = try #require(prompts.top.first)
        #expect(prompts.top.count == 1)
        #expect(top.offersMerge)
        #expect(top.mergePreview == FolderMergePreview(destinationOnlyCount: 2, collidingCount: 2))
        // Each file in both was asked about once, in name order; .DS_Store and the folders never were.
        #expect(prompts.children.map(\.fileName) == ["a.txt", "c.txt"])
        #expect(prompts.children.allSatisfy { !$0.offersMerge && !$0.isDirectory })

        #expect(transferred.map(\.id) == [src.path])
        // `.DS_Store` is left out of the listings: Trashing the replaced a.txt's backup makes macOS
        // drop the folder's `.DS_Store` — measured 2026-09-15 with `trashItem` alone, so every
        // Replace has always done it. What matters here is that the source's never landed over it.
        #expect(files(dst).filter { $0 != ".DS_Store" } == ["a.txt", "b.txt", "only.txt", "sub/c.txt", "sub/deep/d.txt", "sub/keep.txt"])
        #expect(read(dst.appendingPathComponent("a.txt")) == "new a")          // Replace
        #expect(read(dst.appendingPathComponent("sub/c.txt")) == "old c")      // Skip
        #expect(read(dst.appendingPathComponent("only.txt")) == "only here")   // kept
        #expect(read(dst.appendingPathComponent(".DS_Store")) != "src view")   // never copied over
        #expect(read(dst.appendingPathComponent("sub/deep/d.txt")) == "new d")  // a missing folder lands whole
        #expect(files(src).count == 5)                                          // a copy leaves the source alone
        #expect(m.currentError == nil)

        // One ⌘Z takes the merge back: what it added goes, what it replaced returns, and what was
        // only ever in the destination is untouched.
        m.undoManager?.undo()
        await waitUntil("merge undo drains") {
            m.activeFileOperationsCount == 0 && !FileManager.default.fileExists(atPath: dst.appendingPathComponent("b.txt").path)
        }
        await waitUntil("replaced file restored") { self.read(dst.appendingPathComponent("a.txt")) == "old a" }
        #expect(files(dst).filter { $0 != ".DS_Store" } == ["a.txt", "only.txt", "sub/c.txt", "sub/keep.txt"])
    }

    @MainActor
    @Test func applyToAllCoversTheRestOfOneMergeAndNoMore() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-apply-all")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        for folder in ["One", "Two"] {
            for name in ["x.txt", "y.txt", "z.txt"] {
                try write("new", src.appendingPathComponent("\(folder)/\(name)"))
                try write("old", dst.appendingPathComponent("\(folder)/\(name)"))
            }
        }
        let prompts = Prompts()
        let m = manager(prompts: prompts, childAnswers: ["x.txt": (.keepBoth, true)])

        let nodes = ["One", "Two"].map { FileNode(id: src.appendingPathComponent($0).path, name: $0, isDirectory: true) }
        _ = await m.copyItems(nodes: nodes, toPath: dst.path)

        // Asked once per merge: x.txt's "keep both, apply to all" answered y and z of the same
        // folder, and the second folder's merge asked afresh.
        #expect(prompts.top.count == 2)
        #expect(prompts.children.map(\.fileName) == ["x.txt", "x.txt"])
        #expect(files(dst.appendingPathComponent("One")) == ["x 2.txt", "x.txt", "y 2.txt", "y.txt", "z 2.txt", "z.txt"])
    }

    @MainActor
    @Test func aChildThatIsAFileOnOneSideAndAFolderOnTheOtherIsAskedAndNeverAnsweredByApplyToAll() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-type-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/F")
        let dst = root.appendingPathComponent("dst/F")
        try write("new", src.appendingPathComponent("a.txt"))
        try write("file", src.appendingPathComponent("b"))
        try write("old", dst.appendingPathComponent("a.txt"))
        try write("inside", dst.appendingPathComponent("b/inside.txt"))
        let prompts = Prompts()
        let m = manager(prompts: prompts, childAnswers: ["a.txt": (.replace, true)])

        _ = await m.copyItems(nodes: [FileNode(id: src.path, name: "F", isDirectory: true)], toPath: dst.deletingLastPathComponent().path)

        #expect(prompts.children.map(\.fileName) == ["a.txt", "b"])
        #expect(prompts.children.last?.isDirectory == true)
        // "b" was skipped (the default answer), not replaced by the file-level apply-to-all.
        #expect(read(dst.appendingPathComponent("b/inside.txt")) == "inside")
        #expect(read(dst.appendingPathComponent("a.txt")) == "new")
    }

    @MainActor
    @Test func aMoveMergeTrashesTheEmptiedSourceAndKeepsOneThatStillHoldsASkippedItem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let (src, dst) = try fixture(root)
        let prompts = Prompts()
        let m = manager(prompts: prompts, childAnswers: ["a.txt": (.replace, false), "c.txt": (.replace, false)])

        let moved = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)], toPath: dst.deletingLastPathComponent().path)

        #expect(moved.map(\.id) == [src.path])
        #expect(read(dst.appendingPathComponent("sub/c.txt")) == "new c")
        #expect(read(dst.appendingPathComponent("sub/keep.txt")) == "keep me")
        // Everything left the source except its .DS_Store, so the source folder went to the Trash.
        #expect(!FileManager.default.fileExists(atPath: src.path))

        // One ⌘Z puts every moved child back where it came from, the emptied source folder included.
        m.undoManager?.undo()
        await waitUntil("move-merge undo puts the children back") {
            m.activeFileOperationsCount == 0 && self.read(src.appendingPathComponent("sub/deep/d.txt")) == "new d"
        }
        #expect(read(src.appendingPathComponent("b.txt")) == "new b")
        #expect(read(src.appendingPathComponent("sub/c.txt")) == "new c")
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("b.txt").path))
        await waitUntil("replaced destination file restored") { self.read(dst.appendingPathComponent("sub/c.txt")) == "old c" }
        #expect(read(dst.appendingPathComponent("sub/keep.txt")) == "keep me")

        // Same again with a skip: the skipped file keeps its folder where it was.
        let root2 = try makeCanonicalTempRoot(prefix: "folder-merge-move-skip")
        defer { try? FileManager.default.removeItem(at: root2) }
        let (src2, dst2) = try fixture(root2)
        let m2 = manager(prompts: Prompts(), childAnswers: ["a.txt": (.replace, false), "c.txt": (.skip, false)])
        _ = await m2.moveItems(nodes: [FileNode(id: src2.path, name: "Reports", isDirectory: true)], toPath: dst2.deletingLastPathComponent().path)
        #expect(files(src2) == [".DS_Store", "sub/c.txt"])
        #expect(read(dst2.appendingPathComponent("sub/deep/d.txt")) == "new d")
        #expect(read(dst2.appendingPathComponent("sub/c.txt")) == "old c")
    }

    @MainActor
    @Test func mergeIsNotOfferedThroughASymlinkOrForAFileOntoAFolder() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-not-offered")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try write("new", src.appendingPathComponent("Linked/a.txt"))
        try write("outside the tree", elsewhere.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dst.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        try write("file", src.appendingPathComponent("Plain"))
        try write("inside", dst.appendingPathComponent("Plain/inside.txt"))
        let prompts = Prompts()
        // Answer Merge even where it is not offered: it must be read as Skip.
        let m = manager(prompts: prompts, folderAnswer: .merge)

        _ = await m.copyItems(nodes: [FileNode(id: src.appendingPathComponent("Linked").path, name: "Linked", isDirectory: true),
                                      FileNode(id: src.appendingPathComponent("Plain").path, name: "Plain", isDirectory: false)],
                              toPath: dst.path)

        #expect(prompts.top.count == 2)
        #expect(prompts.top.allSatisfy { !$0.offersMerge && $0.mergePreview == nil })
        #expect(prompts.children.isEmpty)
        #expect(read(elsewhere.appendingPathComponent("a.txt")) == "outside the tree")
        #expect(read(dst.appendingPathComponent("Plain/inside.txt")) == "inside")
    }

    /// A package is a document, not a folder: two `.rtfd` bundles collide as one item, at the top
    /// and inside a merge, and are never merged child by child into a bundle neither app wrote.
    @MainActor
    @Test func aPackageIsNeverMergedAtTheTopOrInsideAMerge() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-package")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        for side in [(src, "new"), (dst, "old")] {
            try write(side.1, side.0.appendingPathComponent("Note.rtfd/TXT.rtf"))
            try write(side.1, side.0.appendingPathComponent("Folder/Inner.rtfd/TXT.rtf"))
        }
        try write("new only", src.appendingPathComponent("Note.rtfd/Pasted.png"))
        let isPackage = try URL(fileURLWithPath: src.appendingPathComponent("Note.rtfd").path).resourceValues(forKeys: [.isPackageKey]).isPackage
        try #require(isPackage == true, "the fixture must be a package for this test to mean anything")
        let prompts = Prompts()
        let m = manager(prompts: prompts, folderAnswer: .merge)

        _ = await m.copyItems(nodes: [FileNode(id: src.appendingPathComponent("Note.rtfd").path, name: "Note.rtfd", isDirectory: true),
                                      FileNode(id: src.appendingPathComponent("Folder").path, name: "Folder", isDirectory: true)],
                              toPath: dst.path)

        // The top-level package collision offered no merge; the plain folder did.
        #expect(Dictionary(uniqueKeysWithValues: prompts.top.map { ($0.fileName, $0.offersMerge) }) == ["Note.rtfd": false, "Folder": true])
        // Inside the merge, the nested package was asked about as a whole, as a folder collision.
        #expect(prompts.children.map(\.fileName) == ["Inner.rtfd"])
        #expect(prompts.children.first?.isDirectory == true)
        // Nothing was written into either package (the answers were Skip).
        #expect(files(dst.appendingPathComponent("Note.rtfd")) == ["TXT.rtf"])
        #expect(read(dst.appendingPathComponent("Folder/Inner.rtfd/TXT.rtf")) == "old")
        // And the preview counts a package as one item, not its insides.
        #expect(FileSyncManager.folderMergePreview(source: src.appendingPathComponent("Folder"), destination: dst.appendingPathComponent("Folder"), fileManager: FileManager.default)
                == FolderMergePreview(destinationOnlyCount: 0, collidingCount: 1))
    }

    /// Cancel pressed while a merge is asking about its children stops the merge there.
    @MainActor
    @Test func cancelDuringAMergeStopsTheRemainingChildren() async throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/F")
        let dst = root.appendingPathComponent("dst/F")
        try write("new", src.appendingPathComponent("a.txt"))
        try write("new", src.appendingPathComponent("b.txt"))
        try write("new", src.appendingPathComponent("c.txt"))
        try write("old", dst.appendingPathComponent("a.txt"))
        let m = manager(prompts: Prompts())
        m.bulkCollisionResolver = { [m] _ in
            m.activeProgress?.cancel()
            return (.replace, false)
        }

        _ = await m.copyItems(nodes: [FileNode(id: src.path, name: "F", isDirectory: true)], toPath: dst.deletingLastPathComponent().path)

        // a.txt's prompt pressed Cancel; the answer still stands for a.txt, nothing after it lands.
        #expect(read(dst.appendingPathComponent("b.txt")) == nil)
        #expect(read(dst.appendingPathComponent("c.txt")) == nil)
        #expect(m.currentError == nil)
    }

    @Test func thePreviewGivesUpRatherThanCountingPartOfATree() throws {
        let root = try makeCanonicalTempRoot(prefix: "folder-merge-preview-bound")
        defer { try? FileManager.default.removeItem(at: root) }
        let (src, dst) = try fixture(root)
        let fm = FileManager.default
        #expect(FileSyncManager.folderMergePreview(source: src, destination: dst, fileManager: fm)
                == FolderMergePreview(destinationOnlyCount: 2, collidingCount: 2))
        #expect(FileSyncManager.folderMergePreview(source: src, destination: dst, fileManager: fm, entryLimit: 4) == nil)
        #expect(FileSyncManager.folderMergePreview(source: src, destination: dst, fileManager: fm, timeLimit: -1) == nil)
    }
}
