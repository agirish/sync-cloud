import AppKit
import Design
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

/// Ask Claude's PDF cards, in the window: reading a card's files for it, its run through the
/// window's own PDF runs, the line Claude hears with the next question, and Undo.
extension ContentView {

    var askClaudePDFBridge: AskClaudePDFBridge {
        let cards = askClaudePDFCards
        // Once: the panel builds this bridge on every draw, and installing the hook re-reads every
        // card still checking — which redraws the panel.
        if askClaudeChat.pdfCardOffered == nil { askClaudeChat.pdfCardOffered = { id in cards.askClaudePDFRead(id) } }
        if askClaudeChat.pdfProgress == nil { askClaudeChat.pdfProgress = { id in cards.askClaudePDFProgress(id) } }
        return AskClaudePDFBridge(
            setOptions: { id, options in
                let pagesChanged = askClaudeChat.pdfCard(id).map { $0.options.pages != options.pages
                    || $0.options.splitAt != options.splitAt } ?? false
                askClaudeChat.updatePDFCard(id) { $0.options = options }
                // A strength, a name or a mode changes nothing the card read; the pages typed are
                // checked against the page count it has.
                if pagesChanged { cards.askClaudePDFRecheckPages(id) }
            },
            moveRow: { id, index, step in
                askClaudeChat.updatePDFCard(id) { card in
                    let target = index + step
                    guard card.rows.indices.contains(index), card.rows.indices.contains(target) else { return }
                    card.rows.swapAt(index, target)
                }
                // Combine writes into its first file's folder: a new first file is asked again.
                if min(index, index + step) == 0, askClaudeChat.pdfCard(id)?.action == .combine { cards.askClaudePDFRead(id) }
            },
            run: { cards.askClaudePDFRun($0, password: $1) },
            notNow: { id in
                guard let card = askClaudeChat.pdfCard(id), card.isOpen else { return }
                askClaudeChat.updatePDFCard(id) { $0.state = .notNow }
                askClaudeChat.tellClaude("They chose Not Now on your card “\(card.title)”; nothing was written.")
            },
            undo: { cards.askClaudePDFUndo($0, fromMenu: false) },
            offersUndo: { cards.askClaudePDFOffersUndo($0) },
            hasUndoStep: { askClaudeChat.pdfUndoSteps[$0] != nil },
            download: { id, path in askClaudePDFDownload(id, path) },
            chooseFolder: { askClaudePDFChooseFolder($0) },
            open: { path in _ = handOffToEditor(path) },
            reveal: { paths in
                guard let first = paths.first else { return }
                revealInBrowse(first, with: paths, from: .pdfToolBanner)
            },
            waitReason: { cards.askClaudePDFWaitReason($0) },
            progress: { cards.askClaudePDFProgress($0) },
            stop: { cards.askClaudePDFStop($0) })
    }

    /// The cards' read, run and Undo, with what they need from this window. Built fresh at each
    /// use, as the window's own methods read it fresh. Its own type so a test can run a card end to
    /// end without a window.
    var askClaudePDFCards: AskClaudePDFCards {
        AskClaudePDFCards(
            askClaudeChat: askClaudeChat, panePDFTools: panePDFTools, paneSaveAsPDF: paneSaveAsPDF, editorPDF: editorPDF,
            syncManager: syncManager, fontScale: { appFontScale }, hue: { glassHue }, lockReason: { runWriteLockReason },
            refuse: { refusedWhileRunLocked() }, isHidden: { askClaudeIsHidden($0) },
            reread: { rereadPanesAfterEditorWrite($0, writer: $1) }, handOff: { _ = handOffToEditor($0) },
            reveal: { revealInBrowse($0, with: $1, from: $2) }, download: { downloadFromEdit($0) })
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

    /// The rows whose folder has to take a new file and can't, refused: each file's own folder,
    /// but for Combine only the first file's, the one folder its one new file goes into.
    static func askClaudePDFUnwritable(_ action: AskClaudePDFCard.Action, _ rows: [AskClaudePDFCard.Row],
                                       _ unwritable: Set<String>) -> [AskClaudePDFCard.Row] {
        var rows = rows
        for index in rows.indices where unwritable.contains(rows[index].path) && (action != .combine || index == 0) {
            rows[index].refusal = AskClaudePDFCardView.unwritableFolder
        }
        return rows
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

    static let askClaudePDFHiddenNow = "It’s in a folder hidden from Claude now."
    static let askClaudePDFUnsavedNote = "It runs on the file as saved: what you haven’t saved in Edit isn’t in it."
    static let askClaudePDFGone = "It’s no longer there; it may have moved or been renamed."

    /// Why the pages typed can't be, in one sentence for the file's row.
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
            guard let pages = askClaudePDFRotatePages(card) else { return nil }
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

    // MARK: The click

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

    /// The pages typed for Rotate, or nil for every page: a field he cleared holds "", not nil.
    static func askClaudePDFRotatePages(_ card: AskClaudePDFCard) -> String? {
        guard let pages = card.options.pages, !pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return pages
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
            if askClaudePDFRotatePages(card) != nil { return pages(extract: true).map { .rotate(pages: $0, quarterTurns: turns) } }
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

    /// The line Claude hears with the next question: what the click made, each new file by name
    /// with a mark that becomes its handle when the line is sent. Never a password or a file's
    /// text. A file saved into a folder hidden from Claude is said to be there, unnamed.
    static func askClaudePDFReport(_ card: AskClaudePDFCard, _ result: PDFRunResult, isHidden: (String) -> Bool) -> String {
        // Compress says what each file was, so Claude can say what it saved.
        let sources = card.rows.map { row in
            "“\(row.name)”" + (card.action == .compress ? row.bytes.map { " (\(FileSyncManager.formatBytes($0)))" } ?? "" : "")
        }.joined(separator: ", ")
        func named(_ file: PDFWrittenFile) -> String {
            guard !isHidden(file.path) else { return "a file in a folder hidden from you" }
            var facts = [FileSyncManager.formatBytes(file.bytes)]
            if let pages = file.pageCount { facts.insert(pages == 1 ? "1 page" : "\(pages) pages", at: 0) }
            return "“\((file.path as NSString).lastPathComponent)” \(AskClaudeChat.fileMark(file.path)), " + facts.joined(separator: ", ")
        }
        let made = result.written.map(named).joined(separator: "; ")
        // One folder is named only when every file is in it.
        let folders = Set(card.rows.map(\.folderLabel))
        let place = card.folder != nil ? ", in the folder they chose"
            : folders.count > 1 ? ", next to each original"
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
            if card.action == .compress {
                line += " Its pages are pictures now."
                if result.message.contains("No setting reached") { line += " It didn’t get under the size asked; this is the smallest it got." }
            }
            // A deck's slides that were pictures, as the banner's second line says it.
            if card.action == .saveAsPDF, result.skipped.isEmpty, let detail = result.detail { line += " " + detail }
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

    /// What Claude hears after Undo. The caller has already made the names safe for it.
    static func askClaudePDFUndoReport(_ title: String, trashed: [String], left: [String]) -> String {
        var line = "They undid your card “\(title)”: "
        line += trashed.isEmpty ? "nothing moved." : "\(trashed.joined(separator: ", ")) \(trashed.count == 1 ? "is" : "are") in the Trash."
        if !left.isEmpty { line += " Left where it was: \(left.joined(separator: ", "))." }
        return line
    }

    // MARK: Fill

    /// Opens a form in Edit with Fill & Sign on, once it has loaded (waiting at most 10 s). Its
    /// filled copies are told to Claude while this chat lasts, unless a copy is saved into a folder
    /// hidden from it.
    func askClaudeOpenForFill(_ path: String) async -> AskClaudeBrowseTools.FillOutcome {
        switch handOffToEditor(path) {
        case .cancelled: return .notNow
        case .opened, .alreadyOpen:
            guard editorOpenPath.map({ AskClaudePaths.same($0, path) }) == true else { return .refused }
        }
        func loaded() -> Bool { editorPDF.phase == .open && editorPDF.path.map { AskClaudePaths.same($0, path) } == true }
        for _ in 0..<100 where !loaded() { try? await Task.sleep(for: .milliseconds(100)) }
        guard loaded() else { return .openedWithoutFillSign }
        if !editorPDF.fill.isOn { editorPDF.fill.toggle() }
        // Said as on only once it is: toggle asks first when it can't turn on now.
        guard editorPDF.fill.isOn else { return .openedWithoutFillSign }
        let chat = askClaudeChat
        chat.fillOpened = path
        editorPDF.fill.didSave = { original, copy in
            guard let opened = chat.fillOpened, AskClaudePaths.same(original, opened) else { return }
            let form = "“\((original as NSString).lastPathComponent)”"
            if AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard)).isHidden(copy) {
                chat.tellClaude("They saved a filled copy of \(form) from Fill & Sign, in a folder hidden from you.")
            } else {
                chat.tellClaude("They saved “\((copy as NSString).lastPathComponent)” \(AskClaudeChat.fileMark(copy)) from Fill & Sign on \(form).")
            }
        }
        if case .facts(let facts) = await PDFCardFactsReader.read(path, for: .extract([0])) {
            return .opened(fields: facts.fieldCount)
        }
        return .opened(fields: nil)
    }

    // MARK: Doors

    func askClaudePDFDownload(_ id: UUID, _ path: String) {
        downloadFromEdit(path)
        // Read again once the file is here: checked every two seconds, for at most two minutes.
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                if !MaterializationStatus.isCloudOnly(atPath: MaterializationStatus.linkTarget(of: path)) { break }
            }
            askClaudePDFCards.askClaudePDFRead(id)
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
        askClaudePDFCards.askClaudePDFRead(id)
    }

}

/// What a PDF card does, apart from the window: reads its files, runs on the click, tells Claude
/// how it ended, and takes it back. The window hands in what it owns (the chat, the PDF runs,
/// Edit's document, the undo stack) and its own doors as closures.
@MainActor
struct AskClaudePDFCards {
    let askClaudeChat: AskClaudeChat
    let panePDFTools: PanePDFTools
    let paneSaveAsPDF: PaneSaveAsPDF
    let editorPDF: EditorPDFDocument
    /// The window's undo stack is `syncManager.undoManager`, as a plan card's is.
    let syncManager: FileSyncManager
    let fontScale: () -> CGFloat
    let hue: () -> LiquidGlassHue
    let lockReason: () -> String?
    let refuse: () -> Bool
    let isHidden: (String) -> Bool
    let reread: (_ path: String, _ writer: String) -> Void
    let handOff: (String) -> Void
    let reveal: (_ path: String, _ with: [String], _ door: EditorRevealInBrowse.Door) -> Void
    let download: (String) -> Void
    /// Undo's move to the Trash; a test moves to a folder of its own instead.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    var appFontScale: CGFloat { fontScale() }
    var glassHue: LiquidGlassHue { hue() }
    var runWriteLockReason: String? { lockReason() }
    func refusedWhileRunLocked() -> Bool { refuse() }
    func askClaudeIsHidden(_ path: String) -> Bool { isHidden(path) }
    func rereadPanesAfterEditorWrite(_ path: String, writer: String) { reread(path, writer) }
    func handOffToEditor(_ path: String) { handOff(path) }
    func revealInBrowse(_ path: String, with companions: [String], from door: EditorRevealInBrowse.Door) {
        reveal(path, companions, door)
    }
    func downloadFromEdit(_ path: String) { download(path) }

    // MARK: Reading a card's files
    /// Reads the card's files and readies its button (pages, size, protection, what the copy
    /// loses, the pages typed against the page count), then draws the thumbnails. While the PDF
    /// lane is busy, the card keeps saying it's checking and tries again in a few seconds.
    func askClaudePDFRead(_ id: UUID, attempt: Int = 0) {
        guard let card = askClaudeChat.pdfCard(id), card.isOpen else { return }
        // The first read wakes the "checking" line; a read again after Download or a choice of
        // folder keeps the card as it is until the answer is in.
        if card.rows.contains(where: { $0.stamp == nil && !$0.cloudOnly }) {
            askClaudeChat.updatePDFCard(id) { $0.state = .checking }
        }
        let tool = ContentView.askClaudePDFFactsTool(card)
        Task { @MainActor in
            var read: [String: AskClaudePDFCard.Row] = [:]
            var unwritable: Set<String> = []
            var losses: [String] = []
            for row in card.rows {
                var fresh = row
                fresh.refusal = nil
                fresh.cloudOnly = false
                let path = row.path
                if askClaudeIsHidden(path) {
                    fresh.refusal = ContentView.askClaudePDFHiddenNow
                } else if card.action == .saveAsPDF {
                    if MaterializationStatus.isCloudOnly(atPath: MaterializationStatus.linkTarget(of: path)) {
                        fresh.cloudOnly = true
                    } else if let stamp = EditorFileStore.stamp(ofPath: path) {
                        fresh.stamp = AskClaudeFileStamp(stamp)
                        fresh.bytes = stamp.size
                        if card.folder == nil, !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
                            fresh.refusal = AskClaudePDFCardView.unwritableFolder
                        }
                    } else {
                        fresh.refusal = ContentView.askClaudePDFGone
                    }
                } else {
                    switch await PDFCardFactsReader.read(path, for: tool) {
                    case .facts(let facts):
                        fresh.pageCount = facts.protection == .locked ? nil : facts.pageCount
                        fresh.bytes = facts.bytes
                        fresh.stamp = AskClaudeFileStamp(facts.stamp)
                        fresh.refusal = ContentView.askClaudePDFRefusal(card.action, facts)
                        if fresh.refusal == nil, card.folder == nil, !facts.folderIsWritable { unwritable.insert(path) }
                        for loss in facts.losses where !losses.contains(loss) { losses.append(loss) }
                    case .cloudOnly: fresh.cloudOnly = true
                    case .gone: fresh.refusal = ContentView.askClaudePDFGone
                    case .unreadable: fresh.refusal = "It can’t be read as a PDF."
                    case .busy:
                        // A long scan holds the PDF lane: the card keeps what it had, says it is
                        // checking, and asks again shortly.
                        guard askClaudeChat.pdfCard(id)?.isOpen == true else { return }
                        guard attempt < 24 else {
                            askClaudeChat.updatePDFCard(id) {
                                $0.state = .failed
                                $0.message = "The PDF reader stayed busy with other work. Ask again in a while."
                            }
                            return
                        }
                        askClaudeChat.updatePDFCard(id) { $0.state = .checking }
                        try? await Task.sleep(for: .seconds(5))
                        askClaudePDFRead(id, attempt: attempt + 1)
                        return
                    }
                }
                read[path] = fresh
            }
            guard askClaudeChat.pdfCard(id)?.isOpen == true else { return }
            if card.action == .combine { losses.append(EditorPDFCombineSplit.combineNote) }
            // Open in Edit with a new page order or Fill & Sign items not saved: the card runs on
            // the file as it is on disk, without them.
            if let open = editorPDF.path, read.keys.contains(where: { AskClaudePaths.same($0, open) }),
               editorPDF.tools.arrangement != nil || editorPDF.fill.hasUnsavedChanges {
                losses.append(ContentView.askClaudePDFUnsavedNote)
            }
            // Into the card as it is now, by file: a row moved while the files were read stays
            // where it was moved to, and the options typed since stay too.
            askClaudeChat.updatePDFCard(id) { now in
                now.rows = ContentView.askClaudePDFUnwritable(now.action, now.rows.map { current in read[current.path] ?? current },
                                                              unwritable)
                now.losses = losses
                now.pagesProblem = ContentView.askClaudePDFPagesProblem(now, pageCount: now.rows.first?.pageCount)
                now.state = .offered
            }
            await askClaudePDFDrawPages(id)
        }
    }

    /// The pages typed, checked again against what the card read; no file is read for it.
    func askClaudePDFRecheckPages(_ id: UUID) {
        askClaudeChat.updatePDFCard(id) { now in
            now.pagesProblem = ContentView.askClaudePDFPagesProblem(now, pageCount: now.rows.first?.pageCount)
        }
        Task { @MainActor in await askClaudePDFDrawPages(id) }
    }

    /// The pages a page tool acts on, drawn small for its card.
    func askClaudePDFDrawPages(_ id: UUID) async {
        // Whatever was drawn for pages typed before goes once they can't be drawn now. Exactly
        // the pages the card's row draws: Delete's struck through, Reorder's in order.
        guard let card = askClaudeChat.pdfCard(id), let row = card.rows.first else {
            askClaudeChat.pdfThumbnails[id] = nil
            return
        }
        let shown = AskClaudePDFCardView.stripPages(AskClaudePDFCardView.pageStrip(card))
        let images = shown.isEmpty ? nil : await PDFCardThumbnails.render(row.path, pages: shown, height: 34)
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

    /// The run, on their click. Every file is checked again first: still there, still not hidden,
    /// still as the card read it. One that changed is read again and the card asks again.
    func askClaudePDFRun(_ id: UUID, password: EditorPDFSecret?) {
        guard let card = askClaudeChat.pdfCard(id), card.state == .offered, !askClaudeChat.isRunning,
              card.pagesProblem == nil, askClaudePDFWaitReason(id) == nil else { return }
        let paths = card.rows.map(\.path)
        // A one-file tool is made before anything changes: one that can't be made (no password
        // typed for Protect) leaves the card as it was, saying why.
        let single: EditorPDFTool?
        switch card.action {
        case .saveAsPDF, .split, .combine: single = nil
        default:
            if paths.count > 1, ContentView.askClaudePDFBatchTool(card) != nil {
                single = nil
            } else if let tool = ContentView.askClaudePDFTool(card, password: password) {
                single = tool
            } else {
                askClaudeChat.updatePDFCard(id) {
                    $0.message = card.action == .protect ? "Type the password twice, the same both times."
                        : ContentView.askClaudePDFPagesProblem(card, pageCount: card.rows.first?.pageCount) ?? "Check the pages typed."
                }
                return
            }
        }
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
        let folders = card.folder.map { folder in Dictionary(paths.map { ($0, folder) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        let accepted = Set(card.losses)
        // The card showed the file's form loss, if it had one: that is the loss the click accepts.
        let allowsFormLoss = accepted.contains(PDFCardFactsReader.formFlattened) || accepted.contains(PDFCardFactsReader.formStopsWorking)
        panePDFTools.host = PanePDFToolHost(
            didWrite: { rereadPanesAfterEditorWrite($0, writer: "\(writer) wrote") },
            open: { _ = handOffToEditor($0) },
            reveal: { copies in if let first = copies.first { revealInBrowse(first, with: copies, from: .pdfToolBanner) } },
            download: { downloadFromEdit($0) })
        // Several files of a whole-file tool: the batch, as the row menu runs it.
        if paths.count > 1, let batch = ContentView.askClaudePDFBatchTool(card) {
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
            panePDFTools.startCombineSplitFromChat(.split(paths[0]), splitAt: card.options.splitAt ?? [], folder: card.folder,
                                                   expecting: expected, writer: writer, completion: finish)
        case .combine:
            panePDFTools.startCombineSplitFromChat(.combine(paths), name: card.options.name, folder: card.folder,
                                                   expecting: expected, writer: writer, completion: finish)
        default:
            guard let single else { return }
            panePDFTools.startFromChat(single, path: paths[0], folder: card.folder, expecting: expected[paths[0]], writer: writer,
                                       allow: { _ in allowsFormLoss }, completion: finish)
        }
    }

    // MARK: How it ended
    func askClaudePDFFinished(_ id: UUID, _ result: PDFRunResult) {
        guard let card = askClaudeChat.pdfCard(id) else { return }
        // Nothing written and nothing ended for good (a wrong password, an impossible name, a
        // file that changed, another run first, a loss that changed): the card waits again,
        // saying why, with its files read again.
        let again = result.written.isEmpty && [.failed, .busy, .declined].contains(result.outcome)
        let reasons = Dictionary(result.skipped.map { ($0.path, $0.reason) }, uniquingKeysWith: { first, _ in first })
        askClaudeChat.updatePDFCard(id) { now in
            now.written = result.written.map {
                .init(path: $0.path, stamp: AskClaudeFileStamp($0.stamp), bytes: $0.bytes, pageCount: $0.pageCount)
            }
            now.message = result.message
            now.detail = result.detail
            for index in now.rows.indices {
                now.rows[index].refusal = reasons[now.rows[index].path]
                // Only in the cloud now: its row offers Download again.
                if let download = result.download, AskClaudePaths.same(download, now.rows[index].path) {
                    now.rows[index].cloudOnly = true
                }
            }
            switch result.outcome {
            case .wrote: now.state = .done
            case .partlyWrote: now.state = .partlyDone
            case .nothingWritten: now.state = .nothingWritten
            case .cancelled: now.state = result.written.isEmpty ? .nothingWritten : .partlyDone
            case .busy: now.message = "Another PDF run started first. Click again when it ends."
            case .declined: now.message = "What the copy would lose changed since the card said. Check it and click again."
            case .failed: break
            }
            if again { now.state = .offered } else if result.outcome == .failed || result.outcome == .busy { now.state = .failed }
        }
        if again {
            askClaudePDFRead(id)
            if result.outcome == .declined || result.outcome == .busy { return }
        }
        askClaudeChat.tellClaude(ContentView.askClaudePDFReport(card, result, isHidden: askClaudeIsHidden))
        if !result.written.isEmpty { askClaudePDFRegisterUndo(id, title: card.action.title) }
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

    /// Moves what the card wrote to the Trash: each file only while it is exactly as the card
    /// wrote it and not open in Edit. **Never a delete:** a file with no Trash to go to stays.
    func askClaudePDFUndo(_ id: UUID, fromMenu: Bool) {
        guard let card = askClaudeChat.pdfCard(id), card.state == .done || card.state == .partlyDone else { return }
        if let step = askClaudeChat.pdfUndoSteps.removeValue(forKey: id), !fromMenu {
            step.manager.removeAllActions(withTarget: step.target)
        }
        // The card names every file for him; what Claude hears names none in a folder hidden from it.
        var trashed: [String] = [], left: [String] = [], toldTrashed: [String] = [], toldLeft: [String] = []
        for file in card.written {
            let name = "“\((file.path as NSString).lastPathComponent)”"
            let told = askClaudeIsHidden(file.path) ? "a file in a folder hidden from you" : name
            func leave(_ why: String) {
                left.append("\(name) (\(why))")
                toldLeft.append("\(told) (\(why))")
            }
            guard EditorFileStore.stamp(ofPath: file.path) == file.stamp.editorStamp else { leave("changed since"); continue }
            if let open = editorPDF.path, AskClaudePaths.same(open, file.path) { leave("open in Edit"); continue }
            do {
                try trash(URL(fileURLWithPath: file.path))
                trashed.append(name)
                toldTrashed.append(told)
                rereadPanesAfterEditorWrite(file.path, writer: "Ask Claude moved to the Trash")
            } catch {
                // The card says "couldn't go to the Trash"; the log keeps which file and why.
                Logger.shared.warning("Ask Claude card: Undo “\(card.title)” couldn't move \(file.path) to the Trash — "
                                      + error.localizedDescription)
                leave("it couldn’t go to the Trash")
            }
        }
        Logger.shared.info("Ask Claude card: Undo “\(card.title)” — \(trashed.count) moved to the Trash, \(left.count) left")
        askClaudeChat.updatePDFCard(id) { now in
            if !trashed.isEmpty { now.state = .undone }
            if !left.isEmpty { now.detail = "Left: " + left.joined(separator: ", ") + "." }
        }
        askClaudeChat.tellClaude(ContentView.askClaudePDFUndoReport(card.title, trashed: toldTrashed, left: toldLeft))
    }

    // MARK: Progress
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
