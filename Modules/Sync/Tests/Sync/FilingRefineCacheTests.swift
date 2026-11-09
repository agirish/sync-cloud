import Foundation
import Testing
@testable import Sync

/// Refine's saved answers (TE335, E3): any Claude model's answer counts, the page going is part of
/// the question, an answer naming a hidden folder is not a hit, and answers written before this
/// change are neither trusted as Claude's nor lost for the on-device model.
@MainActor
@Suite struct FilingRefineCacheTests {

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [[String]] = []
        func record(_ files: [FilingCandidateFile]) { lock.withLock { names.append(files.map(\.fileName).sorted()) } }
        var all: [[String]] { lock.withLock { names } }
    }

    private func fixture(_ name: String) throws -> URL { try refineFixture(prefix: "RefineCache-\(name)", looseFiles: 2) }

    /// Claude (via `filingRefineClassifier`) answers Archive/2026 for everything. `identity` is the
    /// backend identity the app would report; a test changes it between passes to change the model.
    private func manager(_ asked: Asked, cacheDir: URL, reads: Bool = false) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefineCacheTests-\(UUID().uuidString)")
        m.filingContentDefaults.set(reads, forKey: FileSyncManager.readContentsDefaultsKey)
        m.filingVerdictCacheURL = cacheDir.appendingPathComponent("verdicts.json")
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingCloudSpendConfirmer = { _ in true }
        if reads { m.filingSnippetExtractor = { _ in "page one text" } }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map { ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "free")) })
        }
        m.filingRefineClassifier = { _, files in
            asked.record(files)
            return FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        return m
    }

    private func scan(_ m: FileSyncManager, root: URL) async {
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
    }

    // MARK: Any Claude model counts

    @Test func changingTheClaudeModelDoesNotAskEveryFileAgain() async throws {
        let root = try fixture("model"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCanonicalTempRoot(prefix: "RefineCacheDir"); defer { try? FileManager.default.removeItem(at: cache) }
        let asked = Asked()
        let m = manager(asked, cacheDir: cache)
        await scan(m, root: root)
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()
        #expect(asked.all.count == 1)

        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-sonnet-5" : FileSyncManager.onDeviceBackendIdentity }
        let second = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(second.reused == 2 && asked.all.count == 1, "another Claude model's answers count as answered")
    }

    @Test func theOnDeviceModelsAnswersAreNotClaudes() {
        let m = manager(Asked(), cacheDir: URL(fileURLWithPath: "/nonexistent"))
        #expect(m.resolvedFilingVerdictIdentity(for: .refine) == FilingVerdictKey.claudeIdentity)
        #expect(m.resolvedFilingVerdictIdentity(for: .free) == FileSyncManager.onDeviceBackendIdentity)
        m.filingBackendIdentity = { _ in "cloud:claude-haiku-4-5" }
        #expect(m.resolvedFilingVerdictIdentity(for: .refine) == FilingVerdictKey.claudeIdentity)
        m.filingContentDefaults.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        #expect(m.resolvedFilingVerdictIdentity(for: .refine) == nil, "reuse off: no identity, no cache")
    }

    // MARK: The page going is part of the question

    @Test func anAnswerGivenWithThePageAlsoAnswersANameOnlyPassButNotTheReverse() async throws {
        let root = try fixture("page"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCanonicalTempRoot(prefix: "RefineCacheDir"); defer { try? FileManager.default.removeItem(at: cache) }
        let asked = Asked()
        // First, the page goes.
        let withPage = manager(asked, cacheDir: cache, reads: true)
        AskClaudePrivacy.shareWithoutAsking(root.path, in: withPage.filingContentDefaults)   // so its page goes
        await scan(withPage, root: root)
        _ = await withPage.refineFilingSuggestions(withPage.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()
        #expect(asked.all.count == 1)

        // A name-only pass reuses it.
        let nameOnly = manager(asked, cacheDir: cache, reads: false)
        await scan(nameOnly, root: root)
        let reused = try #require(await nameOnly.refineFilingSuggestions(nameOnly.filingSuggestions))
        #expect(reused.reused == 2 && asked.all.count == 1, "the page-sent answer counts for a name-only pass")
    }

    @Test func aNameOnlyAnswerIsNotReplayedForAPassThatSendsThePage() async throws {
        let root = try fixture("nameonly"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCanonicalTempRoot(prefix: "RefineCacheDir"); defer { try? FileManager.default.removeItem(at: cache) }
        let asked = Asked()
        let nameOnly = manager(asked, cacheDir: cache, reads: false)
        await scan(nameOnly, root: root)
        _ = await nameOnly.refineFilingSuggestions(nameOnly.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()
        #expect(asked.all.count == 1)

        let withPage = manager(asked, cacheDir: cache, reads: true)
        AskClaudePrivacy.shareWithoutAsking(root.path, in: withPage.filingContentDefaults)   // so its page goes
        await scan(withPage, root: root)
        let summary = try #require(await withPage.refineFilingSuggestions(withPage.filingSuggestions))
        #expect(summary.reused == 0 && asked.all.count == 2, "the page changes the question, so it is asked again")
    }

    // MARK: A hit naming a hidden folder is a miss

    @Test func aSavedAnswerNamingAHiddenFolderIsAskedAgainNotDropped() async throws {
        let root = try fixture("hidden"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCanonicalTempRoot(prefix: "RefineCacheDir"); defer { try? FileManager.default.removeItem(at: cache) }
        let asked = Asked()
        let m = manager(asked, cacheDir: cache)
        await scan(m, root: root)
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()

        // The control: unchanged, the second pass is answered from the saved answers.
        let control = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(control.reused == 2 && asked.all.count == 1)

        // Archive is hidden now: the saved answers name it, so they are not hits.
        AskClaudePrivacy.setHiddenFolders([root.appendingPathComponent("Archive").path], in: m.filingContentDefaults)
        let after = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(after.reused == 0 && asked.all.count == 2, "asked again, not silently dropped")
    }

    // MARK: Old files

    /// A cache file written before this change: its Claude entry (keyed `cloud:<model>`, with no
    /// `pageSent`) is never matched again, and its on-device entry still is.
    @Test func anOldCacheFileLoadsOnDeviceAnswersStillHitAndOldClaudeAnswersDoNot() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        func oldEntry(model: String, path: String) -> [String: Any] {
            ["key": ["filePath": "/r/a.pdf", "modifiedMillis": 1_800_000_000_000, "size": 10, "model": model,
                     "promptVersion": 7, "excludedRelativePaths": [], "artifacts": "x"],
             "relativePath": path, "confidence": "high", "reason": "r", "newSegmentCount": 0,
             "cachedAt": when.timeIntervalSinceReferenceDate]
        }
        let file: [String: Any] = ["schema": 1, "entries": [oldEntry(model: "on-device", path: "Documents"),
                                                              oldEntry(model: "cloud:claude-opus-5", path: "Archive")]]
        let data = try JSONSerialization.data(withJSONObject: file)
        let cache = try JSONDecoder().decode(FilingVerdictCache.self, from: data)
        #expect(cache.count == 2, "the file loads")

        func key(_ model: String, pageSent: Bool = false) -> FilingVerdictKey? {
            FilingVerdictKey(filePath: "/r/a.pdf", modificationDate: Date(timeIntervalSince1970: 1_800_000_000), size: 10, model: model,
                             promptVersion: 7, artifacts: "x", pageSent: pageSent)
        }
        let existing: Set<String> = ["Documents", "Archive"]
        #expect(cache.verdict(for: try #require(key("on-device")), providerRoot: "/r", existingRelative: existing) != nil,
                "the on-device model's answer still hits")
        #expect(cache.verdict(for: try #require(key(FilingVerdictKey.claudeIdentity)), providerRoot: "/r", existingRelative: existing) == nil,
                "a Claude answer written before this change is not Claude's now")
    }

    @Test func thePageFieldRoundTripsAndDefaultsToFalse() throws {
        let key = try #require(FilingVerdictKey(filePath: "/a", modificationDate: Date(timeIntervalSince1970: 5), size: 1,
                                                model: "claude", promptVersion: 7, artifacts: "", pageSent: true))
        let again = try JSONDecoder().decode(FilingVerdictKey.self, from: JSONEncoder().encode(key))
        #expect(again == key && again.pageSent)
        #expect(key.withPageSent(false).pageSent == false && key.withPageSent(false) != key)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
        json["pageSent"] = nil
        let old = try JSONDecoder().decode(FilingVerdictKey.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.pageSent == false, "an entry written before the field decodes as no page sent")
    }

    // MARK: The request

    /// Refine runs on the chat's model (E4), so every request is the 5.5 shape, streamed.
    @Test func refineSendsTheFiveFiveRequestToEveryModelAskClaudeOffers() {
        for option in AskClaudeModels.options {
            let shape = CloudFilingProtocol.RequestShape.current(for: option)
            #expect(shape.toolChoice == .auto && shape.stream, "\(option.id)")
        }
    }
}
