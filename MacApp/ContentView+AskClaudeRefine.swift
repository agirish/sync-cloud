import Design
import Events
import FileExplorer
import Settings
import SwiftUI
import Sync

/// Refine in the Ask Claude chat (TE335, C3): Organize's button opens a plan card here, the person
/// reads what goes and what it costs, and **Send is a click on that card**, never anything typed or
/// spoken. The pass itself is Organize's (`FileSyncManager`); this window only holds the card.
extension ContentView {

    /// Organize's "Set up Claude to refine": with no key, the panel opens in its key setup and the
    /// plan card appears once the key is saved (TE335, LU-A). With a key already, it is Refine.
    func askClaudeRefineSetup() {
        let scope = syncManager.filingSuggestionsEligibleForRefine(syncManager.filingSuggestions)
        guard !AnthropicKeychain.isConfigured else {
            askClaudeRefine(scope: scope)
            return
        }
        let chat = askClaudeChat
        let source = lensProviderName.isEmpty ? "this folder" : lensProviderName
        chat.pendingRefine = (source, scope.map(\.filePath))
        if chat.onKeyChanged == nil {
            chat.onKeyChanged = {
                guard AnthropicKeychain.isConfigured, let pending = chat.pendingRefine else { return }
                chat.pendingRefine = nil
                let paths = Set(pending.paths)
                askClaudeRefine(scope: syncManager.filingSuggestions.filter { paths.contains($0.filePath) }, source: pending.source)
            }
        }
        if !askClaudeHolder.visibility.isOpen { toggleAskClaude() }
        askClaudeHolder.visibility.focusRequests += 1
        Logger.shared.info("Ask Claude: Refine is waiting for a key; the panel is open on its setup")
    }

    /// Organize's "Refine N with Claude…": makes the plan and puts its card in the chat, opening the
    /// panel if it is closed.
    /// `forCard`: the chat's selection card it came from, whose rows its answers also update (TE342).
    func askClaudeRefine(scope: [FilingSuggestion], source named: String? = nil, forCard: UUID? = nil) {
        guard !scope.isEmpty else { return }
        guard AnthropicKeychain.isConfigured else {
            askClaudeRefineSetup()
            return
        }
        let chat = askClaudeChat
        let source = named ?? (lensProviderName.isEmpty ? "this folder" : lensProviderName)
        if !askClaudeHolder.visibility.isOpen { toggleAskClaude() }
        Task { @MainActor in
            guard let plan = await syncManager.prepareFilingRefine(scope) else {
                let hidden = syncManager.filingSuggestionsHiddenFromClaude(scope)
                chat.addNote(syncManager.isRefiningFilingSuggestions
                             ? "A Refine is already running. Its card has Stop."
                             : hidden > 0 && syncManager.filingSuggestionsEligibleForRefine(scope).isEmpty
                             ? "Refine has nothing it may send: every file is hidden from Claude."
                             : "Refine has nothing to ask right now.")
                return
            }
            var card = AskClaudeRefineCard(sourceName: source, plan: plan, scopePaths: scope.map(\.filePath))
            card.forCard = forCard
            chat.addRefineCard(card)
            Logger.shared.info("Ask Claude: a Refine plan for \(plan.eligible) file(s) is waiting for Send")
        }
    }

    /// Organize's way into the chat card that holds the latest pass: only while a chat holds one.
    var askClaudeRefineChatLink: LensRefineChatLink {
        let chat = askClaudeChat
        return LensRefineChatLink(
            isAvailable: { chat.items.contains { if case .refine(let card) = $0.kind, card.answers != nil { true } else { false } } },
            show: { if !askClaudeHolder.visibility.isOpen { toggleAskClaude() } })
    }

    /// Once, at the window's setup: Try Another's requests count on one running line in the chat,
    /// and a Refine Names request leaves its receipt there, whether or not the column has been
    /// opened yet (the panel is built only while it is open).
    func installAskClaudeRefineReports() {
        guard syncManager.filingTryAnotherReports == nil else { return }
        let chat = askClaudeChat
        syncManager.filingTryAnotherReports = { chat.noteTryAnother($0) }
        syncManager.filingMappingRefineReports = { report in
            chat.addNote(AskClaudeRefineCard.refineNamesReceipt(folderNames: report.folderNames, fileNames: report.fileNames,
                                                                costUSD: report.costUSD, modelName: report.modelName,
                                                                answered: report.answered))
        }
    }

    /// What a Refine card does and reads.
    var askClaudeRefineBridge: AskClaudeRefineBridge {
        installAskClaudeRefineReports()
        return AskClaudeRefineBridge(
            send: { askClaudeRefineSend($0, fitting: false) },
            sendFit: { askClaudeRefineSend($0, fitting: true) },
            cancel: { askClaudeRefineCancel($0) },
            stop: { _ in syncManager.stopFilingRefine() },
            setTick: { id, on in askClaudeRefineChange(id) { $0.pagesFromAskEachTime = on } },
            askAgain: { id in askClaudeRefineChange(id) { $0.askAgain = true } },
            requote: { id in askClaudeRefineChange(id) { _ in } },
            retry: { id in
                guard let card = askClaudeChat.refineCard(id) else { return }
                // What Claude already answered is saved, so a new plan asks only about what is left.
                let scope = askClaudeRefineScope(id)
                guard !scope.isEmpty else {
                    askClaudeChat.addNote("The files this Refine was about aren’t in Organize’s list now. Press Refine there to make a new plan.")
                    return
                }
                askClaudeRefine(scope: scope, source: card.sourceName)
            },
            folders: { syncManager.filingLastTaxonomyFolders.sorted() },
            leftOut: { syncManager.filingRefineLeftOutFolders },
            setLeftOut: { id, folders in
                syncManager.filingRefineLeftOutFolders = folders
                askClaudeRefineChange(id) { _ in }
            },
            changeLimit: { openSettings(on: SettingsView.SettingsTab.cloudRefineSetup) },
            undo: { id in
                let chat = askClaudeChat
                // The manager holds the latest pass's undo only: an older card never takes it.
                guard chat.refineUndoCard == id else { return }
                chat.refineUndoCard = nil
                let restored = syncManager.undoFilingRefine()
                guard restored > 0 else {
                    chat.addNote("Nothing went back: the suggestions in Organize changed since this Refine.")
                    return
                }
                chat.updateRefine(id) { $0.answers?.undone = true }
                // The selection card's rows it moved go back too, unless they've touched them.
                if let card = chat.refineCard(id)?.forCard {
                    chat.updatePlan(card) { $0.refineUndone() }
                    askClaudeRenameForFolders(card)
                }
                chat.tellClaude("They chose Undo Refine on the card: \(restored) suggestion\(restored == 1 ? "" : "s") went back to the on-device answer.")
            },
            canUndo: { id in
                guard let card = askClaudeChat.refineCard(id), card.answers?.undone != true,
                      askClaudeChat.refineUndoCard == id else { return false }
                return syncManager.canUndoFilingRefine
            },
            reveal: { path in revealInBrowse(path, with: [path], from: .pdfToolBanner) })
    }

    /// The suggestions a card was made for, as they are now.
    func askClaudeRefineScope(_ id: UUID) -> [FilingSuggestion] {
        let paths = Set(askClaudeChat.refineCard(id)?.scopePaths ?? [])
        return syncManager.filingSuggestions.filter { paths.contains($0.filePath) }
    }

    /// The plan a card controls, while it is still the source's open one.
    private func askClaudeRefineOpenPlan(_ card: AskClaudeRefineCard) -> FileSyncManager.FilingRefinePlan? {
        guard let planID = card.planID else { return nil }
        return syncManager.filingOpenRefinePlans.values.first { $0.id == planID }
    }

    /// Makes the card's plan again with one option changed (the tick, ask again, folders left out).
    /// The new plan replaces the old as the source's open one, so only the card on screen can send.
    /// While it is made the card is quoting: Send and the tick wait, so a click can't send the old
    /// plan. Choices made meanwhile add up (`wantedOptions`), and only the latest quote lands.
    private func askClaudeRefineChange(_ id: UUID, _ change: @escaping (inout FileSyncManager.FilingRefineOptions) -> Void) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id), case .planned = card.phase, card.planID != nil,
              let old = askClaudeRefineOpenPlan(card) else {
            chat.updateRefine(id) { if case .planned = $0.phase { $0.phase = .expired; $0.planID = nil } }
            return
        }
        var options = card.wantedOptions ?? old.options
        change(&options)
        let token = UUID()
        chat.updateRefine(id) { $0.quoting = true; $0.quoteToken = token; $0.wantedOptions = options }
        let scope = askClaudeRefineScope(id)
        Task { @MainActor in
            let fresh = await syncManager.prepareFilingRefine(scope, options: options)
            // A later change, a Cancel or a send since: this quote is not the card's any more.
            guard let now = chat.refineCard(id), now.quoteToken == token, case .planned = now.phase else {
                if let fresh, chat.refineCard(id)?.planID != fresh.id { syncManager.discardFilingRefinePlan(fresh) }
                return
            }
            guard let fresh else {
                chat.updateRefine(id) { $0.phase = .expired; $0.planID = nil; $0.quoting = false; $0.quoteToken = nil }
                return
            }
            chat.updateRefine(id) {
                $0.plan = .init(fresh); $0.planID = fresh.id; $0.notice = nil
                $0.quoting = false; $0.quoteToken = nil; $0.wantedOptions = fresh.options
            }
        }
    }

    private func askClaudeRefineCancel(_ id: UUID) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id) else { return }
        if let plan = askClaudeRefineOpenPlan(card) { syncManager.discardFilingRefinePlan(plan) }
        chat.updateRefine(id) { $0.phase = .closed; $0.planID = nil; $0.notice = nil; $0.quoting = false; $0.quoteToken = nil }
    }

    /// Send, on the person's click: one request for what the plan quoted. If the list, the Hidden
    /// from Claude list, the saved answers or the price changed since, nothing is sent and the card
    /// shows the new plan to read again.
    private func askClaudeRefineSend(_ id: UUID, fitting: Bool) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id), card.planID != nil, case .planned = card.phase, !card.quoting,
              !chat.pressing.contains("refine-\(id)") else { return }
        guard let open = askClaudeRefineOpenPlan(card) else {
            chat.updateRefine(id) { $0.phase = .expired; $0.planID = nil }
            return
        }
        chat.pressing.insert("refine-\(id)")
        let scope = askClaudeRefineScope(id)
        // Each file's first and second folder as the pass finds them, to tell what Claude changed.
        let before = Dictionary(scope.map { ($0.filePath, (best: $0.best?.path, second: $0.candidates.dropFirst().first?.path)) },
                                uniquingKeysWith: { a, _ in a })
        Task { @MainActor in
            defer { chat.pressing.remove("refine-\(id)") }
            var plan = open
            if fitting {
                // The part that fits is a smaller pass of the same plan: made now, sent now.
                guard let fits = open.fits, fits > 0 else { return }
                var options = open.options
                options.limitTo = fits
                let made = await syncManager.prepareFilingRefine(scope, options: options)
                // Cancel (or anything that closed the card) while the smaller plan was made: it is
                // not sent, and does not stay open either.
                guard let current = chat.refineCard(id), case .planned = current.phase, current.planID == open.id else {
                    if let made { syncManager.discardFilingRefinePlan(made) }
                    return
                }
                guard let smaller = made else {
                    chat.updateRefine(id) { $0.phase = .expired; $0.planID = nil }
                    return
                }
                plan = smaller
                chat.updateRefine(id) { $0.plan = .init(smaller); $0.planID = smaller.id }
            } else if !card.canSend { return }
            chat.updateRefine(id) { $0.phase = .sending(answered: nil); $0.notice = nil; $0.startedAt = Date() }
            let result = await syncManager.sendFilingRefine(plan, scope: scope)
            // Refused for the limit, the plan was taken: a new one says what the limit allows.
            var replanned: FileSyncManager.FilingRefinePlan?
            if result == .blocked { replanned = await syncManager.prepareFilingRefine(scope, options: plan.options) }
            let report = syncManager.filingLastRefineReport
            chat.updateRefine(id) { $0.finish(result, report: report, replanned: replanned) }
            if case .sent = result {
                // This card's pass holds the manager's one undo now, or none does.
                chat.refineUndoCard = syncManager.canUndoFilingRefine ? id : nil
                if let line = chat.refineCard(id)?.toldToClaude { chat.tellClaude(line) }
                if let refine = chat.refineCard(id), let card = refine.forCard {
                    askClaudeRefineToCard(card, refine: refine, before: before)
                }
                Logger.shared.info("Ask Claude: Refine sent from its card — \(report?.changes.count ?? 0) home(s) changed")
            }
        }
    }
}
