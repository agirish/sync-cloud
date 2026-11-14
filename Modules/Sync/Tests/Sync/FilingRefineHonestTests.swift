import Foundation
import Testing
@testable import Sync

/// What Claude would have answered for the files named, in `folder`.
private func answers(_ files: [FilingCandidateFile], answering names: [String], to folder: String = "Archive/2026") -> [String: FilingVerdict] {
    Dictionary(uniqueKeysWithValues: files.filter { names.contains($0.fileName) }.map {
        ($0.filePath, FilingVerdict(relativePath: folder, confidence: .high, reason: "claude"))
    })
}

/// What a Refine pass and a Try Another do with how Claude's request ended: a failure or a Stop
/// says so, what arrived is kept, and the on-device model never answers in Claude's place.
@MainActor
@Suite struct FilingRefineHonestTests {

    /// What each classifier was asked, so a test can see which one answered.
    private typealias Calls = LockedBox<HonestCalls>

    private func fixture(_ name: String, files: Int = 3) throws -> URL { try refineFixture(prefix: "RefineHonest-\(name)", looseFiles: files) }

    /// The scan answers Documents/Family on-device. Refine routes to Claude, whose reply is `claude`.
    private func manager(_ calls: Calls, confirm: Bool = true,
                         claude: @escaping @Sendable ([FilingCandidateFile]) async -> FilingRefineResult) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefineHonestTests-\(UUID().uuidString)")
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingCloudSpendConfirmer = { _ in confirm }
        m.filingClassifier = { _, files, tier in
            if tier == .refine { calls.onDevice() }
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "free"))
            })
        }
        m.filingRefineClassifier = { _, files in calls.claude(); return await claude(files) }
        return m
    }

    private func scan(_ m: FileSyncManager, root: URL) async {
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
    }

    private func homes(_ m: FileSyncManager) -> [String: String] {
        Dictionary(uniqueKeysWithValues: m.filingSuggestions.map { ($0.fileName, String($0.best?.path.split(separator: "/").suffix(2).joined(separator: "/") ?? "")) })
    }

    // MARK: Answered

    @Test func anAnsweredPassGoesToClaudeAndNeverToTheOnDeviceModel() async throws {
        let root = try fixture("answered"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.01)
        }
        await scan(m, root: root)
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))

        #expect(summary == FileSyncManager.FilingRefineSummary(asked: 3, reused: 0, classified: 3, changed: 3))
        #expect(calls.claudeAsks == 1 && calls.onDeviceRefines == 0, "Claude answered; the on-device model was not asked at the refine tier")
        #expect(m.banner?.message == "Refined 3 suggestions — 3 homes changed.")
    }

    // MARK: Failed

    /// The connection dropped after 2 of 3: the 2 are applied and cached, the third keeps its free
    /// home, the banner says what happened and that something may have been billed, and the on-device
    /// model did not step in.
    @Test func aFailedPassKeepsTheAnswersThatArrivedAndSaysSo() async throws {
        let root = try fixture("failed"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            FilingRefineResult(ending: .failed("The connection dropped."), verdicts: answers(files, answering: ["mystery-0.pdf", "mystery-1.pdf"]),
                               answered: 2, sent: 3, started: true, costUSD: 0.004)
        }
        let cacheDir = try makeCanonicalTempRoot(prefix: "RefineHonestCache"); defer { try? FileManager.default.removeItem(at: cacheDir) }
        m.filingVerdictCacheURL = cacheDir.appendingPathComponent("verdicts.json")
        await scan(m, root: root)
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))

        #expect(summary.outcome == .failed && summary.classified == 3 && summary.changed == 2)
        #expect(homes(m) == ["mystery-0.pdf": "Archive/2026", "mystery-1.pdf": "Archive/2026", "mystery-2.pdf": "Documents/Family"])
        let text = try #require(m.banner?.message)
        #expect(text.contains("Claude didn’t finish. The connection dropped."))
        #expect(text.contains("2 of 3 answers arrived and were kept, moving 2 homes."))
        #expect(text.contains("A request had started, so up to about") && text.contains("may have been billed."))
        #expect(calls.onDeviceRefines == 0)
        #expect(!m.isRefiningFilingSuggestions)

        // The kept answers were saved, so the next pass reuses them and asks only about the third.
        FilingVerdictStore.waitForPendingWrites()
        let again = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(again.reused == 2)
    }

    @Test func aRequestThatNeverStartedChangesNothingAndSaysNothingWasSent() async throws {
        let root = try fixture("notstarted"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { _ in FilingRefineResult(ending: .failed("There is no Claude key to read.")) }
        await scan(m, root: root)
        let before = homes(m)
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))

        #expect(summary.outcome == .failed && summary.classified == 0 && summary.changed == 0)
        #expect(homes(m) == before)
        #expect(m.banner?.message == "Couldn’t ask Claude. There is no Claude key to read. Nothing was sent, and the suggestions are unchanged.")
        #expect(calls.onDeviceRefines == 0, "no on-device answer stands in for Claude's")
    }

    // MARK: Stop

    @Test func stopEndsTheRequestAndKeepsWhatArrived() async throws {
        let root = try fixture("stop"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            return FilingRefineResult(ending: .stopped, verdicts: answers(files, answering: ["mystery-0.pdf"]), answered: 1, sent: 3,
                                      started: true, costUSD: 0.002)
        }
        await scan(m, root: root)
        let scope = m.filingSuggestions
        async let pass = m.refineFilingSuggestions(scope)
        await waitUntil("the request is out") { m.filingRefineRun != nil }
        m.stopFilingRefine()
        let summary = try #require(await pass)

        #expect(summary.outcome == .stopped && summary.changed == 1)
        #expect(homes(m)["mystery-0.pdf"] == "Archive/2026" && homes(m)["mystery-1.pdf"] == "Documents/Family")
        #expect(m.banner?.message.hasPrefix("Stopped. 1 of 3 answers arrived and were kept, moving 1 home.") == true)
        #expect(m.filingRefineRun == nil && !m.isRefiningFilingSuggestions)
    }

    @Test func stopBeforeTheRequestBeginsSendsNothing() async throws {
        let root = try fixture("earlystop"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { _ in FilingRefineResult(ending: .answered) }
        // The spend dialog runs after the pass is claimed and before the request: Stop lands there.
        m.filingCloudSpendConfirmer = { _ in m.stopFilingRefine(); return true }
        await scan(m, root: root)
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(summary.outcome == .stopped && summary.classified == 0)
        #expect(calls.claudeAsks == 0, "stopped before it began, the request was never made")
    }

    @Test func stopWhenNothingIsRunningDoesNothing() {
        let m = manager(Calls()) { _ in FilingRefineResult(ending: .answered) }
        m.stopFilingRefine()
        #expect(!m.filingRefineStopRequested, "a stray Stop must not stop the next pass")
    }

    // MARK: The cap, said

    @Test func aBatchOverTheRequestCapSaysHowManyWent() async throws {
        let root = try fixture("cap"); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            let sent = Array(files.prefix(2))
            return FilingRefineResult(ending: .answered, verdicts: answers(sent, answering: sent.map(\.fileName)), answered: 2, sent: 2,
                                      started: true, costUSD: 0.01)
        }
        await scan(m, root: root)
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(m.banner?.message.contains("2 of 3 went in this request; press Refine again for the rest.") == true)
    }

    // MARK: Try Another

    @Test func aFailedTryAnotherKeepsTheCardAndSaysWhy() async throws {
        let root = try fixture("tryfail", files: 1); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { _ in FilingRefineResult(ending: .failed("Claude is busy right now. Try again in a moment.")) }
        AskClaudePrivacy.shareWithoutAsking(root.path, in: m.filingContentDefaults)   // a shared folder: the click may ask Claude
        await scan(m, root: root)
        let card = try #require(m.filingSuggestions.first)
        let before = card.best?.path
        #expect(before != nil)

        await m.tryAnotherFolder(for: card)

        #expect(m.filingSuggestions.first?.best?.path == before, "the card keeps its suggestion rather than going blank")
        #expect(m.banner?.message == "Claude didn’t answer for mystery-0.pdf: Claude is busy right now. Try again in a moment. Keeping its earlier suggestion.")
        #expect(calls.onDeviceRefines == 0, "the on-device model did not answer in its place")
    }

    @Test func aTryAnotherThatClaudeAnswersTakesTheAnswer() async throws {
        let root = try fixture("tryok", files: 1); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            FilingRefineResult(ending: .answered, verdicts: answers(files, answering: files.map(\.fileName)), answered: 1, sent: 1, started: true, costUSD: 0.001)
        }
        AskClaudePrivacy.shareWithoutAsking(root.path, in: m.filingContentDefaults)
        await scan(m, root: root)
        await m.tryAnotherFolder(for: try #require(m.filingSuggestions.first))
        #expect(m.filingSuggestions.first?.best?.path.hasSuffix("Archive/2026") == true)
        #expect(calls.claudeAsks == 1 && calls.onDeviceRefines == 0)
    }

    // MARK: Try Another keeps to the folder's sharing choice (TE335, LX-A)

    /// A folder that asks each time is not shared, so a click on Try Another there never reaches
    /// Claude: the on-device model answers, at the free tier, and nothing leaves this Mac.
    @Test func aTryAnotherInAFolderThatAsksEachTimeStaysOnThisMac() async throws {
        let root = try fixture("tryasks", files: 1); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let m = manager(calls) { files in
            FilingRefineResult(ending: .answered, verdicts: answers(files, answering: files.map(\.fileName)), answered: 1, sent: 1, started: true, costUSD: 0.001)
        }
        let tiers = LockedBox<[FilingClassifierTier]>([])
        let scanAnswer = m.filingClassifier
        m.filingClassifier = { ctx, files, tier in
            tiers.withLock { $0.append(tier) }
            return await scanAnswer?(ctx, files, tier) ?? [:]
        }
        await scan(m, root: root)
        let afterScan = tiers.withLock { $0 }.count
        await m.tryAnotherFolder(for: try #require(m.filingSuggestions.first))

        #expect(calls.claudeAsks == 0, "nothing was sent to Claude from a folder that asks each time")
        #expect(Array(tiers.withLock { $0 }.dropFirst(afterScan)) == [.free], "the on-device model answered, at the free tier")
        #expect(m.banner?.message.contains("Claude") != true, "no Claude failure was reported: Claude was never asked")
    }
}

private struct HonestCalls { var onDeviceRefines = 0, claudeAsks = 0 }

private extension LockedBox where Value == HonestCalls {
    convenience init() { self.init(HonestCalls()) }
    func onDevice() { withLock { $0.onDeviceRefines += 1 } }
    func claude() { withLock { $0.claudeAsks += 1 } }
    var onDeviceRefines: Int { withLock { $0.onDeviceRefines } }
    var claudeAsks: Int { withLock { $0.claudeAsks } }
}
