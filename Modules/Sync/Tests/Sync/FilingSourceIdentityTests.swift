import Foundation
import Testing
@testable import Sync

/// **To File moves the file the card is about, or nothing (FR45).**
///
/// `performFiling` checked only that something sat at the card's path. A queue is stepped through
/// minutes after the scan, and in that time a browser can re-download over the name or an editor
/// save a different document to it — and the move then carried that stranger into a folder chosen
/// for the original, leaving nothing where the user last saw it. The scan now records each file's
/// `ItemIdentity`, and the move refuses one that has drifted, as Automations' apply already did.
///
/// Real disk throughout: the identity is a real stat, and the outcome asserted is where the bytes
/// end up.
@Suite @MainActor struct FilingSourceIdentityTests {

    private static func write(_ url: URL, bytes: Int, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// A scanned tree with one loose file and one existing folder to file it into.
    ///
    /// `contentTokens` is what the on-device reader returns for every file; empty (the default)
    /// means phase 2's re-suggest never runs.
    private static func scanned(fileName: String = "invoice.pdf",
                                contentTokens: Set<String> = []) async throws
        -> (root: URL, manager: FileSyncManager, card: FilingSuggestion, folder: FilingDestination) {
        let root = try makeCanonicalTempRoot(prefix: "FilingSourceIdentity")
        try write(root.appendingPathComponent("Documents/Bills/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/\(fileName)"), bytes: 5000)
        let m = FileSyncManager()
        // Content reading on explicitly — it is the default, but a stray `false` in the test
        // process's defaults would switch phase 2 off and leave the content test vacuous.
        let settings = UserDefaults(suiteName: "FilingSourceIdentity-\(UUID().uuidString)")!
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

    /// The scan records the file as the move will re-read it — the precondition for the guard
    /// below, and what keeps it from refusing a file nobody touched.
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

    /// The headline: a different document now sits at the card's path. It stays where it is,
    /// nothing lands in the folder, and the alert says why.
    @Test func aFileReplacedSinceTheScanIsNotFiled() async throws {
        let (root, m, card, folder) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: card.filePath)
        // A re-download under the same name: different bytes, different size.
        try FileManager.default.removeItem(at: src)
        try Self.write(src, bytes: 7000, fill: 0x42)

        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path), "the replacement was moved")
        let landed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != ".keep" }
        #expect(landed.isEmpty, "something was filed into the folder: \(landed)")
        #expect(m.currentError?.reason?.contains("changed since the scan") == true,
                "the alert did not say why: \(m.currentError?.reason ?? "-")")
    }

    /// **The refusal is a filing's, and says nothing untrue about a folder the user picked.** It
    /// went out as "Sync Failed / Couldn't sync “invoice.pdf”" marked retryable, and said "the
    /// folder suggested for it was chosen for a different file" — after "Choose a folder…", where
    /// nothing suggested it and the user chose it. Pressing the same button again cannot change a
    /// file that is no longer the one the card was about, so it is not retryable either.
    @Test func theRefusalIsAFilingsAndFitsAChosenFolder() async throws {
        let (root, m, card, folder) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: card.filePath)
        try FileManager.default.removeItem(at: src)
        try Self.write(src, bytes: 7000, fill: 0x42)

        #expect(await m.applyFilingSuggestion(card, to: folder) == .failed)

        let error = try #require(m.currentError, "the refusal was not presented")
        #expect(error.title == "Filing Failed")
        #expect(error.message == "Couldn’t file “invoice.pdf”.")
        #expect(!error.isRetryable, "a changed file is offered a retry that cannot succeed")
        let reason = try #require(error.reason)
        #expect(reason.contains("changed since the scan"))
        #expect(!reason.contains("suggested"),
                "the refusal calls a folder the user chose a suggestion: \(reason)")
    }

    /// The other direction, so the refusal above is not a guard that refuses everything: the same
    /// card, untouched, files.
    @Test func anUntouchedFileStillFiles() async throws {
        let (root, m, card, folder) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .moved)
        #expect(!FileManager.default.fileExists(atPath: card.filePath))
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: folder.path).appendingPathComponent("invoice.pdf").path))
    }

    /// A re-answered card keeps the identity — "Try another", a refine and Read scan rebuild the
    /// suggestion, and a rebuild that dropped it would silently switch the guard off.
    @Test func aRebuiltCardKeepsTheIdentity() async throws {
        let (root, _, card, _) = try await Self.scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(card.replacingCandidates([]).sourceIdentity == card.sourceIdentity)
        #expect(card.alreadyFiled(at: ["Documents"]).sourceIdentity == card.sourceIdentity)
    }

    /// **Content reading's re-suggest keeps the identity.** Phase 2 replaces the whole list with a
    /// fresh `FilingEngine.suggest`, which knows nothing of identities; with reading on — the
    /// default — every card it rebuilt went out with none, and `performFiling` skips the check
    /// for a card without one. The file's name says nothing, so it has no home before its page is
    /// read; the reader returns a token that gives it one, which proves the re-suggest ran. The
    /// card must still refuse a replaced file.
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
        try Self.write(src, bytes: 7000, fill: 0x42)
        let result = await m.applyFilingSuggestion(card, to: folder)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path), "the replacement was moved")
    }
}
