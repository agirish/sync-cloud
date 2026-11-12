import Foundation

/// The questions a new chat offers, one click each, worked out on this Mac from what is on screen:
/// the selection, the kinds of files, what changed, look-alike copies (TE347b), led by TE309's
/// suggestion while the chat is empty, and filled from a fixed table keyed by the workspace. Free,
/// and nothing is sent until one is clicked; a click sends it exactly as if it were typed.
///
/// **No item's name, ever**: a question names nothing but a source, and a source only while the
/// folder on screen isn't hidden from Claude: a hidden folder hides everything under it, so a
/// shown one means its source's top isn't hidden either. The file open in Edit is "this file".
public enum AskClaudeStarters {

    /// What the table is keyed by: the panel's place (`AskClaudePlace`), in its own words.
    public struct Screen: Equatable, Sendable {
        /// "Browse", "Compare", "Organize" or "Edit".
        public var workspace: String
        public var source: String
        /// Relative to the source; empty at its top.
        public var folder: String
        /// Nil while the folder hasn't loaded.
        public var itemCount: Int?
        public var folderHidden: Bool
        /// The file open in Edit, when Claude is told about it; nil when it is hidden.
        public var openFile: String?
        /// What the rows on screen say; empty for a hidden folder (`signals(rows:selection:now:)`).
        public var signals: Signals

        public init(workspace: String, source: String, folder: String, itemCount: Int?, folderHidden: Bool,
                    openFile: String? = nil, signals: Signals = .init()) {
            self.workspace = workspace
            self.source = source
            self.folder = folder
            self.itemCount = itemCount
            self.folderHidden = folderHidden
            self.openFile = openFile
            self.signals = signals
        }
    }

    /// Counts from the rows Claude would be shown, never their names.
    public struct Signals: Hashable, Sendable {
        public var selected = 0
        /// Selected files `read_text` can read; folders and pictures aren't.
        public var selectedReadable = 0
        public var files = 0
        public var readable = 0
        public var pdfs = 0
        public var changedThisWeek = 0
        /// Names ending "(1)" or "copy": what Finder and downloads name a second copy.
        public var copies = 0
        public var screenshots = 0
        /// TE309's suggestion, while the chat is empty: it leads instead of showing twice (B-R8).
        public var suggested: String?

        public init() {}
    }

    /// The kinds `read_text` reads, by extension (`AskClaudeReading.extractNow`).
    static let readableExtensions: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "tsv", "json", "log", "text",
                                                  "html", "htm", "rtf", "rtfd", "doc", "docx", "odt"]
    static let thisWeek: TimeInterval = 7 * 24 * 3600
    /// Fewer than these isn't worth a question of its own.
    static let minimumCopies = 2
    static let minimumScreenshots = 5
    /// Up to this many readable files get "Summarize them".
    static let summarizable = 5

    /// The signals of `rows`, the rows the screen card would send: hidden ones already left out.
    public static func signals(rows: [AskClaudeScreen.Row], selection: Set<String>, now: Date) -> Signals {
        var signals = Signals()
        for row in rows {
            let selected = selection.contains(row.path)
            if selected { signals.selected += 1 }
            guard !row.isDirectory else { continue }
            let name = row.name as NSString
            let ext = name.pathExtension.lowercased()
            let readable = readableExtensions.contains(ext)
            signals.files += 1
            if readable { signals.readable += 1 }
            if selected, readable { signals.selectedReadable += 1 }
            if ext == "pdf" { signals.pdfs += 1 }
            if let modified = row.modified, now.timeIntervalSince(modified) < thisWeek { signals.changedThisWeek += 1 }
            if isCopy(name.deletingPathExtension) { signals.copies += 1 }
            if row.name.hasPrefix("Screenshot ") || row.name.hasPrefix("Screen Shot ") { signals.screenshots += 1 }
        }
        return signals
    }

    // MARK: The on-device model's question (decision NN)

    /// Starters longer than this wrap in the column's narrowest width (V10).
    public static let longest = 48
    /// How a question Claude's tools can answer begins.
    static let openings = ["summarize", "which", "what", "where", "when", "who", "how many", "does", "do ", "is ",
                           "are ", "find", "rename", "move", "file ", "list", "show"]

    /// The model's question, tidied, or nil when it can't be offered: too long or short, naming a
    /// file or folder on screen, a near-copy of a starter already shown, or not something Claude's
    /// tools do (U4, V10).
    public static func modelQuestion(_ raw: String, beside shown: [String], names: [String]) -> String? {
        var question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .replacingOccurrences(of: "'", with: "’")
        guard !question.contains("\n"), (12...longest).contains(question.count) else { return nil }
        if !question.hasSuffix("?") && question.lowercased().hasPrefix("wh") { question += "?" }
        let lower = question.lowercased()
        guard openings.contains(where: { lower.hasPrefix($0) }) else { return nil }
        // A name's whole stem of two words or more ("lease 2026"), or a long word from one
        // ("brokerage"). A short one-word name ("form", "scan") may be the question's own word.
        for name in names {
            let stem = ((name as NSString).deletingPathExtension).lowercased()
            let words = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if words.count >= 2, lower.contains(stem) { return nil }
            if words.contains(where: { $0.count >= 6 && lower.contains($0) }) { return nil }
        }
        let mine = wordSet(lower)
        for other in shown {
            let theirs = wordSet(other.lowercased())
            let overlap = Double(mine.intersection(theirs).count) / Double(max(1, mine.union(theirs).count))
            if overlap >= 0.5 { return nil }
        }
        return question
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// "Lease (1)", "Lease copy", "Lease copy 2".
    static func isCopy(_ stem: String) -> Bool {
        let lower = stem.lowercased()
        if lower.range(of: #" \(\d+\)$"#, options: .regularExpression) != nil { return true }
        return lower.range(of: #" copy( \d+)?$"#, options: .regularExpression) != nil
    }

    /// For a folder Claude can't see into, an empty one, or one still loading.
    static let anywhere = ["What can you do in SyncCloud?", "Find my newest PDFs", "Open my Downloads folder"]

    /// Three or four questions for `screen`, most useful first: TE309's suggestion, then what the
    /// rows on screen say, then the table's, as many as the table has.
    public static func questions(for screen: Screen) -> [String] {
        let table = tableQuestions(for: screen)
        var picked = screen.signals.suggested.map { [$0] } ?? []
        // The folder's own questions: not for a file open in Edit, or Compare's two sides.
        if sees(screen), screen.workspace != "Compare", screen.workspace != "Edit" || screen.openFile == nil {
            picked += fromSignals(screen.signals)
        }
        for question in table where !picked.contains(question) { picked.append(question) }
        return Array(picked.prefix(table.count))
    }

    /// What the rows say, most specific first: a selection speaks for itself.
    static func fromSignals(_ signals: Signals) -> [String] {
        let n = signals.selected
        if n > 0 {
            var asks: [String] = []
            if signals.selectedReadable == n, n <= summarizable {
                asks.append(n == 1 ? "Summarize the selected file" : "Summarize the \(n) selected files")
            }
            asks.append(n == 1 ? "Where should the selected item go?" : "Where should these \(n) go?")
            if n >= 2 { asks.append("Rename these \(n) like their neighbors") }
            return asks
        }
        var asks: [String] = []
        if signals.copies >= minimumCopies { asks.append("Which of the \(signals.copies) copies can I trash?") }
        if signals.screenshots >= minimumScreenshots { asks.append("Move the \(signals.screenshots) screenshots into a folder") }
        let files = signals.files
        if (1...summarizable).contains(files), signals.readable == files {
            let pdfs = signals.pdfs == files
            switch files {
            case 1: asks.append(pdfs ? "Summarize the PDF" : "Summarize the file")
            case 2: asks.append(pdfs ? "Summarize both PDFs" : "Summarize both files")
            default: asks.append("Summarize the \(files) \(pdfs ? "PDFs" : "files")")
            }
        }
        if signals.changedThisWeek > 0 { asks.append("What changed here this week?") }
        return asks
    }

    /// Today's table: what fits the workspace, with no signal.
    static func tableQuestions(for screen: Screen) -> [String] {
        switch screen.workspace {
        case "Compare":
            let both = ["Show the name conflicts", "What changed, and which side is newer?"]
            return screen.folderHidden ? both + ["What can you do in SyncCloud?"]
                                       : ["What’s only in \(screen.source), by folder?"] + both
        case "Edit":
            guard let open = screen.openFile else { return inFolder(screen) }
            if (open as NSString).pathExtension.lowercased() == "pdf" {
                return ["Summarize this PDF", "What dates and amounts does it mention?", "Make it smaller to email",
                        "Where should this file go?"]
            }
            return ["Summarize this file", "What dates and amounts does it mention?", "Where should this file go?"]
        case "Organize":
            guard sees(screen) else { return anywhere }
            return ["Where should these files go?", "What’s newest here?", "What can you do in Organize?"]
        default:
            return inFolder(screen)
        }
    }

    /// Browse's questions, and Edit's with nothing open: about the folder on screen.
    private static func inFolder(_ screen: Screen) -> [String] {
        guard sees(screen) else { return anywhere }
        let name = screen.folder.split(separator: "/").last.map(String.init) ?? ""
        if name.caseInsensitiveCompare("Downloads") == .orderedSame {
            return ["Where should these files go?", "What came in this week?", "Which are the biggest?"]
        }
        return ["What’s in this folder?", "What’s newest here?", "Which are the biggest?"]
    }

    /// Whether there is something on screen Claude may look at.
    private static func sees(_ screen: Screen) -> Bool {
        !screen.folderHidden && (screen.itemCount ?? 0) > 0
    }
}
