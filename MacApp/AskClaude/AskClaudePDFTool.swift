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
            if let pages = call.string("pages") {
                guard rows.count == 1 else { return refuse("pages rotates one file’s pages; give one handle, or no pages to turn every page.") }
                options.pages = pages
            }
        case .extract, .deletePages, .reorder:
            guard let pages = call.string("pages")?.trimmingCharacters(in: .whitespaces), !pages.isEmpty else {
                return refuse("pages needs the pages \(action == .reorder ? "in their new order, every page once" : "they named"), like 3-5, 1. If they didn’t name pages, ask which.")
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
