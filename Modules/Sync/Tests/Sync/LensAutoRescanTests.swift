import Foundation
import Testing
@testable import Sync

/// What the classifier was asked, and how often the spend confirmer was: the line an auto-scan
/// must never cross.
private typealias CallLog = LockedBox<[[String]]>
private typealias PromptProbe = LockedBox<Int>

/// Auto-rescan on lens open: Duplicates and Organize re-run a scan the user has run before,
/// provided it can't cost money. Two contracts: consent (only the exact target of a completed
/// scan is re-scanned unasked, and only when the app injected the store that remembers it) and
/// money (no scan, automatic or clicked, ever reaches the spend prompt).
@Suite struct LensAutoRescanTests {

    // MARK: Duplicates

    /// A root with one duplicate pair, so a completed scan has a real group to publish.
    private func duplicateFixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "AutoRescanDup-\(name)")
        try writeBytes(root.appendingPathComponent("a/report.pdf"))
        try writeBytes(root.appendingPathComponent("b/report.pdf"))
        return root
    }

    @MainActor
    @Test func aCompletedDuplicateScanRecordsItsRootForNextLaunch() async throws {
        let root = try duplicateFixture("records")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        let defaults = ScratchDefaults("autoRescanRecords")
        manager.persistedUIStateDefaults = defaults

        #expect(defaults.array(forKey: FileSyncManager.lastDuplicatesScanRootKey) == nil)
        await manager.findDuplicates(root: root, cache: nil)
        #expect(defaults.array(forKey: FileSyncManager.lastDuplicatesScanRootKey) as? [String] == [root.path])
    }

    @MainActor
    @Test func aCancelledDuplicateScanRecordsNothing() async throws {
        // The recorded target is consent ("the user scanned exactly this"), and a scan that never
        // finished is not that.
        let root = try duplicateFixture("cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        let defaults = ScratchDefaults("autoRescanCancelled")
        manager.persistedUIStateDefaults = defaults

        manager.startFindDuplicates(root: root)
        manager.cancelFindDuplicates()
        await manager.duplicateScanTask?.value
        #expect(defaults.array(forKey: FileSyncManager.lastDuplicatesScanRootKey) == nil)
    }

    @MainActor
    @Test func duplicatesAutoRescanRunsOnlyForTheRecordedRoot() async throws {
        let root = try duplicateFixture("eligible")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        let defaults = ScratchDefaults("autoRescanEligible")
        manager.persistedUIStateDefaults = defaults

        // A different recorded root is someone else's consent.
        defaults.set(["/somewhere/else"], forKey: FileSyncManager.lastDuplicatesScanRootKey)
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))
        #expect(manager.duplicateScanTask == nil)

        // The matching root starts a scan that really completes and publishes the group, not just
        // a spawned task.
        defaults.set([root.path], forKey: FileSyncManager.lastDuplicatesScanRootKey)
        #expect(manager.autoRescanDuplicatesIfEligible(root: root))
        await manager.duplicateScanTask?.value
        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.count == 1)

        // Completed-this-session declines: the results on screen are already current.
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))
    }

    @MainActor
    @Test func withoutAnInjectedStoreTheFeatureIsOff() async throws {
        // As with the cache-store URLs, nil (what the CLI and bare test managers get) means off,
        // so nothing outside the real app reads or writes real defaults.
        let root = try duplicateFixture("nostore")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))
        #expect(manager.duplicateScanTask == nil)
    }

    @MainActor
    @Test func oneAttemptPerTargetUntilAProviderSwitchRearms() async throws {
        // A cancelled attempt must not be retried by the next workspace switch, since the triggers
        // overlap and would re-pay the walk each time. A provider switch clears the lens's results,
        // though, and coming back should behave like a fresh launch.
        let root = try duplicateFixture("latch")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        let defaults = ScratchDefaults("autoRescanLatch")
        manager.persistedUIStateDefaults = defaults
        defaults.set([root.path], forKey: FileSyncManager.lastDuplicatesScanRootKey)

        #expect(manager.autoRescanDuplicatesIfEligible(root: root))
        manager.cancelFindDuplicates()
        await manager.duplicateScanTask?.value
        #expect(!manager.hasFoundDuplicates)                          // it really was cancelled
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))  // latched, not retried

        manager.clearDuplicates()
        #expect(manager.autoRescanDuplicatesIfEligible(root: root))   // re-armed
        await manager.duplicateScanTask?.value
        #expect(manager.duplicateGroups.count == 1)
    }

    @MainActor
    @Test func scanningASecondProviderDoesNotWithdrawTheFirstsConsent() async throws {
        // Two panes on two providers is the ordinary way the app is used, so scanning the right
        // pane must not withdraw consent for the left: several targets are remembered, not one.
        let first = try duplicateFixture("provider-a")
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try duplicateFixture("provider-b")
        defer { try? FileManager.default.removeItem(at: second) }
        let defaults = ScratchDefaults("autoRescanTwoProviders")

        let manager = FileSyncManager()
        manager.persistedUIStateDefaults = defaults
        await manager.findDuplicates(root: first, cache: nil)
        manager.clearDuplicates()                       // the provider switch
        await manager.findDuplicates(root: second, cache: nil)
        manager.clearDuplicates()                       // …and back

        #expect(manager.autoRescanDuplicatesIfEligible(root: first))
        await manager.duplicateScanTask?.value
        #expect(manager.duplicateGroups.count == 1)
    }

    @MainActor
    @Test func onlyTheMostRecentTargetsAreRemembered() async throws {
        let defaults = ScratchDefaults("autoRescanTargetCap")
        let manager = FileSyncManager()
        manager.persistedUIStateDefaults = defaults
        let key = FileSyncManager.lastDuplicatesScanRootKey

        for i in 0...(FileSyncManager.maxRememberedScanTargets) {
            manager.rememberLensScanTarget("/root\(i)", forKey: key)
        }
        let remembered = defaults.array(forKey: key) as? [String] ?? []
        #expect(remembered.count == FileSyncManager.maxRememberedScanTargets)
        #expect(!remembered.contains("/root0"))                                   // oldest dropped
        #expect(remembered.first == "/root\(FileSyncManager.maxRememberedScanTargets)")

        // Re-scanning a remembered target moves it to the front rather than duplicating it.
        manager.rememberLensScanTarget("/root1", forKey: key)
        let after = defaults.array(forKey: key) as? [String] ?? []
        #expect(after.filter { $0 == "/root1" }.count == 1)
        #expect(after.first == "/root1")
    }

    @MainActor
    @Test func aRememberedTargetThatIsGoneIsNotScannedIntoAnEmptyResult() async throws {
        // An unmounted cloud folder still scans "successfully" and publishes zero rows, and "no
        // duplicates found" reads as a result about the user's files. A manual scan may say it;
        // an automatic one must not.
        let root = try duplicateFixture("vanished")
        let defaults = ScratchDefaults("autoRescanVanished")
        let manager = FileSyncManager()
        manager.persistedUIStateDefaults = defaults
        await manager.findDuplicates(root: root, cache: nil)
        manager.clearDuplicates()

        try FileManager.default.removeItem(at: root)
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))
        #expect(!manager.hasFoundDuplicates)

        // Filing declines on the same ground.
        let filingRoot = try filingFixture("vanished")
        defer { try? FileManager.default.removeItem(at: filingRoot) }
        let downloads = filingRoot.appendingPathComponent("Downloads")
        let filing = filingManager(cacheAt: nil, log: CallLog([]), identity: "on-device", store: defaults)
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        try FileManager.default.removeItem(at: downloads)
        #expect(!filing.autoRescanFilingIfEligible(folder: downloads, providerRoot: filingRoot))
    }

    @MainActor
    @Test func aManuallyCompletedScanIsNotRepeatedByTheTriggers() async throws {
        // The `hasCompleted` guard, distinct from the attempt latch: a manual scan never sets the
        // latch, so without this guard the next workspace switch would re-run a scan whose results
        // are already on screen, for both lenses.
        let root = try duplicateFixture("manual")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        let defaults = ScratchDefaults("autoRescanManual")
        manager.persistedUIStateDefaults = defaults
        defaults.set([root.path], forKey: FileSyncManager.lastDuplicatesScanRootKey)

        await manager.findDuplicates(root: root, cache: nil)
        #expect(manager.hasFoundDuplicates)
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))

        let filingRoot = try filingFixture("manual")
        defer { try? FileManager.default.removeItem(at: filingRoot) }
        let downloads = filingRoot.appendingPathComponent("Downloads")
        let filing = filingManager(cacheAt: nil, log: CallLog([]), identity: "on-device", store: defaults)
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)

        await filing.findFilingSuggestions(folder: downloads, providerRoot: filingRoot)
        #expect(filing.hasSuggestedFiling)
        #expect(!filing.autoRescanFilingIfEligible(folder: downloads, providerRoot: filingRoot))
    }

    // MARK: Organize

    /// A taxonomy folder the classifier's fixed verdict points at, plus one loose file.
    private func filingFixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "AutoRescanFiling-\(name)")
        try writeBytes(root.appendingPathComponent("Documents/Family/Son/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))
        return root
    }

    /// Records the tier every classification came in at, so a test can assert what a scan is
    /// allowed to reach and not merely that it reached something.
    private typealias TierLog = LockedBox<[FilingClassifierTier]>

    /// A manager wired the way the app wires one: the identity resolver answers per tier, with
    /// `.free` pinned to on-device as `SyncCloudApp` pins it, so `identity` is the refine identity.
    /// One identity for both tiers would test a wiring nothing ships, and would hide the case
    /// ``theFreePassIsSkippedRatherThanBilledIfTheAppMisroutesIt`` catches.
    @MainActor
    private func filingManager(cacheAt url: URL?, log: CallLog, identity: String?,
                               store: UserDefaults?, tiers: TierLog? = nil,
                               freeIdentity: String? = FileSyncManager.onDeviceBackendIdentity) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        m.persistedUIStateDefaults = store
        m.filingBackendIdentity = { tier in tier == .refine ? identity : freeIdentity }
        m.filingClassifier = { _, files, tier in
            log.withLock { $0.append(files.map(\.fileName)) }
            tiers?.withLock { $0.append(tier) }
            var out: [String: FilingVerdict] = [:]
            for f in files {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Son",
                                                confidence: .high, reason: "Son’s record")
            }
            return out
        }
        return m
    }

    @MainActor
    @Test func aCompletedFilingScanRecordsItsFolderForNextLaunch() async throws {
        let root = try filingFixture("records")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingRecords")
        let manager = filingManager(cacheAt: nil, log: CallLog([]), identity: "on-device", store: defaults)

        #expect(defaults.array(forKey: FileSyncManager.lastFilingScanFolderKey) == nil)
        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(defaults.array(forKey: FileSyncManager.lastFilingScanFolderKey) as? [String] == [downloads.path])
    }

    @MainActor
    @Test func noScanEverReachesTheSpendPromptWhateverTheCloudSettingSays() async throws {
        // The money contract: a scan can't spend. It classifies at `.free`, which routes
        // on-device, so it never needs to predict whether it would reach the paid backend. Both
        // entry points, both cloud settings, one assertion: the confirmer is never called and every
        // classification came in at `.free`.
        for cloudOn in [false, true] {
            let root = try filingFixture("nospend-\(cloudOn)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeBytes(root.appendingPathComponent("Documents/trailing space /keep.txt"), bytes: 1)
            let downloads = root.appendingPathComponent("Downloads")
            let defaults = ScratchDefaults("autoFilingNoSpend-\(cloudOn)")
            defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
            let log = CallLog([]), tiers = TierLog([]), probe = PromptProbe(0)
            let settings = ScratchDefaults("autoFilingNoSpendSettings-\(cloudOn)")

            // Auto-started.
            let auto = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                     store: defaults, tiers: tiers)
            auto.filingContentDefaults = settings
            auto.filingCloudRefineConfigured = { cloudOn }
            auto.filingCloudSpendConfirmer = { _ in probe.withLock { $0 += 1 }; return true }
            #expect(auto.autoRescanFilingIfEligible(folder: downloads, providerRoot: root,
                                                    nameProvider: .dropBox))
            await auto.filingScanTask?.value

            // Clicked.
            let manual = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                       store: nil, tiers: tiers)
            manual.filingContentDefaults = settings
            manual.filingCloudSpendConfirmer = { _ in probe.withLock { $0 += 1 }; return true }
            await manual.findFilingSuggestions(folder: downloads, providerRoot: root,
                                               nameProvider: .dropBox)

            #expect(probe.withLock { $0 } == 0, "a scan raised a payment dialog (cloud on: \(cloudOn))")
            #expect(tiers.withLock { $0 } == [.free, .free], "a scan classified off the free tier")
            // The positive control: without it "no prompt" is equally consistent with a scan that
            // did nothing. Both scans classified, published, and reported the fixture's bad name.
            #expect(log.withLock { $0.count } == 2)
            #expect(auto.hasSuggestedFiling && manual.hasSuggestedFiling)
            #expect(!auto.riskyNames.isEmpty && !manual.riskyNames.isEmpty)
        }
    }

    @MainActor
    @Test func theFreePassIsSkippedRatherThanBilledIfTheAppMisroutesIt() async throws {
        // `.free` routing on-device is one line in `SyncCloudApp`, and nothing in `Sync` compiles
        // against it. So `Sync` asks the app what it will route `.free` to, and refuses to classify
        // when the answer is a paid backend. `freeIdentity` here is that misrouting.
        let root = try filingFixture("misroute")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let log = CallLog([]), probe = PromptProbe(0)
        let manager = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                    store: nil, freeIdentity: "cloud:claude-opus-5")
        manager.filingCloudSpendConfirmer = { _ in probe.withLock { $0 += 1 }; return true }

        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)

        #expect(log.withLock { $0.count } == 0)     // the classifier was never called
        #expect(probe.withLock { $0 } == 0)
        // Skipped, not failed: phases 1–2 still ran and published. The user loses the AI pass, not
        // the scan.
        #expect(manager.hasSuggestedFiling)
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.best?.fromAI != true)
    }

    @MainActor
    @Test func filingAutoRescanRunsWhenTheBackendIsFree() async throws {
        // The positive control: with an on-device identity the auto-rescan runs to completion and
        // publishes, so the declines elsewhere are not some other guard's doing.
        let root = try filingFixture("free")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingFree")
        let log = CallLog([])
        let manager = filingManager(cacheAt: nil, log: log, identity: "on-device", store: defaults)

        // Until the store names exactly this folder, even a free backend is not consent.
        defaults.set(["/somewhere/else"], forKey: FileSyncManager.lastFilingScanFolderKey)
        #expect(!manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))

        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        #expect(manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await manager.filingScanTask?.value
        #expect(log.withLock { $0.count } == 1)
        #expect(manager.hasSuggestedFiling)
        #expect(manager.filingSuggestions.first?.best?.fromAI == true)
    }

    @MainActor
    @Test func anAutoRescanReusesTheCachedAnswersTheLastScanWrote() async throws {
        // The cache still earns its keep on the free pass: an unchanged file isn't re-asked, so the
        // auto-rescan on lens open is close to instant. Populated by a real scan, so the key
        // construction is the scan's own, not a copy of it here.
        let root = try filingFixture("cached")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeCanonicalTempRoot(prefix: "AutoRescanCache").appendingPathComponent("verdicts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingCached")
        let log = CallLog([])

        let first = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        await first.findFilingSuggestions(folder: downloads, providerRoot: root)
        FilingVerdictStore.waitForPendingWrites()
        #expect(log.withLock { $0.count } == 1)
        let firstResults = first.filingSuggestions

        // A fresh manager, standing in for the next launch.
        let next = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        #expect(next.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await next.filingScanTask?.value
        #expect(log.withLock { $0.count } == 1)                          // the model was never asked again
        #expect(next.filingSuggestions == firstResults)  // and the answer is the same one
        #expect(next.hasSuggestedFiling)
        #expect(next.filingLastCacheReuse == FileSyncManager.FilingCacheReuse(reused: 1, classified: 0))

        // A new file arrives overnight. It is a miss, so the scan asks about it: the answer is
        // free, so there is nothing to stop for.
        try writeBytes(downloads.appendingPathComponent("new-arrival.pdf"))
        let third = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        #expect(third.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await third.filingScanTask?.value
        #expect(log.withLock { $0.count } == 2)
        #expect(third.hasSuggestedFiling)
        #expect(third.filingSuggestions.count == 2)
    }

    @MainActor
    @Test func cloudEnabledWithoutAUsableKeyStillNeverPrompts() async throws {
        // Cloud is on in Settings but the Keychain has no usable key, so the app's resolver reports
        // the on-device downgrade. `cloudSpendAllows` gates the confirmer on the settings toggle, not
        // the route, so anything that judged "free" from the route would raise a payment dialog for
        // a scan the user never asked for. It passes trivially because the scan never consults
        // `cloudSpendAllows`; kept because it is the state a re-wiring would break first.
        let root = try filingFixture("downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingDowngrade")
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        let log = CallLog([])
        let probe = PromptProbe(0)

        // Cloud ON, but the identity the app vouches for is the on-device downgrade.
        let manager = filingManager(cacheAt: nil, log: log, identity: "on-device", store: defaults)
        let scratch = ScratchDefaults("autoFilingDowngradeSettings")
        manager.filingContentDefaults = scratch
        manager.filingCloudRefineConfigured = { true }
        manager.filingCloudSpendConfirmer = { _ in probe.withLock { $0 += 1 }; return true }

        _ = manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root)
        await manager.filingScanTask?.value
        #expect(probe.withLock { $0 } == 0)   // no payment dialog, whatever the eligibility answer was
        #expect(manager.hasSuggestedFiling)   // and the scan ran, rather than declining to
    }
}
