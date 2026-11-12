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
        /// Second copies of a file in the same folder: "Lease (1).pdf" or "Lease copy.pdf" beside
        /// "Lease.pdf". A name that only looks like one ("Taxes (2024)", "Signed hard copy") isn't.
        public var copies = 0
        public var screenshots = 0
        /// Which rows are selected, as a number that names nothing: a starter the model wrote for
        /// one selection isn't shown for another (the panel's cache key).
        public var selectionKey = 0
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
        // Each file's stem, so a copy counts only beside its original.
        let stems = Set(rows.filter { !$0.isDirectory }.map { (($0.name as NSString).deletingPathExtension).lowercased() })
        var selectedPaths: [String] = []
        for row in rows {
            let selected = selection.contains(row.path)
            if selected {
                signals.selected += 1
                selectedPaths.append(row.path)
            }
            guard !row.isDirectory else { continue }
            let name = row.name as NSString
            let ext = name.pathExtension.lowercased()
            let readable = readableExtensions.contains(ext)
            signals.files += 1
            if readable { signals.readable += 1 }
            if selected, readable { signals.selectedReadable += 1 }
            if ext == "pdf" { signals.pdfs += 1 }
            // A date in the future (a clock off, a camera) isn't "this week".
            if let modified = row.modified, (0..<thisWeek).contains(now.timeIntervalSince(modified)) { signals.changedThisWeek += 1 }
            if let original = originalStem(name.deletingPathExtension), stems.contains(original) { signals.copies += 1 }
            if row.name.hasPrefix("Screenshot ") || row.name.hasPrefix("Screen Shot ") { signals.screenshots += 1 }
        }
        var hasher = Hasher()
        for path in selectedPaths.sorted() { hasher.combine(path) }
        signals.selectionKey = selectedPaths.isEmpty ? 0 : hasher.finalize()
        return signals
    }

    // MARK: The on-device model's question (decision NN)

    /// Starters longer than this wrap in the column's narrowest width (V10).
    public static let longest = 48
    /// How a question about files begins: asked ones end in "?", the rest are requests.
    static let asking = ["which", "what", "where", "when", "who", "how many", "does", "do ", "is ", "are "]
    static let requests = ["summarize", "find", "rename", "move", "file ", "list", "show"]
    /// Words common enough in file and folder names to be the question's own ("Which documents…").
    static let commonWords: Set<String> = ["documents", "document", "downloads", "download", "desktop", "pictures",
                                           "screenshot", "screenshots", "photos", "folder", "folders", "invoice",
                                           "invoices", "receipt", "receipts", "change", "changes", "statement",
                                           "statements", "report", "reports", "scanned"]

    /// The model's question, tidied, or nil when it can't be offered: too long or short, naming
    /// something on screen, a near-copy of a starter already shown, or not shaped like a question
    /// about files (U4, V10). `names`: everything the screen card names, rows, columns, tabs and disks.
    public static func modelQuestion(_ raw: String, beside shown: [String], names: [String]) -> String? {
        var question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .replacingOccurrences(of: "'", with: "’")
        let lower = question.lowercased()
        let asks = asking.contains { lower.hasPrefix($0) }
        guard !question.contains("\n"), asks || requests.contains(where: { lower.hasPrefix($0) }) else { return nil }
        if asks, !question.hasSuffix("?") { question += "?" }
        guard (12...longest).contains(question.count) else { return nil }
        // Compared word by word, so "Lease_2026" and "Mom's Taxes" match "lease 2026" and "Mom’s
        // taxes": a name of two words or more whole, or a long uncommon word from any name.
        let asked = words(lower)
        for name in names {
            let named = words(((name as NSString).deletingPathExtension).lowercased())
            if named.count >= 2, contains(asked, run: named) { return nil }
            if named.contains(where: { $0.count >= 6 && !commonWords.contains($0) && asked.contains($0) }) { return nil }
        }
        let mine = wordSet(lower)
        for other in shown {
            let theirs = wordSet(other.lowercased())
            let overlap = Double(mine.intersection(theirs).count) / Double(max(1, mine.union(theirs).count))
            if overlap >= 0.5 { return nil }
        }
        return question
    }

    private static func wordSet(_ text: String) -> Set<String> { Set(words(text)) }

    /// Letters and digits only, an apostrophe of either kind dropped: "mom's" and "mom’s" are "moms".
    private static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func contains(_ words: [String], run: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<$0 + run.count]) == run }
    }

    /// The original's stem when `stem` names a second copy: "lease (1)" or "lease copy 2" →
    /// "lease". A number of three digits or more in brackets is a year or a part, never a copy.
    static func originalStem(_ stem: String) -> String? {
        let lower = stem.lowercased()
        for pattern in [#" \(\d{1,2}\)$"#, #" copy( \d{1,2})?$"#] {
            if let range = lower.range(of: pattern, options: .regularExpression) {
                return String(lower[..<range.lowerBound])
            }
        }
        return nil
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
            asks.append(n == 1 ? "Where should the selected item go?" : "Where should these \(count(n)) go?")
            if n >= 2 { asks.append("Rename these \(count(n)) like their neighbors") }
            return asks
        }
        var asks: [String] = []
        if signals.copies >= minimumCopies { asks.append("Which of the \(count(signals.copies)) copies can I trash?") }
        if signals.screenshots >= minimumScreenshots { asks.append("Move the \(count(signals.screenshots)) screenshots into a folder") }
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

    /// "1,234", grouped as the Mac's region groups numbers.
    private static func count(_ n: Int) -> String { n.formatted(.number) }

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
