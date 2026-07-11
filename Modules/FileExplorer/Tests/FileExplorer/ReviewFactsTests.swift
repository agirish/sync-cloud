import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Real-disk coverage for the review card's facts loader: modification dates on both sides,
/// folder detection, and the contents count behind the folder-replace warning.
@Suite struct ReviewFactsTests {

    /// A scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewFactsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func difference(
        left: URL, right: URL, name: String,
        type: FileDifference.DifferenceType, action: FileDifference.SyncAction = .copyToRight
    ) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: left.appendingPathComponent(name).path,
            rightItemPath: right.appendingPathComponent(name).path,
            type: type,
            action: action,
            description: "test"
        )
    }

    @Test func statsBothSidesDatesForAReplace() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: left.appendingPathComponent("a.txt"))
        try Data("old".utf8).write(to: right.appendingPathComponent("a.txt"))
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let destinationDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: left.appendingPathComponent("a.txt").path)
        try FileManager.default.setAttributes([.modificationDate: destinationDate], ofItemAtPath: right.appendingPathComponent("a.txt").path)

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "a.txt", type: .differentDates))

        #expect(facts.sourceModified == sourceDate)
        #expect(facts.destinationModified == destinationDate)
        #expect(!facts.destinationIsDirectory)
        #expect(facts.destinationChildCount == nil)
    }

    @Test func countsAReplacedFoldersContentsRecursively() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        // Destination folder: two files at the top and one nested — enumerator counts all
        // four entries (the subfolder itself plus its file).
        let destinationDocs = right.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: destinationDocs.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: destinationDocs.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: destinationDocs.appendingPathComponent("two.txt"))
        try Data("3".utf8).write(to: destinationDocs.appendingPathComponent("sub/three.txt"))

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "Docs", type: .differentDates))

        #expect(facts.destinationIsDirectory)
        #expect(facts.destinationChildCount == 4)
        #expect(!facts.destinationChildCountCapped)
    }

    @Test func missingSideItemsSkipTheDestinationStat() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: left.appendingPathComponent("a.txt"))

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "a.txt", type: .missingOnRight))

        #expect(facts.sourceModified != nil)
        #expect(facts.destinationModified == nil)
        #expect(!facts.destinationIsDirectory)
    }
}
