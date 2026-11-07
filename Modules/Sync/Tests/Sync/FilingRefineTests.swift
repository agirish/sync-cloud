import Foundation
import Testing
@testable import Sync

/// Organize's refine pass, the opt-in one that can spend money. It acts on a list already on
/// screen, so a stale result is dropped, not applied; it is priced per file, so its scope and its
/// count must be one value; and it is the only Filing path to a paid backend, so what it excludes
/// is a cost question.
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


    /// A provider with two destination folders and `count` loose files. Two folders let the free and
    /// refine passes disagree, which makes "changed" testable.
    private func fixture(_ name: String, looseFiles count: Int = 2) throws -> URL {
        try refineFixture(prefix: "Refine-\(name)", looseFiles: count)
    }

    /// `freeDestination` is the scan's answer, `refineDestination` the refine pass's. Different
    /// values let a test see the refine land, not merely run.
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
        // The pass ran, was billed, and moved nothing. Reporting `asked` as the result would claim
        // two improvements that didn't happen.
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
        // `isSuggestingFiles` swaps the lens to its scanning view, which would take the list away
        // mid-refine. Observed from inside the classifier, since a flag set and cleared can't be
        // seen afterwards.
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
        #expect(seen.refining)      // but the button knew it was busy
        #expect(seen.rows == 2)     // and the rows were still there to look at
    }

    // MARK: Scope

    @MainActor
    @Test func refiningActsOnTheListItWasHandedNotTheWholeQueue() async throws {
        // A search can narrow the rows, and the button counts those rows. Sending more would bill
        // for files the user couldn't see; `applyRecommendedFiling` follows the same rule.
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
        // The two files out of scope kept the free pass's home.
        let unrefined = m.filingSuggestions.filter { $0.fileName != "mystery-1.pdf" }
        #expect(unrefined.count == 2)
        #expect(unrefined.allSatisfy { $0.best?.path.hasSuffix("Documents/Family") == true })
    }

    @MainActor
    @Test func aSuggestionYourOwnRuleSteeredIsNeverSent() async throws {
        // `applyVerdicts` discards any verdict for a rule-steered file, so sending one pays for an
        // answer thrown away, and counting one quotes the user for work that won't happen.
        let root = try fixture("remembered", looseFiles: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        // A second loose file with a word distinctive enough to key a rule on: a rule on
        // "mystery-0"'s one salient token would also steer any file sharing it.
        try writeFilingFile(root.appendingPathComponent("Downloads/tesla-invoice.pdf"))
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

        // Both the eligibility answer the button counts
        let eligible = m.filingSuggestionsEligibleForRefine(m.filingSuggestions)
        #expect(eligible.map(\.fileName) == ["mystery-0.pdf"])

        // and what the pass actually sends.
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(summary.asked == 1)
        #expect(asked.refines == [["mystery-0.pdf"]])
        // The steered file still points where the rule said, not where the model would have.
        let after = try #require(m.filingSuggestions.first { $0.fileName == "tesla-invoice.pdf" })
        #expect(after.best?.path.hasSuffix("Documents/Family") == true)
        // The one that was sent moved, so "not sent" isn't just "nothing happened".
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
        // An empty scope after a scan is still nothing to do, not a billed batch of zero.
        #expect(await m.refineFilingSuggestions([]) == nil)
        #expect(asked.refines.isEmpty)
    }

    @MainActor
    @Test func suggestionsFromAnotherProviderAreNotRefined() async throws {
        // The cached taxonomy belongs to one provider. A verdict resolved against the wrong tree
        // would offer to move a file into the wrong account. `tryAnotherFolder` checks the same.
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
        // Two facts in tension. The verdicts must not be applied: the cards on screen belong to the
        // rescan, and overwriting them would silently undo it. They must still be cached: the call
        // was billed, and the cache exists so the same answer isn't bought twice.
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

        // A second refine of the same unchanged files asks nothing: the discarded pass's answers
        // were kept.
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
        // The button is disabled while a pass runs, but a menu item or two clicks in one run-loop
        // turn get past it. Two passes would race each other's publish.
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

        // Both passes launch before either is awaited, and that is required: with the guard broken,
        // awaiting the second inline would block on a gate only the next line opens, and the suite
        // would hang instead of failing.
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

    /// Refine republishes, and `publishFilingSuggestions` bumps the generation, so a refine
    /// invalidates an in-flight "Try another" as a scan or `clearFiling()` does. The re-ask must drop
    /// its verdict rather than write it over the refined list.
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

        // A "Try another" goes out and is held open
        let gate = AsyncGate()
        m.filingClassifier = { _, files, _ in
            await gate.wait()
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents", confidence: .high, reason: "re-ask"))
            })
        }
        async let reask: Void = m.tryAnotherFolder(for: card)
        await waitUntil("the re-ask reaches the classifier") { m.filingTryAnotherInFlight[card.id] != nil }

        // while a refine completes and republishes the whole list.
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "refine"))
            })
        }
        await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.filingSuggestions.first?.best?.path.hasSuffix("Archive/2026") == true)

        await gate.open()
        await reask

        // The re-ask's answer is about the pre-refine list, so it is dropped and the card keeps the
        // refine's home.
        #expect(m.filingSuggestions.first?.best?.path.hasSuffix("Archive/2026") == true,
                "an in-flight Try another overwrote the refine that republished after it started")
    }

    @MainActor
    @Test func aNewScanClearsThePreviousRefinesSummary() async throws {
        // The summary describes the rows beside it. A rescan replaces those rows, so a summary left
        // standing would describe files no longer on screen.
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

/// States where the refine pass answers "will this cost money", "what did the user reject" or
/// "what is in scope" in two places that could disagree.
@MainActor
@Suite struct FilingRefineReviewTests {

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts = 0
        func record() { lock.lock(); prompts += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return prompts }
    }


    private func fixture(_ name: String) throws -> URL {
        try refineFixture(prefix: "RefineReview-\(name)", looseFiles: 1)
    }

    /// Cloud on in Settings but no usable key, so the router downgrades to on-device. The pass is
    /// free, so the spend guardrail must follow the route, not the setting, or it raises a payment
    /// dialog for a call nobody is billed for.
    @Test func aDowngradedRefineDoesNotRaiseAPaymentDialog() async throws {
        let root = try fixture("downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = Probe()
        let m = FileSyncManager()
        // Cloud on,
        let settings = ScratchDefaults("refineDowngrade")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        // verdict reuse off, so there is a miss for the guardrail to price (with the cache on, the
        // scan's on-device verdicts are hits and the confirmer is never reached),
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        // but the app resolves both tiers to the on-device downgrade.
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

    /// The same state, seen from the button. `filingCloudRefineAvailable` picks between "Refine N
    /// with Opus" and the "set up Claude" invitation; keyed on the toggle, it would promise a model
    /// that won't run. With no `filingCloudRefineConfigured` seam (the CLI and test shape) it falls
    /// back to the real route, so this pins the fallback too.
    @Test func theButtonDoesNotPromiseAModelTheRouterWillNotUse() async throws {
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineDowngradeLabel")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = settings
        m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity }

        #expect(!m.filingCloudRefineAvailable,
                "the button would name a cloud model for a pass the router sends on-device")
    }

    /// The display seam answers the button and the route answers the money. They disagree in one
    /// state, a key stored but unreadable, and then the pass must say so rather than report a
    /// Claude result nobody got.
    @Test func aStoredButUnreadableKeyOffersRefineAndThenNamesTheDowngrade() async throws {
        let root = try fixture("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineUnreadable")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = settings
        // A key is stored, so the button offers Claude,
        m.filingCloudRefineConfigured = { true }
        // but the router can't read it, so the pass runs on-device.
        m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        let probe = Probe()
        m.filingCloudSpendConfirmer = { _ in probe.record(); return true }

        #expect(m.filingCloudRefineAvailable)      // the button is offered,
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        await m.refineFilingSuggestions(m.filingSuggestions)

        #expect(probe.count == 0)                  // nothing was priced or billed,
        #expect(m.banner?.severity == .warning)       // and the banner names the key rather than
        #expect(m.banner?.message.contains("couldn’t be read") == true)   // claiming a Claude answer

        // The durable summary, which the pill reads, carries the downgrade too. `classified` is 0
        // because nothing reached Claude, right for billing but not an explanation: without the
        // cause the tooltip would read that 0 as an exhausted cache.
        let summary = try #require(m.filingLastRefine, "a downgraded refine recorded no summary")
        #expect(summary.outcome == .downgraded,
                "the summary calls a downgraded pass “\(summary.outcome.rawValue)”")
        #expect(summary.classified == 0, "a pass that never reached Claude counted files as sent")
        #expect(summary.asked > 0, "nothing was asked — this check would be vacuous")
    }

    /// A rejection recorded while a refine is out must still be honoured when it applies. The
    /// pre-await snapshot is right for the request but not for the apply, or the refine could
    /// re-suggest the folder the user just rejected.
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

    /// `scope` is caller-supplied, and dictionaries built with `uniqueKeysWithValues` trap on a
    /// duplicate key. A list naming the same file twice must not crash.
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
        // Deduped, not merely survived: the count is what the user is quoted, and sending a file
        // twice would bill it twice.
        #expect(summary?.asked == 1)
    }

    /// With no app resolver (the CLI, and tests that don't inject one), the free tier stays
    /// on-device even with cloud on, or the CLI would file free-pass answers under a Claude model's
    /// name.
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

    // MARK: A declined charge is not a result

    /// Declining the spend prompt is not a completed pass. `cloudSpendAllows` returns false for
    /// Cancel and for the over-cap dialog's "Use On-Device Instead", which must not read as "nothing
    /// to send" or a green banner would claim the refine ran and found no better homes.
    @Test func decliningTheSpendPromptIsNotReportedAsSuccess() async throws {
        let root = try fixture("declined")
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Probe()
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineDeclined")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        m.filingClassifier = { _, files, _ in
            asked.record()
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)
        let asksBeforeRefine = asked.count

        // The user declines.
        m.filingCloudSpendConfirmer = { _ in false }
        m.banner = nil
        await m.refineFilingSuggestions(m.filingSuggestions)

        #expect(asked.count == asksBeforeRefine, "the pass was sent despite the decline")
        let banner = try #require(m.banner, "a declined refine said nothing at all")
        #expect(banner.severity != .success,
                "a charge the user declined was reported as a completed pass: “\(banner.message)”")
        #expect(banner.message.contains("declined"),
                "the banner does not say why nothing happened: “\(banner.message)”")
        #expect(!banner.message.contains("no better homes"),
                "the banner reports an outcome the decline prevented: “\(banner.message)”")
        // The durable summary says so too: the banner goes away, but the "refined" pill's tooltip
        // reads `filingLastRefine`, and `classified == 0` alone reads as an exhausted cache.
        let summary = try #require(m.filingLastRefine, "a declined refine recorded no summary")
        #expect(summary.outcome == .declined,
                "the summary calls a declined pass “\(summary.outcome.rawValue)”")
        #expect(summary.classified == 0, "a declined pass counted files as sent to Claude")
    }

    /// The other direction, so the test above isn't passing because every refine warns: an
    /// approved pass still reports success.
    @Test func anApprovedRefineStillReportsSuccess() async throws {
        let root = try fixture("approved")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        let settings = ScratchDefaults("refineApproved")
        settings.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "t"))
            })
        }
        m.filingCloudSpendConfirmer = { _ in true }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)
        m.banner = nil
        await m.refineFilingSuggestions(m.filingSuggestions)

        let banner = try #require(m.banner, "an approved refine said nothing")
        #expect(banner.severity == .success, "an approved refine no longer reports success")
        // The summary too, or `outcome` could be hard-wired to `.declined`.
        let summary = try #require(m.filingLastRefine)
        #expect(summary.outcome == .ran, "an approved pass is recorded as \(summary.outcome.rawValue)")
        #expect(summary.classified > 0, "an approved pass counted nothing as sent")
    }
}

/// A cost assertion, machine-pinned (`calibratedTiming`): the bar is a ratio between two calls in
/// one run, so it scales with the machine, but it is still a latency claim. The empty-verdicts early-out must come before the taxonomy overload's full walk of the
/// provider; skipping it changes only the cost, which only a clock can see.
@Suite(.machinePinned(.calibratedTiming)) struct FilingApplyVerdictsCostTests {

    /// With no verdicts (the backend declined, as on a Mac without Apple Intelligence),
    /// `applyVerdicts(taxonomy:)` must not walk the provider tree to build a folder set nothing
    /// reads. Timed, because the result is identical either way.
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
        // The empty case must not pay for the walk the populated case needs. A generous ratio: the
        // question is whether the walk happened at all.
        #expect(empty < populated / 4,
                "empty verdicts cost \(empty) vs \(populated) populated — the walk was not skipped")
    }

}

/// Reads of the persisted rejection store must not scale with the number of suggestions.
/// `filingRejections` decodes JSON from `UserDefaults` on every access (see `readPersistedStore`),
/// so the request's exclusion list and the apply filter each read it once per loop, not once per
/// suggestion on the main actor.
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
        }
        override func data(forKey defaultName: String) -> Data? {
            if defaultName == watched { lock.lock(); n += 1; lock.unlock() }
            return super.data(forKey: defaultName)
        }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
    }


    @Test func theRejectionStoreIsDecodedOncePerLoopNotOncePerSuggestion() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RefineRejectionReads")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFilingFile(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        let fileCount = 25
        for i in 0..<fileCount { try writeFilingFile(root.appendingPathComponent("Downloads/mystery-\(i).pdf")) }

        let suite = "refineRejectionReads-\(UUID().uuidString)"
        let counting = try #require(CountingDefaults(name: suite, watching: FileSyncManager.rejectionsDefaultsKey))
        defer { wipeDefaultsSuite(suite) }
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
        // count, so it fails on per-suggestion reads, not on one extra hoisted read.
        #expect(spent <= 4,
                "the refine pass decoded the rejection store \(spent) times for \(fileCount) suggestions")
    }
}
