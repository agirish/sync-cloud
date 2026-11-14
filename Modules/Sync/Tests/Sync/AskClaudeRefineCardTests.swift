import Foundation
import Testing
@testable import Sync

/// The Refine card's words and moves (TE335, C3): what each state says, which buttons it allows, and
/// what a send does to it. Built from real plans, so the sentences are about real numbers.
extension HandBuiltRefineSuites {
@MainActor
@Suite struct AskClaudeRefineCardTests {

    /// One manager for the suite, reset per test (see `HandBuiltFiling.reset`).
    private static var shared: FileSyncManager { HandBuiltFiling.manager }
    private static var defaults: ScratchDefaults { HandBuiltFiling.defaults }


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
                        requests: Int = 1, cost: Double = 0.04, waiting: Int = 0, offered: Int = 0) -> FileSyncManager.FilingRefineReport {
        var report = FileSyncManager.FilingRefineReport(
            changes: (0..<changes).map { .init(filePath: "/r/f\($0).pdf", fileName: "f\($0).pdf", before: "Receipts/2026", after: "Work/Invoices", reason: "Page 1 is an invoice") },
            asked: sent, reused: 1, hiddenFromClaude: 1, sent: sent, answered: answered, pagesSent: 2, folderNames: 238,
            requests: requests, costUSD: cost, modelName: "Opus 5.5", ending: ending, keptForNextPress: 0, waitingForPage: waiting)
        report.offered = offered
        return report
    }

    // MARK: The plan says what goes

    @Test func aNormalPlanGroupsWhatGoesTheOneCallAndWhatIsLeftOut() async throws {
        let m = manager(model: AskClaudeModels.opus.id)
        let (p, root) = try await plan(m, files: 4, shared: [0, 1]); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)

        #expect(card.layout == .normal && card.title == "Refine 4 files in Cloud Drive")
        let goes = card.goesLines
        #expect(goes[0] == .init(count: "4", text: "files: name, type, year", info: nil, action: .whichFiles))
        #expect(goes[1].count == "2" && goes[1].text == "first pages" && goes[1].info != nil)
        #expect(goes.last?.text == "folder names" && goes.last?.action == .customize, "the folder list is a visible line with Customize…")
        let ok = try #require(card.ok)
        #expect(ok.title == "Send first pages for 2 more files" && !ok.checked)
        #expect(ok.info == "Their folders aren’t shared with Claude, so a first page goes only if you tick this. It counts for this pass only.")
        #expect(card.monthLine.hasPrefix("Opus 5.5 · ") && card.monthLine.contains("of $25 this month"))
        #expect(card.sendTitle.hasPrefix("Send 4 files · ") && card.canSend)
        #expect(card.limitMessage == nil && card.cutNote == nil && card.tickHint == nil)
    }

    @Test func theTickIsTheOneDecisionAndTheButtonFollowsIt() async throws {
        let m = manager()
        let (plain, root) = try await plan(m, files: 3, configure: { try readFromText($0, name: "mystery-2.pdf") }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: plain)
        let ok = try #require(card.ok)
        #expect(ok.title == "Send first pages for 3 more files")
        #expect(ok.detail?.hasPrefix("Improves 1 more file") == true, "\(ok.detail ?? "")")
        #expect(card.plan.toSend == 2 && card.sendTitle.hasPrefix("Send 2 files"))

        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        let on = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: ticked)
        #expect(on.ok?.checked == true && on.ok?.detail == "Included in the price below")
        #expect(on.sendTitle.hasPrefix("Send 3 files"), "ticking brings the waiting file in")
    }

    /// The case from the screenshot: one file waits for its first page and nothing else can go.
    @Test func whenEveryFileWaitsTheCardSaysWhyAndTheTickUnblocksIt() async throws {
        let m = manager()
        let (zero, root) = try await plan(m, files: 1, configure: { try readFromText($0, name: "mystery-0.pdf") }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "iCloud", plan: zero)

        #expect(card.layout == .needsFirstPages)
        let note = try #require(card.needsFirstPagesNote)
        #expect(note.text == "A name alone can’t improve this file.")
        #expect(note.info == "Its suggested folder came from reading its first page, and its folder isn’t shared with Claude, so Claude hasn’t seen that page.")
        #expect(card.waitingNames == ["mystery-0.pdf"])
        let ok = try #require(card.ok)
        #expect(ok.title == "Send its first page" && !ok.checked && ok.info == "Up to 800 characters of text from each first page, once, for this pass only.")
        #expect(card.tickHint == "Tick the box to send this file.")
        #expect(card.sendTitle == "Send 0 files" && !card.canSend, "Send is off, and the card says what turns it on")
        #expect(card.goesLines.isEmpty)

        let ticked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(pagesFromAskEachTime: true)))
        let on = AskClaudeRefineCard(sourceName: "iCloud", plan: ticked)
        #expect(on.layout == .normal && on.canSend && on.tickHint == nil)
        #expect(on.sendTitle.hasPrefix("Send 1 file · "))
    }

    @Test func whichFilesNamesEachFileAndWhatItSends() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 4, shared: [0, 1], configure: { try readFromText($0, name: "mystery-3.pdf") }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        let status = Dictionary(uniqueKeysWithValues: card.plan.files.map { ($0.name, $0.status) })
        #expect(status == ["mystery-0.pdf": .namePlusPage, "mystery-1.pdf": .namePlusPage, "mystery-2.pdf": .nameOnly, "mystery-3.pdf": .needsOK])
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
        #expect(card.notSentLines.contains { $0.count == "12" && $0.text == "wait for the next Refine" })
    }

    @Test func hiddenFilesAreCountedAndNeverNamed() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 3, configure: {
            AskClaudePrivacy.setHiddenFolders([$0.filingLastProviderRoot.map { $0 + "/Downloads/mystery-0.pdf" } ?? ""], in: $0.filingContentDefaults)
        }); defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        let hidden = try #require(card.notSentLines.first)
        #expect(hidden.count == "1" && hidden.text == "hidden from Claude" && hidden.info?.contains("never sent or named") == true)
        #expect(!card.plan.files.contains { $0.name == "mystery-0.pdf" } && card.waitingNames.isEmpty)
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
        #expect(card.layout == .nothingNew && !card.canSend)
        #expect(card.nothingNewTitle == "Nothing new to ask")
        #expect(card.nothingNewMessage == "All 3 were answered before. Nothing to send, nothing billed.")
        #expect(card.goesLines.isEmpty && card.notSentLines.isEmpty && card.ok == nil)

        let asked = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(askAgain: true)))
        let ask = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: asked)
        #expect(ask.layout == .normal && ask.canSend && ask.plan.askedAgain)
    }

    @Test func overTheLimitTheCardLeadsWithTheWarningAndOffersTheSmallerPart() async throws {
        let m = manager()
        let (open, root) = try await plan(m, files: 8); defer { try? FileManager.default.removeItem(at: root) }
        guard case .quote(let quote) = open.billing else { Issue.record("no quote"); return }
        m.filingContentDefaults.set(quote.estCostUSD * 0.6, forKey: AskClaudeSpend.limitDefaultsKey)
        let over = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: over)

        #expect(card.layout == .overLimit && !card.canSend, "Send is off over the limit")
        let message = try #require(card.limitMessage)
        #expect(message.hasPrefix("Over your ") && message.contains(" limit by ") && message.hasSuffix("."))
        let fits = try #require(over.fits)
        #expect(card.wholePlanLine.count == "8" && card.wholePlanLine.action == .whichFiles)
        #expect(card.fitLine?.count == "\(fits)")
        #expect(try #require(card.sendFitTitle).hasPrefix("Send \(fits) file"))
    }

    @Test func aModelWithNoPriceBlocksTheCardAndSaysWhichToDo() async throws {
        var plan = AskClaudeRefineCard.Plan()
        plan.eligible = 3; plan.toSend = 3; plan.modelName = "Mystery 9"; plan.blocked = true
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: plan, phase: .planned)
        #expect(card.layout == .blocked)
        #expect(card.blockedMessage == "Refine isn’t available on Mystery 9. Switch this chat to another model with the menu under the text box, then press Refine again.")
        #expect(!card.canSend)
    }

    @Test func aPlanOffTheClaudeRouteSaysNothingIsBilled() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 2, configure: { $0.filingBackendIdentity = { _ in FileSyncManager.onDeviceBackendIdentity } })
        defer { try? FileManager.default.removeItem(at: root) }
        let card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        #expect(!card.plan.routesToClaude && card.monthLine == "Runs on this Mac · nothing is billed")
    }

    // MARK: Moves

    @Test func aSentPlanBecomesItsAnswersWithAReceiptBehindAnInfoMark() async throws {
        let m = manager()
        let (p, root) = try await plan(m, files: 4); defer { try? FileManager.default.removeItem(at: root) }
        var card = AskClaudeRefineCard(sourceName: "Cloud Drive", plan: p)
        card.phase = .sending(answered: nil)
        card.finish(.sent(.init(asked: 4, reused: 1, classified: 4, changed: 2)), report: report())
        #expect(card.phase == .done && card.planID == nil && !card.canSend)
        #expect(card.answersTitle == "2 homes changed")
        #expect(card.answersSub == "4 files checked · about 4¢ · nothing has moved yet")
        #expect(card.answersFootnote == "2 kept · 1 reused · 1 hidden from Claude")
        #expect(card.receiptInfo == "1 request · 4 names, 2 first pages and 238 folder names sent · Opus 5.5 · about 4¢.")
        #expect(card.endingTitle == nil && card.answersWaitingNote == nil && card.retryTitle == nil)
        #expect(card.answers?.rows.first?.before == "Receipts/2026" && card.answers?.rows.first?.after == "Work/Invoices")
    }

    @Test func theAnswersSayWhichFilesStillNeedAFirstPage() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 4, reused: 0, classified: 4, changed: 2)), report: report(waiting: 2))
        #expect(card.answersWaitingNote == "2 files still need a first page.")
        var one = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        one.finish(.sent(.init(asked: 4, reused: 0, classified: 4, changed: 2)), report: report(waiting: 1))
        #expect(one.answersWaitingNote == "1 file still needs a first page.")
    }

    @Test func aPassThatChangedNothingSaysSo() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 3, reused: 0, classified: 3, changed: 0)), report: report(sent: 3, answered: 3, changes: 0))
        #expect(card.answersTitle == "No better homes found")
        #expect(card.answersSub == "3 files checked · about 4¢ · nothing has moved yet")
    }

    @Test func aPassWhoseAnswerWentUnderTryAnotherSaysWhereItIs() throws {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 1, reused: 0, classified: 1, changed: 0)),
                    report: report(sent: 1, answered: 1, changes: 0, offered: 1))
        #expect(card.answersTitle == "No home changed")
        #expect(card.answersFootnote?.hasPrefix("Claude picked another folder for 1 file: Try Another Folder shows it · ") == true)
        #expect(card.toldToClaude?.hasSuffix("no suggestion changed. For 1 file you picked another folder, "
                                             + "kept as the next choice under Try Another Folder.") == true)
        // Kept through a save.
        let saved = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONEncoder().encode(card))
        #expect(saved.answers?.offered == 1)

        var both = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        both.finish(.sent(.init(asked: 4, reused: 0, classified: 4, changed: 2)),
                    report: report(changes: 2, offered: 2))
        #expect(both.answersTitle == "2 homes changed")
        #expect(both.answersFootnote?.hasPrefix("Claude picked another folder for 2 files: Try Another Folder shows each") == true)
        #expect(both.toldToClaude?.contains("(Page 1 is an invoice). For 2 files you picked another folder") == true)
    }

    @Test func aFailedPassKeepsWhatArrivedAndOffersToTryAgainForTheRest() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 6, reused: 0, classified: 6, changed: 2, outcome: .failed)),
                    report: report(sent: 6, answered: 4, changes: 2, ending: .failed("The connection dropped."), cost: 0.04))
        #expect(card.endingTitle == "The connection dropped after 4 of 6 answers")
        #expect(card.endingMessage == "The 4 answers are kept in Organize. 2 files weren’t answered.")
        #expect(card.endingInfo == "A request had started, so up to about 4¢ may have been billed even though it didn’t finish. Nothing is called Claude’s that Claude didn’t answer.")
        #expect(card.retryTitle == "Try Again for the 2")
        #expect(card.receiptInfo?.hasPrefix("1 request, not finished") == true)
    }

    @Test func aStoppedPassSaysWhatRanAndWhatItCost() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 6, reused: 0, classified: 6, changed: 1, outcome: .stopped)),
                    report: report(sent: 6, answered: 3, changes: 1, ending: .stopped, cost: 0.03))
        #expect(card.endingTitle == "Stopped after 3 of 6 answers")
        #expect(card.endingMessage == "The 3 answers are kept in Organize. 3 files weren’t answered.")
        #expect(card.endingInfo == "About 3¢ was billed for what ran.")
        #expect(card.retryTitle == "Try Again for the 3")
        #expect(card.toldToClaude?.contains("They stopped it after 3 of 6 answers; ") == true)
    }

    @Test func aPassThatNeverStartedSaysNothingWasSent() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .failed)),
                    report: report(sent: 0, answered: 0, changes: 0, ending: .failed("There is no Claude key to read."), requests: 0, cost: 0))
        #expect(card.endingTitle == "Couldn’t ask Claude")
        #expect(card.endingMessage == "There is no Claude key to read. Nothing was sent, and the suggestions are unchanged.")
        #expect(card.receiptInfo == nil && card.endingInfo == nil && card.retryTitle == nil, "no request, no receipt, nothing to retry")
        #expect(card.toldToClaude == nil, "the card says nothing was sent, so Claude is not told a request ran")
    }

    @Test func anUnreadableKeySaysSoAndOwnsNothingAsClaudes() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .downgraded)),
                    report: report(sent: 0, answered: 0, changes: 0, ending: .downgraded, requests: 0, cost: 0))
        #expect(card.endingTitle == "Couldn’t reach Claude")
        #expect(card.endingMessage?.contains("nothing was sent or billed") == true)
    }

    @Test func theRunningTimeIsOnlyAsKnownAsTheStartTime() {
        let card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        #expect(card.progressLine(elapsed: 12) == "12 s · keep working in Organize")
        #expect(card.progressLine(elapsed: nil) == "Keep working in Organize")
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
        #expect(line?.contains("It changed 25 suggested homes: “f0.pdf” ⟦/r/f0.pdf⟧ → Work/Invoices (Page 1 is an invoice)") == true)
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

    /// A changed file goes to Claude marked with its path, so the chat turns it into a handle, and a
    /// folder hidden before the next question drops the line on the privacy restart.
    @Test func eachChangedFileCarriesItsPathSoAFolderHiddenSinceDropsTheLine() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        let r = FileSyncManager.FilingRefineReport(
            changes: [.init(filePath: "/Users/x/Downloads/Lab results.pdf", fileName: "Lab results.pdf", before: nil, after: "Health/Labs", reason: nil)],
            asked: 1, reused: 0, hiddenFromClaude: 0, sent: 1, answered: 1, pagesSent: 0, folderNames: 10,
            requests: 1, costUSD: 0.01, modelName: "Opus 5.5", ending: .answered, keptForNextPress: 0, waitingForPage: 0)
        card.finish(.sent(.init(asked: 1, reused: 0, classified: 1, changed: 1)), report: r)
        let line = try? #require(card.toldToClaude)
        #expect(line?.contains("“Lab results.pdf” ⟦/Users/x/Downloads/Lab results.pdf⟧ → Health/Labs") == true)
        #expect(line?.contains("Downloads") == true, "the folder's name is in the line, for the hidden check to find")
    }

    @Test func aStopThatNeverReachedClaudeTellsItNothing() {
        var stopped = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        stopped.finish(.sent(.init(asked: 2, reused: 0, classified: 0, changed: 0, outcome: .stopped)),
                       report: report(sent: 2, answered: 0, changes: 0, ending: .stopped, requests: 0, cost: 0))
        #expect(stopped.toldToClaude == nil)
    }

    @Test func savedAnswersThatMovedHomesAreNotCalledUnchanged() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 3, reused: 2, classified: 0, changed: 2, outcome: .failed)),
                    report: report(sent: 1, answered: 0, changes: 2, ending: .failed("There is no Claude key to read."), requests: 0, cost: 0))
        #expect(card.endingMessage == "There is no Claude key to read. Nothing was sent; saved answers changed the homes below.")
    }

    @Test func aStopThatLandsAfterTheLastAnswerDoesNotCountZeroUnanswered() {
        var card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        card.finish(.sent(.init(asked: 3, reused: 0, classified: 3, changed: 1, outcome: .stopped)),
                    report: report(sent: 3, answered: 3, changes: 1, ending: .stopped, cost: 0.02))
        #expect(card.endingMessage == "The 3 answers are kept in Organize.")
    }

    @Test func aStopBeforeSendingAndAPassWhoseListMovedSayWhatHappened() {
        var stopped = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        stopped.finish(.stoppedBeforeSending, report: nil)
        #expect(stopped.phase == .closed && stopped.closedLine == "Stopped before anything was sent.")

        var gone = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .sending(answered: nil))
        gone.finish(.discarded(sent: 4, costUSD: 0.03), report: nil)
        #expect(gone.phase == .closed)
        #expect(gone.closedLine == "The list in Organize changed while Claude answered, so the answers for 4 files weren’t applied. "
                + "About 3¢ was billed. They’re saved: press Refine in Organize to use them without asking again.")
    }

    @Test func singularCountsReadAsSingular() {
        var plan = AskClaudeRefineCard.Plan()
        plan.eligible = 3; plan.toSend = 2; plan.folderNames = 1; plan.keptForNextPress = 1; plan.costUSD = 0.05
        plan.exceedsLimit = true; plan.fits = 1; plan.fitsCostUSD = 0.02; plan.spentUSD = 24.99; plan.limitUSD = 25
        let card = AskClaudeRefineCard(sourceName: "X", plan: plan, phase: .planned)
        #expect(card.goesLines.contains { $0.text == "folder name" })
        #expect(card.notSentLines.contains { $0.text == "waits for the next Refine" })
        #expect(card.fitLine?.text == "fits under the limit · about 2¢", "its own quote, not half the whole price")
        #expect(card.sendFitTitle == "Send 1 file · about 2¢")
    }

    @Test func aCardKeepsTheFilesItWasForThroughASavedChat() throws {
        let card = AskClaudeRefineCard(sourceName: "X", plan: .init(), phase: .done, answers: .init())
        var withScope = card; withScope.scopePaths = ["/r/a.pdf", "/r/b.pdf"]
        let back = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONEncoder().encode(withScope)).restored
        #expect(back.scopePaths == ["/r/a.pdf", "/r/b.pdf"], "Try Again after a relaunch still knows its files")
        // A card saved before the field existed still decodes.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        json["scopePaths"] = nil
        let old = try JSONDecoder().decode(AskClaudeRefineCard.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.scopePaths.isEmpty && old.phase == .done)
    }

    @Test func aCardBeingQuotedCannotSendOrTick() {
        var plan = AskClaudeRefineCard.Plan()
        plan.eligible = 2; plan.toSend = 2; plan.costUSD = 0.01
        var card = AskClaudeRefineCard(sourceName: "X", plan: plan, phase: .planned)
        card.planID = UUID()
        #expect(card.canSend && card.canTick)
        card.quoting = true
        #expect(!card.canSend && !card.canTick, "Send waits for the new plan, so the old one can't go")
        #expect(!card.restored.quoting)
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
        #expect(back.phase == .expired && back.closedLine == "This Refine plan is out of date, so it can’t send. Press Refine in Organize to make a new one.")

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
}
