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
