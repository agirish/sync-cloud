import Foundation
import Testing
@testable import Sync

/// A permission-denied directory must scan as unexplored, never as empty, on both the warm (tree)
/// and cold (disk) branches. Read as empty, the diff would mint actionable "Missing" rows for
/// contents nobody can read, and accepting one would copy into, or "restore" from, a locked folder.
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

    /// The cold diff, case-insensitive, of two temp roots: `left` and `right` are files to write,
    /// `rightDirs` empty folders on the right, and `locked` the folder chmodded to 000 on one side
    /// (`""` for that side's root). Permissions are restored and both roots removed before it
    /// returns.
    private func lockedDiff(left leftFiles: [String] = [], right rightFiles: [String] = [],
                            rightDirs: [String] = [], locked: (onLeft: Bool, path: String)) throws -> [FileDifference] {
        let leftBase = try makeTempDir()
        let rightBase = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: leftBase)
            try? FileManager.default.removeItem(at: rightBase)
        }
        for path in leftFiles { try write(leftBase.appendingPathComponent(path), text: "content") }
        for path in rightFiles { try write(rightBase.appendingPathComponent(path), text: "content") }
        for path in rightDirs {
            try FileManager.default.createDirectory(at: rightBase.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        let side = locked.onLeft ? leftBase : rightBase
        let lockedURL = locked.path.isEmpty ? side : side.appendingPathComponent(locked.path)
        if !locked.path.isEmpty {
            try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        }
        try chmod(lockedURL, 0o000)
        defer { try? chmod(lockedURL, 0o755) }   // before the removal above: defers run last-first
        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", rootPath: leftBase.path, type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", rootPath: rightBase.path, type: .iCloud)
        return FileDiffEngine.computeDifferences(
            left: left, leftURL: leftBase,
            right: right, rightURL: rightBase,
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(leftBase),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(rightBase),
            caseInsensitive: true)
    }

    /// The warm diff of two pane trees at `/L` and `/R`, with the right side's map.
    private func warmDiff(left leftNodes: [FileNode], right rightNodes: [FileNode])
    -> (rightInfo: [String: FileDiffEngine.FileInfo], diffs: [FileDifference]) {
        let leftInfo = FileDiffEngine.filesInfo(fromTree: leftNodes, basePath: "/L")
        let rightInfo = FileDiffEngine.filesInfo(fromTree: rightNodes, basePath: "/R")
        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", rootPath: "/L", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", rootPath: "/R", type: .iCloud)
        return (rightInfo, FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"),
            right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo))
    }

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

    /// The same rule through an injected file manager, a different branch of `childURLs` from the
    /// real filesystem's `contentsOfDirectory`. An unlistable directory must come back as
    /// `listingFailed`, not as `([], listingFailed: false)`, "listed, and empty".
    @Test func buildTreeThroughAnInjectedManagerMarksAnUnlistableDirectoryUnexplored() async throws {
        let fm = MockFileManager()
        for dir in ["/base", "/base/locked"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        let stub = MockFileManager.FileStub(
            isDirectory: false,
            attributes: [.size: NSNumber(value: 9), .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            contents: nil)
        fm.virtualDisk["/base/open.txt"] = stub
        fm.virtualDisk["/base/locked/secret.txt"] = stub
        fm.unlistableDirectories = ["/base/locked"]

        let tree = await FileSyncManager.buildTree(
            url: URL(fileURLWithPath: "/base"), sortOption: .name, fileManager: fm, maxDepth: nil)

        let lockedNode = try #require(tree.first { $0.name == "locked" })
        #expect(lockedNode.isDirectory)
        #expect(lockedNode.isUnexplored == true,
                "an unlistable directory must not masquerade as a genuinely empty one")
        #expect(lockedNode.children?.contains { $0.name == "secret.txt" } != true)
        // The readable sibling is untouched: the failure is scoped to the directory that had one.
        #expect(tree.contains { $0.name == "open.txt" })
    }

    /// The other direction: a directory that really is empty walks as an ordinary explored folder.
    /// Otherwise "mark everything unexplored" would pass the test above, and every empty folder
    /// would suppress real diff rows.
    @Test func buildTreeThroughAnInjectedManagerLeavesAGenuinelyEmptyDirectoryExplored() async throws {
        let fm = MockFileManager()
        for dir in ["/base", "/base/hollow"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }

        let tree = await FileSyncManager.buildTree(
            url: URL(fileURLWithPath: "/base"), sortOption: .name, fileManager: fm, maxDepth: nil)

        let hollow = try #require(tree.first { $0.name == "hollow" })
        #expect(hollow.isDirectory)
        #expect(hollow.isUnexplored != true, "nothing failed here — the folder is simply empty")
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

    /// A denied folder whose name opens with a combining mark, which forms one Character with the
    /// `/` before it. The entry's key and the failure's key must both drop that slash by scalar:
    /// by Character the slash stays on (`/◌́locked`, a key the warm branch never makes), and mixing
    /// the two misses the entry, so the folder reads as empty.
    @Test func getFilesInDirectoryMarksADeniedDirectoryWhoseNameOpensWithACombiningMark() throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        let locked = base.appendingPathComponent("\u{0301}locked")
        try write(locked.appendingPathComponent("secret.txt"), text: "hidden")
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let info = try FileDiffEngine.getFilesInDirectory(base)

        #expect(info.keys.map { Array($0.unicodeScalars) } == [Array("\u{0301}locked".unicodeScalars)],
                "\(info.keys.map { $0.unicodeScalars.map { String($0.value, radix: 16) } })")
        #expect(info["\u{0301}locked"]?.isUnexplored == true, "the denied descent was not recorded against its entry")
    }

    // MARK: Diff level — no phantom Missing rows in either direction

    @Test func unreadableDirectoryOnOneSideProducesNoMissingRowsForItsContents() throws {
        guard !runningAsRoot else { return }
        // Same directory on both sides; the RIGHT one is unreadable, the LEFT one has content.
        let diffs = try lockedDiff(left: ["shared/doc.txt", "shared/sub/deep.txt", "really-missing.txt"], locked: (onLeft: false, path: "shared"))

        // Nothing under the unreadable directory may surface as an actionable Missing row:
        // the right side's view of "shared" is unknown, not empty.
        #expect(!diffs.contains { $0.relativePath.hasPrefix("shared/") },
                "phantom rows: \(diffs.map(\.relativePath))")
        #expect(!diffs.contains { $0.relativePath == "shared" })
        // A genuinely one-sided file elsewhere still reports normally.
        #expect(diffs.contains { $0.relativePath == "really-missing.txt" && $0.type == .missingOnRight })
    }

    @Test func unreadableDirectoryWithCaseVariantNameStillSuppressesMissingRows() throws {
        guard !runningAsRoot else { return }
        // The pairing matches ancestors across case variants, so the suppression must too: left
        // readable "Shared" with content, right unreadable "shared". The unexplored set holds the
        // right-side spelling, which an exact-string ancestor lookup would miss.
        let diffs = try lockedDiff(left: ["Shared/doc.txt", "Shared/sub/deep.txt", "really-missing.txt"], locked: (onLeft: false, path: "shared"))

        #expect(!diffs.contains { $0.relativePath.hasPrefix("Shared/") },
                "phantom rows under a case-variant unreadable folder: \(diffs.map(\.relativePath))")
        #expect(diffs.contains { $0.relativePath == "really-missing.txt" && $0.type == .missingOnRight })
    }

    @Test func unreadableDirectoryWithNearNameVariantStillSuppressesMissingRows() throws {
        guard !runningAsRoot else { return }
        // The near-name shape: right's unreadable folder is "shared " (trailing space). Near-name
        // pairing matches the two dirs, and must not remap phantom child rows into the unreadable
        // variant.
        let diffs = try lockedDiff(left: ["shared/doc.txt"], locked: (onLeft: false, path: "shared "))

        #expect(!diffs.contains { $0.relativePath.hasPrefix("shared/") },
                "phantom rows under a near-name unreadable folder: \(diffs.map(\.relativePath))")
    }

    @Test func readableExactFolderBesideAnUnreadableVariantStillReportsItsMissing() throws {
        guard !runningAsRoot else { return }
        // Negative control for the folded suppression: the right side has both a readable,
        // empty "shared" and an unreadable "shared ". The missing row for left's shared/doc.txt
        // targets the readable folder and must survive: folding may only suppress when no
        // exact-spelling entry owns the ancestor.
        let diffs = try lockedDiff(left: ["shared/doc.txt"], rightDirs: ["shared"], locked: (onLeft: false, path: "shared "))

        #expect(diffs.contains { $0.relativePath == "shared/doc.txt" && $0.type == .missingOnRight },
                "the legit row into the readable exact folder was over-suppressed: \(diffs.map(\.relativePath))")
    }

    @Test func readableCaseVariantOwnerBesideAnUnreadableVariantStillReports() throws {
        guard !runningAsRoot else { return }
        // The readable owner of the ancestor can be a case variant: left "Docs/x.txt", right has
        // readable, empty "docs" and unreadable "Docs ". The pairing matches "Docs" with "docs",
        // so the child row is actionable and must survive. An exact-spelling-only gate would miss
        // the owner (rightFilesInfo["Docs"] is nil) and suppress it on the folded key.
        let diffs = try lockedDiff(left: ["Docs/x.txt"], rightDirs: ["docs"], locked: (onLeft: false, path: "Docs "))

        #expect(diffs.contains { $0.relativePath == "Docs/x.txt" && $0.type == .missingOnRight },
                "over-suppressed the row into the readable case-variant owner: \(diffs.map(\.relativePath))")
    }

    @Test func unreadableDirectoryOnTheLeftSuppressesMissingOnLeftRowsToo() throws {
        guard !runningAsRoot else { return }
        let diffs = try lockedDiff(right: ["shared/doc.txt"], locked: (onLeft: true, path: "shared"))

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

        // Never a bare [], which reads downstream as an authoritatively empty root. The root
        // comes back as a single unexplored node, the same shape as any capped directory.
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
        let diffs = try lockedDiff(left: ["doc.txt", "sub/deep.txt"], locked: (onLeft: false, path: ""))

        // The right side's entire view is unknown: nothing may surface as actionable Missing.
        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    @Test func unreadableRootOnTheLeftSuppressesMissingOnLeftRowsToo() throws {
        guard !runningAsRoot else { return }
        let diffs = try lockedDiff(right: ["doc.txt"], locked: (onLeft: true, path: ""))

        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    @Test func warmTreeBranchSuppressesRootLevelPhantomRowsToo() {
        // The warm branch's root marker: buildTree hands back [root node, unexplored] when the
        // root listing failed; filesInfo(fromTree:) must turn that into the root-key ("")
        // record, and computeDifferences must suppress the whole side on it, as the cold branch
        // does.
        let leftNodes = [
            FileNode(id: "/L/doc.txt", name: "doc.txt", isDirectory: false, fileSize: 100),
        ]
        let rightNodes = [
            FileNode(id: "/R", name: "R", isDirectory: true, children: [], isUnexplored: true),
        ]
        let (rightInfo, diffs) = warmDiff(left: leftNodes, right: rightNodes)
        #expect(rightInfo[""]?.isUnexplored == true)

        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    // MARK: Warm/cold agreement

    @Test func warmTreeBranchSuppressesTheSamePhantomRows() {
        // The warm (cached-tree) branch feeds computeDifferences via filesInfo(fromTree:); an
        // isUnexplored node must carry the marker into the map and suppress the same rows the
        // cold branch suppresses: the two branches must give one answer.
        let leftNodes = [
            FileNode(id: "/L/shared", name: "shared", isDirectory: true, children: [
                FileNode(id: "/L/shared/doc.txt", name: "doc.txt", isDirectory: false, fileSize: 100),
            ]),
        ]
        let rightNodes = [
            FileNode(id: "/R/shared", name: "shared", isDirectory: true, children: [],
                     isUnexplored: true),
        ]
        let (rightInfo, diffs) = warmDiff(left: leftNodes, right: rightNodes)
        #expect(rightInfo["shared"]?.isUnexplored == true)

        #expect(diffs.isEmpty, "phantom rows: \(diffs.map(\.relativePath))")
    }

    // MARK: Name scan (Rename lens)

    /// The denied-root marker node must never become a rename candidate. `NameNormalizer.scan`'s
    /// flatten emits every node, so a risky-named unreadable root would appear in the Rename lens,
    /// and "Fix all" would rename a folder we can't list (a rename needs only parent-write),
    /// dangling the pane focus.
    @MainActor
    @Test func nameScanOfAPermissionDeniedRootYieldsNoCandidates() async throws {
        guard !runningAsRoot else { return }
        let base = try makeTempDir()
        // The root's own name is cloud-risky (trailing space), so it would be flagged if scanned.
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
