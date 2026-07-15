import Testing
import Foundation
@testable import Sync

/// Manager-level coverage for Filing: the end-to-end scan (real folders) and the apply path
/// (real move, creating new folders, undoable).
/// A tiny thread-safe flag for asserting whether an injected closure ran.
final class Flag: @unchecked Sendable { var value = false }

@Suite struct FileSyncManagerFilingTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilingTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findFilingSuggestionsFindsHomesInYourFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)   // existing Vehicles folder
        try write(root.appendingPathComponent("Downloads/Tesla Auto Policy.pdf"))
        try write(root.appendingPathComponent("Downloads/zxqw9.bin"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(manager.hasSuggestedFiling)
        let tesla = manager.filingSuggestions.first { $0.fileName.hasPrefix("Tesla") }
        #expect(tesla?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(tesla?.best?.newSegments == ["Tesla", "Insurance"])
        // The unrecognized file appears but with no confident home.
        let junk = manager.filingSuggestions.first { $0.fileName == "zxqw9.bin" }
        #expect(junk?.hasConfidentHome == false)
    }

    @MainActor
    @Test func applyFilingMovesFileAndCreatesNewFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf",
                                          size: 5000, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let ok = await manager.applyFilingSuggestion(suggestion, to: dest)

        let movedPath = root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/Tesla Policy.pdf").path
        #expect(ok == .moved)
        #expect(FileManager.default.fileExists(atPath: movedPath))          // moved, new folders created
        #expect(!FileManager.default.fileExists(atPath: srcPath.path))      // gone from Downloads
        #expect(manager.filingSuggestions.isEmpty)                          // dropped from the list
        #expect(manager.banner?.severity == .success)
    }

    @MainActor
    @Test func applyRecommendedFilesConfidentOnlyLeavesTheRest() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let junkPath = root.appendingPathComponent("Downloads/zxqw9.bin")
        try write(junkPath)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.count == 2)

        await manager.applyRecommendedFiling()

        // The Tesla file moved; the unrecognized one stays put and stays in the list.
        #expect(FileManager.default.fileExists(atPath: junkPath.path))
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.fileName == "zxqw9.bin")
    }

    @MainActor
    @Test func contentExtractorUpgradesFilesWithNoHomeFromTheName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/scan0012.pdf"))

        let manager = FileSyncManager()
        // Simulate on-device extraction finding the entities inside the uninformatively-named scan.
        manager.filingContentExtractor = { path in
            path.hasSuffix("scan0012.pdf") ? ["tesla", "policy", "geico"] : []
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(scan?.best?.reasons.first?.contains("read from the file") == true)
    }

    @MainActor
    @Test func applyingToTheFilesOwnFolderIsANoOpNotARename() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcPath = root.appendingPathComponent("Downloads/report.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "report.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("Downloads").path,
                                     confidence: .high, reasons: [], newSegments: [])

        let ok = await manager.applyFilingSuggestion(s, to: dest)

        #expect(ok == .notNeeded)   // filing into its own folder is a no-op success, not a move
        #expect(FileManager.default.fileExists(atPath: srcPath.path))                                   // unchanged
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/report 2.pdf").path))
        #expect(manager.filingSuggestions.isEmpty)                                                      // dropped from list
    }

    @MainActor
    @Test func batchFilingIsASingleUndo() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let tesla = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        let toyota = root.appendingPathComponent("Downloads/Toyota Registration.pdf")
        try write(tesla); try write(toyota)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.filter { $0.isBatchEligible }.count == 2)

        await manager.applyRecommendedFiling()
        #expect(!FileManager.default.fileExists(atPath: tesla.path))
        #expect(!FileManager.default.fileExists(atPath: toyota.path))

        // A single ⌘Z reverts the whole batch.
        #expect(undo.canUndo)
        undo.undo()
        await waitUntil("both files restored") {
            FileManager.default.fileExists(atPath: tesla.path) && FileManager.default.fileExists(atPath: toyota.path)
        }
    }

    @MainActor
    @Test func batchSkipsContentDerivedSuggestions() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/scan0012.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        manager.filingContentExtractor = { $0.hasSuffix("scan0012.pdf") ? ["tesla", "policy"] : [] }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.hasConfidentHome == true)     // content gave it a home
        #expect(scan?.isBatchEligible == false)     // but content-derived → not batch-eligible

        await manager.applyRecommendedFiling()
        #expect(FileManager.default.fileExists(atPath: srcPath.path))   // the batch did NOT move it
    }

    @MainActor
    @Test func readContentsToggleOffSkipsExtraction() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/scan0012.pdf"))

        let manager = FileSyncManager()
        let suite = "FilingToggle-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { manager.filingContentDefaults.removePersistentDomain(forName: suite) }
        manager.filingContentDefaults.set(false, forKey: FileSyncManager.readContentsDefaultsKey)
        // An extractor that WOULD give a home — proving it isn't consulted when the toggle is off.
        manager.filingContentExtractor = { _ in ["tesla", "policy"] }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.hasConfidentHome == false)   // stayed no-home → contents were not read
    }

    @MainActor
    @Test func clearFilingResetsState() {
        let manager = FileSyncManager()
        manager.filingSuggestions = [FilingSuggestion(filePath: "/a/x", fileName: "x", size: 1,
                                                      modificationDate: nil, candidates: [])]
        manager.filingScanFolder = "/a"
        manager.hasSuggestedFiling = true
        manager.filingSessionRejections = ["/a/x": ["/a/Docs"]]

        manager.clearFiling()

        #expect(manager.filingSuggestions.isEmpty)
        #expect(manager.filingScanFolder == nil)
        #expect(manager.hasSuggestedFiling == false)
        // Session rejections are keyed by file path; a provider switch invalidates them (another
        // provider can legitimately host a same-named path), so clearFiling must drop them.
        #expect(manager.filingSessionRejections.isEmpty)
    }

    /// "Try another" on a file whose name has no salient tokens ("IMG 0007" — exactly the files
    /// the content/AI pipeline exists for) can't persist a token-keyed rejection, but the click
    /// must still take effect: the rejected folder never comes back for that file. It used to
    /// re-install the identical candidate list forever.
    @MainActor
    @Test func tryAnotherAdvancesForTokenlessFilenames() async throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = UserDefaults(suiteName: "tryAnotherTokenless-\(UUID().uuidString)")!
        let first = FilingDestination(path: "/root/A", confidence: .medium, reasons: [], newSegments: [])
        let second = FilingDestination(path: "/root/B", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/root/Loose/IMG 0007.pdf", fileName: "IMG 0007.pdf", size: 1,
                                 modificationDate: nil, candidates: [first, second], providerRoot: "/root")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)
        #expect(manager.filingSuggestions.first?.best?.path == "/root/B", "first rejection advances to the next candidate")

        let advanced = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: advanced)
        // Both candidates rejected; no classifier is wired, so the card falls back to "Choose a folder…".
        #expect(manager.filingSuggestions.first?.candidates.isEmpty == true, "a rejected folder must never be re-offered")
    }

    // MARK: Remembered rules (F3)

    /// Points the manager's rule store at a throwaway suite so tests never touch standard defaults.
    @MainActor private func manager(withRuleSuite suite: String) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = UserDefaults(suiteName: suite)!
        return m
    }

    @MainActor
    @Test func applyingWithRememberPersistsAReusableRule() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Archive/Tesla/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(srcPath)

        let suite = "FilingRules-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { manager.filingRuleDefaults.removePersistentDomain(forName: suite) }

        // File it into Archive/Tesla and ask Filing to remember the correction.
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("Archive/Tesla").path,
                                     confidence: .high, reasons: [], newSegments: [])
        _ = await manager.applyFilingSuggestion(s, to: dest, remember: true)

        // A rule keyed on "tesla" now exists…
        #expect(manager.filingRules.count == 1)
        #expect(manager.filingRules.first?.tokens == ["tesla"])

        // …and a fresh scan of another Tesla file files it into that same remembered folder,
        // high-confidence & batch-eligible, carrying the "remembered" flag.
        try write(root.appendingPathComponent("Downloads/tesla renewal 2025.pdf"))
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let renewal = manager.filingSuggestions.first { $0.fileName.hasPrefix("tesla renewal") }
        #expect(renewal?.best?.path == root.appendingPathComponent("Archive/Tesla").path)
        #expect(renewal?.best?.remembered == true)
        #expect(renewal?.isBatchEligible == true)
    }

    @MainActor
    @Test func rulesAreScopedToTheProviderTheyPointInto() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/tesla thing.pdf"))

        let suite = "FilingRules-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { manager.filingRuleDefaults.removePersistentDomain(forName: suite) }
        // A rule whose destination lives in a DIFFERENT provider's tree must never fire here.
        manager.filingRules = [FilingRule(tokens: ["tesla"], destinationPath: "/SomeOtherProvider/Cars")]

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = manager.filingSuggestions.first { $0.fileName == "tesla thing.pdf" }
        #expect(!(s?.candidates.contains { $0.remembered } ?? false))
    }

    @MainActor
    @Test func rememberForgetAndClearRules() {
        let suite = "FilingRules-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { manager.filingRuleDefaults.removePersistentDomain(forName: suite) }

        #expect(manager.rememberFilingRule(fileName: "Tesla Policy.pdf", destinationPath: "/p/Vehicles/Tesla"))
        #expect(manager.rememberFilingRule(fileName: "Geico Bill.pdf", destinationPath: "/p/Insurance/Geico"))
        #expect(manager.filingRules.count == 2)

        // A nameless file (IMG_0007 → no usable tokens) yields nothing to key on — nothing remembered.
        #expect(manager.rememberFilingRule(fileName: "IMG_0007.pdf", destinationPath: "/p/Misc") == false)
        #expect(manager.filingRules.count == 2)

        // Re-teaching the same trigger replaces the destination rather than duplicating.
        _ = manager.rememberFilingRule(fileName: "Tesla Card.pdf", destinationPath: "/p/Cars/Tesla")
        #expect(manager.filingRules.count == 2)
        #expect(manager.filingRules.first { $0.tokens == ["tesla"] }?.destinationPath == "/p/Cars/Tesla")

        if let geico = manager.filingRules.first(where: { $0.tokens == ["geico"] }) {
            manager.forgetFilingRule(geico)
        }
        #expect(manager.filingRules.count == 1)

        manager.clearFilingRules()
        #expect(manager.filingRules.isEmpty)
    }

    @MainActor
    @Test func rejectionsPersistMatchAndClear() {
        let suite = "FilingRej-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)   // rejections share filingRuleDefaults
        defer { manager.filingRuleDefaults.removePersistentDomain(forName: suite) }

        #expect(manager.rememberFilingRejection(fileName: "Tesla Policy.pdf", destinationPath: "/p/Archive/Old"))
        #expect(manager.filingRejections.count == 1)
        // A same-signature file inherits the rejection; an unrelated one doesn't.
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Tesla Policy 2025.pdf", in: manager.filingRejections).contains("/p/Archive/Old"))
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Geico Bill.pdf", in: manager.filingRejections).isEmpty)
        // A nameless file can't seed a rejection.
        #expect(manager.rememberFilingRejection(fileName: "IMG_0007.pdf", destinationPath: "/p/x") == false)

        manager.clearFilingRejections()
        #expect(manager.filingRejections.isEmpty)
    }

    // MARK: Intelligent classifier (AI)

    @MainActor
    @Test func classifierVerdictDrivesTheSuggestion() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Physician's Report - Divit.pdf"))

        let manager = FileSyncManager()
        // A stand-in for the on-device model: it "reasons" Divit → Family/Divit.
        manager.filingClassifier = { taxonomy, files in
            #expect(taxonomy.contains("Documents/Family/Divit"))     // handed the real taxonomy
            var out: [String: FilingVerdict] = [:]
            for f in files where f.fileName.contains("Divit") {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s medical record")
            }
            return out
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let s = manager.filingSuggestions.first { $0.fileName.contains("Divit") }
        #expect(s?.best?.path == root.appendingPathComponent("Documents/Family/Divit").path)
        #expect(s?.best?.fromAI == true)
        #expect(s?.best?.reasons.first == "Divit’s medical record")
    }

    @MainActor
    @Test func aiToggleOffSkipsTheClassifier() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/mystery.pdf"))

        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { manager.filingContentDefaults.removePersistentDomain(forName: suite) }
        manager.filingContentDefaults.set(false, forKey: FileSyncManager.usesAIDefaultsKey)
        // A classifier that WOULD give a home — proving it isn't consulted when AI is off.
        let consulted = Flag()
        manager.filingClassifier = { _, files in
            consulted.value = true
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Documents", confidence: .high, reason: "x")) })
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(consulted.value == false)
        #expect(manager.filingSuggestions.first { $0.fileName == "mystery.pdf" }?.best?.fromAI != true)
    }

    // MARK: "Try another" (provider-scoped cache)

    /// The cached root/taxonomy for single-file re-asks must belong to THIS suggestion's provider:
    /// a scan of another provider (even a cancelled one) overwrites the cache, and resolving
    /// against it would move the file into the wrong provider's tree.
    @MainActor
    @Test func tryAnotherFolderIgnoresAnotherProvidersCachedTaxonomy() async throws {
        let manager = FileSyncManager()
        let consulted = Flag()
        manager.filingClassifier = { _, _ in consulted.value = true; return [:] }
        manager.filingLastProviderRoot = "/other"          // stale: another provider's scan
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0008.HEIC", fileName: "IMG_0008.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        #expect(consulted.value == false, "must not resolve against the wrong provider's taxonomy")
        #expect(manager.filingSuggestions.first?.candidates.isEmpty == true, "falls back to Choose a folder…")
    }

    @MainActor
    @Test func tryAnotherFolderReasksBackendWhenCacheMatchesProvider() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { manager.filingContentDefaults.removePersistentDomain(forName: suite) }
        manager.filingClassifier = { _, files in
            Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"              // cache belongs to this provider
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0009.HEIC", fileName: "IMG_0009.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.fromAI == true)
        #expect(best?.newSegments == ["Fresh"])
    }

    /// `filingScanFolder` labels what's ON SCREEN, so it publishes with the results — a cancelled
    /// rescan of a different folder must not relabel the previous results.
    @MainActor
    @Test func filingScanFolderLabelsResultsNotTheInFlightScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let downloads = root.appendingPathComponent("Downloads")
        let rootB = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: rootB) }

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(manager.filingScanFolder == downloads.path, "a completed scan labels its results")
        let suggestionsBefore = manager.filingSuggestions.map(\.id)

        // A rescan of a DIFFERENT folder, cancelled before it publishes.
        manager.startFindFilingSuggestions(folder: rootB.appendingPathComponent("Downloads"), providerRoot: rootB)
        manager.cancelFindFilingSuggestions()
        await manager.filingScanTask?.value

        #expect(manager.filingScanFolder == downloads.path, "the label must still match the on-screen results")
        #expect(manager.filingSuggestions.map(\.id) == suggestionsBefore)
    }
}
