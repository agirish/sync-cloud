import Foundation
import Testing
@testable import Sync

/// Round-5 fix: a permission-denied directory must scan as UNEXPLORED, never as empty.
/// Before, both listing attempts were try?-swallowed into a plain empty node (warm/tree branch)
/// or a silently skipped subtree (cold/disk branch, nil enumerator errorHandler), so the diff
/// minted phantom actionable "Missing" rows for contents nobody could read — and accepting one
/// would copy into (or "restore" from) a locked folder.
@Suite struct PermissionDeniedScanTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PermTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// chmod 000 is a no-op for root (it can read anything), so these fixtures prove nothing there.
    private var runningAsRoot: Bool { geteuid() == 0 }

    // MARK: Tree walk (warm branch)

    @Test func buildTreeMarksAPermissionDeniedDirectoryUnexplored() async throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        let locked = base.appendingPathComponent("locked")
        try write(locked.appendingPathComponent("secret.txt"), text: "hidden")
        try write(base.appendingPathComponent("open.txt"), text: "visible")
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let tree = await FileSyncManager.buildTree(url: base, sortOption: .name, maxDepth: nil)

        let lockedNode = try #require(tree.first { $0.name == "locked" })
        #expect(lockedNode.isDirectory)
        #expect(lockedNode.isUnexplored == true,
                "an unlistable directory must not masquerade as a genuinely empty one")
        #expect(lockedNode.children?.isEmpty == true)
        // The readable sibling is untouched.
        #expect(tree.contains { $0.name == "open.txt" })
    }

    // MARK: Disk walk (cold branch)

    @Test func getFilesInDirectoryMarksAPermissionDeniedDirectoryUnexplored() throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        let locked = base.appendingPathComponent("locked")
        try write(locked.appendingPathComponent("secret.txt"), text: "hidden")
        try write(base.appendingPathComponent("open.txt"), text: "visible")
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let info = try FileDiffEngine.getFilesInDirectory(base)

        let lockedInfo = try #require(info["locked"])
        #expect(lockedInfo.isDirectory)
        #expect(lockedInfo.isUnexplored, "the enumerator's errorHandler must record the denied descent")
        #expect(info["locked/secret.txt"] == nil)         // contents were unreadable
        #expect(info["open.txt"]?.isUnexplored == false)  // readable entries unaffected
    }

    // MARK: Diff level — no phantom Missing rows in either direction

    @Test func unreadableDirectoryOnOneSideProducesNoMissingRowsForItsContents() throws {
        guard !runningAsRoot else { return }
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        // Same directory on both sides; the RIGHT one is unreadable, the LEFT one has content.
        try write(leftBase.appendingPathComponent("shared/doc.txt"), text: "content")
        try write(leftBase.appendingPathComponent("shared/sub/deep.txt"), text: "content")
        try write(leftBase.appendingPathComponent("really-missing.txt"), text: "content")
        let rightLocked = rightBase.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: rightLocked, withIntermediateDirectories: true)
        try chmod(rightLocked, 0o000)
        defer {
            try? chmod(rightLocked, 0o755)
            try? FileManager.default.removeItem(at: leftBase)
            try? FileManager.default.removeItem(at: rightBase)
        }

        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: leftBase.path, type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: rightBase.path, type: .iCloud)
        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: leftBase,
            right: right, rightURL: rightBase,
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(leftBase),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(rightBase),
            caseInsensitive: true)

        // Nothing under the unreadable directory may surface as an actionable Missing row —
        // the right side's view of "shared" is unknown, not empty.
        #expect(!diffs.contains { $0.relativePath.hasPrefix("shared/") },
                "phantom rows: \(diffs.map(\.relativePath))")
        #expect(!diffs.contains { $0.relativePath == "shared" })
        // A genuinely one-sided file elsewhere still reports normally.
        #expect(diffs.contains { $0.relativePath == "really-missing.txt" && $0.type == .missingOnRight })
    }

    @Test func unreadableDirectoryOnTheLeftSuppressesMissingOnLeftRowsToo() throws {
        guard !runningAsRoot else { return }
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(rightBase.appendingPathComponent("shared/doc.txt"), text: "content")
        let leftLocked = leftBase.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: leftLocked, withIntermediateDirectories: true)
        try chmod(leftLocked, 0o000)
        defer {
            try? chmod(leftLocked, 0o755)
            try? FileManager.default.removeItem(at: leftBase)
            try? FileManager.default.removeItem(at: rightBase)
        }

        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: leftBase.path, type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: rightBase.path, type: .iCloud)
        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: leftBase,
            right: right, rightURL: rightBase,
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(leftBase),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(rightBase),
            caseInsensitive: true)

        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    // MARK: Warm/cold agreement

    @Test func warmTreeBranchSuppressesTheSamePhantomRows() {
        // The warm (cached-tree) branch feeds computeDifferences via filesInfo(fromTree:); an
        // isUnexplored node must carry the marker into the map and suppress the same rows the
        // cold branch now suppresses — the two branches must give one answer.
        let leftNodes = [
            FileNode(id: "/L/shared", name: "shared", isDirectory: true, children: [
                FileNode(id: "/L/shared/doc.txt", name: "doc.txt", isDirectory: false, fileSize: 100),
            ]),
        ]
        let rightNodes = [
            FileNode(id: "/R/shared", name: "shared", isDirectory: true, children: [],
                     isUnexplored: true),
        ]
        let leftInfo = FileDiffEngine.filesInfo(fromTree: leftNodes, basePath: "/L")
        let rightInfo = FileDiffEngine.filesInfo(fromTree: rightNodes, basePath: "/R")
        #expect(rightInfo["shared"]?.isUnexplored == true)

        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: "/L", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: "/R", type: .iCloud)
        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"),
            right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo)

        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }
}
