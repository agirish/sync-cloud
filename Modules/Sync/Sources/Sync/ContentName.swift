import Foundation

/// A name for a badly named file, made from what its first page says (TE328).
///
/// Apple Intelligence picks out the facts on this Mac; this turns them into a name in the style of
/// the folder the file is going to (decision JL): a numbered folder's next slot, by the same
/// planner Organize's Renames runs, or the shape of the folder's own names, or a plain name when
/// the folder has none. Pure: no disk, no model, no clock.
public enum ContentName {

    /// What a first page says, as Apple Intelligence read it.
    public struct Facts: Codable, Sendable, Equatable {
        public var year: Int
        public var month: Int?
        /// For a payslip, the period ending (his rule, 5 Aug), never the check date.
        public var day: Int?
        /// Who it's from: "Ally", "PG&E".
        public var from: String
        /// What it is: "1099-INT", "Statement".
        public var what: String

        public init(year: Int, month: Int? = nil, day: Int? = nil, from: String, what: String) {
            self.year = year
            self.month = month
            self.day = day
            self.from = from
            self.what = what
        }
    }

    /// Where a name's style came from, for the card's line under the name.
    public enum Basis: Sendable, Equatable {
        /// A numbered folder's slot, after the file numbered before it (nil when it's the first).
        case numbered(after: String?)
        /// The shape of this file in the folder.
        case like(String)
        /// No style to copy: year, who it's from, what it is.
        case plain

        /// The card's line under the name.
        public var line: String {
            switch self {
            case .numbered(let after?): "Numbered after \(after)"
            case .numbered(nil): "Numbered first in its folder"
            case .like(let name): "Named like \(name)"
            case .plain: "Named by year, who it’s from and what it is"
            }
        }
    }

    /// The line under a name they typed.
    public static let typedBasis = "Your name"

    /// Why `stem` can't name a file, or nil: the pane's own rules, and no leading dot, which would
    /// hide the file.
    public static func stemProblem(_ stem: String) -> String? {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return "A name starting with “.” would hide the file." }
        return FileSyncManager.validateItemName(trimmed)
    }

    public struct Proposal: Sendable, Equatable {
        public let name: String
        public let basis: Basis

        public init(name: String, basis: Basis) {
            self.name = name
            self.basis = basis
        }
    }

    // MARK: Which names change

    /// Words a scanner, camera, browser or app puts in a name, which say nothing about the file.
    static let genericWords: Set<String> = [
        "scan", "scanned", "scansnap", "scanner", "img", "image", "images", "dsc", "dscn", "dcim", "pxl",
        "photo", "pic", "picture", "document", "documents", "doc", "docx", "untitled", "file", "files",
        "download", "downloads", "attachment", "attachments", "print", "printout", "page", "pages",
        "copy", "export", "new", "pdf", "output", "out", "cam", "camera", "screenshot", "screen", "shot",
        "at", "am", "pm", "item", "unnamed", "noname", "temp", "tmp", "upload", "uploaded",
    ]

    /// Whether a name says nothing about its file: "Scan 0042.pdf", "IMG_2231.HEIC",
    /// "document (3).pdf", "download-9.pdf". Any word left after the generic ones and the numbers
    /// keeps the name ("W-2 2025.pdf", "Statement.pdf"): a wrong rename costs more than a dull name.
    public static func needsName(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        let words = stem.lowercased().split { !$0.isLetter }.map(String.init)
        return !stem.isEmpty && words.allSatisfy(genericWords.contains)
    }

    // MARK: The name

    /// The name `facts` give a `.ext` file going into `folderPath`, or nil when the facts are too thin
    /// to name it by (no who and no what).
    /// - Parameters:
    ///   - folderFiles: the files already in the folder.
    ///   - profile: the folder survey, whose entry says whether the folder numbers its files.
    public static func propose(_ facts: Facts, ext: String, folderPath: String, relativePath: String,
                               folderFiles: [FolderFile], profile: FolderProfile?) -> Proposal? {
        let from = clean(facts.from), what = clean(facts.what)
        guard !from.isEmpty || !what.isEmpty, (1900...2100).contains(facts.year) else { return nil }
        let facts = Facts(year: facts.year, month: facts.month.flatMap { (1...12).contains($0) ? $0 : nil },
                          day: facts.day.flatMap { (1...31).contains($0) ? $0 : nil }, from: from, what: what)
        let entry = profile?.folders[relativePath]
        if RenamePlanner.slotGranularity(files: folderFiles, entry: entry) != nil {
            if let numbered = numbered(facts, ext: ext, folderPath: folderPath, relativePath: relativePath,
                                       folderFiles: folderFiles, profile: profile) {
                return numbered
            }
        } else if let like = likeSiblings(facts, ext: ext, folderFiles: folderFiles) {
            return like
        }
        return Proposal(name: finished(plainStem(facts), ext: ext), basis: .plain)
    }

    /// A numbered folder's slot, from Renames' own planner: the file is handed in with a name that
    /// carries only the date, so the planner reads the same month or day the page gave. Nil when it
    /// declines (no slot without renumbering the rest, a year the folder doesn't own, no day in a
    /// day-keyed folder): the file then gets a plain name, and Renames numbers it later.
    static func numbered(_ facts: Facts, ext: String, folderPath: String, relativePath: String,
                         folderFiles: [FolderFile], profile: FolderProfile?) -> Proposal? {
        guard let month = facts.month else { return nil }
        let dated = facts.day.map { String(format: "%04d-%02d-%02d", facts.year, month, $0) }
            ?? OrdinalMonthName.body(month: month, year: facts.year)
        let carrier = finished(dated, ext: ext)
        guard let name = FileSyncManager.incomingName(for: carrier, into: folderPath, relativePath: relativePath,
                                                      folderFiles: folderFiles, profile: profile),
              let slot = OrdinalMonthName.parse(name) else { return nil }
        let lowerExt = ext.lowercased()
        let before = folderFiles
            .filter { ($0.name as NSString).pathExtension.lowercased() == lowerExt }
            .first { OrdinalMonthName.parse($0.name)?.ordinal == slot.ordinal - 1 }
        return Proposal(name: name, basis: .numbered(after: before?.name))
    }

    // MARK: Copying the folder's own names

    /// How a sibling writes its one date.
    enum DateShape: Equatable {
        case year                 // 2024
        case yearMonth            // 2024-03
        case yearMonthDay         // 2024-03-15
        case monthYear            // Mar 2024
        case yearMonthDaySpelled  // 2024 Mar 15

        func render(_ facts: Facts) -> String? {
            switch self {
            case .year: return String(facts.year)
            case .yearMonth: return facts.month.map { String(format: "%04d-%02d", facts.year, $0) }
            case .yearMonthDay:
                guard let m = facts.month, let d = facts.day else { return nil }
                return String(format: "%04d-%02d-%02d", facts.year, m, d)
            case .monthYear: return facts.month.map { OrdinalMonthName.body(month: $0, year: facts.year) }
            case .yearMonthDaySpelled:
                guard let m = facts.month, let d = facts.day else { return nil }
                return "\(facts.year) \(OrdinalMonthName.monthAbbreviations[m - 1]) \(String(format: "%02d", d))"
            }
        }
    }

    /// A sibling's stem split around its one date.
    struct Shape: Equatable {
        let date: DateShape
        let before: String
        let after: String
    }

    private static let months = "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
    /// Most specific first, so "2024-03-15" isn't read as a bare year.
    private static let datePatterns: [(DateShape, String)] = [
        (.yearMonthDay, #"(?<!\d)(?:19|20)\d{2}-\d{2}-\d{2}(?!\d)"#),
        (.yearMonthDaySpelled, #"(?<!\d)(?:19|20)\d{2} \#(months) \d{1,2}(?!\d)"#),
        (.yearMonth, #"(?<!\d)(?:19|20)\d{2}-\d{2}(?![\d-])"#),
        (.monthYear, #"\#(months) (?:19|20)\d{2}(?!\d)"#),
        (.year, #"(?<![\d-])(?:19|20)\d{2}(?![\d-])"#),
    ]

    /// The one date in a stem and the text either side of it, or nil for none or more than one.
    static func shape(of stem: String) -> Shape? {
        for (kind, pattern) in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(stem.startIndex..., in: stem)
            let matches = regex.matches(in: stem, range: range)
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let found = Range(matches[0].range, in: stem) else { return nil }
            return Shape(date: kind, before: String(stem[..<found.lowerBound]), after: String(stem[found.upperBound...]))
        }
        return nil
    }

    /// A name in the shape of the folder's closest sibling: the one naming the same sender and
    /// kind has only its date changed ("2024 Ally 1099-INT" → "2025 Ally 1099-INT"); failing that,
    /// one naming the same kind, then the same sender, lends where its date goes and what sits
    /// between ("2024 - Chase 1099-INT" → "2025 - Ally 1099-INT").
    static func likeSiblings(_ facts: Facts, ext: String, folderFiles: [FolderFile]) -> Proposal? {
        let from = folded(facts.from), what = folded(facts.what)
        var best: (score: Int, file: FolderFile, stem: String)?
        for file in folderFiles.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedDescending }) {
            let stem = (file.name as NSString).deletingPathExtension
            // A scanner's name is no style to copy.
            guard !needsName(file.name), let shape = shape(of: stem), shape.date.render(facts) != nil else { continue }
            let text = folded(shape.before + " " + shape.after)
            let hasFrom = !from.isEmpty && text.contains(from)
            let hasWhat = !what.isEmpty && text.contains(what)
            let rank = hasFrom && hasWhat ? 3 : hasWhat ? 2 : hasFrom ? 1 : 0
            let sameExt = (file.name as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame
            let score = rank * 2 + (sameExt ? 1 : 0)
            if best.map({ score > $0.score }) ?? true { best = (score, file, stem) }
        }
        guard let best, let shape = shape(of: best.stem), let date = shape.date.render(facts) else { return nil }
        let stem: String
        if best.score >= 6 {
            stem = shape.before + date + shape.after
        } else {
            let rest = [facts.from, facts.what].filter { !$0.isEmpty }.joined(separator: " ")
            if shape.before.trimmingCharacters(in: .whitespaces).isEmpty {
                stem = shape.before + date + separator(leading: shape.after) + rest
            } else if shape.after.trimmingCharacters(in: .whitespaces).isEmpty {
                stem = rest + separator(trailing: shape.before) + date + shape.after
            } else {
                return nil
            }
        }
        return Proposal(name: finished(stem, ext: ext), basis: .like(best.file.name))
    }

    /// " - " from " - Chase 1099-INT", " " from " Chase".
    static func separator(leading text: String) -> String {
        let run = text.prefix { $0 == " " || $0 == "-" || $0 == "_" || $0 == "–" || $0 == "," }
        return run.isEmpty ? " " : String(run)
    }

    static func separator(trailing text: String) -> String {
        let run = text.reversed().prefix { $0 == " " || $0 == "-" || $0 == "_" || $0 == "–" || $0 == "," }
        return run.isEmpty ? " " : String(run.reversed())
    }

    // MARK: Plain names and tidying

    /// "2025-10 Ally Statement", or "2025 Ally 1099-INT" when the page gave no month.
    static func plainStem(_ facts: Facts) -> String {
        let date = facts.month.map { String(format: "%04d-%02d", facts.year, $0) } ?? String(facts.year)
        let what = facts.what.isEmpty || folded(facts.from).contains(folded(facts.what)) ? "" : facts.what
        let from = !facts.from.isEmpty && folded(facts.what).contains(folded(facts.from)) ? "" : facts.from
        return [date, from, what].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A model's words made safe for a name: no "/", ":" or line breaks, one space between words,
    /// no leading dot, at most 60 characters.
    static func clean(_ text: String) -> String {
        let replaced = text.map { "/:\\\n\r\t".contains($0) ? " " : $0 }
        var words = String(replaced).split(separator: " ").joined(separator: " ")
        while words.hasPrefix(".") { words.removeFirst() }
        words = words.trimmingCharacters(in: .whitespaces)
        return words.count > 60 ? String(words.prefix(60)).trimmingCharacters(in: .whitespaces) : words
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func finished(_ stem: String, ext: String) -> String {
        let stem = stem.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? stem : stem + "." + ext
    }
}

/// Whether Claude has a card's new names (TE328, decision IW): only after Share Names, or at once
/// when the files are in a folder shared without asking.
public struct AskClaudeHeldNames: Codable, Equatable, Sendable {
    /// Claude has them.
    public var shared: Bool
    /// The folder shared without asking, by label, when that's why Claude has them.
    public var sharedBy: String?
    /// Why the card's files couldn't be named now (Apple Intelligence off): the card's line.
    public var unavailable: String?

    public init(shared: Bool = false, sharedBy: String? = nil, unavailable: String? = nil) {
        self.shared = shared
        self.sharedBy = sharedBy
        self.unavailable = unavailable
    }

    /// The share button: "Share 2 Names and Folders".
    public static func shareButton(_ count: Int) -> String {
        count == 1 ? "Share 1 Name and Folder" : "Share \(count) Names and Folders"
    }

    /// The held line, before the click; what Claude has, after.
    public func line(_ count: Int) -> String {
        let names = count == 1 ? "the new name or where the file goes" : "the \(count) new names or where the files go"
        if let sharedBy { return "\(sharedBy) shares without asking, so Claude has \(count == 1 ? "this name and folder" : "these names and folders")." }
        if shared { return "Claude has the \(count == 1 ? "name and folder" : "\(count) names and folders") you shared." }
        return "Claude hasn’t seen \(names). Apple Intelligence made \(count == 1 ? "it" : "them") on this Mac from what \(count == 1 ? "the file says" : "the files say")."
    }

    /// Under the held line: what the button sends.
    public static let foot = "Not shared yet. Share Names and Folders sends each new name and its folder. No other content."
}
