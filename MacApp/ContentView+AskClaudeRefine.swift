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
    func askClaudeRefine(scope: [FilingSuggestion], source named: String? = nil) {
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
            let id = chat.addRefineCard(AskClaudeRefineCard(sourceName: source, plan: plan))
            chat.refineScopes[id] = scope.map(\.filePath)
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

    /// What a Refine card does and reads.
    var askClaudeRefineBridge: AskClaudeRefineBridge {
        // Once: Try Another's requests count on one running line in the chat, and a Refine Names
        // request leaves its receipt there.
        if syncManager.filingTryAnotherReports == nil {
            let chat = askClaudeChat
            syncManager.filingTryAnotherReports = { chat.noteTryAnother($0) }
            syncManager.filingMappingRefineReports = { report in
                chat.addNote(AskClaudeRefineCard.refineNamesReceipt(folderNames: report.folderNames, fileNames: report.fileNames,
                                                                    costUSD: report.costUSD, modelName: report.modelName,
                                                                    answered: report.answered))
            }
        }
        return AskClaudeRefineBridge(
            send: { askClaudeRefineSend($0, fitting: false) },
            sendFit: { askClaudeRefineSend($0, fitting: true) },
            cancel: { askClaudeRefineCancel($0) },
            stop: { _ in syncManager.stopFilingRefine() },
            setTick: { id, on in askClaudeRefineChange(id) { $0.pagesFromAskEachTime = on } },
            askAgain: { id in askClaudeRefineChange(id) { $0.askAgain = true } },
            retry: { id in
                guard let card = askClaudeChat.refineCard(id) else { return }
                // What Claude already answered is saved, so a new plan asks only about what is left.
                askClaudeRefine(scope: askClaudeRefineScope(id), source: card.sourceName)
            },
            folders: { syncManager.filingLastTaxonomyFolders.sorted() },
            leftOut: { syncManager.filingRefineLeftOutFolders },
            setLeftOut: { id, folders in
                syncManager.filingRefineLeftOutFolders = folders
                askClaudeRefineChange(id) { _ in }
            },
            changeLimit: { openSettings(on: SettingsView.SettingsTab.cloudRefineSetup) },
            undo: { id in
                let restored = syncManager.undoFilingRefine()
                askClaudeChat.updateRefine(id) { $0.answers?.undone = true }
                askClaudeChat.tellClaude("They chose Undo Refine on the card: \(restored) suggestion\(restored == 1 ? "" : "s") went back to the on-device answer.")
            },
            canUndo: { id in
                guard let card = askClaudeChat.refineCard(id), card.answers?.undone != true else { return false }
                return syncManager.canUndoFilingRefine
            },
            reveal: { path in revealInBrowse(path, with: [path], from: .pdfToolBanner) })
    }

    /// The suggestions a card was made for, as they are now.
    func askClaudeRefineScope(_ id: UUID) -> [FilingSuggestion] {
        let paths = Set(askClaudeChat.refineScopes[id] ?? [])
        return syncManager.filingSuggestions.filter { paths.contains($0.filePath) }
    }

    /// The plan a card controls, while it is still the source's open one.
    private func askClaudeRefineOpenPlan(_ card: AskClaudeRefineCard) -> FileSyncManager.FilingRefinePlan? {
        guard let planID = card.planID else { return nil }
        return syncManager.filingOpenRefinePlans.values.first { $0.id == planID }
    }

    /// Makes the card's plan again with one option changed (the tick, ask again, folders left out).
    /// The new plan replaces the old as the source's open one, so only the card on screen can send.
    private func askClaudeRefineChange(_ id: UUID, _ change: @escaping (inout FileSyncManager.FilingRefineOptions) -> Void) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id), card.canTick, let old = askClaudeRefineOpenPlan(card) else {
            chat.updateRefine(id) { if case .planned = $0.phase { $0.phase = .expired; $0.planID = nil } }
            return
        }
        var options = old.options
        change(&options)
        let scope = askClaudeRefineScope(id)
        Task { @MainActor in
            guard let fresh = await syncManager.prepareFilingRefine(scope, options: options) else {
                chat.updateRefine(id) { $0.phase = .expired; $0.planID = nil }
                return
            }
            chat.updateRefine(id) { $0.plan = .init(fresh); $0.planID = fresh.id; $0.notice = nil }
        }
    }

    private func askClaudeRefineCancel(_ id: UUID) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id) else { return }
        if let plan = askClaudeRefineOpenPlan(card) { syncManager.discardFilingRefinePlan(plan) }
        chat.updateRefine(id) { $0.phase = .closed; $0.planID = nil; $0.notice = nil }
    }

    /// Send, on the person's click: one request for what the plan quoted. If the list, the Hidden
    /// from Claude list, the saved answers or the price changed since, nothing is sent and the card
    /// shows the new plan to read again.
    private func askClaudeRefineSend(_ id: UUID, fitting: Bool) {
        let chat = askClaudeChat
        guard let card = chat.refineCard(id), card.planID != nil, case .planned = card.phase,
              !chat.pressing.contains("refine-\(id)") else { return }
        guard let open = askClaudeRefineOpenPlan(card) else {
            chat.updateRefine(id) { $0.phase = .expired; $0.planID = nil }
            return
        }
        chat.pressing.insert("refine-\(id)")
        let scope = askClaudeRefineScope(id)
        Task { @MainActor in
            defer { chat.pressing.remove("refine-\(id)") }
            var plan = open
            if fitting {
                // The part that fits is a smaller pass of the same plan: made now, sent now.
                guard let fits = open.fits, fits > 0 else { return }
                var options = open.options
                options.limitTo = fits
                guard let smaller = await syncManager.prepareFilingRefine(scope, options: options) else {
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
                if let line = chat.refineCard(id)?.toldToClaude { chat.tellClaude(line) }
                Logger.shared.info("Ask Claude: Refine sent from its card — \(report?.changes.count ?? 0) home(s) changed")
            }
        }
    }
}
