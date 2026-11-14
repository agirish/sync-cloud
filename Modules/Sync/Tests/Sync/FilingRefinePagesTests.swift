import Foundation
import Testing
@testable import Sync

/// What the plan card lets the person choose for one Refine pass: which pages go, which files wait
/// for them, saved answers asked again, the pass cut to what fits, and folders left out of the list.
/// Each choice is shown changing what the request holds, and what the plan says about it.
extension HandBuiltRefineSuites {
@MainActor
@Suite struct FilingRefinePagesTests {

    /// One manager for the suite, reset per test (see `HandBuiltFiling.reset`).
    private static var shared: FileSyncManager { HandBuiltFiling.manager }
    private static var defaults: ScratchDefaults { HandBuiltFiling.defaults }

    /// What each request carried, and the "avoid: …" folders it named.
    private typealias Seen = LockedBox<[PagesRequest]>

    private func fixture(_ name: String, files: Int = 2) throws -> URL { HandBuiltFiling.root(name, files: files) }

    private func manager(_ seen: Seen, cacheDir: URL? = nil, limit: Double? = nil) -> FileSyncManager {
        let m = Self.shared
        HandBuiltFiling.reset(m, defaults: Self.defaults)
        let defaults = Self.defaults
        defaults.set(true, forKey: FileSyncManager.readContentsDefaultsKey)
        if let limit { defaults.set(limit, forKey: AskClaudeSpend.limitDefaultsKey) }
        m.filingContentDefaults = defaults
        if let cacheDir { m.filingVerdictCacheURL = cacheDir.appendingPathComponent("verdicts.json") }
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingSnippetExtractor = { _ in "page one text" }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "free"))
            })
        }
        m.filingRefineClassifier = { context, files in
            seen.record(files, context)
            return FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        return m
    }

    private func scan(_ m: FileSyncManager, root: URL) async {
        HandBuiltFiling.build(m, root: root)
    }

    private func sharedFile(_ root: URL, _ n: Int) -> String { root.appendingPathComponent("Downloads/mystery-\(n).pdf").path }

    /// Gives a card a home read from the file's text, which a name-only answer may not replace.
    private func readFromText(_ m: FileSyncManager, name: String) throws {
        let card = try #require(m.filingSuggestions.first { $0.fileName == name })
        let best = try #require(card.best)
        let fromText = FilingDestination(path: best.path, base: .high, evidence: .content, reasons: ["Page 1 says so"], newSegments: [])
        m.replaceFilingSuggestion(card.id, candidates: [fromText])
        #expect(m.filingSuggestions.first { $0.fileName == name }?.best?.fromContent == true, "the fixture did not take")
    }

    // MARK: Pages

    @Test func aSharedFolderSendsItsPageAndAnAskEachTimeFolderDoesNot() async throws {
        let root = try fixture("pages"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        AskClaudePrivacy.shareWithoutAsking(sharedFile(root, 0), in: m.filingContentDefaults)
        await scan(m, root: root)

        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.toSend == 2 && plan.pagesShared == 1 && plan.pagesAskEachTime == 0)
        #expect(plan.pagesWaiting == 1, "one page waits for the tick")
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        let sent = try #require(seen.all.first)
        #expect(sent.snippets["mystery-0.pdf"] == .some("page one text"), "the shared folder's page went")
        #expect(sent.snippets["mystery-1.pdf"] == .some(nil), "the other file went by name alone")
    }

    @Test func theTickSendsThePagesFromFoldersThatAskEachTime() async throws {
        let root = try fixture("tick"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        AskClaudePrivacy.shareWithoutAsking(sharedFile(root, 0), in: m.filingContentDefaults)
        await scan(m, root: root)

        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        #expect(plan.pagesShared == 1 && plan.pagesAskEachTime == 1 && plan.pagesWaiting == 0)
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        let sent = try #require(seen.all.first)
        #expect(sent.snippets["mystery-0.pdf"] == .some("page one text") && sent.snippets["mystery-1.pdf"] == .some("page one text"))
    }

    @Test func theTickIsPerPassAndStartsOff() async throws {
        let root = try fixture("pertick"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        await scan(m, root: root)
        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        #expect(ticked.pagesAskEachTime == 2)
        let next = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(next.pagesAskEachTime == 0 && next.options == FileSyncManager.FilingRefineOptions(), "the next pass starts unticked")
    }

    @Test func aHomeReadFromTheTextWaitsForTheTickAndSaysWhatTheTickBuys() async throws {
        let root = try fixture("waits"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        await scan(m, root: root)
        try readFromText(m, name: "mystery-1.pdf")

        let plain = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plain.toSend == 1 && plain.waitingForPage == 1, "the file whose home came from its text is left out until the tick")
        let gain = try #require(plain.tickGain)
        #expect(gain.files == 1 && gain.costUSD > 0, "ticking adds that file, and costs a little more")

        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        #expect(ticked.toSend == 2 && ticked.waitingForPage == 0 && ticked.tickGain == nil)
        guard case .quote(let a) = plain.billing, case .quote(let b) = ticked.billing else { Issue.record("no quotes"); return }
        #expect(abs((b.estCostUSD - a.estCostUSD) - gain.costUSD) < 1e-9, "the card's figure is the difference of the two quotes")
    }

    @Test func aSharedFolderIsNeverHeldBackForTheTick() async throws {
        let root = try fixture("sharedwait"); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        AskClaudePrivacy.shareWithoutAsking(sharedFile(root, 1), in: m.filingContentDefaults)
        await scan(m, root: root)
        try readFromText(m, name: "mystery-1.pdf")
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.waitingForPage == 0 && plan.toSend == 2, "its page goes, so a name-only answer is not what it gets")
    }

    @Test func withReadingOffNothingWaitsAndNoPageGoes() async throws {
        let root = try fixture("noreads"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        m.filingContentDefaults.set(false, forKey: FileSyncManager.readContentsDefaultsKey)
        await scan(m, root: root)
        try readFromText(m, name: "mystery-1.pdf")
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.waitingForPage == 0 && plan.pagesShared == 0 && plan.pagesWaiting == 0 && plan.tickGain == nil)
        #expect(plan.toSend == 2)
    }

    // MARK: Ask again, the cut, the limit

    @Test func askAgainSendsFilesThatWereAnsweredBefore() async throws {
        let root = try fixture("again")
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RefinePagesCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let seen = Seen()
        let m = manager(seen, cacheDir: cache)
        await scan(m, root: root)
        let first = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        _ = await m.sendFilingRefine(first, scope: m.filingSuggestions)
        // Same manager: its saved answers are in memory at once, so nothing waits for the disk write.
        let reused = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(reused.reused == 2 && reused.toSend == 0, "answered before: nothing new to ask")
        let again = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(askAgain: true)))
        #expect(again.reused == 0 && again.toSend == 2, "ask again looks at no saved answer")
    }

    @Test func aPassIsCutToOneRequestAndSaysHowManyWaitForTheNextPress() async throws {
        let root = try fixture("cap", files: 2); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        // A long list built by hand, not written to disk: a few hundred files in a scan would hold the
        // cooperative pool at the start of the package run, where the parking suites need it.
        let template = try #require(m.filingSuggestions.first)
        m.publishFilingSuggestions((0..<(CloudFilingRefiner.maxFiles + 10)).map {
            FilingSuggestion(filePath: root.path + "/Downloads/hand-\($0).pdf", fileName: "hand-\($0).pdf", size: 10,
                             modificationDate: nil, candidates: template.candidates, providerRoot: template.providerRoot)
        })
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.eligible == CloudFilingRefiner.maxFiles + 10)
        #expect(plan.toSend == CloudFilingRefiner.maxFiles && plan.keptForNextPress == 10)
    }

    @Test func sendTheNThatFitCutsThePassAndIsPricedForIt() async throws {
        let root = try fixture("fit", files: 8); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        let all = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        guard case .quote(let full) = all.billing else { Issue.record("no quote"); return }

        // A limit of 60% of the pass's cost: some of it fits.
        m.filingContentDefaults.set(full.estCostUSD * 0.6, forKey: AskClaudeSpend.limitDefaultsKey)
        let over = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        guard case .quote(let overQuote) = over.billing else { Issue.record("no quote"); return }
        #expect(overQuote.wouldExceedCap)
        let fits = try #require(over.fits)
        #expect(fits > 0 && fits < 8, "some fit, not all: \(fits)")

        let smaller = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(limitTo: fits)))
        guard case .quote(let q) = smaller.billing else { Issue.record("no quote"); return }
        #expect(smaller.toSend == fits && smaller.keptForNextPress == 8 - fits)
        #expect(!q.wouldExceedCap, "the part that fits is under the limit")
        #expect(q.estCostUSD < full.estCostUSD)
    }

    @Test func aPassThatFitsHasNoFitFigure() async throws {
        let root = try fixture("nofit"); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.fits == nil)
    }

    // MARK: Folder names

    @Test func foldersLeftOutByCustomizeLeaveTheListAndAreCounted() async throws {
        let root = try fixture("leftout"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        await scan(m, root: root)

        let before = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(before.folderNamesLeftOut == 0 && before.folderNames > 0)

        m.filingRefineLeftOutFolders = ["Archive"]
        let after = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(after.folderNamesLeftOut > 0 && after.folderNames == before.folderNames - after.folderNamesLeftOut)
        _ = await m.sendFilingRefine(after, scope: m.filingSuggestions)
        let sent = try #require(seen.all.first)
        #expect(!sent.folders.contains { $0 == "Archive" || $0.hasPrefix("Archive/") }, "a left-out folder, and what is under it, was not sent: \(sent.folders)")
        #expect(sent.folders.contains { $0.hasPrefix("Documents") })
    }

    /// A folder left out goes nowhere, not even as a rejected folder's "avoid: …" line.
    @Test func aLeftOutFolderIsNotSentAsAnAvoidLineEither() async throws {
        let root = try fixture("leftout-avoid"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        await scan(m, root: root)
        let file = try #require(m.filingSuggestions.first)
        m.filingSessionRejections[file.filePath] = [root.appendingPathComponent("Archive/2026").path,
                                                    root.appendingPathComponent("Projects/Taxes").path]
        m.filingRefineLeftOutFolders = ["Archive"]
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        let avoided = try #require(seen.avoids.first)
        #expect(!avoided.contains { $0.hasPrefix("Archive") }, "the left-out folder's name stayed home: \(avoided)")
        #expect(avoided.contains("Projects/Taxes"), "a rejection that isn't left out still goes")
    }

    // MARK: Stop, and saved answers

    /// Stop shows from the click, while the request is still being made: pressed then, nothing goes.
    @Test func aStopWhileSendIsStillMakingTheRequestSendsNothing() async throws {
        let root = try fixture("stop-early"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        // The send reads the pages again; Stop arrives while it does.
        m.filingSnippetExtractor = { [m] _ in
            await m.stopFilingRefine()
            return "page one text"
        }
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(result == .stoppedBeforeSending)
        #expect(seen.all.isEmpty, "nothing was sent")
        #expect(!m.isRefiningFilingSuggestions)
    }

    /// A folder hidden while Send is still making the request (reading pages, downloading): the
    /// request was built before the hide, so nothing goes.
    @Test func aFolderHiddenWhileSendIsStillMakingTheRequestSendsNothing() async throws {
        let root = try fixture("hide-early"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        let downloads = root.appendingPathComponent("Downloads").path
        AskClaudePrivacy.shareWithoutAsking(downloads, in: m.filingContentDefaults)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        m.filingSnippetExtractor = { [m] _ in
            await MainActor.run { AskClaudePrivacy.setHiddenFolders([downloads], in: m.filingContentDefaults) }
            return "page one text"
        }
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(seen.all.isEmpty, "nothing was sent: \(result)")
        #expect(!m.isRefiningFilingSuggestions)
    }

    /// The same for a folder taken off the shared list meanwhile: its pages no longer go unasked.
    @Test func aFolderUnsharedWhileSendIsStillMakingTheRequestSendsNothing() async throws {
        let root = try fixture("unshare-early"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        m.filingSnippetExtractor = { [m] _ in
            await MainActor.run { AskClaudePrivacy.setSharedFolders([], in: m.filingContentDefaults) }
            return "page one text"
        }
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(seen.all.isEmpty, "the pages would have gone from a folder no longer shared")
    }

    /// Makes every card's file cloud-only until its download, which runs `during` (on the main
    /// actor): the one await between the plan's last check and the send.
    private func downloading(_ m: FileSyncManager, during: @escaping @MainActor () -> Void) {
        let landed = LockedBox<Set<String>>([])
        for s in m.filingSuggestions { m.filingNotDownloaded.insert(s.filePath) }
        m.filingSnippetExtractor = { p in landed.withLock { $0.contains(p) } ? "page one text" : nil }
        m.filingStatFlags = { p in landed.withLock { $0.contains(p) } ? 0 : MaterializationStatus.datalessFlag }
        m.filingDownloadWait = (3, .zero)
        m.filingDownloader = { p in
            landed.withLock { _ = $0.insert(p) }
            MainActor.assumeIsolated { during() }
        }
    }

    /// A folder hidden while a pass downloads its cloud-only files: the request was made before
    /// the hide, so nothing goes, the downloaded pages included.
    @Test func aFolderHiddenWhileThePassDownloadsSendsNothing() async throws {
        let root = try fixture("hide-download"); defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let m = manager(seen)
        let downloads = root.appendingPathComponent("Downloads").path
        AskClaudePrivacy.shareWithoutAsking(downloads, in: m.filingContentDefaults)
        await scan(m, root: root)
        downloading(m) { AskClaudePrivacy.setHiddenFolders([downloads], in: m.filingContentDefaults) }
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.toSend == 2, "the fixture sends both")
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(seen.all.isEmpty, "nothing was sent")
        #expect(!m.isRefiningFilingSuggestions)
    }

    /// Where the pass goes changed while it downloaded (the key removed, say): its saved answers
    /// were keyed to Claude, so nothing this Mac answers is saved as Claude's.
    @Test func aRouteThatChangesWhileThePassDownloadsSavesNothingAsClaudes() async throws {
        let root = try fixture("route-flip"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RefinePagesCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let seen = Seen()
        let m = manager(seen, cacheDir: cache)
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        await scan(m, root: root)
        downloading(m) { m.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity } }
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(seen.all.isEmpty)
        // Back on Claude: nothing this Mac answered stands in for Claude's answer.
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingSnippetExtractor = { _ in "page one text" }
        let again = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(again.reused == 0 && again.toSend == 2, "this Mac's answers were saved as Claude's")
    }

    /// A pass that outlived its list (`clearFiling()`, then a new pass) leaves the new pass's Stop
    /// working: finishing, it does not take the new pass's request handle with it.
    @Test func anAbandonedPassLeavesTheNextPassesStopWorking() async throws {
        let root = try fixture("abandoned", files: 1); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        let gate = LockedBox((calls: 0, released: false, cancelled: false))
        m.filingRefineClassifier = { _, files in
            let deadline = Date().addingTimeInterval(10)
            if gate.withLock({ $0.calls += 1; return $0.calls }) == 1 {
                while !gate.withLock({ $0.released }), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
            } else {
                while !Task.isCancelled, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
                if Task.isCancelled {
                    gate.withLock { $0.cancelled = true }
                    return FilingRefineResult(ending: .stopped, started: true, costUSD: 0)
                }
            }
            return FilingRefineResult(ending: .answered, verdicts: [:], answered: 0, sent: files.count, started: true, costUSD: 0)
        }
        let planA = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let a = Task { await m.sendFilingRefine(planA, scope: m.filingSuggestions) }
        await waitUntil("the first pass reached Claude") { gate.withLock { $0.calls } >= 1 }
        m.clearFiling()
        await scan(m, root: root)
        let planB = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let b = Task { await m.sendFilingRefine(planB, scope: m.filingSuggestions) }
        await waitUntil("the second pass reached Claude") { gate.withLock { $0.calls } >= 2 }
        #expect(gate.withLock { $0.calls } == 2, "both passes reached Claude")
        gate.withLock { $0.released = true }
        _ = await a.value

        m.stopFilingRefine()
        _ = await b.value
        #expect(gate.withLock { $0.cancelled }, "Stop ended the second pass's request")
    }

    /// The list replaced while Claude answered: the paid answers are saved, not applied, and the send
    /// says what it cost instead of calling the plan out of date.
    @Test func aPassWhoseListMovedWhileClaudeAnsweredSaysWhatItCost() async throws {
        let root = try fixture("moved"); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        m.filingRefineClassifier = { [m] _, files in
            await m.publishFilingSuggestions(m.filingSuggestions)   // a rescan lands meanwhile
            return FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.002)
        }
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        #expect(result == .discarded(sent: 2, costUSD: 0.002))
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Documents/Family") == true }, "nothing applied to the new list")
    }

    /// A saved answer Claude gave with page 1 is a read answer when it is used again: after Undo
    /// Refine, sending the plan again (nothing new to ask) puts Claude's homes back.
    @Test func aSavedAnswerGivenWithThePageStillMovesAHomeFromText() async throws {
        let root = try fixture("reuse-page")
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RefinePagesCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let seen = Seen()
        let m = manager(seen, cacheDir: cache)
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        await scan(m, root: root)
        try readFromText(m, name: "mystery-0.pdf")
        try readFromText(m, name: "mystery-1.pdf")
        let first = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(first.pagesShared == 2, "the fixture sends both pages")
        _ = await m.sendFilingRefine(first, scope: m.filingSuggestions)
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Archive/2026") == true }, "Claude read the pages and moved both")

        #expect(m.undoFilingRefine() == 2)
        let again = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(again.reused == 2 && again.toSend == 0)
        _ = await m.sendFilingRefine(again, scope: m.filingSuggestions)
        #expect(seen.all.count == 1, "nothing was asked twice")
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Archive/2026") == true },
                "the saved answers were read ones, so they move homes read from text again")
    }

    /// A pass that meant to send a page but couldn't read it saves a name-only answer.
    @Test func anAnswerIsSavedAsNameOnlyWhenItsPageDidNotGo() async throws {
        let root = try fixture("unread-page")
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RefinePagesCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let seen = Seen()
        let m = manager(seen, cacheDir: cache)
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        m.filingSnippetExtractor = { _ in nil }   // no text layer: the page can't be read
        await scan(m, root: root)
        let first = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        _ = await m.sendFilingRefine(first, scope: m.filingSuggestions)
        #expect(seen.all.first?.snippets.values.allSatisfy { $0 == nil } == true, "names alone went")

        // Now the page reads: the name-only answer must not stand in for one given with it.
        m.filingSnippetExtractor = { _ in "page one text" }
        let withPages = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(withPages.reused == 0 && withPages.toSend == 2, "asked again, with the pages")
    }

    @Test func leftOutAppliesToTheFolderAndEverythingUnderIt() {
        let left: Set<String> = ["Archive"]
        #expect(FileSyncManager.isLeftOut("Archive", in: left))
        #expect(FileSyncManager.isLeftOut("Archive/2026/Taxes", in: left))
        #expect(!FileSyncManager.isLeftOut("Archives", in: left), "a name that only starts the same is another folder")
        #expect(!FileSyncManager.isLeftOut("Documents/Archive", in: left))
        #expect(!FileSyncManager.isLeftOut("Archive", in: []))
    }

    // MARK: A plan names what it was made with

    @Test func aPlanNamesTheChatsModelAndIsAboutItsOptions() async throws {
        let root = try fixture("model"); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Seen())
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.modelID == m.filingRefineModelID && plan.modelName == m.filingRefineModelName)

        // Send builds again with the plan's own options: a tick the plan was not made with is not applied.
        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        #expect(ticked.options.pagesFromAskEachTime)
        #expect(plan.fingerprint != ticked.fingerprint, "a tick changes what the request is, so a plan made without it cannot send with it")
    }
}
}

private struct PagesRequest {
    var snippets: [String: String?]
    var folders: [String]
    var avoids: [String]
}

private extension LockedBox where Value == [PagesRequest] {
    convenience init() { self.init([]) }
    func record(_ files: [FilingCandidateFile], _ context: FilingContext) {
        let request = PagesRequest(
            snippets: Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.contentSnippet) }),
            folders: context.destinations, avoids: files.flatMap(\.excludedRelativePaths))
        withLock { $0.append(request) }
    }
    var all: [(snippets: [String: String?], folders: [String])] { withLock { $0.map { ($0.snippets, $0.folders) } } }
    /// Every "avoid: …" folder each request carried.
    var avoids: [[String]] { withLock { $0.map(\.avoids) } }
}
