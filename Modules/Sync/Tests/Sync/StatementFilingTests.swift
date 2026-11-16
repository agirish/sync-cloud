import Foundation
import Testing
@testable import Sync

/// File Here and the rename pass on disk, in a folder ``StatementOrdinals`` governs: the statements
/// a filing renumbers move with it, in an order that never collides, and one ⌘Z puts all of it
/// back.
@Suite struct StatementFilingTests {

    static let rel = "Finance/US/Credit Accounts/American Express/Credit 1001"

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    /// `year` under the account, holding each name with a size of its own, so a test can tell
    /// which file ended up under which name.
    private func yearFolder(_ root: URL, _ year: String, _ names: [String]) throws -> URL {
        let dir = root.appendingPathComponent(Self.rel + "/" + year)
        for (i, n) in names.enumerated() { try writeBytes(dir.appendingPathComponent(n), bytes: 100 + i) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A card filing `loose` into `dir` under the account's own name `proposed`.
    private func card(_ loose: URL, into dir: URL, proposed: String, root: URL) -> FilingSuggestion {
        FilingSuggestion(filePath: loose.path, fileName: loose.lastPathComponent, size: 7, modificationDate: nil,
                         candidates: [FilingDestination(path: dir.path, confidence: .high, reasons: [],
                                                        newSegments: [], proposedName: proposed,
                                                        nameOrigin: .template)],
                         providerRoot: root.path)
    }

    @MainActor
    @Test func fileHereRenumbersTheStatementsAfterItAndOneUndoPutsThemBack() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StatementFiling")
        defer { try? FileManager.default.removeItem(at: root) }
        let year = try yearFolder(root, "2025", ["1. Jan 2025.pdf", "2. Jun 2025.pdf"])
        let loose = root.appendingPathComponent("TODO/Statement_20250315.pdf")
        try writeBytes(loose, bytes: 7)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        let suggestion = card(loose, into: year, proposed: "03. Mar 2025.pdf", root: root)
        manager.publishFilingSuggestions([suggestion])

        #expect(await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best)) == .moved)
        #expect(names(in: year) == ["1. Jan 2025.pdf", "2. Mar 2025.pdf", "3. Jun 2025.pdf"])
        #expect(size(year.appendingPathComponent("2. Mar 2025.pdf")) == 7, "the statement filed")
        #expect(size(year.appendingPathComponent("3. Jun 2025.pdf")) == 101, "June, moved up one")

        undo.undo()
        await waitUntil("one ⌘Z took the filing and the renumbering back") {
            names(in: year) == ["1. Jan 2025.pdf", "2. Jun 2025.pdf"]
                && FileManager.default.fileExists(atPath: loose.path)
        }
        #expect(size(year.appendingPathComponent("2. Jun 2025.pdf")) == 101)
    }

    @MainActor
    @Test func theTwelfthStatementRespellsAllElevenAndUndoesWithThem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StatementFiling")
        defer { try? FileManager.default.removeItem(at: root) }
        let eleven = (1...11).map { "\($0). \(OrdinalMonthName.monthAbbreviations[$0 - 1]) 2026.pdf" }
        let year = try yearFolder(root, "2026", eleven + ["0. Summary 2026.pdf"])
        let loose = root.appendingPathComponent("TODO/December.pdf")
        try writeBytes(loose, bytes: 7)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        let suggestion = card(loose, into: year, proposed: "12. Dec 2026.pdf", root: root)
        manager.publishFilingSuggestions([suggestion])

        #expect(await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best)) == .moved)
        let twelve = (1...12).map { String(format: "%02d. %@ 2026.pdf", $0, OrdinalMonthName.monthAbbreviations[$0 - 1]) }
        #expect(names(in: year) == (["0. Summary 2026.pdf"] + twelve).sorted())
        #expect(size(year.appendingPathComponent("01. Jan 2026.pdf")) == 100)

        undo.undo()
        await waitUntil("the eleven are one digit again and December is back where it was") {
            names(in: year) == (eleven + ["0. Summary 2026.pdf"]).sorted()
                && FileManager.default.fileExists(atPath: loose.path)
        }
    }

    @MainActor
    @Test func aRenumberingThatCannotBeMadeFilesNothingAndMovesNothing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StatementFiling")
        let year = try yearFolder(root, "2025", ["1. Jan 2025.pdf", "2. Jun 2025.pdf", "3. Oct 2025.pdf"])
        let locked = year.appendingPathComponent("3. Oct 2025.pdf")
        // Locked in Finder, so it can't be renamed: June moves first, then October refuses.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let loose = root.appendingPathComponent("TODO/March.pdf")
        try writeBytes(loose, bytes: 7)

        let manager = FileSyncManager()
        let suggestion = card(loose, into: year, proposed: "03. Mar 2025.pdf", root: root)
        manager.publishFilingSuggestions([suggestion])

        #expect(await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best)) == .failed)
        #expect(names(in: year) == ["1. Jan 2025.pdf", "2. Jun 2025.pdf", "3. Oct 2025.pdf"],
                "June was put back: no half-renumbered folder")
        #expect(size(year.appendingPathComponent("2. Jun 2025.pdf")) == 101)
        #expect(FileManager.default.fileExists(atPath: loose.path))
    }

    @MainActor
    @Test func theRenamePassRenumbersThroughSameNamedStatementsAndUndoesThem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StatementFiling")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two July statements, and a June numbered after them by hand: June takes 1. and both
        // Julys move up through each other's names.
        let year = try yearFolder(root, "2016", ["1. Jul 2016.pdf", "2. Jul 2016.pdf", "3. Jun 2016.pdf"])
        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        let plan = RenamePlanner.plan(folderPath: year.path, relativePath: Self.rel + "/2016",
                                      files: names(in: year).map { FolderFile(path: year.path + "/" + $0, name: $0) },
                                      entry: nil)
        #expect(plan.steps.count == 3)

        await manager.applyRenamePlans([plan])
        #expect(names(in: year) == ["1. Jun 2016.pdf", "2. Jul 2016.pdf", "3. Jul 2016.pdf"])
        #expect(size(year.appendingPathComponent("2. Jul 2016.pdf")) == 100, "the first July, not a “2” copy")
        #expect(size(year.appendingPathComponent("3. Jul 2016.pdf")) == 101)

        undo.undo()
        await waitUntil("the folder is as it was") {
            names(in: year) == ["1. Jul 2016.pdf", "2. Jul 2016.pdf", "3. Jun 2016.pdf"]
        }
        #expect(size(year.appendingPathComponent("1. Jul 2016.pdf")) == 100)
        #expect(size(year.appendingPathComponent("3. Jun 2016.pdf")) == 102)
    }

    @MainActor
    @Test func theQueueNamesAStatementByItsPlaceAndSaysWhatItRenumbers() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StatementFiling")
        defer { try? FileManager.default.removeItem(at: root) }
        let year = try yearFolder(root, "2025", ["1. Jan 2025.pdf", "2. Jun 2025.pdf"])
        let loose = root.appendingPathComponent("TODO/March.pdf")
        try writeBytes(loose, bytes: 7)
        let manager = FileSyncManager()
        let suggestion = card(loose, into: year, proposed: "03. Mar 2025.pdf", root: root)
        manager.publishFilingSuggestions([suggestion])
        // Re-answered after the scan (Try Another, Refine): named against the disk now.
        manager.replaceFilingSuggestion(suggestion.id, candidates: suggestion.candidates)
        let home = try #require(manager.filingSuggestions.first?.best)
        #expect(home.proposedName == "2. Mar 2025.pdf")
        #expect(home.renumbersOthers == 1)
    }
}
