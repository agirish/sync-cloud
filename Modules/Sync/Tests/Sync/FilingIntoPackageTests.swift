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
        // A filing's alert (E3).
        #expect(manager.currentError?.title == "Filing Failed")
    }

    /// **A folder the filing would CREATE can be a document too** (FR3). `enclosingPackage` asks
    /// the disk, and a segment not made yet has nothing on disk to ask — so `Notes.rtfd` as a new
    /// segment was created as a plain folder and the file moved inside what Finder then shows as
    /// one document. The extension is what makes it a package, so the extension is what is asked.
    @MainActor
    @Test func aNewSegmentThatWouldBeAPackageIsRefused() async throws {
        for document in ["Notes.rtfd", "Helper.app"] {
            let root = try makeCanonicalTempRoot(prefix: "FilingNewPackage")
            defer { try? FileManager.default.removeItem(at: root) }
            let finance = root.appendingPathComponent("Finance")
            try FileManager.default.createDirectory(at: finance, withIntermediateDirectories: true)
            let loose = root.appendingPathComponent("Inbox/Budget 2025.pdf")
            try FileManager.default.createDirectory(at: loose.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("pdf".utf8).write(to: loose)

            let manager = FileSyncManager()
            manager.undoManager = UndoManager()
            let dest = FilingDestination(path: finance.appendingPathComponent("\(document)/2025").path,
                                         confidence: .high, reasons: [], newSegments: [document, "2025"])
            let suggestion = FilingSuggestion(
                filePath: loose.path, fileName: loose.lastPathComponent, size: 3, modificationDate: nil,
                candidates: [dest], providerRoot: root.path)
            manager.publishFilingSuggestions([suggestion])

            let result = await manager.applyFilingSuggestion(suggestion, to: dest)

            #expect(result == .failed, "\(document): filed into a folder that is a document")
            #expect(FileManager.default.fileExists(atPath: loose.path), "\(document): the file left its folder")
            #expect(!FileManager.default.fileExists(atPath: finance.appendingPathComponent(document).path),
                    "\(document): the package-named folder was created")
            #expect(manager.currentError?.reason?.contains("“\(document)” is a document, not a folder") == true,
                    "\(document): \(manager.currentError?.reason ?? "no reason")")
        }
    }

    /// The other side: a new segment whose name only LOOKS like it has an extension — a dotted
    /// name, an unknown one — is an ordinary folder and is still created.
    @MainActor
    @Test func aNewSegmentWithAnOrdinaryDotIsStillCreated() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingNewPackage")
        defer { try? FileManager.default.removeItem(at: root) }
        let finance = root.appendingPathComponent("Finance")
        try FileManager.default.createDirectory(at: finance, withIntermediateDirectories: true)
        let loose = root.appendingPathComponent("Inbox/Budget 2025.pdf")
        try FileManager.default.createDirectory(at: loose.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: loose)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let dest = FilingDestination(path: finance.appendingPathComponent("Acme Inc. 2.0").path,
                                     confidence: .high, reasons: [], newSegments: ["Acme Inc. 2.0"])
        let suggestion = FilingSuggestion(
            filePath: loose.path, fileName: loose.lastPathComponent, size: 3, modificationDate: nil,
            candidates: [dest], providerRoot: root.path)
        manager.publishFilingSuggestions([suggestion])

        #expect(await manager.applyFilingSuggestion(suggestion, to: dest) == .moved)
        #expect(FileManager.default.fileExists(atPath: finance.appendingPathComponent("Acme Inc. 2.0/Budget 2025.pdf").path))
    }
}
