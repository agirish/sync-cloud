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
        try makeCanonicalTempRoot(prefix: "PermTest")
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

    @Test func unreadableDirectoryWithCaseVariantNameStillSuppressesMissingRows() throws {
        guard !runningAsRoot else { return }
        // The pairing matches ancestors across case variants, so the suppression must too:
        // left readable "Shared" with content, right UNREADABLE "shared". The unexplored set
        // holds the right-side spelling; an exact-string ancestor lookup missed it and minted
        // actionable Missing rows into a folder nobody can read.
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(leftBase.appendingPathComponent("Shared/doc.txt"), text: "content")
        try write(leftBase.appendingPathComponent("Shared/sub/deep.txt"), text: "content")
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

        #expect(!diffs.contains { $0.relativePath.hasPrefix("Shared/") },
                "phantom rows under a case-variant unreadable folder: \(diffs.map(\.relativePath))")
        #expect(diffs.contains { $0.relativePath == "really-missing.txt" && $0.type == .missingOnRight })
    }

    @Test func unreadableDirectoryWithNearNameVariantStillSuppressesMissingRows() throws {
        guard !runningAsRoot else { return }
        // Near-name shape of the same hole: right's unreadable folder is "shared " (trailing
        // space). The near-name machinery pairs the two dirs — and then REMAPPED the phantom
        // child rows to target paths inside the unreadable variant.
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(leftBase.appendingPathComponent("shared/doc.txt"), text: "content")
        let rightLocked = rightBase.appendingPathComponent("shared ")
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

        #expect(!diffs.contains { $0.relativePath.hasPrefix("shared/") },
                "phantom rows under a near-name unreadable folder: \(diffs.map(\.relativePath))")
    }

    @Test func readableExactFolderBesideAnUnreadableVariantStillReportsItsMissing() throws {
        guard !runningAsRoot else { return }
        // Negative control for the folded suppression: the right side has BOTH a readable
        // exact-spelling "shared" (empty) and an unreadable "shared " variant. The missing row
        // for left's shared/doc.txt targets the READABLE folder and must survive — folding
        // may only suppress when no exact-spelling entry owns the ancestor.
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(leftBase.appendingPathComponent("shared/doc.txt"), text: "content")
        try FileManager.default.createDirectory(
            at: rightBase.appendingPathComponent("shared"), withIntermediateDirectories: true)
        let rightLocked = rightBase.appendingPathComponent("shared ")
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

        #expect(diffs.contains { $0.relativePath == "shared/doc.txt" && $0.type == .missingOnRight },
                "the legit row into the readable exact folder was over-suppressed: \(diffs.map(\.relativePath))")
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

    // MARK: Scan ROOT denied (the round-5 fix covered subdirectories only)

    @Test func buildTreeReturnsTheRootMarkedUnexploredWhenTheRootItselfIsDenied() async throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        try write(base.appendingPathComponent("secret.txt"), text: "hidden")
        try chmod(base, 0o000)
        defer {
            try? chmod(base, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let tree = await FileSyncManager.buildTree(url: base, sortOption: .name, maxDepth: nil)

        // Never a bare [] — that read as an authoritatively EMPTY root downstream. The root
        // itself comes back as a single unexplored node, same shape as any capped directory.
        let rootNode = try #require(tree.first)
        #expect(tree.count == 1)
        #expect(rootNode.id == base.path)
        #expect(rootNode.isDirectory)
        #expect(rootNode.isUnexplored == true)
        #expect(rootNode.children?.isEmpty == true)
    }

    @Test func getFilesInDirectoryRecordsARootLevelFailureWhenTheRootIsDenied() throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        try write(base.appendingPathComponent("secret.txt"), text: "hidden")
        try chmod(base, 0o000)
        defer {
            try? chmod(base, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let info = try FileDiffEngine.getFilesInDirectory(base)

        // The root has no parent listing to have minted an entry; the failure is recorded
        // under the root key ("") so the diff knows the WHOLE side is unknown, not empty.
        let rootInfo = try #require(info[""])
        #expect(rootInfo.isDirectory)
        #expect(rootInfo.isUnexplored)
        #expect(info["secret.txt"] == nil)   // contents were unreadable
    }

    @Test func unreadableRootOnOneSideProducesNoMissingRowsAtAll() throws {
        guard !runningAsRoot else { return }
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(leftBase.appendingPathComponent("doc.txt"), text: "content")
        try write(leftBase.appendingPathComponent("sub/deep.txt"), text: "content")
        try chmod(rightBase, 0o000)
        defer {
            try? chmod(rightBase, 0o755)
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

        // The right side's ENTIRE view is unknown — nothing may surface as actionable Missing.
        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    @Test func unreadableRootOnTheLeftSuppressesMissingOnLeftRowsToo() throws {
        guard !runningAsRoot else { return }
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        try write(rightBase.appendingPathComponent("doc.txt"), text: "content")
        try chmod(leftBase, 0o000)
        defer {
            try? chmod(leftBase, 0o755)
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

    @Test func warmTreeBranchSuppressesRootLevelPhantomRowsToo() {
        // The warm branch's root marker: buildTree hands back [root node, unexplored] when the
        // root listing failed; filesInfo(fromTree:) must turn that into the root-key ("")
        // record, and computeDifferences must suppress the whole side on it — matching the
        // cold branch's answer for the same denied root.
        let leftNodes = [
            FileNode(id: "/L/doc.txt", name: "doc.txt", isDirectory: false, fileSize: 100),
        ]
        let rightNodes = [
            FileNode(id: "/R", name: "R", isDirectory: true, children: [], isUnexplored: true),
        ]
        let leftInfo = FileDiffEngine.filesInfo(fromTree: leftNodes, basePath: "/L")
        let rightInfo = FileDiffEngine.filesInfo(fromTree: rightNodes, basePath: "/R")
        #expect(rightInfo[""]?.isUnexplored == true)

        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: "/L", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: "/R", type: .iCloud)
        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"),
            right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo)

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

    // MARK: Name scan (Rename lens)

    /// Round-7 fix: the denied-root marker node must never become a rename candidate. Before,
    /// the marker flowed into `NameNormalizer.scan`'s flatten (which emits every node), so a
    /// risky-named unreadable root appeared in the Rename lens — and "Fix all" would rename a
    /// folder we can't even list (a rename only needs parent-write), dangling the pane focus.
    @MainActor
    @Test func nameScanOfAPermissionDeniedRootYieldsNoCandidates() async throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        // The root's own name is cloud-risky (trailing space) — exactly the shape that would
        // have been flagged and batch-renamed before the fix.
        let lockedRoot = base.appendingPathComponent("Locked ")
        try write(lockedRoot.appendingPathComponent("secret.txt"), text: "hidden")
        try chmod(lockedRoot, 0o000)
        defer {
            try? chmod(lockedRoot, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = FileSyncManager()
        await manager.scanNames(root: lockedRoot, provider: .dropBox)

        #expect(manager.riskyNames.isEmpty,
                "an unreadable root must not offer itself for renaming: \(manager.riskyNames.map(\.currentName))")
        // The scan still completes honestly (root labels the empty result, no stale prior state).
        #expect(manager.nameScanLifecycle.hasCompleted)
    }
}
