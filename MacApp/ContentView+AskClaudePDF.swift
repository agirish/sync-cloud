import AppKit
import Events
import FileExplorer
import SwiftUI
import Sync

/// The target an Ask Claude PDF card's Edit ▸ Undo step is registered against — one per card, so
/// the card's own Undo can take exactly that step off the menu.
final class AskClaudePDFUndoTarget {
    let card: UUID
    init(card: UUID) { self.card = card }
}

extension AskClaudeFileStamp {
    init(_ stamp: EditorFileStore.Stamp) {
        self.init(modifiedAt: stamp.modifiedAt, size: stamp.size, fileID: stamp.fileID)
    }

    var editorStamp: EditorFileStore.Stamp {
        EditorFileStore.Stamp(modifiedAt: modifiedAt, size: size, fileID: fileID)
    }
}

/// **Ask Claude's PDF cards, in the window** (TE294 step 3): reading a card's files for it, its
/// run through the window's own PDF runs, the line Claude hears with the next question, and Undo.
extension ContentView {

    var askClaudePDFBridge: AskClaudePDFBridge {
        // Once: the panel builds this bridge on every draw, and installing the hook re-reads every
        // card still checking — which redraws the panel.
        if askClaudeChat.pdfCardOffered == nil { askClaudeChat.pdfCardOffered = { id in askClaudePDFRead(id) } }
        return AskClaudePDFBridge(
            setOptions: { id, options in
                askClaudeChat.updatePDFCard(id) { $0.options = options }
                askClaudePDFRead(id)
            },
            moveRow: { id, index, step in
                askClaudeChat.updatePDFCard(id) { card in
                    let target = index + step
                    guard card.rows.indices.contains(index), card.rows.indices.contains(target) else { return }
                    card.rows.swapAt(index, target)
                }
            },
            run: { askClaudePDFRun($0, password: $1) },
            notNow: { id in
                guard let card = askClaudeChat.pdfCard(id), card.isOpen else { return }
                askClaudeChat.updatePDFCard(id) { $0.state = .notNow }
                askClaudeChat.tellClaude("They chose Not Now on your card “\(card.title)”; nothing was written.")
            },
            undo: { askClaudePDFUndo($0, fromMenu: false) },
            offersUndo: { askClaudePDFOffersUndo($0) },
            download: { id, path in askClaudePDFDownload(id, path) },
            chooseFolder: { askClaudePDFChooseFolder($0) },
            open: { path in _ = handOffToEditor(path) },
            reveal: { paths in
                guard let first = paths.first else { return }
                revealInBrowse(first, with: paths, from: .pdfToolBanner)
            },
            waitReason: { askClaudePDFWaitReason($0) },
            progress: { askClaudePDFProgress($0) },
            stop: { askClaudePDFStop($0) })
    }

    // MARK: Reading a card's files

    /// The tool a card would run, as the files are read for it — what its losses are reckoned for.
    static func askClaudePDFFactsTool(_ card: AskClaudePDFCard) -> EditorPDFTool {
        switch card.action {
        case .compress: return .compress(.quality(0.6))
        case .rotate: return .rotate(pages: [0], quarterTurns: card.options.quarterTurns ?? 1)
        case .cleanMetadata: return .cleanMetadataCleared
        case .protect: return .protect(restrictEditing: card.options.mode == .restrictEditing, password: EditorPDFSecret(""))
        case .removePassword: return .removePassword(EditorPDFSecret(""))
        case .extract, .split, .combine: return .extract([0])
        case .deletePages: return .deletePages([0])
        case .reorder: return .reorder([0])
        case .saveAsPDF: return .rotate(pages: [0], quarterTurns: 1)
        }
    }

    /// What protection keeps `action` from running on a file, in the menu's words; nil when it can.
    static func askClaudePDFRefusal(_ action: AskClaudePDFCard.Action, _ facts: PDFCardFacts) -> String? {
        switch (facts.protection, action) {
        case (.locked, .removePassword): return nil
        case (.locked, _): return EditorPDFTools.lockedReason
        case (.none, .removePassword): return "It has no password to remove."
        case (.restricted, .protect): return "It already has a password. Remove it first."
        case (.restricted, .cleanMetadata): return EditorPDFTools.metadataEncryptedReason + "."
        default: return facts.pageCount == 0 ? "It has no pages." : nil
        }
    }

    /// **Reads the card's files and readies its button** — pages, size, protection, what the copy
    /// loses, the pages typed against the page count — then the thumbnails. The lane is busy?
    /// The card keeps saying it's checking and tries again in a few seconds.
    func askClaudePDFRead(_ id: UUID, attempt: Int = 0) {
        guard let card = askClaudeChat.pdfCard(id), card.isOpen else { return }
        // Read again after an edit on the card (the pages typed, a strength) without waking the
        // "checking" line on every keystroke; the click checks the files again anyway.
        let first = card.rows.contains { $0.stamp == nil && !$0.cloudOnly }
        if first { askClaudeChat.updatePDFCard(id) { $0.state = .checking } }
        let tool = Self.askClaudePDFFactsTool(card)
        Task { @MainActor in
            var rows = card.rows
            var losses: [String] = []
            var busy = false
            for index in rows.indices {
                let path = rows[index].path
                rows[index].refusal = nil
                rows[index].cloudOnly = false
                if card.action == .saveAsPDF {
                    if MaterializationStatus.isCloudOnly(atPath: MaterializationStatus.linkTarget(of: path)) {
                        rows[index].cloudOnly = true
                    } else if let stamp = EditorFileStore.stamp(ofPath: path) {
                        rows[index].stamp = AskClaudeFileStamp(stamp)
                        rows[index].bytes = stamp.size
                        if card.folder == nil, !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
                            rows[index].refusal = AskClaudePDFCardView.unwritableFolder
                        }
                    } else {
                        rows[index].refusal = Self.askClaudePDFGone
                    }
                    continue
                }
                switch await PDFCardFactsReader.read(path, for: tool) {
                case .facts(let facts):
                    rows[index].pageCount = facts.protection == .locked ? nil : facts.pageCount
                    rows[index].bytes = facts.bytes
                    rows[index].stamp = AskClaudeFileStamp(facts.stamp)
                    rows[index].refusal = Self.askClaudePDFRefusal(card.action, facts)
                    if rows[index].refusal == nil, card.folder == nil, !facts.folderIsWritable {
                        rows[index].refusal = AskClaudePDFCardView.unwritableFolder
                    }
                    for loss in facts.losses where !losses.contains(loss) { losses.append(loss) }
                case .cloudOnly: rows[index].cloudOnly = true
                case .gone: rows[index].refusal = Self.askClaudePDFGone
                case .unreadable: rows[index].refusal = "It can’t be read as a PDF."
                case .busy: busy = true
                }
            }
            guard askClaudeChat.pdfCard(id)?.isOpen == true else { return }
            if busy {
                // A long scan holds the PDF lane: still checking, and asked again shortly.
                askClaudeChat.updatePDFCard(id) { $0.rows = rows }
                guard attempt < 24 else {
                    askClaudeChat.updatePDFCard(id) { $0.state = .failed; $0.message = "The PDF reader stayed busy with other work. Ask again in a while." }
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                askClaudePDFRead(id, attempt: attempt + 1)
                return
            }
            if card.action == .combine { losses.append(EditorPDFCombineSplit.combineNote) }
            // Open in Edit with a new page order or Fill & Sign items not saved: the card runs on
            // the file as it is on disk, without them.
            if let open = editorPDF.path, rows.contains(where: { $0.path == open }),
               editorPDF.tools.arrangement != nil || editorPDF.fill.hasUnsavedChanges {
                losses.append(Self.askClaudePDFUnsavedNote)
            }
            if let problem = Self.askClaudePDFPagesProblem(card, pageCount: rows.first?.pageCount) {
                rows[0].refusal = rows[0].refusal ?? problem
            }
            askClaudeChat.updatePDFCard(id) { now in
                now.rows = rows
                now.losses = losses
                now.state = .offered
            }
            await askClaudePDFDrawPages(id)
        }
    }

    static let askClaudePDFUnsavedNote = "It runs on the file as saved: what you haven’t saved in Edit isn’t in it."
    static let askClaudePDFGone = "It’s no longer there; it may have moved or been renamed."

    /// Why the pages typed can't be — one sentence, said on the file's row.
    static func askClaudePDFPagesProblem(_ card: AskClaudePDFCard, pageCount: Int?) -> String? {
        guard let count = pageCount, count > 0 else { return nil }
        switch card.action {
        case .extract, .deletePages, .reorder:
            switch PDFCardPages.parse(card.options.pages ?? "", extract: card.action != .deletePages, pageCount: count) {
            case .failure(let problem): return problem.sentence
            case .success(let pages):
                if card.action == .reorder, pages.sorted() != Array(0..<count) {
                    return "List every page once, in the new order: this PDF has \(count) pages."
                }
                return nil
            }
        case .rotate:
            guard let pages = card.options.pages, !pages.isEmpty else { return nil }
            if case .failure(let problem) = PDFCardPages.parse(pages, extract: true, pageCount: count) { return problem.sentence }
            return nil
        case .split:
            if let last = card.options.splitAt?.last, last > count {
                return "Page \(last) is past the end: this PDF has \(count) pages."
            }
            return nil
        default:
            return nil
        }
    }

    /// The pages a page tool acts on, drawn small for its card.
    func askClaudePDFDrawPages(_ id: UUID) async {
        guard let card = askClaudeChat.pdfCard(id), card.action.choosesPages, let row = card.rows.first,
              let count = row.pageCount, row.refusal == nil else { return }
        let acted: [Int]
        switch card.action {
        case .split: acted = (card.options.splitAt ?? []).map { $0 - 1 }
        default:
            guard case .success(let pages) = PDFCardPages.parse(card.options.pages ?? "", extract: card.action != .deletePages,
                                                               pageCount: count) else { return }
            acted = card.action == .reorder ? Array(pages.prefix(3)) : pages
        }
        let shown = PDFCardThumbnails.shown(acted, pageCount: count).compactMap { $0 }
        guard !shown.isEmpty, let images = await PDFCardThumbnails.render(row.path, pages: Array(shown.prefix(12)), height: 34)
        else { return }
        askClaudeChat.pdfThumbnails[id] = images
    }

    // MARK: The click

    /// What the button waits on now, or nil: a sync, or another run of the same kind.
    func askClaudePDFWaitReason(_ id: UUID) -> String? {
        if let reason = runWriteLockReason { return reason }
        guard let card = askClaudeChat.pdfCard(id) else { return nil }
        let busy = card.action == .saveAsPDF ? paneSaveAsPDF.isRunning : panePDFTools.isBusy
        return busy ? "Waits for the other PDF run to finish." : nil
    }

    /// **The run, on their click** — every file checked again first: still there, still not
    /// hidden, still as the card read it. One that changed is read again and the card asks again.
    func askClaudePDFRun(_ id: UUID, password: EditorPDFSecret?) {
        guard let card = askClaudeChat.pdfCard(id), card.state == .offered, !askClaudeChat.isRunning,
              askClaudePDFWaitReason(id) == nil else { return }
        var expected: [String: EditorFileStore.Stamp] = [:]
        for row in card.rows {
            guard !askClaudeIsHidden(row.path), let stamp = row.stamp?.editorStamp,
                  EditorFileStore.stamp(ofPath: row.path) == stamp else {
                askClaudeChat.updatePDFCard(id) { $0.message = "A file changed since the card was made. Check it and click again." }
                askClaudePDFRead(id)
                return
            }
            expected[row.path] = stamp
        }
        guard !refusedWhileRunLocked() else { return }
        askClaudeChat.updatePDFCard(id) { $0.state = .running; $0.written = []; $0.message = nil; $0.detail = nil }
        let writer = "Ask Claude"
        let finish: @MainActor (PDFRunResult) -> Void = { askClaudePDFFinished(id, $0) }
        let paths = card.rows.map(\.path)
        let folders = card.folder.map { folder in Dictionary(uniqueKeysWithValues: paths.map { ($0, folder) }) } ?? [:]
        let accepted = Set(card.losses)
        // The card showed the file's form loss, if it had one: that is the loss the click accepts.
        let allowsFormLoss = accepted.contains(PDFCardFactsReader.formFlattened) || accepted.contains(PDFCardFactsReader.formStopsWorking)
        panePDFTools.host = PanePDFToolHost(
            didWrite: { rereadPanesAfterEditorWrite($0, writer: "\(writer) wrote") },
            open: { _ = handOffToEditor($0) },
            reveal: { copies in if let first = copies.first { revealInBrowse(first, with: copies, from: .pdfToolBanner) } },
            download: { downloadFromEdit($0) })
        // Several files of a whole-file tool: the batch, as the row menu runs it.
        if paths.count > 1, let batch = Self.askClaudePDFBatchTool(card) {
            panePDFTools.startBatchFromChat(batch, paths: paths, folder: card.folder, expecting: expected, writer: writer,
                                            allow: { _ in allowsFormLoss }, completion: finish)
            return
        }
        switch card.action {
        case .saveAsPDF:
            paneSaveAsPDF.fontScale = appFontScale
            paneSaveAsPDF.accent = glassHue.accentColor
            paneSaveAsPDF.host = PaneSaveAsPDFHost(didWrite: { rereadPanesAfterEditorWrite($0, writer: "\(writer) wrote") })
            paneSaveAsPDF.startFromChat(paths: paths, folders: folders, expecting: expected, writer: writer, completion: finish)
        case .split:
            panePDFTools.startCombineSplitFromChat(.split(paths[0]), splitAt: card.options.splitAt ?? [], expecting: expected,
                                                   writer: writer, completion: finish)
        case .combine:
            panePDFTools.startCombineSplitFromChat(.combine(paths), name: card.options.name, expecting: expected,
                                                   writer: writer, completion: finish)
        default:
            guard let tool = Self.askClaudePDFTool(card, password: password) else {
                askClaudeChat.updatePDFCard(id) {
                    $0.state = .offered
                    $0.message = nil
                    $0.rows[0].refusal = Self.askClaudePDFPagesProblem(card, pageCount: card.rows.first?.pageCount)
                        ?? "Check the pages typed."
                }
                return
            }
            panePDFTools.startFromChat(tool, path: paths[0], folder: card.folder, expecting: expected[paths[0]], writer: writer,
                                       allow: { _ in allowsFormLoss }, completion: finish)
        }
    }

    /// A card's whole-file tool over several files.
    static func askClaudePDFBatchTool(_ card: AskClaudePDFCard) -> EditorPDFBatchTool? {
        switch card.action {
        case .compress: return .compress(askClaudePDFCompression(card.options))
        case .rotate: return .rotate(quarterTurns: card.options.quarterTurns ?? 1)
        case .cleanMetadata: return .cleanMetadata
        default: return nil
        }
    }

    static func askClaudePDFCompression(_ options: AskClaudePDFCard.Options) -> EditorPDFCompression {
        if let mb = options.underMB { return .target(bytes: EditorPDFCompression.bytes(megabytes: mb)) }
        let quality: [AskClaudePDFCard.Options.Strength: Double] = [.best: 0.85, .balanced: 0.6, .smallestFile: 0.35]
        return .quality(quality[options.strength ?? .balanced] ?? 0.6)
    }

    /// A card's tool on its one file, with the pages typed read as Edit reads them.
    static func askClaudePDFTool(_ card: AskClaudePDFCard, password: EditorPDFSecret?) -> EditorPDFTool? {
        let count = card.rows.first?.pageCount ?? 0
        func pages(extract: Bool) -> [Int]? {
            guard case .success(let pages) = PDFCardPages.parse(card.options.pages ?? "", extract: extract, pageCount: count)
            else { return nil }
            return pages
        }
        switch card.action {
        case .compress: return .compress(askClaudePDFCompression(card.options))
        case .rotate:
            let turns = card.options.quarterTurns ?? 1
            if card.options.pages != nil { return pages(extract: true).map { .rotate(pages: $0, quarterTurns: turns) } }
            return .rotate(pages: Array(0..<count), quarterTurns: turns)
        case .cleanMetadata: return .cleanMetadataCleared
        case .protect:
            guard let password else { return nil }
            return .protect(restrictEditing: card.options.mode == .restrictEditing, password: password)
        case .removePassword: return .removePassword(password ?? EditorPDFSecret(""))
        case .extract: return pages(extract: true).map { .extract($0) }
        case .deletePages: return pages(extract: false).map { .deletePages($0) }
        case .reorder: return pages(extract: true).map { .reorder($0) }
        case .saveAsPDF, .split, .combine: return nil
        }
    }

    // MARK: How it ended

    func askClaudePDFFinished(_ id: UUID, _ result: PDFRunResult) {
        guard let card = askClaudeChat.pdfCard(id) else { return }
        let reasons = Dictionary(result.skipped.map { ($0.path, $0.reason) }, uniquingKeysWith: { first, _ in first })
        askClaudeChat.updatePDFCard(id) { now in
            now.written = result.written.map {
                .init(path: $0.path, stamp: AskClaudeFileStamp($0.stamp), bytes: $0.bytes, pageCount: $0.pageCount)
            }
            now.message = result.message
            now.detail = result.detail
            for index in now.rows.indices { now.rows[index].refusal = reasons[now.rows[index].path] }
            switch result.outcome {
            case .wrote: now.state = .done
            case .partlyWrote: now.state = .partlyDone
            case .nothingWritten: now.state = .nothingWritten
            case .cancelled: now.state = result.written.isEmpty ? .nothingWritten : .partlyDone
            case .declined:
                // What the copy would lose changed since the card said: read again, ask again.
                now.state = .checking
            case .failed, .busy: now.state = .failed
            }
        }
        if result.outcome == .declined {
            askClaudePDFRead(id)
            return
        }
        askClaudeChat.tellClaude(Self.askClaudePDFReport(card, result, isHidden: askClaudeIsHidden))
        if !result.written.isEmpty { askClaudePDFRegisterUndo(id, title: card.action.title) }
    }

    /// **The line Claude hears with the next question** — what the click made, each new file by
    /// name with a mark that becomes its handle when the line is sent; never a password, never a
    /// file's text. A file saved into a folder hidden from Claude is said to be there, unnamed.
    static func askClaudePDFReport(_ card: AskClaudePDFCard, _ result: PDFRunResult, isHidden: (String) -> Bool) -> String {
        let sources = card.rows.map { "“\($0.name)”" }.joined(separator: ", ")
        func named(_ file: PDFWrittenFile) -> String {
            guard !isHidden(file.path) else { return "a file in a folder hidden from you" }
            var facts = [FileSyncManager.formatBytes(file.bytes)]
            if let pages = file.pageCount { facts.insert(pages == 1 ? "1 page" : "\(pages) pages", at: 0) }
            return "“\((file.path as NSString).lastPathComponent)” \(AskClaudeChat.fileMark(file.path)), " + facts.joined(separator: ", ")
        }
        let made = result.written.map(named).joined(separator: "; ")
        let place = card.folder != nil ? ""
            : card.rows.first.map { ", next to \(card.rows.count > 1 ? "each original" : "it") in \($0.folderLabel)" } ?? ""
        var line: String
        let wroteSome = !result.written.isEmpty && [.wrote, .partlyWrote, .cancelled].contains(result.outcome)
        switch wroteSome ? .wrote : result.outcome {
        case .wrote, .partlyWrote:
            let verb: String
            switch card.action {
            case .saveAsPDF: verb = "They saved \(sources) as PDF"
            case .compress: verb = "They compressed \(sources)"
            case .rotate: verb = "They rotated \(sources)"
            case .cleanMetadata: verb = "They cleaned the metadata of \(sources)"
            case .protect: verb = "They protected \(sources) with a password (\(card.options.mode == .restrictEditing ? "editing restricted" : "locked to open"))"
            case .removePassword: verb = "They removed the password from \(sources)"
            case .extract: verb = "They took pages \(card.options.pages ?? "") out of \(sources)"
            case .deletePages: verb = "They deleted pages \(card.options.pages ?? "") from \(sources)"
            case .reorder: verb = "They put the pages of \(sources) in a new order"
            case .split: verb = "They split \(sources)"
            case .combine: verb = "They combined \(sources)"
            }
            line = "\(verb): \(made)\(place)."
            if card.action == .compress { line += " Its pages are pictures now." }
            if !result.skipped.isEmpty {
                line += " Not done: " + result.skipped.prefix(10).map { "“\(($0.path as NSString).lastPathComponent)” (\($0.reason))" }
                    .joined(separator: "; ") + "."
            }
            if result.outcome == .cancelled { line += " They stopped it before the rest." }
        case .nothingWritten:
            line = "Your card “\(card.title)” wrote nothing: \(result.message)"
        case .cancelled:
            line = "They stopped your card “\(card.title)” before it wrote anything."
        case .failed, .busy, .declined:
            line = "Your card “\(card.title)” didn’t run: \(result.message)"
        }
        return line
    }

    // MARK: Undo

    /// One Edit ▸ Undo step for the card, against a target of its own (main window's stack, as a
    /// plan card's is): it works while it's the latest step, and the card's own Undo takes it off.
    func askClaudePDFRegisterUndo(_ id: UUID, title: String) {
        guard let undo = syncManager.undoManager else { return }
        let target = AskClaudePDFUndoTarget(card: id)
        askClaudeChat.pdfUndoSteps[id] = (target, undo)
        undo.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated { askClaudePDFUndo(target.card, fromMenu: true) }
        }
        undo.setActionName(title)
    }

    /// Whether the card's Undo can take anything back: its step is still held this session, and a
    /// file it wrote is as it wrote it.
    func askClaudePDFOffersUndo(_ id: UUID) -> Bool {
        guard let card = askClaudeChat.pdfCard(id), card.state == .done || card.state == .partlyDone,
              askClaudeChat.pdfUndoSteps[id] != nil else { return false }
        return card.written.contains { EditorFileStore.stamp(ofPath: $0.path) == $0.stamp.editorStamp }
    }

    /// **Moves what the card wrote to the Trash** — each file only while it is exactly as the card
    /// wrote it, and not open in Edit. Never a delete: a file with no Trash to go to stays.
    func askClaudePDFUndo(_ id: UUID, fromMenu: Bool) {
        guard let card = askClaudeChat.pdfCard(id), card.state == .done || card.state == .partlyDone else { return }
        if let step = askClaudeChat.pdfUndoSteps.removeValue(forKey: id), !fromMenu {
            step.manager.removeAllActions(withTarget: step.target)
        }
        var trashed: [String] = [], left: [String] = []
        for file in card.written {
            let name = (file.path as NSString).lastPathComponent
            guard EditorFileStore.stamp(ofPath: file.path) == file.stamp.editorStamp else {
                left.append("“\(name)” (changed since)")
                continue
            }
            guard editorPDF.path != file.path else {
                left.append("“\(name)” (open in Edit)")
                continue
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                trashed.append("“\(name)”")
                rereadPanesAfterEditorWrite(file.path, writer: "Ask Claude moved to the Trash")
            } catch {
                left.append("“\(name)” (it couldn’t go to the Trash)")
            }
        }
        Logger.shared.info("Ask Claude card: Undo “\(card.title)” — \(trashed.count) moved to the Trash, \(left.count) left")
        askClaudeChat.updatePDFCard(id) { now in
            if !trashed.isEmpty { now.state = .undone }
            if !left.isEmpty { now.detail = "Left: " + left.joined(separator: ", ") + "." }
        }
        var line = "They undid your card “\(card.title)”: "
        line += trashed.isEmpty ? "nothing moved." : "\(trashed.joined(separator: ", ")) \(trashed.count == 1 ? "is" : "are") in the Trash."
        if !left.isEmpty { line += " Left where it was: \(left.joined(separator: ", "))." }
        askClaudeChat.tellClaude(line)
    }

    // MARK: Doors

    func askClaudePDFDownload(_ id: UUID, _ path: String) {
        downloadFromEdit(path)
        // Read again once the file is here — checked every two seconds, for at most two minutes.
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                if !MaterializationStatus.isCloudOnly(atPath: MaterializationStatus.linkTarget(of: path)) { break }
            }
            askClaudePDFRead(id)
        }
    }

    func askClaudePDFChooseFolder(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the new files."
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        askClaudeChat.updatePDFCard(id) { $0.folder = folder }
        askClaudePDFRead(id)
    }

    /// "page 14 of 22", "File 2 of 5", while the card's run is the one going.
    func askClaudePDFProgress(_ id: UUID) -> String? {
        guard let card = askClaudeChat.pdfCard(id), card.state == .running else { return nil }
        if card.action == .saveAsPDF {
            return paneSaveAsPDF.progress.map { $0.total > 1 ? "File \($0.done + 1) of \($0.total) · \($0.name)" : $0.name }
        }
        switch panePDFTools.current {
        case .single(let tools): return tools.progress.map { "page \($0.page) of \($0.total)" }
        case .batch(let batch): return batch.progress?.text
        case .combineSplit(let run): return run.progress.map { "\($0.step) of \($0.steps) · \($0.detail)" }
        case nil: return nil
        }
    }

    func askClaudePDFStop(_ id: UUID) {
        guard let card = askClaudeChat.pdfCard(id), card.state == .running else { return }
        if card.action == .saveAsPDF { paneSaveAsPDF.stop(); return }
        switch panePDFTools.current {
        case .single(let tools): tools.cancelRun()
        case .batch(let batch): batch.cancel()
        case .combineSplit(let run): run.stop()
        case nil: break
        }
    }
}
