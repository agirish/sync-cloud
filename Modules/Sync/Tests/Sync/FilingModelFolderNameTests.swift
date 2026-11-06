import Foundation
import Testing
@testable import Sync

/// A folder a model proposes creating must have a legal name. Every new segment is held to
/// `validateItemName` and to the destination provider's rules, and a candidate that fails is
/// dropped: `Taxes: 2025` would show in Finder with a `/`, and Dropbox and OneDrive refuse to sync
/// a name ending in a period. An existing folder is never judged.
@Suite struct FilingModelFolderNameTests {

    static let root = "/root"
    static let existing: Set<String> = ["Clients", "Clients/Acme Inc.", "Taxes"]

    static func resolve(_ path: String, provider: CloudProvider.ProviderType? = nil) -> FilingDestination? {
        FilingEngine.destination(from: FilingVerdict(relativePath: path, confidence: .high,
                                                     reason: "t", proposesNewFolder: true),
                                 providerRoot: root, existingRelative: existing,
                                 nameProvider: provider)
    }

    /// A character no folder name may carry, whatever the provider.
    @Test func aNewFolderNameValidateItemNameRefusesIsDropped() {
        #expect(Self.resolve("Taxes/Taxes: 2025") == nil)
        #expect(Self.resolve("Taxes/Taxes: 2025", provider: .iCloud) == nil)
        // Control: the same answer with a legal name resolves, new segment and all.
        let ok = Self.resolve("Taxes/Taxes 2025")
        #expect(ok?.path == "/root/Taxes/Taxes 2025")
        #expect(ok?.newSegments == ["Taxes 2025"])
    }

    /// The provider's own rules — and only that provider's.
    @Test func aNewFolderNameTheProviderRefusesIsDropped() {
        #expect(Self.resolve("Clients/Beta Corp.", provider: .dropBox) == nil)
        #expect(Self.resolve("Clients/Beta Corp.", provider: .oneDrive) == nil)
        #expect(Self.resolve("Clients/Beta?Corp", provider: .oneDrive) == nil)
        // iCloud stores a trailing period fine, and no provider at all applies no provider rules.
        #expect(Self.resolve("Clients/Beta Corp.", provider: .iCloud)?.path == "/root/Clients/Beta Corp.")
        #expect(Self.resolve("Clients/Beta Corp.")?.path == "/root/Clients/Beta Corp.")
        // A legal name on Dropbox still resolves, so the refusal above is about the name.
        #expect(Self.resolve("Clients/Beta Corp", provider: .dropBox)?.path == "/root/Clients/Beta Corp")
    }

    /// A folder that already exists is the user's, whatever it is called: the rule judges only
    /// what it would create.
    @Test func anExistingFolderIsNeverJudged() {
        let dest = Self.resolve("Clients/Acme Inc.", provider: .dropBox)
        #expect(dest?.path == "/root/Clients/Acme Inc.")
        #expect(dest?.newSegments == [])
    }

    /// At the call site: the scan hands its `nameProvider` through `applyVerdicts`, so a model's
    /// `Beta Corp.` never reaches a Dropbox card. On iCloud the same answer does, which shows the
    /// classifier was reached at all.
    @MainActor
    @Test func theScanHoldsAModelsNewFolderToTheProvidersRules() async throws {
        func scan(_ provider: CloudProvider.ProviderType) async throws -> (FilingSuggestion, URL) {
            let root = try makeCanonicalTempRoot(prefix: "FilingModelFolderName")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Clients"),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("Clients/.keep"))
            let file = root.appendingPathComponent("Downloads/beta-invoice.pdf")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 5000).write(to: file)
            let settings = ScratchDefaults("filingModelFolderName.\(provider)")
            settings.set(true, forKey: FileSyncManager.usesAIDefaultsKey)
            let m = FileSyncManager()
            m.filingContentDefaults = settings
            m.filingContentExtractor = { _ in [] }
            m.filingClassifier = { _, _, _ in
                [file.path: FilingVerdict(relativePath: "Clients/Beta Corp.", confidence: .high,
                                          reason: "the vendor", proposesNewFolder: true)]
            }
            await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                          providerRoot: root, nameProvider: provider)
            #expect(m.filingLastNameProvider == provider)
            return (try #require(m.filingSuggestions.first), root)
        }

        let (onDropbox, dropboxRoot) = try await scan(.dropBox)
        defer { try? FileManager.default.removeItem(at: dropboxRoot) }
        #expect(!onDropbox.candidates.contains { $0.path.hasSuffix("/Beta Corp.") },
                "a folder Dropbox will not sync was offered: \(onDropbox.candidates.map(\.path))")

        let (onICloud, iCloudRoot) = try await scan(.iCloud)
        defer { try? FileManager.default.removeItem(at: iCloudRoot) }
        #expect(onICloud.best?.path == iCloudRoot.appendingPathComponent("Clients/Beta Corp.").path,
                "the control never reached the classifier: \(onICloud.candidates.map(\.path))")
    }
}
