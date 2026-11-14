import Foundation
import Testing
@testable import Sync

/// To File moves the file the card is about, or nothing. A queue is stepped through minutes after
/// the scan, and a browser can re-download over the name or an editor save a different document
/// there; a path check alone would carry that stranger into a folder chosen for the original. The
/// scan records each file's `ItemIdentity`, and the move refuses one that has drifted, as
/// Automations' apply does. Real disk throughout: the identity is a real stat.
@Suite @MainActor struct FilingSourceIdentityTests {

    /// A scanned tree with one loose file and one existing folder to file it into.
    ///
    /// `contentTokens` is what the on-device reader returns for every file; empty (the default)
    /// means phase 2's re-suggest never runs.
    private static func scanned(fileName: String = "invoice.pdf",
                                contentTokens: Set<String> = []) async throws
        -> (root: URL, manager: FileSyncManager, card: FilingSuggestion, folder: FilingDestination) {
        let root = try makeCanonicalTempRoot(prefix: "FilingSourceIdentity")
        try writeBytes(root.appendingPathComponent("Documents/Bills/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/\(fileName)"), bytes: 5000)
        let m = FileSyncManager()
        // Content reading on explicitly: it is the default, but a stray `false` in the test
        // process's defaults would switch phase 2 off and leave the content test vacuous.
        let settings = ScratchDefaults("FilingSourceIdentity")
        settings.set(true, forKey: FileSyncManager.readContentsDefaultsKey)
        m.filingContentDefaults = settings
        m.filingContentExtractor = { _ in contentTokens }
        m.filingSnippetExtractor = { _ in nil }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let card = try #require(m.filingSuggestions.first { $0.fileName == fileName })
        let folder = FilingDestination(path: root.appendingPathComponent("Documents/Bills").path,
                                       confidence: .high, reasons: ["You chose this folder"],
                                       newSegments: [])
        return (root, m, card, folder)
    }

    /// The scan records the file as the move will re-read it, so the guard doesn't refuse a file
    /// nobody touched.
    @Test func theScanRecordsEachFilesIdentity() async throws {
        let (root, _, card, _) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = try #require(card.sourceIdentity, "the scan recorded no identity")
        guard case .file(let size, _) = recorded else {
            Issue.record("expected a file identity, got \(recorded)"); return
        }
        #expect(size == 5000)
        #expect(recorded.drift(at: URL(fileURLWithPath: card.filePath),
                               fileManager: FileManager.default) == .unchanged)
    }

    /// A different document now sits at the card's path. It stays put, nothing lands in the
    /// folder, and the alert says why. The refusal is a filing failure, not a sync one, and doesn't
    /// call a folder the user chose (via "Choose a folder…") a suggestion.
    @Test func aFileReplacedSinceTheScanIsNotFiled() async throws {
        let (root, m, card, folder) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: card.filePath)
        // A re-download under the same name: different bytes, different size.
        try FileManager.default.removeItem(at: src)
        try writeBytes(src, bytes: 7000, fill: 0x42)

        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path), "the replacement was moved")
        let landed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != ".keep" }
        #expect(landed.isEmpty, "something was filed into the folder: \(landed)")
        let error = try #require(m.currentError, "the refusal was not presented")
        #expect(error.title == "Filing Failed")
        #expect(error.message == "Couldn’t file “invoice.pdf”.")
        #expect(error.reason?.contains("changed since the scan") == true,
                "the alert did not say why: \(error.reason ?? "-")")
        #expect(error.reason?.contains("suggested") == false,
                "the refusal calls a folder the user chose a suggestion: \(error.reason ?? "-")")
    }

    /// The other direction, so the guard doesn't refuse everything: the same card, untouched,
    /// files.
    @Test func anUntouchedFileStillFiles() async throws {
        let (root, m, card, folder) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .moved)
        #expect(!FileManager.default.fileExists(atPath: card.filePath))
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: folder.path).appendingPathComponent("invoice.pdf").path))
    }

    /// A re-answered card keeps the identity: "Try another", a refine and Read scan rebuild the
    /// suggestion, and dropping it would silently switch the guard off.
    @Test func aRebuiltCardKeepsTheIdentity() async throws {
        let (root, _, card, _) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(card.replacingCandidates([]).sourceIdentity == card.sourceIdentity)
        #expect(card.alreadyFiled(at: ["Documents"]).sourceIdentity == card.sourceIdentity)
    }

    /// Content reading's re-suggest keeps the identity. Phase 2 replaces the list with a fresh
    /// `FilingEngine.suggest`, which knows nothing of identities, and `performFiling` skips the
    /// check for a card without one. The filename says nothing, so a home from content proves the
    /// re-suggest ran; the card must still refuse a replaced file.
    @Test func contentReadingKeepsTheIdentity() async throws {
        let (root, m, card, folder) = try await Self.scanned(fileName: "scan0042.pdf",
                                                             contentTokens: ["bills"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(card.candidates.contains { $0.fromContent },
                "the content re-suggest never ran: \(card.candidates.map(\.path))")
        let recorded = try #require(card.sourceIdentity, "the re-suggest dropped the identity")
        #expect(recorded.drift(at: URL(fileURLWithPath: card.filePath),
                               fileManager: FileManager.default) == .unchanged)

        let src = URL(fileURLWithPath: card.filePath)
        try FileManager.default.removeItem(at: src)
        try writeBytes(src, bytes: 7000, fill: 0x42)
        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path), "the replacement was moved")
    }
}
