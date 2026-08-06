import Foundation
import Testing
@testable import Sync

/// Organize's second pass — the opt-in one that can spend money.
///
/// The suite is organized around the three things that make the refine pass different from the
/// scan it improves: it acts on a list already on screen (so a stale result must be dropped, not
/// applied), it is priced per file (so its scope and its count must be one value), and it is the
/// only Filing path that reaches a paid backend (so what it excludes is a cost question, not a
/// tidiness one).
@Suite struct FilingRefineTests {

    /// What the classifier was asked, and at which tier.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(names: [String], tier: FilingClassifierTier)] = []
        func record(_ names: [String], _ tier: FilingClassifierTier) {
            lock.lock(); defer { lock.unlock() }; calls.append((names, tier))
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var refines: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return calls.filter { $0.tier == .refine }.map { $0.names.sorted() }
        }
        var tiers: [FilingClassifierTier] {
            lock.lock(); defer { lock.unlock() }; return calls.map { $0.tier }
        }
    }

    private func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A provider with two destination folders and `count` loose files. Two folders is the point:
    /// the free pass and the refine pass can then disagree, which is what makes "changed" testable.
    private func fixture(_ name: String, looseFiles count: Int = 2) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "Refine-\(name)")
        try write(root.appendingPathComponent("Documents/Family/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        for i in 0..<count { try write(root.appendingPathComponent("Downloads/mystery-\(i).pdf")) }
        return root
    }

    /// `freeDestination` is what the scan's classifier answers, `refineDestination` what the refine
    /// pass answers. Different values are what let a test see the refine actually landing rather
    /// than merely running.
    @MainActor
    private func manager(_ asked: Asked, freeDestination: String = "Documents/Family",
                         refineDestination: String = "Archive/2026") -> FileSyncManager {
        let m = FileSyncManager()
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingClassifier = { _, files, tier in
            asked.record(files.map(\.fileName), tier)
            let dest = tier == .refine ? refineDestination : freeDestination
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: dest, confidence: .high, reason: "test"))
            })
        }
        return m
    }

    /// Scans, and returns the folder that was scanned.
    @MainActor
    private func scan(_ m: FileSyncManager, root: URL) async -> URL {
        let downloads = root.appendingPathComponent("Downloads")
        await m.findFilingSuggestions(folder: downloads, providerRoot: root)
        return downloads
    }

    // MARK: The happy path

    @MainActor
    @Test func refiningReplacesTheFreePassesHomesAndReportsWhatChanged() async throws {
        let root = try fixture("happy")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)
        _ = await scan(m, root: root)

        // The free pass placed both files, on-device.
        #expect(m.filingSuggestions.count == 2)
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Documents/Family") == true })
        #expect(m.filingLastRefine == nil)

        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))

        #expect(asked.tiers == [.free, .refine])
        #expect(asked.refines == [["mystery-0.pdf", "mystery-1.pdf"]])
        #expect(summary == FileSyncManager.FilingRefineSummary(asked: 2, reused: 0,
                                                               classified: 2, changed: 2))
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Archive/2026") == true })
        #expect(m.filingLastRefine == summary)
        #expect(!m.isRefiningFilingSuggestions)
    }

    @MainActor
    @Test func aRefineThatFindsNothingBetterIsReportedAsChangingNothing() async throws {
        // The honest-headline case: the pass ran, was billed, and moved nothing. Reporting
        // `asked` as the achievement would read as two improvements that did not happen.
        let root = try fixture("nochange")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked, freeDestination: "Documents/Family", refineDestination: "Documents/Family")
        _ = await scan(m, root: root)
        let before = m.filingSuggestions

        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(summary.classified == 2)
        #expect(summary.changed == 0)
        #expect(m.filingSuggestions == before)
    }

    @MainActor
    @Test func theListStaysOnScreenWhileRefining() async throws {
        // `isSuggestingFiles` swaps the lens to its scanning view. A refine that set it would take
        // the list away and put it back changed — the one thing "refine what I'm looking at" must
        // not do. Observed from INSIDE the classifier, mid-pass: nothing asserted afterwards can
        // see a flag that was set and cleared.
        let root = try fixture("onscreen")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)
        _ = await scan(m, root: root)

        final class Observed: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (scanning: Bool, refining: Bool, rows: Int)?
            func set(_ v: (Bool, Bool, Int)) { lock.lock(); defer { lock.unlock() }; value = v }
            var seen: (scanning: Bool, refining: Bool, rows: Int)? {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let observed = Observed()
        m.filingClassifier = { _, _, _ in
            await MainActor.run {
                observed.set((m.isSuggestingFiles, m.isRefiningFilingSuggestions,
                              m.filingSuggestions.count))
            }
            return [:]
        }

        await m.refineFilingSuggestions(m.filingSuggestions)
        let seen = try #require(observed.seen)
        #expect(!seen.scanning)     // the lens never showed its scanning view
        #expect(seen.refining)      // …but the button knew it was busy
        #expect(seen.rows == 2)     // and the rows were still there to look at
    }

    // MARK: Scope

    @MainActor
    @Test func refiningActsOnTheListItWasHandedNotTheWholeQueue() async throws {
        // A search can narrow the rows, and the button's count comes from those rows. Sending more
        // than was counted means billing for files the user could not see — the same rule
        // `applyRecommendedFiling` follows, with money attached.
        let root = try fixture("scope", looseFiles: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)
        _ = await scan(m, root: root)
        #expect(m.filingSuggestions.count == 3)

        let narrowed = m.filingSuggestions.filter { $0.fileName == "mystery-1.pdf" }
        let summary = try #require(await m.refineFilingSuggestions(narrowed))

        #expect(summary.asked == 1)
        #expect(asked.refines == [["mystery-1.pdf"]])
        // The two files that were NOT in scope kept the free pass's home.
        let unrefined = m.filingSuggestions.filter { $0.fileName != "mystery-1.pdf" }
        #expect(unrefined.count == 2)
        #expect(unrefined.allSatisfy { $0.best?.path.hasSuffix("Documents/Family") == true })
    }

    @MainActor
    @Test func aSuggestionYourOwnRuleSteeredIsNeverSent() async throws {
        // `applyVerdicts` discards a verdict for a rule-steered file whatever it says, so sending
        // one means paying for an answer that is thrown away on arrival — and counting one means
        // quoting the user for work that will not happen.
        let root = try fixture("remembered", looseFiles: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        // A second loose file with a word distinctive enough to key a rule on — "mystery-0" gives
        // one salient token that the other file shares, so a rule on it would steer both.
        try write(root.appendingPathComponent("Downloads/tesla-invoice.pdf"))
        let asked = Asked()
        let m = manager(asked)
        m.filingRuleDefaults = ScratchDefaults("refineRemembered")
        m.upsertAutomationRule(AutomationRule(
            name: "Tesla", matchMode: .all,
            conditions: [.mentionsAll(["tesla"])],
            destinationTemplate: root.appendingPathComponent("Documents/Family").path))
        _ = await scan(m, root: root)

        let steered = try #require(m.filingSuggestions.first { $0.fileName == "tesla-invoice.pdf" })
        #expect(steered.best?.remembered == true)

        // Both the eligibility answer the button counts…
        let eligible = m.filingSuggestionsEligibleForRefine(m.filingSuggestions)
        #expect(eligible.map(\.fileName) == ["mystery-0.pdf"])

        // …and what the pass actually sends.
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(summary.asked == 1)
        #expect(asked.refines == [["mystery-0.pdf"]])
        // The steered file still points where the rule said, not where the model would have.
        let after = try #require(m.filingSuggestions.first { $0.fileName == "tesla-invoice.pdf" })
        #expect(after.best?.path.hasSuffix("Documents/Family") == true)
        // …and the one that WAS sent moved, so "not sent" isn't just "nothing happened".
        let refined = try #require(m.filingSuggestions.first { $0.fileName == "mystery-0.pdf" })
        #expect(refined.best?.path.hasSuffix("Archive/2026") == true)
    }

    @MainActor
    @Test func refiningIsRefusedWithNothingToRefine() async throws {
        let root = try fixture("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)

        // No scan has run: no list, no cached taxonomy, nothing to reason against.
        #expect(!m.canRefineFilingSuggestions)
        #expect(await m.refineFilingSuggestions([]) == nil)

        _ = await scan(m, root: root)
        #expect(m.canRefineFilingSuggestions)
        // An empty scope after a scan is still nothing to do — and must not be billed as a batch
        // of zero.
        #expect(await m.refineFilingSuggestions([]) == nil)
        #expect(asked.refines.isEmpty)
    }

    @MainActor
    @Test func suggestionsFromAnotherProviderAreNotRefined() async throws {
        // The cached taxonomy belongs to ONE provider. A verdict resolved against the wrong tree
        // names a destination in the wrong account — and the pass would then offer to move a file
        // there. `tryAnotherFolder` validates the same thing for the same reason.
        let root = try fixture("provider-a")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try fixture("provider-b")
        defer { try? FileManager.default.removeItem(at: other) }
        let asked = Asked()
        let m = manager(asked)
        _ = await scan(m, root: root)

        let foreign = m.filingSuggestions.map {
            FilingSuggestion(filePath: $0.filePath, fileName: $0.fileName, size: $0.size,
                             modificationDate: $0.modificationDate, candidates: $0.candidates,
                             providerRoot: other.path)
        }
        #expect(m.filingSuggestionsEligibleForRefine(foreign).isEmpty)
        #expect(await m.refineFilingSuggestions(foreign) == nil)
        #expect(asked.refines.isEmpty)
    }

    // MARK: Staleness and re-entrancy

    @MainActor
    @Test func aRefineWhoseListWasReplacedIsDroppedButStillCached() async throws {
        // Two facts in one, because they are in tension. The verdicts must NOT be applied — the
        // cards on screen belong to the rescan, and overwriting them would silently undo it. The
        // verdicts must still be RECORDED — the call happened and was billed, and re-buying the
        // same answer is the one thing the cache exists to prevent.
        let root = try fixture("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = try makeCanonicalTempRoot(prefix: "RefineStaleCache")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asked = Asked()
        let m = manager(asked)
        m.filingVerdictCacheURL = cacheDir.appendingPathComponent("verdicts.json")
        let downloads = await scan(m, root: root)
        let scope = m.filingSuggestions

        // The classifier republishes mid-flight, standing in for a rescan landing while the refine
        // is out at the backend.
        m.filingClassifier = { _, files, tier in
            asked.record(files.map(\.fileName), tier)
            await MainActor.run { m.publishFilingSuggestions(m.filingSuggestions) }
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "test"))
            })
        }
        #expect(await m.refineFilingSuggestions(scope) == nil)   // dropped
        #expect(m.filingLastRefine == nil)
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Documents/Family") == true })
        FilingVerdictStore.waitForPendingWrites()

        // …but a second refine of the same unchanged files asks nothing, because the discarded
        // pass's answers were kept.
        let fresh = manager(asked)
        fresh.filingVerdictCacheURL = m.filingVerdictCacheURL
        await fresh.findFilingSuggestions(folder: downloads, providerRoot: root)
        let summary = try #require(await fresh.refineFilingSuggestions(fresh.filingSuggestions))
        #expect(summary.reused == 2)
        #expect(summary.classified == 0)
        #expect(summary.changed == 2)   // the paid-for answer still lands
    }

    @MainActor
    @Test func aSecondRefineWhileOneIsOutIsANoOp() async throws {
        // The button is disabled while a pass runs, but a menu equivalent and two clicks in one
        // run-loop turn are not the button. Two passes would race each other's publish.
        let root = try fixture("reentrant")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)
        _ = await scan(m, root: root)

        let gate = AsyncGate()
        m.filingClassifier = { _, files, tier in
            asked.record(files.map(\.fileName), tier)
            await gate.wait()
            return [:]
        }
        let scope = m.filingSuggestions

        // **Both passes are launched before either is awaited, and that shape is required rather
        // than stylistic.** Awaiting the second call inline deadlocks when the guard is broken: the
        // second pass blocks on the gate that only the line after the await opens. Measured — with
        // the guard deleted, the suite hung instead of failing. A regression must fail, not hang.
        async let first = m.refineFilingSuggestions(scope)
        async let second = m.refineFilingSuggestions(scope)
        await waitUntil("the first refine reaches the classifier") { asked.refines.count >= 1 }
        await gate.open()
        let results = await [first, second]

        // Exactly one pass ran: one of the two returned a summary, the other refused outright.
        #expect(results.compactMap { $0 }.count == 1)
        #expect(asked.refines.count == 1)
        #expect(!m.isRefiningFilingSuggestions)   // and the guard was released, not latched
    }

    /// Refine republishes, and `publishFilingSuggestions` bumps the generation — so refine is a NEW
    /// invalidator of an in-flight "Try another", which before this feature only scans and
    /// `clearFiling()` could be. Pinned because it is an interaction nothing else covers: the
    /// re-ask must drop its verdict rather than write it over the list refine just produced.
    @MainActor
    @Test func aTryAnotherInFlightIsDiscardedByARefinesRepublish() async throws {
        let root = try fixture("tryanother-vs-refine")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("refineVsTryAnother")
        m.filingClassifier = { _, files, tier in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: tier == .free ? "Documents/Family" : "Archive/2026",
                                            confidence: .high, reason: "t"))
            })
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let card = try #require(m.filingSuggestions.first)
        #expect(card.best?.path.hasSuffix("Documents/Family") == true)

        // A "Try another" goes out and is held open…
        let gate = AsyncGate()
        m.filingClassifier = { _, files, _ in
            await gate.wait()
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents", confidence: .high, reason: "re-ask"))
            })
        }
        async let reask: Void = m.tryAnotherFolder(for: card)
        await waitUntil("the re-ask reaches the classifier") { m.filingTryAnotherInFlight[card.id] != nil }

        // …while a refine completes and republishes the whole list.
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "refine"))
            })
        }
        await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.filingSuggestions.first?.best?.path.hasSuffix("Archive/2026") == true)

        await gate.open()
        await reask

        // The re-ask's answer is about the pre-refine list, so it is dropped — the card keeps what
        // the refine put there rather than reverting to the stale re-ask destination.
        #expect(m.filingSuggestions.first?.best?.path.hasSuffix("Archive/2026") == true,
                "an in-flight Try another overwrote the refine that republished after it started")
    }

    @MainActor
    @Test func aNewScanClearsThePreviousRefinesSummary() async throws {
        // The summary describes the rows it is shown beside. A rescan replaces those rows, so a
        // summary left standing would be about files that are no longer on screen.
        let root = try fixture("resummary")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Asked()
        let m = manager(asked)
        let downloads = await scan(m, root: root)
        await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.filingLastRefine != nil)

        await m.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(m.filingLastRefine == nil)

        await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.filingLastRefine != nil)
        m.clearFiling()
        #expect(m.filingLastRefine == nil)
        #expect(!m.isRefiningFilingSuggestions)
    }
}

/// A one-shot gate so a test can hold a classifier open across an await without sleeping.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations = []
        for c in waiting { c.resume() }
    }
}

/// The states an adversarial review of the refine split turned up, each written to fail against
/// `5e326d78` first. They are grouped rather than scattered because they share one theme: every
/// one is a place where the pass's answer to "will this cost money / what did the user reject /
/// what is in scope" was derived twice and the two derivations could disagree.
@MainActor
@Suite struct FilingRefineReviewTests {

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts = 0
        func record() { lock.lock(); prompts += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return prompts }
    }

    private func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func fixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "RefineReview-\(name)")
        try write(root.appendingPathComponent("Documents/Family/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/mystery-0.pdf"))
        return root
    }

    /// Cloud ON in Settings, no usable key, so the app's router downgrades to
    /// on-device. The refine pass really is free and really will run on-device, but the spend
    /// guardrail keys on the SETTING, so it raises a payment dialog for a call nobody is billed
    /// for. This is the exact failure the auto-rescan shipped and had fixed a day earlier — the
    /// tier split moved it from the scan to the Refine button rather than removing it.
    @Test func aDowngradedRefineDoesNotRaiseAPaymentDialog() async throws {
        let root = try fixture("downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = Probe()
        let m = FileSyncManager()
        // Cloud ON…
        let settings = ScratchDefaults("refineDowngrade")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        // …and verdict reuse OFF, which is what leaves a miss for the guardrail to price. With the
        // cache on, the scan's own on-device verdicts are hits under the same downgraded identity
        // and the dialog never comes up — the state is real either way, this is just the half that
        // reaches the confirmer.
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        // …but the app vouches for the on-device DOWNGRADE, for both tiers.
        m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        m.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)
        await m.refineFilingSuggestions(m.filingSuggestions)

        #expect(probe.count == 0, "a refine that runs on-device raised a payment dialog")
    }

    /// The same state, seen from the button. `filingCloudRefineAvailable` is what picks between
    /// "Refine N with Opus" and the "set up Claude" invitation, so keying it on the toggle makes
    /// the button promise a model that is not going to run.
    ///
    /// With no `filingCloudRefineConfigured` seam it falls back to the real route, which is the
    /// CLI/test shape — so this pins the fallback as well as the branch.
    @Test func theButtonDoesNotPromiseAModelTheRouterWillNotUse() async throws {
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineDowngradeLabel")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = settings
        m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity }

        #expect(!m.filingCloudRefineAvailable,
                "the button would name a cloud model for a pass the router sends on-device")
    }

    /// The display seam answers the button, and the ROUTE answers the money — they are allowed to
    /// disagree in exactly one state (a key that is stored but cannot be read), and when they do
    /// the pass must say so rather than report a Claude result nobody got.
    @Test func aStoredButUnreadableKeyOffersRefineAndThenNamesTheDowngrade() async throws {
        let root = try fixture("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineUnreadable")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = settings
        // A key IS stored (so the button offers Claude)…
        m.filingCloudRefineConfigured = { true }
        // …but the router cannot read it, so the pass runs on-device.
        m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        let probe = Probe()
        m.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        #expect(m.filingCloudRefineAvailable)      // the button is offered…
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        await m.refineFilingSuggestions(m.filingSuggestions)

        #expect(probe.count == 0)                  // …nothing was priced or billed…
        #expect(m.banner?.severity == .warning)       // …and the banner names the key rather than
        #expect(m.banner?.message.contains("couldn't be read") == true)   // claiming a Claude answer
    }

    /// A "Try another" landing while a refine is out records a rejection the refine's
    /// pre-await snapshot cannot see, so the refine can re-suggest the folder the user just
    /// rejected. The snapshot is right for the REQUEST (that is what was sent); it is wrong for
    /// the APPLY, which is about what the user is shown.
    @Test func aRejectionRecordedDuringTheRoundTripIsStillHonoured() async throws {
        let root = try fixture("rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("refineRejected")
        let rejected = root.appendingPathComponent("Archive/2026").path
        m.filingClassifier = { _, files, tier in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: tier == .refine ? "Archive/2026" : "Documents/Family",
                                            confidence: .high, reason: "t"))
            })
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let scope = m.filingSuggestions
        let file = try #require(scope.first)

        // The user rejects Archive/2026 while the refine is out at the backend.
        m.filingClassifier = { [weak m] _, files, _ in
            await MainActor.run {
                m?.filingSessionRejections[file.filePath, default: []].insert(rejected)
            }
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        await m.refineFilingSuggestions(scope)

        let after = try #require(m.filingSuggestions.first)
        #expect(after.best?.path != rejected,
                "the refine landed on a folder the user rejected while it was running")
    }

    /// `scope` is caller-supplied, and two of the dictionaries built from it use
    /// `uniqueKeysWithValues`, which TRAPS on a duplicate key. A public API should not crash on a
    /// list that happens to name the same file twice.
    @Test func aDuplicateInTheScopeDoesNotTrap() async throws {
        let root = try fixture("dupes")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let doubled = m.filingSuggestions + m.filingSuggestions

        let summary = await m.refineFilingSuggestions(doubled)
        // Deduped rather than merely survived: the count is what the user is quoted, and sending a
        // file twice would bill for it twice.
        #expect(summary?.asked == 1)
    }

    /// The free tier's identity is pinned to on-device even with cloud switched on, with no app
    /// resolver in play (the CLI, and every test that doesn't inject one). Without this a
    /// cloud-enabled CLI would file its free-pass answers under a Claude model's name.
    @Test func theFreeTiersConfiguredIdentityIgnoresTheCloudToggle() {
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineFreeIdentity")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = settings

        #expect(m.configuredFilingBackendIdentity(for: .free) == FileSyncManager.onDeviceBackendIdentity)
        #expect(m.configuredFilingBackendIdentity(for: .refine).hasPrefix("cloud:"))
        #expect(!m.filingRoutesToCloud(.free))
        #expect(m.filingRoutesToCloud(.refine))

    }
}

/// The one cost assertion in this package, and it earns the machine-pinned marker for the same
/// reason `ColumnClickCostBenchmark` does: the bar is a RATIO between two calls in the same run,
/// so it scales with the machine, but it is still a latency claim rather than a behavioural one.
///
/// It exists because the regression it catches was invisible to every other test: the refactor
/// that added the `existingRelative:` overload moved the empty-verdicts early-out into it, so the
/// taxonomy overload derived the folder set — a full recursive walk of the provider — before
/// returning the input untouched. The result was identical, so only the cost changed, and only a
/// clock can see that.
@Suite(.machinePinned(.calibratedTiming)) struct FilingApplyVerdictsCostTests {

    /// `applyVerdicts(taxonomy:)` lost its empty-verdicts early-out in the refactor, so
    /// a scan whose backend declined (no Apple Intelligence — an ordinary Mac) now walks the whole
    /// provider tree to build a folder set nothing reads. Asserted on the walk itself, because the
    /// result is identical either way and only the cost changed.
    @Test func anEmptyVerdictSetDoesNotWalkTheTaxonomy() {
        // A tree big enough that the difference is unmistakable, and a suggestion list to map over.
        let taxonomy = (0..<2000).map {
            FileNode(id: "/root/f\($0)", name: "f\($0)", isDirectory: true)
        }
        let suggestions = [FilingSuggestion(filePath: "/root/Downloads/a.pdf", fileName: "a.pdf",
                                            size: 1, modificationDate: nil, candidates: [],
                                            providerRoot: "/root")]
        let clock = ContinuousClock()
        let empty = clock.measure {
            for _ in 0..<200 {
                _ = FilingEngine.applyVerdicts([:], to: suggestions, taxonomy: taxonomy,
                                               providerRoot: "/root")
            }
        }
        let populated = clock.measure {
            for _ in 0..<200 {
                _ = FilingEngine.applyVerdicts(
                    ["/root/Downloads/a.pdf": FilingVerdict(relativePath: "f1", confidence: .high, reason: "t")],
                    to: suggestions, taxonomy: taxonomy, providerRoot: "/root")
            }
        }
        // The empty case should not pay for the taxonomy walk the populated case needs. A generous
        // ratio, because this is about "did the walk happen at all", not about microseconds.
        #expect(empty < populated / 4,
                "empty verdicts cost \(empty) vs \(populated) populated — the walk was not skipped")
    }

}

/// Reads of the persisted rejection store must not scale with the number of suggestions.
///
/// `filingRejections` decodes JSON out of `UserDefaults` on every access — `readPersistedStore`
/// says as much ("these getters are hot — a scan reads them per file"). The round-1 review
/// extracted a `rejectedFolders(for:…)` helper for the good reason that the request's exclusion
/// list and the apply filter must derive rejections identically; the helper then fetched the store
/// itself, turning two decodes into two per suggestion, on the main actor.
@MainActor
@Suite struct FilingRefineRejectionReadTests {

    /// Counts `data(forKey:)` reads of one key, which is what `readPersistedStore` fetches.
    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        let watched: String
        private let lock = NSLock()
        private var n = 0
        init?(name: String, watching key: String) {
            self.watched = key
            super.init(suiteName: name)
            removePersistentDomain(forName: name)
        }
        override func data(forKey defaultName: String) -> Data? {
            if defaultName == watched { lock.lock(); n += 1; lock.unlock() }
            return super.data(forKey: defaultName)
        }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func theRejectionStoreIsDecodedOncePerLoopNotOncePerSuggestion() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RefineRejectionReads")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        let fileCount = 25
        for i in 0..<fileCount { try write(root.appendingPathComponent("Downloads/mystery-\(i).pdf")) }

        let counting = try #require(CountingDefaults(name: "refineRejectionReads",
                                                     watching: FileSyncManager.rejectionsDefaultsKey))
        let m = FileSyncManager()
        m.filingRuleDefaults = counting
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(m.filingSuggestions.count == fileCount)

        let before = counting.reads
        await m.refineFilingSuggestions(m.filingSuggestions)
        let spent = counting.reads - before

        // Two loops read the store, so two decodes is the floor. The bar is well under the file
        // count so it fails on "per suggestion" rather than on an extra hoisted read appearing.
        #expect(spent <= 4,
                "the refine pass decoded the rejection store \(spent) times for \(fileCount) suggestions")
    }
}
