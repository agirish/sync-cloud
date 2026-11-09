import Foundation
import Testing
@testable import Sync

/// The Refine card's words and moves (TE335, C3): what each state says, which buttons it allows, and
/// what a send does to it. Built from real plans, so the sentences are about real numbers.
@MainActor
@Suite(.serialized) struct AskClaudeRefineCardTests {

    /// One manager for the suite, reset per test (see `HandBuiltFiling.reset`).
    private static let shared = FileSyncManager()
    private static let defaults = ScratchDefaults("AskClaudeRefineCardTests")


    private func manager(limit: Double? = nil, model: String? = nil) -> FileSyncManager {
        let m = Self.shared
        HandBuiltFiling.reset(m, defaults: Self.defaults)
        let defaults = Self.defaults
        defaults.set(true, forKey: FileSyncManager.readContentsDefaultsKey)
        if let limit { defaults.set(limit, forKey: AskClaudeSpend.limitDefaultsKey) }
        if let model { defaults.set(model, forKey: AskClaudeModels.defaultsKey) }
        m.filingContentDefaults = defaults
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingSnippetExtractor = { _ in "page one text" }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "free"))
            })
        }
        m.filingRefineClassifier = { _, files in
            FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        return m
    }

    private func plan(_ m: FileSyncManager, files: Int = 4, shared: [Int] = [], options: FileSyncManager.FilingRefineOptions = .init(),
                      configure: (FileSyncManager) throws -> Void = { _ in }) async throws -> (FileSyncManager.FilingRefinePlan, URL) {
        let root = HandBuiltFiling.root("card", files: files)
        for n in shared {
            AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads/mystery-\(n).pdf").path, in: m.filingContentDefaults)
        }
        HandBuiltFiling.build(m, root: root)
        try configure(m)
        return (try #require(await m.prepareFilingRefine(m.filingSuggestions, options: options)), root)
    }

    private func readFromText(_ m: FileSyncManager, name: String) throws {
        let card = try #require(m.filingSuggestions.first { $0.fileName == name })
        let best = try #require(card.best)
        m.replaceFilingSuggestion(card.id, candidates: [FilingDestination(path: best.path, base: .high, evidence: .content, reasons: ["Page 1"], newSegments: [])])
    }

    private func report(sent: Int = 4, answered: Int = 4, changes: Int = 2, ending: FileSyncManager.FilingRefineReport.Ending = .answered,
                        requests: Int = 1, cost: Double = 0.04, offered: Int = 0) -> FileSyncManager.FilingRefineReport {
        var report = FileSyncManager.FilingRefineReport(
            changes: (0..<changes).map { .init(filePath: "/r/f\($0).pdf", fileName: "f\($0).pdf", before: "Receipts/2026", after: "Work/Invoices", reason: "Page 1 is an invoice") },
            asked: sent, reused: 1, hiddenFromClaude: 1, sent: sent, answered: answered, pagesSent: 2, folderNames: 238,
            requests: requests, costUSD: cost, modelName: "Opus 5.5", ending: ending, keptForNextPress: 0)
        report.offered = offered
        return report
    }

    // MARK: The plan says what goes

    @Test func aPlanNamesWhatGoesWhatWaitsAndWhatItCosts() async throws {
        let m = manager(model: AskClaudeModels.opus.id)
        let (p, root) = try await plan(m, files: 4, shared: [0, 1]); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)

        #expect(card.title == "Refine 4 files in Cloud Drive")
        let lines = card.lines
        #expect(lines.first?.text.hasPrefix("Your folder names (") == true)
        #expect(lines.contains { $0.text == "Names, types and years of 4 files" })
        #expect(lines.contains { $0.text.contains("Page-1 text, up to 800 characters, from 2 files in folders shared without asking") })
        let tick = try #require(lines.first { $0.kind == .tick })
        #expect(tick.text == "Also page-1 text from files in folders that ask each time")
        #expect(tick.detail?.hasPrefix("Unticked: those files go by name") == true)
        #expect(card.quoteLine.hasPrefix("Opus 5.5 · this chat’s model ≈ "))
        #expect(card.monthLine?.hasPrefix("This month ") == true && card.monthLine?.contains("of $25") == true)
        #expect(card.sendTitle == "Send 4 files" && card.canSend)
        #expect(card.limitMessage == nil && card.cutNote == nil)
    }

    @Test func theTickChangesTheLineAndSaysWhatItBuys() async throws {
        let m = manager()
        let (plain, root) = try await plan(m, files: 3, configure: { try readFromText($0, name: "mystery-2.pdf") }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: plain)
        let tick = try #require(card.lines.first { $0.kind == .tick })
        #expect(tick.detail?.contains("1 wait for their page text") == true)
        #expect(tick.detail?.contains("tick to include: +1 file") == true, "\(tick.detail ?? "")")
        #expect(card.plan.ticked == false)

        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        let on = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: ticked)
        #expect(on.plan.ticked && on.plan.waitingForPage == 0)
        #expect(on.lines.first { $0.kind == .tick }?.text == "Also page-1 text from 3 files in folders that ask each time")
        #expect(on.sendTitle == "Send 3 files")
    }

    @Test func aBigPassSaysHowManyGoAndHowManyWait() async throws {
        let m = manager()
        let (_, root) = try await plan(m, files: 2); defer { try? FileManager.default.removeItem(at: root) }
        // Built by hand, not written to disk (see `FilingRefinePagesTests`).
        let template = try #require(m.filingSuggestions.first)
        m.publishFilingSuggestions((0..<(CloudFilingRefiner.maxFiles + 12)).map {
            FilingSuggestion(filePath: root.path + "/Downloads/hand-\($0).pdf", fileName: "hand-\($0).pdf", size: 10,
                             modificationDate: nil, candidates: template.candidates, providerRoot: template.providerRoot)
        })
        let p = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        #expect(card.title == "Refine \(CloudFilingRefiner.maxFiles + 12) files in Cloud Drive")
        #expect(card.cutNote == "\(CloudFilingRefiner.maxFiles) of \(CloudFilingRefiner.maxFiles + 12) this pass. The other 12 stay for the next Refine.")
    }

    @Test func hiddenAndReusedFilesAreCountedAndNeverNamed() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 3, configure: {
            AskClaudePrivacy.setHiddenFolders([$0.filingLastProviderRoot.map { $0 + "/Downloads/mystery-0.pdf" } ?? ""], in: $0.filingContentDefaults)
        }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        let hidden = try #require(card.lines.first { $0.kind == .notSent })
        #expect(hidden.text == "1 file in a folder hidden from Claude" && hidden.detail == "Not named anywhere")
        #expect(!card.lines.contains { $0.text.contains("mystery-0") })
        #expect(card.plan.eligible == 2 && card.title == "Refine 2 files in Cloud Drive")
    }

    @Test func nothingNewOffersAskAgainAndCannotSend() async throws {
        let m = manager()
        let cache = try makeCanonicalTempRoot(prefix: "RefineCardCache"); defer { try? FileManager.default.removeItem(at: cache) }
        m.filingVerdictCacheURL = cache.appendingPathComponent("verdicts.json")
        let (first, root) = try await plan(m, files: 3); defer { try? FileManager.default.removeItem(at: root) }
        _ = await m.sendFilingRefine(first, scope: m.filingSuggestions)
        // Same manager: its saved answers are in memory at once, so no process-wide barrier on the disk write.

        let again = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: again)
        #expect(card.plan.nothingNew && !card.canSend)
        #expect(card.nothingNewTitle == "Nothing new to ask")
        #expect(card.nothingNewMessage == "All 3 files were answered before and are reused free.")
        #expect(card.lines.isEmpty)

        let asked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(askAgain: true)))
        let ask = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: asked)
        #expect(!ask.plan.nothingNew && ask.canSend && ask.plan.askedAgain)
    }

    @Test func overTheLimitTheCardOffersChangeLimitAndTheSmallerPartInstead() async throws {
        let m = manager()
        let (open, root) = try await plan(m, files: 8); defer { try? FileManager.default.removeItem(at: root) }
        guard case .quote(let quote) = open.billing else { Issue.record("no quote"); return }
        m.filingContentDefaults.set(quote.estCostUSD * 0.6, forKey: AskClaudeSpend.limitDefaultsKey)
        let over = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: over)

        #expect(card.plan.exceedsLimit && !card.canSend, "Send is off over the limit")
        let message = try #require(card.limitMessage)
        #expect(message.hasPrefix("This pass would pass your ") && message.contains("limit by"))
        #expect(message.hasSuffix("or send the smaller part that fits."))
        let fit = try #require(card.sendFitTitle)
        #expect(fit == "Send the \(try #require(over.fits)) that fit")
    }

    @Test func aModelWithNoPriceBlocksTheCardAndSaysWhichToDo() async throws {
        var plan = AskClaudeRefineCard.Plan()
        plan.eligible = 3; plan.toSend = 3; plan.modelName = "Mystery 9"; plan.blocked = true
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: plan, phase: .planned)
        #expect(card.blockedMessage == "Refine isn’t available on Mystery 9. Switch this chat to another model with the menu under the text box, then press Refine again.")
        #expect(!card.canSend)
    }

    @Test func aPlanThatIsNotBilledSaysNothingIsBilled() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 2, configure: { $0.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity } })
        defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        #expect(card.quoteLine.hasSuffix("nothing is billed") && card.monthLine == nil)
    }

    // MARK: Moves

    @Test func aSentPlanBecomesItsAnswersWithAReceipt() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 4); defer { try? FileManager.default.removeItem(at: root) }
        var card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        card.phase = .sending(answered: nil)
        card.finish(.sent(.init(asked: 4, reused: 1, classified: 4, changed: 2)), report: report())
        #expect(card.phase == .done && card.planID == nil && !card.canSend)
        #expect(card.answersTitle == "Refined 4 files · 2 homes changed")
        #expect(card.answersFootnote == "1 answered before was reused · 1 left out: hidden from Claude")
        #expect(card.receiptLine == "Sent 4 file names, 2 page-1 excerpts and your folder list (238) · 1 request · 4¢ · Opus 5.5")
        #expect(card.endingTitle == nil)
        #expect(card.answers?.rows.first?.before == "Receipts/2026" && card.answers?.rows.first?.after == "Work/Invoices")
    }

    @Test func aPassThatChangedNothingSaysSo() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 3, reused: 0, classified: 3, changed: 0)), report: report(sent: 3, answered: 3, changes: 0))
        #expect(card.answersTitle == "Refined 3 files · no better homes found")
    }

    @Test func aPassWhoseAnswerWentUnderTryAnotherSaysWhereItIs() throws {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 1, reused: 0, classified: 1, changed: 0)),
                    report: report(sent: 1, answered: 1, changes: 0, offered: 1))
        #expect(card.answersTitle == "Refined 1 file · no home changed")
        #expect(card.answersFootnote?.hasPrefix("Claude picked another folder for 1 file: Try Another Folder shows it · ") == true)
        #expect(card.toldToClaude?.hasSuffix("no suggestion changed. For 1 file you picked another folder, "
                                             + "kept as the next choice under Try Another Folder.") == true)
        // Kept through a save.
        let saved = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONEncoder().encode(card))
        #expect(saved.answers?.offered == 1)

        var both = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        both.finish(.sent(.init(asked: 4, reused: 0, classified: 4, changed: 2)),
                    report: report(changes: 2, offered: 2))
        #expect(both.answersTitle == "Refined 4 files · 2 homes changed")
        #expect(both.answersFootnote?.hasPrefix("Claude picked another folder for 2 files: Try Another Folder shows each") == true)
        #expect(both.toldToClaude?.contains("(Page 1 is an invoice). For 2 files you picked another folder") == true)
    }

    @Test func aFailedPassKeepsWhatArrivedAndSaysItMayHaveBeenBilled() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 6, reused: 0, classified: 6, changed: 2, outcome: .failed)),
                    report: report(sent: 6, answered: 4, changes: 2, ending: .failed("The connection dropped."), cost: 0.04))
        #expect(card.endingTitle == "Claude didn’t finish: 4 of 6 answers arrived")
        let text = try? #require(card.endingMessage)
        #expect(text?.hasPrefix("The connection dropped. The 4 answers that arrived are kept and shown in Organize.") == true)
        #expect(text?.contains("Nothing is called Claude’s that Claude did not answer.") == true)
        #expect(text?.hasSuffix("A request had started, so up to about 4¢ may have been billed.") == true)
        #expect(card.receiptLine?.contains("1 request, not finished") == true)
    }

    @Test func aStoppedPassSaysWhatRanAndWhatItCost() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 6, reused: 0, classified: 6, changed: 1, outcome: .stopped)),
                    report: report(sent: 6, answered: 3, changes: 1, ending: .stopped, cost: 0.03))
        #expect(card.endingTitle == "Stopped after 3 of 6 answers")
        #expect(card.endingMessage == "The 3 answers that arrived are kept and shown in Organize. About 3¢ was billed for what ran.")
    }

    @Test func aPassThatNeverStartedSaysNothingWasSent() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .failed)),
                    report: report(sent: 0, answered: 0, changes: 0, ending: .failed("There is no Claude key to read."), requests: 0, cost: 0))
        #expect(card.endingTitle == "Couldn’t ask Claude")
        #expect(card.endingMessage == "There is no Claude key to read. Nothing was sent, and the suggestions are unchanged.")
        #expect(card.receiptLine == nil, "no request, no receipt")
    }

    @Test func anUnreadableKeySaysSoAndOwnsNothingAsClaudes() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .downgraded)),
                    report: report(sent: 0, answered: 0, changes: 0, ending: .downgraded, requests: 0, cost: 0))
        #expect(card.endingTitle == "Couldn’t reach Claude")
        #expect(card.endingMessage?.contains("nothing was sent or billed") == true)
    }

    @Test func aChangedRequestShowsTheNewPlanAndSendsNothing() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 3); defer { try? FileManager.default.removeItem(at: root) }
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.requoted(p), report: nil)
        #expect(card.phase == .planned && card.planID == p.id && card.plan.toSend == p.toSend)
        #expect(card.notice?.hasSuffix("Nothing was sent.") == true)
        #expect(card.canSend, "the new plan can be read and sent")
    }

    @Test func aPlanRefusedForTheLimitComesBackAsANewPlanOrClosesWithTheReason() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 3); defer { try? FileManager.default.removeItem(at: root) }
        var withNew = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        withNew.finish(.blocked, report: nil, replanned: p)
        #expect(withNew.phase == .planned && withNew.planID == p.id)
        #expect(withNew.notice?.hasPrefix("Nothing was sent: this would pass your monthly limit") == true)

        var without = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        without.finish(.blocked, report: nil)
        #expect(without.phase == .closed && without.closedLine?.hasPrefix("Nothing was sent: this would pass") == true)
    }

    @Test func everyOtherResultLeavesACardThatCannotSend() {
        for result: FileSyncManager.FilingRefineSendResult in [.stale, .unavailable, .nothingToSend] {
            var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
            card.finish(result, report: nil)
            #expect(!card.canSend && card.closedLine != nil, "\(result)")
        }
        // Sent, but no report to show: out of date rather than a card claiming answers it lacks.
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 1, reused: 0, classified: 1, changed: 0)), report: nil)
        #expect(card.phase == .expired && card.answers == nil)
    }

    @Test func refineNamesLeavesAReceiptInTheChat() {
        #expect(AskClaudeRefineCard.refineNamesReceipt(folderNames: 3, fileNames: 5, costUSD: 0.012, modelName: "Opus 5.5", answered: true)
                == "Refine Names · sent 3 folder names and 5 file names · 1 request · 1¢ · Opus 5.5")
        #expect(AskClaudeRefineCard.refineNamesReceipt(folderNames: 1, fileNames: 0, costUSD: 0, modelName: "Opus 5.5", answered: false)
                == "Refine Names · sent 1 folder name, no file names · 1 request, not finished · no cost recorded · Opus 5.5")
    }

    // MARK: What Claude is told

    @Test func theChatsClaudeHearsAboutTheTwentyMostChangedAndHowManyMore() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 30, reused: 0, classified: 30, changed: 25)), report: report(sent: 30, answered: 30, changes: 25))
        let line = try? #require(card.toldToClaude)
        #expect(line?.hasPrefix("They ran Refine from Organize on 30 files; a separate request to Opus 5.5 that you didn’t make.") == true)
        #expect(line?.contains("It changed 25 suggested homes: “f0.pdf” → Work/Invoices (Page 1 is an invoice)") == true)
        #expect(line?.contains("“f19.pdf”") == true && line?.contains("“f20.pdf”") == false)
        #expect(line?.contains("; and 5 more") == true)
        #expect(line?.hasSuffix("Nothing has moved: they still File it in Organize.") == true)
    }

    @Test func aPassThatChangedNothingOrNeverRanTellsClaudeLittleOrNothing() {
        var none = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        none.finish(.sent(.init(asked: 3, reused: 0, classified: 3, changed: 0)), report: report(sent: 3, answered: 3, changes: 0))
        #expect(none.toldToClaude?.hasSuffix("no suggestion changed.") == true)

        var key = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        key.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .downgraded)),
                   report: report(sent: 0, answered: 0, changes: 0, ending: .downgraded, requests: 0, cost: 0))
        #expect(key.toldToClaude == nil, "nothing Claude did not hear of happened")

        let waiting = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .planned)
        #expect(waiting.toldToClaude == nil, "a plan that was not sent is not told")
    }

    @Test func aStoppedPassTellsClaudeItWasStopped() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 6, reused: 0, classified: 6, changed: 1, outcome: .stopped)),
                    report: report(sent: 6, answered: 3, changes: 1, ending: .stopped))
        #expect(card.toldToClaude?.contains("They stopped it after 3 of 6 answers; ") == true)
    }

    // MARK: Saved and restored

    @Test func aRestoredCardCannotSendAndAnAnsweredOneKeepsItsAnswers() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 3); defer { try? FileManager.default.removeItem(at: root) }
        let waiting = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        #expect(waiting.canSend)
        let saved = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONEncoder().encode(waiting))
        #expect(saved.planID == nil && !saved.canSend, "a plan does not outlive the app: its id is not saved")
        let back = saved.restored
        #expect(back.phase == .expired && back.closedLine == "This plan is out of date, so it can’t send. Press Refine in Organize to make a new one.")

        var sending = waiting; sending.phase = .sending(answered: 2)
        #expect(sending.restored.phase == .expired, "a request that ran when the app quit has no card to finish")

        var done = waiting
        done.finish(.sent(.init(asked: 3, reused: 0, classified: 3, changed: 2)), report: report())
        let kept = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONEncoder().encode(done)).restored
        #expect(kept.phase == .done && kept.answers?.rows.count == 2, "answers come back as they were")

        var closed = waiting; closed.phase = .closed
        #expect(closed.restored.phase == .closed)
    }

    @Test func aCardWithNoSavedFieldsStillDecodesFromAnOlderShape() throws {
        // `notice` and `answers` are optional, so a card saved without them is still a card.
        let json = #"{"sourceName":"Cloud Drive","plan":{},"phase":{"planned":{}}}"#
        let card = try JSONDecoder().decode(AskClaudeRefineCard.self, from: Data(json.utf8))
        #expect(card.sourceName == "Cloud Drive" && card.notice == nil && card.answers == nil)
    }
}
