import Foundation
import Testing
@testable import Sync

/// The live-twin step at its call sites, driven end to end: the scan, Refine and Try Another each
/// hear a model answer the archived folder, and the card leads with the live one, unless the live
/// one is another person's (`FilingLiveTwinTests` tests the rule itself).
@MainActor
@Suite struct FilingLiveTwinDrivenTests {
    private nonisolated static let archived = "Home/Archive/Old House/Utilities/Power Co"
    private nonisolated static let live = "Home/Utilities/Power Co"

    /// Statements in the archive to 2019 and in the live folder since, a neutral folder, and a
    /// statement for Daughter dated August 2026.
    private func fixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "LiveTwin-\(name)")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for (folder, year) in [(Self.archived, 2019), (Self.live, 2025)] {
            for (i, m) in months.enumerated() {
                try writeBytes(root.appendingPathComponent(String(format: "%@/%d/%02d. %@ %d.pdf", folder, year, i + 1, m, year)))
            }
        }
        try writeBytes(root.appendingPathComponent("Misc/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/Daughter energy statement 2026-08-13.pdf"))
        return root
    }

    /// The live folder is Son's.
    private func profile(of root: URL) -> FolderProfile {
        let e = FolderProfileEntry(path: Self.live, role: .destination, naming: nil, anchors: [], acceptsNewFiles: nil,
                                   fileCount: 12, subfolderCount: 1, axes: ["person": "Son"])
        return FolderProfile(profileId: "t", root: root.path, folders: [e.path: e], personTokens: ["daughter", "son"])
    }

    /// The free model answers `free`, Claude answers the archive.
    private func manager(root: URL, sonsLiveFolder: Bool, free: String) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingLiveTwinDriven-content")
        m.filingRuleDefaults = ScratchDefaults("FilingLiveTwinDriven-rules")
        m.filingPersonVetoLog = PersonVetoLog(userDefaults: ScratchDefaults("FilingLiveTwinDriven-vetoes"))
        if sonsLiveFolder {
            m.filingFolderProfile = profile(of: root)
            m.filingPersonRegistry = FilingTryAnotherVetoTests.household
        }
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        m.filingSnippetExtractor = { _ in "Power Co\nStatement Date: 08/13/2026\nENERGY STATEMENT" }
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { _, files, tier in
            let dest = tier == .refine ? Self.archived : free
            return Dictionary(uniqueKeysWithValues: files.map {
                // The neutral folder weakly, so Claude's answer leads over it with the survey's
                // shortlist in play.
                ($0.filePath, FilingVerdict(relativePath: dest, confidence: dest == "Misc" ? .low : .high,
                                            reason: "Power Co energy statement"))
            })
        }
        return m
    }

    private func scanned(_ name: String, sonsLiveFolder: Bool = false, free: String = archived) async throws -> (FileSyncManager, URL) {
        let root = try fixture(name)
        let m = manager(root: root, sonsLiveFolder: sonsLiveFolder, free: free)
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        _ = try #require(m.filingSuggestions.first, "the scan made no card")
        return (m, root)
    }

    @Test func theScanLeadsWithTheLiveFolder() async throws {
        let (m, root) = try await scanned("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(m.filingSuggestions.first)
        #expect(card.best?.path == root.path + "/" + Self.live + "/2026", "\(card.candidates.map(\.path))")
        #expect(card.candidates.dropFirst().first?.path == root.path + "/" + Self.archived)
    }

    /// Judged by the cross-person rule like any home: the live folder is Son's, the statement
    /// Daughter's.
    @Test func theScanRefusesALiveFolderOfAnotherPerson() async throws {
        let (m, root) = try await scanned("scan-veto", sonsLiveFolder: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(m.filingSuggestions.first)
        #expect(!card.candidates.contains { $0.path.hasPrefix(root.path + "/" + Self.live) }, "\(card.candidates.map(\.path))")
    }

    @Test func refineLeadsWithTheLiveFolder() async throws {
        let (m, root) = try await scanned("refine", free: "Misc")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.filingSuggestions.first?.best?.path == root.path + "/Misc", "the free pass answered elsewhere")
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.filingSuggestions.first?.best?.path == root.path + "/" + Self.live + "/2026",
                "\(m.filingSuggestions.first?.candidates.map(\.path) ?? [])")
    }

    @Test func refineRefusesALiveFolderOfAnotherPerson() async throws {
        let (m, root) = try await scanned("refine-veto", sonsLiveFolder: true, free: "Misc")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        let card = try #require(m.filingSuggestions.first)
        #expect(card.best?.path == root.path + "/" + Self.archived, "Claude's answer, not moved to Son's folder")
        #expect(!card.candidates.contains { $0.path.hasPrefix(root.path + "/" + Self.live) }, "\(card.candidates.map(\.path))")
    }

    @Test func tryAnotherLeadsWithTheLiveFolder() async throws {
        let (m, root) = try await scanned("try", free: "Misc")
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<6 {
            guard let card = m.filingSuggestions.first, card.best != nil,
                  card.best?.path.hasPrefix(root.path + "/" + Self.live) != true else { break }
            await m.tryAnotherFolder(for: card)
        }
        let card = try #require(m.filingSuggestions.first)
        #expect(card.best?.path == root.path + "/" + Self.live + "/2026", "\(card.candidates.map(\.path))")
        #expect(card.candidates.dropFirst().first?.path == root.path + "/" + Self.archived)
    }
}
