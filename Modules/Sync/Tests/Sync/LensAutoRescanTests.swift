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
        manager.lensAutoRescanDefaults = defaults

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
        manager.lensAutoRescanDefaults = defaults

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
        manager.lensAutoRescanDefaults = defaults

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
        manager.lensAutoRescanDefaults = defaults
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
        manager.lensAutoRescanDefaults = defaults
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
        manager.lensAutoRescanDefaults = defaults
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
        manager.lensAutoRescanDefaults = defaults
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
        manager.lensAutoRescanDefaults = defaults
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

    @MainActor
    private func filingManager(cacheAt url: URL?, log: CallLog, identity: String?,
                               store: UserDefaults?) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        m.lensAutoRescanDefaults = store
        m.filingBackendIdentity = { identity }
        m.filingClassifier = { _, files in
            log.record(files.map(\.fileName))
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
    @Test func filingAutoRescanStopsWhenTheScanWouldCostMoney() async throws {
        // The heart of the money contract, as a minimal pair with the test below — the two
        // differ ONLY in what the backend identity resolves to. Cloud with an empty cache means
        // the one loose file would be sent, and paid for.
        //
        // Asserted on the OUTCOME, not on the eligibility answer: eligibility is now consent and
        // idempotence only, and the scan itself decides the money question. What the user must
        // never see is what is checked — no classifier call, nothing published, and (the point
        // of stopping this early) no risky-name finding either.
        let root = try filingFixture("paid")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/trailing space /keep.txt"), bytes: 1)
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingPaid")
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)
        let log = CallLog()
        let manager = filingManager(cacheAt: nil, log: log,
                                    identity: "cloud:claude-opus-5", store: defaults)

        manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root,
                                           nameProvider: .dropBox)
        await manager.filingScanTask?.value

        #expect(log.count == 0)                       // the paid backend was never consulted
        #expect(manager.filingSuggestions.isEmpty)
        #expect(!manager.hasSuggestedFiling)          // the lens stays on its intro card
        // **The stop is before the provider walk, so the name check never ran.** Publishing a
        // rename finding here would put "Fix all" — a bulk rename of the user's files — on
        // screen under an intro card saying nothing had been scanned. The fixture really does
        // contain a name Dropbox rejects, so this assertion can fail.
        #expect(manager.riskyNames.isEmpty)
        #expect(!manager.hasScannedNames)
        // Nothing was remembered either: a stopped scan is not consent.
        #expect(defaults.array(forKey: FileSyncManager.lastFilingScanFolderKey) as? [String]
                == [downloads.path])
    }

    @MainActor
    @Test func aManualScanOfTheSameFolderStillPromptsAndClassifies() async throws {
        // The positive control for the stop above, on the SAME fixture: without `autoFreeOnly`
        // the identical scan reaches the confirmer and the classifier, and publishes both the
        // suggestions and the name finding. Without this, "nothing happened" would be equally
        // consistent with a fixture that could never have produced anything.
        let root = try filingFixture("paid-manual")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/trailing space /keep.txt"), bytes: 1)
        let downloads = root.appendingPathComponent("Downloads")
        let log = CallLog()
        let probe = PromptProbe()
        let manager = filingManager(cacheAt: nil, log: log,
                                    identity: "cloud:claude-opus-5", store: nil)
        let scratch = ScratchDefaults("autoFilingPaidManual")
        scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        manager.filingContentDefaults = scratch
        manager.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        await manager.findFilingSuggestions(folder: downloads, providerRoot: root,
                                            nameProvider: .dropBox)

        #expect(probe.prompts == 1)
        #expect(log.count == 1)
        #expect(manager.hasSuggestedFiling)
        #expect(!manager.riskyNames.isEmpty)   // the fixture's bad name IS reportable
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
    @Test func filingAutoRescanRunsWhenEveryFileIsAlreadyCached() async throws {
        // Cloud backend, but a previous (manual, paid) scan cached the verdict for the one loose
        // file — so a rescan costs nothing and may auto-run. The cache is populated by a real
        // scan rather than by hand, so the pre-flight's key construction is checked against the
        // scan's own, not against a copy of it in the test.
        let root = try filingFixture("cached")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeCanonicalTempRoot(prefix: "AutoRescanCache").appendingPathComponent("verdicts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingCached")
        let log = CallLog()

        let paidScan = filingManager(cacheAt: url, log: log,
                                     identity: "cloud:claude-opus-5", store: defaults)
        await paidScan.findFilingSuggestions(folder: downloads, providerRoot: root)
        FilingVerdictStore.waitForPendingWrites()
        #expect(log.count == 1)
        let paidResults = paidScan.filingSuggestions

        // A fresh manager, standing in for the next launch.
        let next = filingManager(cacheAt: url, log: log,
                                 identity: "cloud:claude-opus-5", store: defaults)
        #expect(next.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await next.filingScanTask?.value
        #expect(log.count == 1)                          // the paid backend was never consulted
        #expect(next.filingSuggestions == paidResults)   // and the answer is the same one
        #expect(next.hasSuggestedFiling)

        // A new file arrives overnight: the folder is no longer fully answered, so the next
        // launch's scan stops instead of paying for it (fresh manager, because the completed run
        // above latched this one).
        try write(downloads.appendingPathComponent("new-arrival.pdf"))
        let blocked = filingManager(cacheAt: url, log: log,
                                    identity: "cloud:claude-opus-5", store: defaults)
        blocked.autoRescanFilingIfEligible(folder: downloads, providerRoot: root)
        await blocked.filingScanTask?.value
        #expect(log.count == 1)
        #expect(!blocked.hasSuggestedFiling)
    }

    @MainActor
    @Test func aCachedButNoLongerResolvableVerdictIsStoppedByThePhaseThreeCheck() async throws {
        // Why there are two stops. The early one runs before the taxonomy exists, so all it can
        // ask is whether a verdict is CACHED. A cached verdict whose destination no longer
        // resolves — its anchor folder deleted since — is a MISS at phase 3, and would be sent
        // and paid for. Only the second stop can see that, and this is the state that proves it
        // is not redundant.
        let root = try filingFixture("stale-anchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeCanonicalTempRoot(prefix: "AutoRescanStale").appendingPathComponent("verdicts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")
        let defaults = ScratchDefaults("autoFilingStale")
        let log = CallLog()
        let probe = PromptProbe()

        // A paid scan caches a verdict naming Documents/Family/Divit, which exists today.
        let paidScan = filingManager(cacheAt: url, log: log,
                                     identity: "cloud:claude-opus-5", store: defaults)
        await paidScan.findFilingSuggestions(folder: downloads, providerRoot: root)
        FilingVerdictStore.waitForPendingWrites()
        #expect(log.count == 1)

        // Documents/Family goes away, so the cached destination now proposes MORE new folders
        // than it did when cached — the staleness rule turns the hit into a miss.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents/Family"))

        let next = filingManager(cacheAt: url, log: log,
                                 identity: "cloud:claude-opus-5", store: defaults)
        let scratch = ScratchDefaults("autoFilingStaleSettings")
        scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        next.filingContentDefaults = scratch
        next.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        // The early stop lets it through — the key IS present — and phase 3 catches it.
        #expect(next.autoRescanFilingIfEligible(folder: downloads, providerRoot: root))
        await next.filingScanTask?.value
        #expect(probe.prompts == 0)
        #expect(log.count == 1)                 // still just the original paid call
        #expect(!next.hasSuggestedFiling)
    }

    @MainActor
    @Test func cloudEnabledWithoutAUsableKeyStillNeverPrompts() async throws {
        // THE case the first round's minimal pair could not see, because its two inputs moved
        // together: cloud is ON in Settings but the Keychain has no usable key, so the app's
        // resolver reports the DOWNGRADE — "on-device". The scan really is free, but
        // `cloudSpendAllows` gates the confirmer on the SETTINGS TOGGLE, not on the route, so
        // anything that decides "free" from the route alone walks straight into a payment
        // dialog raised by a scan the user never asked for.
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
    }

    @MainActor
    @Test func anAutoScanStopsBeforeTheSpendPromptEvenPastThePreflight() async throws {
        // The in-scan backstop, tested by driving the scan directly with `autoFreeOnly` — the
        // state the pre-flight cannot rule out (a file can change between pre-flight and phase
        // 3). The spend confirmer is the line that must not be crossed: an auto-scan popping a
        // payment prompt is the feature at its worst, worse than not existing.
        let root = try filingFixture("backstop")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let log = CallLog()

        let probe = PromptProbe()

        func cloudManager() -> FileSyncManager {
            let m = filingManager(cacheAt: nil, log: log, identity: "cloud:claude-opus-5", store: nil)
            let scratch = ScratchDefaults("autoFilingBackstop")
            scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
            m.filingContentDefaults = scratch
            m.filingCloudSpendConfirmer = { _ in probe.record(); return true }
            return m
        }

        // Auto: stops before the prompt, publishes nothing.
        let auto = cloudManager()
        await auto.findFilingSuggestions(folder: downloads, providerRoot: root, autoFreeOnly: true)
        #expect(probe.prompts == 0)
        #expect(log.count == 0)
        #expect(!auto.hasSuggestedFiling)
        #expect(auto.filingSuggestions.isEmpty)

        // Manual control: the same scan without the flag prompts and proceeds — proving the
        // stop above was `autoFreeOnly`'s doing, not the confirmer never being reachable.
        let manual = cloudManager()
        await manual.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(probe.prompts == 1)
        #expect(log.count == 1)
        #expect(manual.hasSuggestedFiling)
    }
}
