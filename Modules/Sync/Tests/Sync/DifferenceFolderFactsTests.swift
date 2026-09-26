import Testing
import Foundation
@testable import Sync

/// **Each difference records, per side, whether its item is a folder** — the fact a row's menu needs
/// to keep "Open in Edit" and "Compare…" off directories named like files.
///
/// `enclosedItemCount` was the only folder marker a row carried, and it is recorded only for a
/// folder whose contents were collapsed into it: an EMPTY folder, a name-conflicted pair of folders
/// and a folder-versus-file row with an empty folder all came out with `nil`, and where it was set
/// it could not say which side was the folder. Every shape below is built by the real engine.
@Suite struct DifferenceFolderFactsTests {

    private let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/L", type: .iCloud)
    private let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/R", type: .iCloud)

    private func info(_ path: String, _ isDirectory: Bool) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: path, isDirectory: isDirectory),
                                modificationDate: Date(timeIntervalSince1970: 1_000),
                                fileSize: isDirectory ? nil : 10, isDirectory: isDirectory)
    }

    private func rows(left l: [String: Bool], right r: [String: Bool]) -> [FileDifference] {
        var leftInfo = ["d": info("/L/d", true)], rightInfo = ["d": info("/R/d", true)]
        for (key, isDir) in l { leftInfo[key] = info("/L/\(key)", isDir) }
        for (key, isDir) in r { rightInfo[key] = info("/R/\(key)", isDir) }
        return FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"), right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo)
    }

    private func facts(_ d: FileDifference?) -> [Bool]? {
        d.map { [$0.leftIsDirectory, $0.rightIsDirectory] }
    }

    @Test func aMissingFolderIsAFolderOnTheSideThatHasItWhetherOrNotItIsEmpty() {
        let empty = rows(left: ["d/x.md": true], right: [:]).first
        #expect(empty?.enclosedItemCount == nil, "the premise: an empty folder carries no count")
        #expect(facts(empty) == [true, false])
        let full = rows(left: [:], right: ["d/x.md": true, "d/x.md/in.txt": false]).first
        #expect(full?.enclosedItemCount == 1)
        #expect(facts(full) == [false, true])
    }

    @Test func aMissingFileIsNotAFolder() {
        #expect(facts(rows(left: ["d/x.md": false], right: [:]).first) == [false, false])
        #expect(facts(rows(left: [:], right: ["d/x.md": false]).first) == [false, false])
    }

    @Test func aNameConflictedFolderPairIsAFolderOnBothSides() {
        let d = rows(left: ["d/x.md": true], right: ["d/x.md ": true]).first
        #expect(d?.type == .nameConflict)
        #expect(d?.enclosedItemCount == nil)
        #expect(facts(d) == [true, true])
        let files = rows(left: ["d/x.md": false], right: ["d/x.md ": false]).first
        #expect(files?.type == .nameConflict)
        #expect(facts(files) == [false, false])
    }

    /// The count cannot say which side is the folder; the facts can, empty folder or not.
    @Test func aFolderAgainstAFileNamesWhichSideIsTheFolder() {
        #expect(facts(rows(left: ["d/x.md": true], right: ["d/x.md": false]).first) == [true, false])
        let full = rows(left: ["d/x.md": false], right: ["d/x.md": true, "d/x.md/in.txt": false]).first
        #expect(full?.enclosedItemCount == 1)
        #expect(facts(full) == [false, true])
    }

    @Test func twoChangedFilesAreNotFolders() {
        var l = ["d/x.md": info("/L/d/x.md", false)]
        l["d"] = info("/L/d", true)
        let r = ["d": info("/R/d", true),
                 "d/x.md": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/R/d/x.md"),
                                                   modificationDate: Date(timeIntervalSince1970: 5_000),
                                                   fileSize: 99, isDirectory: false)]
        let d = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"), right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: l, rightFilesInfo: r).first
        #expect(d?.type == .differentDates)
        #expect(facts(d) == [false, false])
    }

    /// Swapping the panes swaps the facts with the paths they describe.
    @Test func mirroringSwapsTheFacts() throws {
        let d = try #require(rows(left: ["d/x.md": true], right: ["d/x.md": false]).first)
        #expect(facts(d.mirrored()) == [false, true])
        #expect(d.mirrored().mirrored() == d)
    }
}
