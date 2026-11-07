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
            for: difference(left: left, right: right, name: "a.txt", type: .differentDates),
            fileManager: FileManager.default)

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
        // Destination folder: two files at the top and one nested; the enumerator counts all
        // four entries (the subfolder itself plus its file).
        let destinationDocs = right.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: destinationDocs.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: destinationDocs.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: destinationDocs.appendingPathComponent("two.txt"))
        try Data("3".utf8).write(to: destinationDocs.appendingPathComponent("sub/three.txt"))

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "Docs", type: .differentDates),
            fileManager: FileManager.default)

        #expect(facts.destinationIsDirectory)
        #expect(facts.destinationChildCount == 4)
        #expect(!facts.destinationChildCountCapped)
    }

    // MARK: Folders that cannot be read

    /// `chmod` is a no-op for root, so the locked directory these tests need would be readable and
    /// they would pass for the wrong reason. Same guard as `DirectoryListingTests`. It records an
    /// issue rather than returning quietly, since a bare `return` reports the test as passed.
    private func skippedBecauseRoot(_ fixture: String, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard geteuid() == 0 else { return false }
        Issue.record("""
            Skipped “\(fixture)”: running as root (euid 0), where chmod 000 does not restrict \
            access, so the locked destination folder this needs is readable and the fixture \
            proves nothing. Treat the suite as not having covered it.
            """, sourceLocation: sourceLocation)
        return true
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A destination folder that can't be listed must not reach the warning as a count of zero,
    /// or the card says "0 items on iCloud will be removed" right before removing all of them.
    /// Asserted on the sentence a person reads. The enumerator doesn't fail on such a folder, so a
    /// `guard let enumerator` else-branch can't catch it, as proved inline below.
    @Test func anUnreadableDestinationFolderIsNotAnnouncedAsZeroItems() async throws {
        guard !skippedBecauseRoot("anUnreadableDestinationFolderIsNotAnnouncedAsZeroItems") else { return }
        let scratch = try makeScratch()
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        let destinationDocs = right.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: destinationDocs, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: destinationDocs.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: destinationDocs.appendingPathComponent("two.txt"))
        try Data("3".utf8).write(to: destinationDocs.appendingPathComponent("three.txt"))
        try lock(destinationDocs)
        defer {
            unlock(destinationDocs)
            try? FileManager.default.removeItem(at: scratch)
        }

        // The premise, measured rather than assumed: three files are in there, and the plain
        // enumerator returns non-nil and yields nothing.
        let raw = FileManager.default.enumerator(at: destinationDocs, includingPropertiesForKeys: nil,
                                                 options: [], errorHandler: nil)
        #expect(raw != nil, "the else-branch of `guard let enumerator` is dead on a real disk")
        #expect(raw?.allObjects.count == 0)

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "Docs", type: .differentDates),
            fileManager: FileManager.default)

        #expect(facts.destinationIsDirectory)

        let text = ReviewCardModel.warningText(
            difference: difference(left: left, right: right, name: "Docs", type: .differentDates),
            facts: facts, destinationName: "iCloud", isMove: false)

        #expect(text == "Replacing this folder replaces its entire contents — everything on iCloud will be removed.")
        // Stated separately and in the negative: a wording change could reach the sentence above
        // while the count stayed wrong, and "0 items" is the claim that must never appear.
        #expect(text?.contains("0 items") == false)

        // The control, inside this test. The unreadable branch leaves `destinationChildCount`
        // nil, which is also its default, so deleting the `childCount` call from `loadFacts`
        // would pass everything above. The same loader, in the same run, must produce a real
        // number for a folder it can read.
        let readable = right.appendingPathComponent("Open")
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: readable.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: readable.appendingPathComponent("two.txt"))
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Open"),
                                                withIntermediateDirectories: true)

        let openFacts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "Open", type: .differentDates),
            fileManager: FileManager.default)

        #expect(openFacts.destinationIsDirectory)
        #expect(openFacts.destinationChildCount == 2,
                "a readable folder must reach a real count — otherwise nil above proves nothing")
        let openText = ReviewCardModel.warningText(
            difference: difference(left: left, right: right, name: "Open", type: .differentDates),
            facts: openFacts, destinationName: "iCloud", isMove: false)
        #expect(openText?.contains("2 items") == true,
                "the two sentences have to differ, or “everything” is not a decision: \(openText ?? "nil")")
        #expect(openText != text)
    }

    /// The middle case: the folder itself listed, one subtree inside it did not. The count is then
    /// a floor, and the sentence has to say so rather than presenting it as a total.
    @Test func aPartlyUnreadableDestinationFolderCountsAsAFloor() async throws {
        guard !skippedBecauseRoot("aPartlyUnreadableDestinationFolderCountsAsAFloor") else { return }
        let scratch = try makeScratch()
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        let destinationDocs = right.appendingPathComponent("Docs")
        // Two readable files plus a locked subdirectory holding four more. The enumerator yields
        // three entries (the two files and the subdirectory itself) and reports the subdirectory
        // through the error handler, so 3 is a floor under an actual 7.
        let locked = destinationDocs.appendingPathComponent("locked-sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d"] {
            try Data(name.utf8).write(to: locked.appendingPathComponent("\(name).txt"))
        }
        try Data("1".utf8).write(to: destinationDocs.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: destinationDocs.appendingPathComponent("two.txt"))
        try lock(locked)
        defer {
            unlock(locked)
            try? FileManager.default.removeItem(at: scratch)
        }

        let diff = difference(left: left, right: right, name: "Docs", type: .differentDates)
        let facts = await ReviewCardView.loadFacts(for: diff, fileManager: FileManager.default)

        #expect(facts.destinationChildCount == 3)
        #expect(facts.destinationChildCountIsPartial)
        #expect(!facts.destinationChildCountCapped)

        let text = ReviewCardModel.warningText(
            difference: diff, facts: facts, destinationName: "iCloud", isMove: false)

        #expect(text == "Replacing this folder replaces its entire contents — at least 3 items on iCloud will be removed.")
    }

    /// The counterweight to the two above: a folder that really holds nothing still says "0 items",
    /// or "treat every folder as unreadable" would pass them.
    @Test func aGenuinelyEmptyDestinationFolderStillReadsAsZero() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right.appendingPathComponent("Docs"), withIntermediateDirectories: true)

        let diff = difference(left: left, right: right, name: "Docs", type: .differentDates)
        let facts = await ReviewCardView.loadFacts(for: diff, fileManager: FileManager.default)

        #expect(facts.destinationChildCount == 0)
        #expect(!facts.destinationChildCountIsPartial)

        let text = ReviewCardModel.warningText(
            difference: diff, facts: facts, destinationName: "iCloud", isMove: false)

        #expect(text == "Replacing this folder replaces its entire contents — 0 items on iCloud will be removed.")
    }

    @Test func missingSideItemsSkipTheDestinationStat() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let left = scratch.appendingPathComponent("left")
        let right = scratch.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: left.appendingPathComponent("a.txt"))

        let facts = await ReviewCardView.loadFacts(
            for: difference(left: left, right: right, name: "a.txt", type: .missingOnRight),
            fileManager: FileManager.default)

        #expect(facts.sourceModified != nil)
        #expect(facts.destinationModified == nil)
        #expect(!facts.destinationIsDirectory)
    }
}
