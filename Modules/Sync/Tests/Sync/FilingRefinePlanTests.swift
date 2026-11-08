import Foundation
import Testing
@testable import Sync

/// Refine split in two (TE335, C1): ``FileSyncManager/prepareFilingRefine(_:)`` quotes without
/// sending, and ``FileSyncManager/sendFilingRefine(_:scope:)`` builds the request again and sends
/// only what the plan quoted. Each test that expects a send is paired with one where the same
/// change should stop it.
@MainActor
@Suite struct FilingRefinePlanTests {

    /// Every `.refine` call the classifier received.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ files: [FilingCandidateFile]) { lock.lock(); defer { lock.unlock() }; calls.append(files.map(\.fileName).sorted()) }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func fixture(_ name: String, files: Int = 2) throws -> URL { try refineFixture(prefix: "RefinePlan-\(name)", looseFiles: files) }

    /// The scan answers Documents/Family; Refine answers Archive/2026, so a refined home is visible.
    /// The spend dialog says no, to show that the plan's send never asks it.
    private func manager(_ sent: Sent, cap: Double = 0) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefinePlanTests-\(UUID().uuidString)")
        m.filingContentDefaults.set(cap, forKey: FileSyncManager.monthlyBudgetCapKey)
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingCloudSpendConfirmer = { _ in false }
        m.filingClassifier = { _, files, tier in
            if tier == .refine { sent.record(files) }
            let dest = tier == .refine ? "Archive/2026" : "Documents/Family"
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: dest, confidence: .high, reason: "test"))
            })
        }
        return m
    }

    private func scan(_ m: FileSyncManager, root: URL) async {
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
    }

    // MARK: Prepare

    @Test func prepareQuotesAndSendsNothing() async throws {
        let root = try fixture("quote")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let homesBefore = m.filingSuggestions.map { $0.best?.path }

        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))

        #expect(plan.eligible == 2 && plan.toSend == 2 && plan.reused == 0 && plan.hiddenFromClaude == 0)
        guard case .quote(let quote) = plan.billing else { Issue.record("not a quote: \(plan.billing)"); return }
        #expect(quote.fileCount == 2 && quote.estCostUSD > 0)
        #expect(sent.all.isEmpty, "preparing asked the backend nothing")
        #expect(m.filingSuggestions.map { $0.best?.path } == homesBefore, "and changed no card")
        #expect(m.banner == nil && m.filingLastRefine == nil && !m.isRefiningFilingSuggestions)
        #expect(m.filingOpenRefinePlans[plan.providerRoot]?.id == plan.id)
    }

    @Test func aNewPlanReplacesTheOpenOneAndTheOldOneCannotSend() async throws {
        let root = try fixture("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)

        let first = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let second = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(m.filingOpenRefinePlans.count == 1 && m.filingOpenRefinePlans[second.providerRoot]?.id == second.id)

        #expect(await m.sendFilingRefine(first, scope: m.filingSuggestions) == .stale)
        #expect(sent.all.isEmpty)
        if case .sent = await m.sendFilingRefine(second, scope: m.filingSuggestions) {} else { Issue.record("the open plan did not send") }
    }

    @Test func discardingAPlanLeavesNothingToSend() async throws {
        let root = try fixture("discard")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(Sent())
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        m.discardFilingRefinePlan(plan)
        #expect(m.filingOpenRefinePlans.isEmpty)
        #expect(await m.sendFilingRefine(plan, scope: m.filingSuggestions) == .stale)
    }

    // MARK: Send

    @Test func sendRunsThePassTheDialogFlowWould() async throws {
        let root = try fixture("send")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))

        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        guard case .sent(let summary) = result else { Issue.record("not sent: \(result)"); return }
        #expect(summary == FileSyncManager.FilingRefineSummary(asked: 2, reused: 0, classified: 2, changed: 2))
        #expect(sent.all == [["mystery-0.pdf", "mystery-1.pdf"]])
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path.hasSuffix("Archive/2026") == true })
        #expect(m.filingOpenRefinePlans.isEmpty && !m.isRefiningFilingSuggestions)
    }

    @Test func aSecondSendOfTheSamePlanSendsNothing() async throws {
        let root = try fixture("double")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let scope = m.filingSuggestions

        async let one = m.sendFilingRefine(plan, scope: scope)
        async let two = m.sendFilingRefine(plan, scope: scope)
        let results = await [one, two]

        #expect(results.filter { if case .sent = $0 { true } else { false } }.count == 1)
        #expect(results.contains(.stale))
        #expect(sent.all.count == 1, "one request, however fast the clicks")
    }

    // MARK: Send rebuilds, and re-quotes when the request changed

    @Test func aRescanWhileAPlanWaitsMakesSendQuoteAgain() async throws {
        let root = try fixture("rescan")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))

        await scan(m, root: root)   // the list is republished
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        guard case .requoted(let fresh) = result else { Issue.record("not re-quoted: \(result)"); return }
        #expect(fresh.id != plan.id)
        #expect(sent.all.isEmpty, "nothing was sent against a list the person had not been quoted for")
        #expect(m.filingOpenRefinePlans[fresh.providerRoot]?.id == fresh.id)
        // The control: the new plan, read again, sends.
        if case .sent = await m.sendFilingRefine(fresh, scope: m.filingSuggestions) {} else { Issue.record("the new plan did not send") }
        #expect(sent.all.count == 1)
    }

    @Test func aFolderHiddenWhileAPlanWaitsKeepsItsFilesOutAndQuotesAgain() async throws {
        let root = try fixture("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        #expect(plan.toSend == 2)

        AskClaudePrivacy.setHiddenFolders([root.appendingPathComponent("Downloads/mystery-0.pdf").path],
                                          in: m.filingContentDefaults)
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        guard case .requoted(let fresh) = result else { Issue.record("not re-quoted: \(result)"); return }
        #expect(fresh.toSend == 1 && fresh.hiddenFromClaude == 1)
        #expect(sent.all.isEmpty)
        if case .sent = await m.sendFilingRefine(fresh, scope: m.filingSuggestions) {} else { Issue.record("did not send") }
        #expect(sent.all == [["mystery-1.pdf"]], "the hidden file never went")
    }

    @Test func aTryAnotherWhileAPlanWaitsMakesSendQuoteAgain() async throws {
        let root = try fixture("tryanother")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))

        // A rejected folder goes out as "avoid: …" and is part of the saved answer's key.
        await m.tryAnotherFolder(for: m.filingSuggestions[0])
        let result = await m.sendFilingRefine(plan, scope: m.filingSuggestions)

        guard case .requoted = result else { Issue.record("not re-quoted: \(result)"); return }
        #expect(sent.all.filter { $0.count == 2 }.isEmpty, "the two-file request the plan quoted was not sent")
    }

    @Test func everyEligibleFileHiddenAfterThePlanSendsNothing() async throws {
        let root = try fixture("allhidden")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        AskClaudePrivacy.setHiddenFolders([root.appendingPathComponent("Downloads").path], in: m.filingContentDefaults)
        #expect(await m.sendFilingRefine(plan, scope: m.filingSuggestions) == .nothingToSend)
        #expect(sent.all.isEmpty)
    }

    // MARK: The limit

    @Test func aPlanOverTheLimitIsBlockedAtSend() async throws {
        let root = try fixture("cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, cap: 0.000001)
        await scan(m, root: root)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        guard case .quote(let quote) = plan.billing else { Issue.record("not a quote"); return }
        #expect(quote.wouldExceedCap)

        #expect(await m.sendFilingRefine(plan, scope: m.filingSuggestions) == .blocked)
        #expect(sent.all.isEmpty)
    }

    // MARK: The whole pass is unchanged

    @Test func theSingleCallPassStillPutsTheDialogBeforeTheSend() async throws {
        let root = try fixture("dialog")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent)   // the dialog answers no
        await scan(m, root: root)

        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))

        #expect(summary.outcome == .declined && summary.classified == 0)
        #expect(sent.all.isEmpty, "declined at the dialog: nothing sent")
    }
}
