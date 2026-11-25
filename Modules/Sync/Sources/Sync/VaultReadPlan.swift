import Foundation

/// Which of the files in the read folders Read Documents opens, and in what order, decided from
/// their paths alone, so the files opened are a small share of what is on disk.
///
/// - **Identity papers** (under Immigration or Legal): every file, as the ID readers need them.
/// - **Accounts** (under Health, Home, Vehicles or School): one file per account per year, the
///   newest first. An account is its folder with any year folders taken out
///   (`Home/Utilities/EBMUD/2024` is EBMUD in 2024), and the paper's name without its date and
///   kind, so cards from three plans filed side by side are three accounts. Folders that hold
///   records rather than an account's papers (test results, visits, homework, bylaws) are passed
///   over, and under School only files named for what carries a student's number (an ID card, an
///   enrollment, a report card). ``VaultModel`` stops reading an account once two of its years
///   agree on its number, once a number its papers print unlabelled is in two years, or after
///   three years that gave nothing.
/// - **Everywhere else**: only a file whose name says it is an ID (a passport, a visa, a license).
public struct VaultReadPlan: Equatable, Sendable {
    public enum Area: String, Equatable, Sendable, CustomStringConvertible {
        case identity, accounts, elsewhere
        public var description: String { rawValue }
    }

    /// One file to open; `account` names the account it is a year of, for accounts.
    public struct Step: Equatable, Sendable {
        public let file: URL
        public let account: String?
    }

    public let steps: [Step]

    /// `roots` are the read folders: a file's area is the folder just below its root, so
    /// `Claude/Projects/Home` is not Home. `modified` gives a file's date when neither a year folder
    /// nor its name says which year it is.
    public init(files: [URL], under roots: [String] = [], modified: (URL) -> Date? = { _ in nil }) {
        var whole: [Step] = []
        var years: [String: [String: (url: URL, date: Date?)]] = [:]
        for file in files {
            switch Self.area(of: file.path, under: roots) {
            case .identity:
                whole.append(Step(file: file, account: nil))
            case .elsewhere:
                if Self.namesAnID(file.lastPathComponent) { whole.append(Step(file: file, account: nil)) }
            case .accounts:
                guard let (account, year) = Self.accountYear(of: file, under: roots, modified: modified) else { continue }
                let date = modified(file)
                // The newest file of each year speaks for it.
                if let held = years[account]?[year], (held.date ?? .distantPast) >= (date ?? .distantPast) { continue }
                years[account, default: [:]][year] = (file, date)
            }
        }
        var accounts: [Step] = []
        for account in years.keys.sorted() {
            for year in years[account]!.keys.sorted(by: >) {
                accounts.append(Step(file: years[account]![year]!.url, account: account))
            }
        }
        steps = Self.originalsFirst(whole, under: roots) + accounts
    }

    /// Identity papers with the originals first: a file in an ID's own folder (Passport, Visa,
    /// Form I-94…) before the rest, and copies in packets, applications and archives last, each
    /// group in the order given. What is read is the same either way; a read stopped partway has
    /// the originals, and a copy read after its original only confirms it (VT107).
    static func originalsFirst(_ steps: [Step], under roots: [String] = []) -> [Step] {
        steps.enumerated()
            .map { (offset: $0.offset, step: $0.element, score: originalScore(below(roots, $0.element.file.path))) }
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
            .map(\.step)
    }

    /// `path` below the read folder it is in: a folder above it (a home folder named "Old")
    /// says nothing about one copy against another.
    private static func below(_ roots: [String], _ path: String) -> String {
        guard let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return path }
        return String(path.dropFirst(root.count))
    }

    /// Whether a file is a copy filed in a packet (a petition's, an application's, evidence):
    /// what ``originalScore(_:)`` puts last, below the read folder.
    static func isPacketCopy(_ path: String, under roots: [String]) -> Bool {
        originalScore(below(roots, path)) <= -2
    }

    /// How much a file's folders say it is an original, from the folder words
    /// ``VaultSource/placement(for:)`` weighs, with no kind yet known: a packet of copies (−2) is
    /// last wherever it is filed, even in an ID's own folder; otherwise an ID's own folder is +2,
    /// and an Archive, Backup or unfiled folder −1 (``VaultReading/ranksBelowFiled(_:)``).
    static func originalScore(_ path: String) -> Int {
        let folders = (path as NSString).deletingLastPathComponent.lowercased().split(separator: "/").map(String.init)
        if folders.contains(where: VaultSource.copyFolders.contains) { return -2 }
        var score = 0
        if folders.contains(where: VaultSource.homeFolders.contains) { score += 2 }
        if folders.contains(where: VaultReading.ranksBelowFiled) {
            score -= 1
        }
        return score
    }

    /// Steps for a refresh: every file given and none passed over, since each already gave an ID.
    /// An account's papers keep its name and go newest year first, so a number that two years'
    /// papers print unlabelled is read from both again.
    public static func every(_ files: [URL], under roots: [String] = [], modified: (URL) -> Date? = { _ in nil }) -> [Step] {
        var whole: [Step] = []
        var papers: [(account: String, year: String, file: URL)] = []
        for file in files {
            if area(of: file.path, under: roots) == .accounts,
               let (account, year) = accountYear(of: file, under: roots, modified: modified) {
                papers.append((account, year, file))
            } else {
                whole.append(Step(file: file, account: nil))
            }
        }
        papers.sort { $0.account != $1.account ? $0.account < $1.account : $0.year > $1.year }
        return originalsFirst(whole, under: roots) + papers.map { Step(file: $0.file, account: $0.account) }
    }

    // MARK: Areas

    private static let identityFolders: Set<String> = ["immigration", "legal"]
    private static let accountFolders: Set<String> = ["health", "home", "vehicles", "school"]

    /// Where a file is: by the folder just below its read folder (`Documents/Home/…` is Home,
    /// `Documents/Claude/Projects/Home/…` is not), or by the read folder itself when it is one
    /// (`Documents/Health` read on its own). With no read folder above it, by the first folder on
    /// its path that names an area.
    public static func area(of path: String, under roots: [String] = []) -> Area {
        guard let first = place(of: path, under: roots).first?.lowercased() else { return .elsewhere }
        if identityFolders.contains(first) { return .identity }
        if accountFolders.contains(first) { return .accounts }
        return .elsewhere
    }

    /// The folders a file sits in, from its area down: `["Home", "Utilities", "EBMUD", "2024"]`
    /// for `Documents/Home/Utilities/EBMUD/2024/March.pdf` read under `Documents`. Never a folder
    /// above the read folder, whose names say whose Mac it is or where a disk is mounted, not
    /// what a paper is. Empty for a paper filed in no area.
    static func place(of path: String, under roots: [String]) -> [String] {
        let directory = (path as NSString).deletingLastPathComponent
        if let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            let below = directory.dropFirst(root.count).split(separator: "/").map(String.init)
            let rootName = (root as NSString).lastPathComponent
            let isArea = { (name: String) in
                identityFolders.contains(name.lowercased()) || accountFolders.contains(name.lowercased())
            }
            return isArea(rootName) ? [rootName] + below : below
        }
        let all = directory.split(separator: "/").map(String.init)
        guard let start = all.firstIndex(where: {
            identityFolders.contains($0.lowercased()) || accountFolders.contains($0.lowercased())
        }) else { return [] }
        return Array(all[start...])
    }

    // MARK: Accounts

    /// Folders that hold an account's records, not its number: what a visit, a test, a bylaw or a
    /// class leaves.
    static let recordFolders: Set<String> = [
        "records", "visits", "immunizations", "devices", "reference", "test results", "procedures",
        "complaints & appeals", "cost estimates", "financial assistance", "authorizations", "claims",
        "brochures", "homework", "kinder decodables", "lors", "gre", "cc&rs", "landscaping", "pool rules",
        "notices", "violations", "club house", "hoa board", "financials", "budget", "chat transcripts",
        "delinquency", "applications", "reservations", "water quality", "quotes", "purchase", "service",
        "service record", "address change", "archive", "other copies", "tax", "bills", "eobs", "form 1095-b",
        "transfer", "sale", "mileage", "license plate", "medical baseline", "info form", "transaction history",
        "rental cars",
    ]

    /// Under School, the papers that carry a student's number.
    private static let schoolPapers = try! NSRegularExpression(
        pattern: #"(?<![a-z])(?:id|card|enrol(?:l)?ment|registration|report card|admission)(?![a-z])"#,
        options: [.caseInsensitive])

    private static let yearFolder = try! NSRegularExpression(pattern: #"^(?:19|20)[0-9]{2}$"#)
    private static let yearInName = try! NSRegularExpression(pattern: #"(?<![0-9])(20[0-9]{2})(?![0-9])"#)

    /// What a paper's name says beyond its date and its kind: "PG&E 2024-03 Statement" and
    /// "PGE_eBill_Apr" are both "pg e"/"pge", and "Kaiser - Shweta" is Kaiser for Shweta. Two
    /// papers of one folder with different names are two accounts (a dental, a medical and a vision
    /// card filed side by side); a month's bill and the next month's are one.
    private static let paperWords = try! NSRegularExpression(
        pattern: #"(?<![a-z])(?:e-?statements?|statements?|e-?bills?|bills?|invoices?|copy|scan(?:ned)?|front|back|page|final|signed|img|jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?![a-z])"#,
        options: [.caseInsensitive])

    static func paperName(_ name: String) -> String {
        let letters = String(name.lowercased().map { $0.isLetter ? $0 : " " })
        let ns = letters as NSString
        let bare = paperWords.stringByReplacingMatches(in: letters, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return bare.split(separator: " ").joined(separator: " ")
    }

    /// The account a file is a paper of, and the year it is for; nil for a file passed over.
    /// Record folders and School's own rule look only below the read folder (``place(of:under:)``).
    static func accountYear(of file: URL, under roots: [String] = [], modified: (URL) -> Date?) -> (account: String, year: String)? {
        let folders = file.deletingLastPathComponent().path.split(separator: "/").map(String.init)
        let place = Self.place(of: file.path, under: roots)
        // An account's papers filed away (Archive, Archived, Old, Backup) are records of it, not
        // its number to read: not only Archive (VT50, owner).
        guard !place.contains(where: {
            let name = $0.lowercased()
            return recordFolders.contains(name) || VaultReading.archiveNames.contains(name) || VaultReading.backupNames.contains(name)
        })
        else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        if place.first?.lowercased() == "school",
           schoolPapers.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) == nil {
            return nil
        }
        func isYear(_ s: String) -> Bool { yearFolder.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
        let account = "/" + folders.filter { !isYear($0) }.joined(separator: "/") + "#" + paperName(name)
        let year = folders.last(where: isYear)
            ?? yearInName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length))
                .map { (name as NSString).substring(with: $0.range(at: 1)) }
            ?? modified(file).map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) }
            ?? "-"
        return (account, year)
    }

    // MARK: Elsewhere

    private static let idName = try! NSRegularExpression(
        pattern: #"(?<![a-z])(?:passport|visa|oci|e-?visa|licen[cs]e|dl|i-?94|i-?797|i-?20|ead|green card|social security|ssn|itin|pan card|aadhaa?r|voter|id card)(?![a-z])"#,
        options: [.caseInsensitive])

    /// Whether a file's name says it is an ID: "Passport - Anna.pdf", "DL front.jpg".
    static func namesAnID(_ name: String) -> Bool {
        idName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }
}
