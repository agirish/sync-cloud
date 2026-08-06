import Foundation
import Testing
@testable import Sync

/// Records what the classifier was asked — same shape as the verdict-cache tests' log, private to
/// each file because test targets share one namespace.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ names: [String]) { lock.lock(); defer { lock.unlock() }; calls.append(names) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

/// Counts spend-confirmer invocations — the line an auto-scan must never cross.
private final class PromptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var prompts: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Auto-rescan on lens open: Duplicates and Organize re-run a scan the user has run before,
/// provided it cannot cost money. Two contracts under test — **consent** (only the exact target
/// of the last COMPLETED scan is ever re-scanned unasked, and only when the app injected the
/// store that remembers it) and **money** (an Organize auto-scan must stop, prompting nothing,
/// the moment classification would reach the paid backend).
@Suite struct LensAutoRescanTests {

    private func write(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    // MARK: Duplicates

    /// A root with one duplicate pair, so a completed scan has a real group to publish.
    private func duplicateFixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "AutoRescanDup-\(name)")
        try write(root.appendingPathComponent("a/report.pdf"))
        try write(root.appendingPathComponent("b/report.pdf"))
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
        // The recorded target is CONSENT — "the user scanned exactly this" — and a scan that
        // never finished is not that.
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

        // The matching root starts a scan that really completes and publishes the group — the
        // outcome the feature exists for, not just a task having been spawned.
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
        // Same rule as the cache-store URLs: nil — what the CLI and bare test managers get —
        // means off, so nothing outside the real app ever reads or writes real defaults.
        let root = try duplicateFixture("nostore")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        #expect(!manager.autoRescanDuplicatesIfEligible(root: root))
        #expect(manager.duplicateScanTask == nil)
    }

    @MainActor
    @Test func oneAttemptPerTargetUntilAProviderSwitchRearms() async throws {
        // A cancelled attempt must not be retried by the next workspace switch — the triggers
        // overlap and would otherwise re-pay the walk each time — but a provider switch clears
        // the lens's results, and coming back should behave like a fresh launch.
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
        // Two panes on two providers is the ordinary way this app is used. With a single
        // remembered target, scanning the right pane silently withdrew consent for the left, and
        // the feature fired or didn't depending on which provider happened to be scanned last.
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
        // An unmounted cloud folder still scans "successfully" and publishes zero rows, and
        // "no duplicates found" is a very different claim from "not scanned" — it reads as a
        // result about the user's files. A manual scan may say it; an automatic one must not.
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
        let filing = filingManager(cacheAt: nil, log: CallLog(), identity: "on-device", store: defaults)
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        try FileManager.default.removeItem(at: downloads)
        #expect(!filing.autoRescanFilingIfEligible(folder: downloads, providerRoot: filingRoot))
    }

    @MainActor
    @Test func aManuallyCompletedScanIsNotRepeatedByTheTriggers() async throws {
        // The `hasCompleted` guard, as distinct from the attempt latch: a MANUAL scan never sets
        // the latch, so without this guard the next workspace switch would silently re-run a
        // scan whose results are already on screen — for both lenses.
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
        let filing = filingManager(cacheAt: nil, log: CallLog(), identity: "on-device", store: defaults)
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)

        await filing.findFilingSuggestions(folder: downloads, providerRoot: filingRoot)
        #expect(filing.hasSuggestedFiling)
        #expect(!filing.autoRescanFilingIfEligible(folder: downloads, providerRoot: filingRoot))
    }

    // MARK: Organize

    /// A taxonomy folder the classifier's fixed verdict points at, plus one loose file.
    private func filingFixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "AutoRescanFiling-\(name)")
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))
        return root
    }

    /// Records the tier every classification came in at, so a test can assert what a scan is
    /// allowed to reach and not merely that it reached something.
    private final class TierLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [FilingClassifierTier] = []
        func record(_ tier: FilingClassifierTier) { lock.lock(); seen.append(tier); lock.unlock() }
        var tiers: [FilingClassifierTier] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// A manager wired the way the **app** wires one: the identity resolver answers per tier, with
    /// `.free` pinned to on-device exactly as `SyncCloudApp` pins it. `identity` is therefore the
    /// REFINE identity — the only one a route can vary.
    ///
    /// Mirroring the app's shape here is the point. A helper that returned one identity for both
    /// tiers would be testing a wiring nothing ships, and would hide the case
    /// ``theFreePassIsSkippedRatherThanBilledIfTheAppMisroutesIt`` exists to catch.
    @MainActor
    private func filingManager(cacheAt url: URL?, log: CallLog, identity: String?,
                               store: UserDefaults?, tiers: TierLog? = nil,
                               freeIdentity: String? = FileSyncManager.onDeviceBackendIdentity) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        m.persistedUIStateDefaults = store
        m.filingBackendIdentity = { tier in tier == .refine ? identity : freeIdentity }
        m.filingClassifier = { _, files, tier in
            log.record(files.map(\.fileName))
            tiers?.record(tier)
            var out: [String: FilingVerdict] = [:]
            for f in files {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s record")
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
        let manager = filingManager(cacheAt: nil, log: CallLog(), identity: "on-device", store: defaults)

        #expect(defaults.array(forKey: FileSyncManager.lastFilingScanFolderKey) == nil)
        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(defaults.array(forKey: FileSyncManager.lastFilingScanFolderKey) as? [String] == [downloads.path])
    }

    @MainActor
    @Test func noScanEverReachesTheSpendPromptWhateverTheCloudSettingSays() async throws {
        // **The money contract, and it is now one sentence: a scan cannot spend.** This replaces a
        // pair of tests that pinned the old contract — an auto-scan predicting whether it would
        // reach the paid backend and stopping if so. That prediction had to agree with the app's
        // router and didn't (see `cloudEnabledWithoutAUsableKeyStillNeverPrompts`), and everything
        // it protected is now structural: the scan classifies at `.free`, which routes on-device.
        //
        // Both entry points, both cloud settings, one assertion — the confirmer is never called
        // and every classification came in at `.free`. The old version of this file needed six
        // tests to say less than this.
        for cloudOn in [false, true] {
            let root = try filingFixture("nospend-\(cloudOn)")
            defer { try? FileManager.default.removeItem(at: root) }
            try write(root.appendingPathComponent("Documents/trailing space /keep.txt"), bytes: 1)
            let downloads = root.appendingPathComponent("Downloads")
            let defaults = ScratchDefaults("autoFilingNoSpend-\(cloudOn)")
            defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
            let log = CallLog(), tiers = TierLog(), probe = PromptProbe()
            let settings = ScratchDefaults("autoFilingNoSpendSettings-\(cloudOn)")
            settings.set(cloudOn, forKey: FileSyncManager.usesCloudDefaultsKey)

            // Auto-started.
            let auto = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                     store: defaults, tiers: tiers)
            auto.filingContentDefaults = settings
            auto.filingCloudSpendConfirmer = { _ in probe.record(); return true }
            #expect(auto.autoRescanFilingIfEligible(folder: downloads, providerRoot: root,
                                                    nameProvider: .dropBox))
            await auto.filingScanTask?.value

            // Clicked.
            let manual = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                       store: nil, tiers: tiers)
            manual.filingContentDefaults = settings
            manual.filingCloudSpendConfirmer = { _ in probe.record(); return true }
            await manual.findFilingSuggestions(folder: downloads, providerRoot: root,
                                               nameProvider: .dropBox)

            #expect(probe.prompts == 0, "a scan raised a payment dialog (cloud on: \(cloudOn))")
            #expect(tiers.tiers == [.free, .free], "a scan classified off the free tier")
            // The positive control, and it is load-bearing: without it "no prompt" is equally
            // consistent with a scan that did nothing at all. Both scans classified, published,
            // and — the thing the old early stop had to suppress — reported the fixture's bad name.
            #expect(log.count == 2)
            #expect(auto.hasSuggestedFiling && manual.hasSuggestedFiling)
            #expect(!auto.riskyNames.isEmpty && !manual.riskyNames.isEmpty)
        }
    }

    @MainActor
    @Test func theFreePassIsSkippedRatherThanBilledIfTheAppMisroutesIt() async throws {
        // `.free` routing on-device is one line in `SyncCloudApp`, and nothing in `Sync` compiles
        // against it. So `Sync` asks the app what it will route `.free` to, and refuses to
        // classify when the answer is a paid backend — the guarantee is checked, not assumed.
        //
        // `freeIdentity` is the misrouting: an app that reports "cloud" for the free tier.
        let root = try filingFixture("misroute")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let log = CallLog(), probe = PromptProbe()
        let manager = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5",
                                    store: nil, freeIdentity: "cloud:claude-opus-5")
        manager.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)

        #expect(log.count == 0)     // the classifier was never called
        #expect(probe.prompts == 0)
        // Skipped, not failed: phases 1–2 still ran and published. The user loses the AI pass,
        // not the scan.
        #expect(manager.hasSuggestedFiling)
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.best?.fromAI != true)
    }

    @MainActor
    @Test func filingAutoRescanRunsWhenTheBackendIsFree() async throws {
        // The other half of the minimal pair: identical setup, on-device identity. The scan must
        // actually run to completion and publish — the positive control proving the decline
        // above is the identity's doing and not some other guard's.
        let root = try filingFixture("free")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingFree")
        let log = CallLog()
        let manager = filingManager(cacheAt: nil, log: log, identity: "on-device", store: defaults)

        // Until the store names exactly this folder, even a free backend is not consent.
        defaults.set(["/somewhere/else"], forKey: FileSyncManager.lastFilingScanFolderKey)
        #expect(!manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))

        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        #expect(manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await manager.filingScanTask?.value
        #expect(log.count == 1)
        #expect(manager.hasSuggestedFiling)
        #expect(manager.filingSuggestions.first?.best?.fromAI == true)
    }

    @MainActor
    @Test func anAutoRescanReusesTheCachedAnswersTheLastScanWrote() async throws {
        // The cache still earns its keep on the free pass — an unchanged file is not re-asked, so
        // the auto-rescan on lens open is close to instant instead of re-running the model over
        // the whole folder. Populated by a real scan rather than by hand, so the key construction
        // is checked against the scan's own rather than against a copy of it here.
        let root = try filingFixture("cached")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeCanonicalTempRoot(prefix: "AutoRescanCache").appendingPathComponent("verdicts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingCached")
        let log = CallLog()

        let first = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        await first.findFilingSuggestions(folder: downloads, providerRoot: root)
        FilingVerdictStore.waitForPendingWrites()
        #expect(log.count == 1)
        let firstResults = first.filingSuggestions

        // A fresh manager, standing in for the next launch.
        let next = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        #expect(next.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await next.filingScanTask?.value
        #expect(log.count == 1)                          // the model was never asked again
        #expect(next.filingSuggestions == firstResults)  // and the answer is the same one
        #expect(next.hasSuggestedFiling)
        #expect(next.filingLastCacheReuse == FileSyncManager.FilingCacheReuse(reused: 1, classified: 0))

        // A new file arrives overnight. It is a miss, so the scan asks about it — and, unlike
        // before the tier split, that is simply what happens: the answer is free, so there is
        // nothing to stop for. The old version of this test asserted the opposite.
        try write(downloads.appendingPathComponent("new-arrival.pdf"))
        let third = filingManager(cacheAt: url, log: log, identity: "on-device", store: defaults)
        #expect(third.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await third.filingScanTask?.value
        #expect(log.count == 2)
        #expect(third.hasSuggestedFiling)
        #expect(third.filingSuggestions.count == 2)
    }

    @MainActor
    @Test func cloudEnabledWithoutAUsableKeyStillNeverPrompts() async throws {
        // The state that killed the previous design, kept as a regression: cloud is ON in Settings
        // but the Keychain has no usable key, so the app's resolver reports the DOWNGRADE. The
        // scan is free, but `cloudSpendAllows` gates the confirmer on the SETTINGS TOGGLE rather
        // than the route — so anything that decided "free" from the route walked straight into a
        // payment dialog for a scan the user never asked for.
        //
        // It passes trivially now, and that is the result rather than a weakness of the test: the
        // scan never consults `cloudSpendAllows` at all. Kept because it is cheap and because it
        // is the exact state a future re-wiring would break first.
        let root = try filingFixture("downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingDowngrade")
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        let log = CallLog()
        let probe = PromptProbe()

        // Cloud ON, but the identity the app vouches for is the on-device downgrade.
        let manager = filingManager(cacheAt: nil, log: log, identity: "on-device", store: defaults)
        let scratch = ScratchDefaults("autoFilingDowngradeSettings")
        scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        manager.filingContentDefaults = scratch
        manager.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        _ = manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root)
        await manager.filingScanTask?.value
        #expect(probe.prompts == 0)   // no payment dialog, whatever the eligibility answer was
        #expect(manager.hasSuggestedFiling)   // and the scan ran, rather than declining to
    }
}
