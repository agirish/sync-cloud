import FileExplorer
import Foundation
import Sync

/// **The `pdf` tool's half that builds a card** (TE294 step 3): Claude's call checked field by
/// field, its files resolved and held to the hidden list and the tool's kinds, and a card offered
/// that reads its files and waits for their click. Nothing runs here.
///
/// Built ahead of the tool list: no tool name reaches this until the `pdf` tool is turned on
/// (step 4), so the cached prefix and every saved chat are untouched until then.
extension AskClaudeBrowseTools {

    /// How opening a form for Fill & Sign went.
    enum FillOutcome: Equatable {
        /// Open in Edit with Fill & Sign on; how many form fields it has, when it was read.
        case opened(fields: Int?)
        /// Open in Edit, but it hadn't loaded in time to turn Fill & Sign on.
        case openedWithoutFillSign
        case refused
        /// Edit is waiting on a question about the open document, or it was canceled.
        case notNow
    }

    /// **The `pdf` tool** (TE294): `info` reads one file, `fill` opens a form in Edit, and every
    /// other action offers a card.
    func pdf(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        let action = call.string("action")?.lowercased() ?? ""
        guard action == "info" || action == "fill" else { return pdfCard(call, ctx, handles) }
        func refuse(_ why: String) -> AskClaudeToolOutcome {
            AskClaudeToolOutcome(result: why, isError: true, step: action == "info" ? "Couldn’t read that PDF" : "Didn’t open that form")
        }
        let given = call.strings("handles") ?? []
        guard given.count == 1, let path = handles.path(for: given[0]) else {
            return refuse("\(action) needs one handle from this chat, such as r9.")
        }
        guard !ctx.isHidden(path) else { return refuse("That file is in a folder they hid from you.") }
        let name = (path as NSString).lastPathComponent
        guard EditableText.isPDF(path: path) else { return refuse("\(name) isn’t a PDF.") }
        if action == "info" {
            switch await PDFCardFactsReader.read(path, for: .extract([0])) {
            case .facts(let facts):
                var parts = [facts.protection == .locked ? "locked with a password, so its pages can’t be counted until it’s unlocked"
                                                         : (facts.pageCount == 1 ? "1 page" : "\(facts.pageCount) pages"),
                             FileSyncManager.formatBytes(facts.bytes)]
                if facts.protection == .restricted { parts.append("its owner restricts editing") }
                parts.append(facts.fieldCount == 0 ? "no form fields" : "a form with \(facts.fieldCount) field\(facts.fieldCount == 1 ? "" : "s")")
                return AskClaudeToolOutcome(result: "“\(AskClaudeScreenCard.escape(name))”: " + parts.joined(separator: ", ") + ".",
                                            step: "Read \(name)’s pages")
            case .cloudOnly:
                return refuse("\(name) is only in the cloud. It isn’t read until it’s downloaded; a card offers Download.")
            case .gone: return refuse("\(name) is gone; it may have moved or been renamed. Look again.")
            case .unreadable: return refuse("\(name) can’t be read as a PDF.")
            case .busy: return refuse("The PDF reader is busy with other work. Try again in a moment.")
            }
        }
        if let busy = ctx.busyReason { return refuse("Can’t open it right now: \(busy).") }
        switch await ctx.openForFill(AskClaudePaths.canonical(path)) {
        case .opened(let fields):
            let count = fields.map { $0 == 0 ? " It has no form fields: they place text and signatures on the page." : " It has \($0) form field\($0 == 1 ? "" : "s")." } ?? ""
            return AskClaudeToolOutcome(result: "Opened \(name) in Edit with Fill & Sign on.\(count) They type and sign there; Save Filled Copy writes a copy next to it, and you’re told when they save. Say so in a line and stop.",
                                        step: "Opened \(name) in Fill & Sign", movedView: "Moved you to Edit")
        case .openedWithoutFillSign:
            return AskClaudeToolOutcome(result: "Opened \(name) in Edit, but it took too long to load to turn Fill & Sign on: they click Fill & Sign above it.",
                                        step: "Opened \(name) in Edit", movedView: "Moved you to Edit")
        case .refused:
            return refuse("Edit couldn’t show \(name). Edit says why.")
        case .notNow:
            return refuse("\(name) didn’t open in Edit yet: Edit is waiting on a question about the open document, or it was canceled.")
        }
    }

    /// The actions a card runs, by the name Claude calls them.
    static let pdfActions: [String: AskClaudePDFCard.Action] = [
        "save_as_pdf": .saveAsPDF, "compress": .compress, "rotate": .rotate, "clean_metadata": .cleanMetadata,
        "protect": .protect, "remove_password": .removePassword, "extract": .extract,
        "delete_pages": .deletePages, "reorder": .reorder, "split": .split, "combine": .combine,
    ]

    func pdfCard(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome {
        func refuse(_ why: String) -> AskClaudeToolOutcome {
            AskClaudeToolOutcome(result: "Nothing was offered: \(why)", isError: true, step: "Couldn’t offer that PDF card")
        }
        let named = call.string("action")?.lowercased() ?? ""
        guard let action = Self.pdfActions[named] else {
            return refuse("action must be one of \(Self.pdfActions.keys.sorted().joined(separator: ", ")).")
        }
        let given = call.strings("handles") ?? []
        guard !given.isEmpty else { return refuse("handles needs the file’s handle, such as r9.") }
        if let twice = given.first(where: { handle in given.filter { $0.lowercased() == handle.lowercased() }.count > 1 }) {
            return refuse("handles: \(twice) is given twice; give each file once.")
        }
        if action == .combine, given.count < 2 { return refuse("combine needs two or more handles, in the order they go in.") }
        if !action.takesSeveral, given.count > 1 { return refuse("\(named) takes one handle; offer a card for each file.") }
        guard given.count <= AskClaudePDFCard.maxFiles else {
            return refuse("at most \(AskClaudePDFCard.maxFiles) files on one card. Offer the first \(AskClaudePDFCard.maxFiles).")
        }

        var rows: [AskClaudePDFCard.Row] = []
        for handle in given {
            guard let path = handles.path(for: handle) else {
                return refuse("handles: \(handle) isn’t a handle from this chat.")
            }
            if ctx.isHidden(path) { return refuse("handles: \(handle) is in a folder they hid from you.") }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
                return refuse("handles: \(handle) is gone; it may have moved or been renamed. Look again.")
            }
            let name = (path as NSString).lastPathComponent
            if isFolder.boolValue { return refuse("handles: \(name) is a folder.") }
            if action == .saveAsPDF {
                guard SaveAsPDFKind.of(path: path) != nil else {
                    return refuse("\(name) can’t be saved as PDF: Save as PDF reads Word, RTF, text, Markdown, Excel and PowerPoint files. Pages, Keynote and Numbers can export a PDF themselves.")
                }
            } else if !EditableText.isPDF(path: path) {
                return refuse("\(name) isn’t a PDF. For a document, offer save_as_pdf first.")
            }
            let folder = (path as NSString).deletingLastPathComponent
            rows.append(AskClaudePDFCard.Row(path: path, name: name,
                                             folderLabel: Self.breadcrumb(folder, sources: ctx.sources, fallback: folder),
                                             bytes: ctx.node(path)?.fileSize))
        }

        var options = AskClaudePDFCard.Options()
        switch action {
        case .compress:
            if let strength = call.string("strength")?.lowercased() {
                guard let picked = ["best": AskClaudePDFCard.Options.Strength.best, "balanced": .balanced,
                                    "smallest_file": .smallestFile][strength] else {
                    return refuse("strength must be best, balanced or smallest_file.")
                }
                options.strength = picked
            }
            if let mb = Self.number(call.input["under_mb"]) {
                guard mb > 0 else { return refuse("under_mb must be a number of megabytes above 0.") }
                guard options.strength == nil else { return refuse("give strength or under_mb, not both.") }
                options.underMB = mb
            }
            // “Make it smaller” with nothing more: Balanced, and the card says so.
            if options.strength == nil, options.underMB == nil { options.strength = .balanced }
        case .rotate:
            switch call.string("turn")?.lowercased() {
            case "left": options.quarterTurns = 3
            case "right", nil: options.quarterTurns = 1
            case "180": options.quarterTurns = 2
            default: return refuse("turn must be left, right or 180.")
            }
            if let pages = call.string("pages")?.trimmingCharacters(in: .whitespaces), !pages.isEmpty {
                guard rows.count == 1 else { return refuse("pages rotates one file’s pages; give one handle, or no pages to turn every page.") }
                options.pages = pages
            }
        case .extract, .deletePages:
            // No pages named: the card opens with its Pages field empty, and they type them there.
            if let pages = call.string("pages")?.trimmingCharacters(in: .whitespaces), !pages.isEmpty { options.pages = pages }
        case .reorder:
            guard let pages = call.string("pages")?.trimmingCharacters(in: .whitespaces), !pages.isEmpty else {
                return refuse("pages needs the pages in their new order, every page once, like 3-5, 1. If they didn’t say the order, ask.")
            }
            options.pages = pages
        case .split:
            let starts = call.input["split_at"]?.arrayValue?.compactMap(\.intValue) ?? []
            guard !starts.isEmpty else { return refuse("split_at needs the pages new files start at, like [4, 9].") }
            guard starts == starts.sorted(), Set(starts).count == starts.count, starts.allSatisfy({ $0 >= 2 }) else {
                return refuse("split_at must go up, each page once, each 2 or more: the first file always starts at page 1.")
            }
            guard starts.count < AskClaudePDFCard.maxParts else {
                return refuse("that makes more than \(AskClaudePDFCard.maxParts) files; split it in fewer places.")
            }
            options.splitAt = starts
        case .protect:
            switch call.string("mode")?.lowercased() {
            case "lock_to_open", nil: options.mode = .lockToOpen
            case "restrict_editing": options.mode = .restrictEditing
            default: return refuse("mode must be lock_to_open or restrict_editing.")
            }
        case .combine:
            options.name = EditorPDFCombineSplit.defaultName(rows[0].path)
        case .saveAsPDF, .cleanMetadata, .removePassword:
            break
        }

        let card = AskClaudePDFCard(action: action, rows: rows, options: options)
        let files = rows.map { "“\(AskClaudeScreenCard.escape($0.name))”" }.joined(separator: ", ")
        var lines = ["Offered them a card: \(card.title) — \(files). Nothing has happened: they click \(AskClaudePDFCardView.runTitle(card)) or Not Now. The card reads the files, says what the copy loses, and makes a new file next to each original; the original stays as it was."]
        // A choice they didn't name starts on the card's default; they change it there, not in the chat.
        let picked: String? = switch action {
        case .rotate where call.string("turn") == nil: "They didn’t say which way: the card starts on Right, with Left and 180° beside it."
        case .compress where call.string("strength") == nil && options.underMB == nil: "They didn’t say how hard: the card starts on Balanced, with Best and Smallest beside it."
        case .protect where call.string("mode") == nil: "They didn’t say which protection: the card starts on Lock to open, with Restrict editing beside it."
        case .extract where options.pages == nil, .deletePages where options.pages == nil:
            "They didn’t name pages: the card opens with its Pages field empty, and they type them there."
        default: nil
        }
        if let picked { lines.append(picked) }
        if action == .protect || action == .removePassword {
            lines.append("They type the password on the card. Never ask for it, suggest one or repeat one.")
        }
        lines.append("Say in one line what the card will make, and stop. Never say it’s done.")
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"),
                                    step: "Offered \(card.title) for \(rows.count == 1 ? rows[0].name : "\(rows.count) files")",
                                    pdf: card)
    }

    static func number(_ value: JSONFragment?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .integer(let number)?: return Double(number)
        case .string(let text)?: return Double(text)
        default: return nil
        }
    }
}
