import Foundation
import Testing
@testable import Sync

/// FR3 at the call site: whatever route named the destination, filing never moves a file into a
/// package. `FilingEngine` already leaves packages out of its candidates; this pins the backstop
/// in `performFiling`, which the router, a model's answer and a typed folder all reach.
@Suite struct FilingIntoPackageTests {

    @MainActor
    @Test func filingIntoAPackageIsRefusedAndTheFileStays() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingPackage")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("Finance/Budget 2025.numbers/Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let loose = root.appendingPathComponent("Inbox/Budget 2025.pdf")
        try FileManager.default.createDirectory(at: loose.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: loose)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let suggestion = FilingSuggestion(
            filePath: loose.path, fileName: loose.lastPathComponent, size: 3, modificationDate: nil,
            candidates: [FilingDestination(path: data.path, confidence: .high, reasons: [], newSegments: [])],
            providerRoot: root.path)
        manager.publishFilingSuggestions([suggestion])

        let result = await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best))

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: loose.path), "the file left its folder")
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).isEmpty)
        #expect(manager.currentError?.reason?.contains("is a document, not a folder") == true,
                "the refusal says why, not \"couldn't file this item\"")
    }
}
