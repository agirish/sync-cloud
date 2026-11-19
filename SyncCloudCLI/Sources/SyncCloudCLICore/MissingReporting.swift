import Foundation
import Sync

/// `synccloud missing`: the statements each account folder lacks, from a terminal.
///
/// It reads file and folder names under one folder and nothing else: no file is opened, and
/// nothing is moved, fetched or written. The folder is the surveyed one unless another is named.
/// The finder is ``MissingStatements``; this is the walk that feeds it and the two renderings.
public enum MissingReporting {

    /// The command's whole result, in a stable public format: scripts parse it, so fields are only
    /// ever added, never renamed. Months are `YYYY-MM`.
    public struct Output: Codable, Equatable, Sendable {
        public struct Gap: Codable, Equatable, Sendable {
            /// `missing`, `behind`, `open`, `csvOnly`, `silence`, `waiting` or `expectedNext`.
            public let kind: String
            public let first: String
            public let last: String
            /// The months a statement was due; for a silence, every uncovered month.
            public let months: [String]
            /// Statements on the count. 0 when the gap is not counted.
            public let statements: Int
            /// `recent`, `sinceNewest` or `older`, for a counted gap.
            public var age: String?
            /// For a silence in a steady account: what it would hold at the account's rhythm.
            public var estimate: Int?
            /// The name suffix of the series the gap is in, such as `(NRO)`.
            public var series: String?
            /// PDFs beside the gap that do not follow the naming; above zero it is not counted.
            public var unnamedFiles: Int?
            /// For `waiting`: the file in an inbox folder, relative to the root.
            public var waitingFile: String?
            /// Due months marked Not Expected in the app.
            public var notExpected: [String]?
        }

        public struct Account: Codable, Equatable, Sendable {
            /// Relative to the root.
            public let path: String
            public let card: Bool
            /// `tracked`, `quiet` or `stopped`.
            public let tracking: String
            /// Hidden in the app: listed here, left out of every total.
            public let hidden: Bool
            public let statements: Int
            public let first: String
            public let newest: String
            public let counted: Int
            public let gaps: [Gap]
            /// Years lacking the `0. Summary YYYY` the two years before them have.
            public let missingSummaries: [Int]
        }

        public let schemaVersion: Int
        public let root: String
        public let asOf: String
        public let counted: Int
        public let countedAccounts: Int
        public let recent: Int
        public let sinceNewest: Int
        public let older: Int
        public let accounts: [Account]
        /// Folders that could not be listed. Their statements are unknown, not missing.
        public let notChecked: [String]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noFolder
        case notAFolder(path: String)

        public var errorDescription: String? {
            switch self {
            case .noFolder:
                return "No folder to check. SyncCloud has not surveyed a folder on this machine - "
                    + "name one: synccloud missing ~/Documents"
            case .notAFolder(let path):
                return "\(path) is not a folder this command can list."
            }
        }
    }

    // MARK: - Reading the tree

    /// Every file under `root` by its relative path, and the folders that would not list.
    /// Names only: nothing is opened. Hidden files and package contents are skipped.
    static func walk(_ root: URL, fileManager: FileManager = .default) -> (files: [String], notChecked: [String]) {
        let base = root.standardizedFileURL
        let depth = base.pathComponents.count
        func relative(_ url: URL) -> String {
            url.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
        }
        var notChecked: [String] = []
        guard let walker = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { url, _ in
                                                      notChecked.append(relative(url))
                                                      return true
                                                  }) else { return ([], [""]) }
        var files: [String] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(relative(url))
        }
        return (files, notChecked)
    }

    /// The surveyed folder, when there is an active profile to name one.
    static func surveyedRoot(profilesDirectory: URL?) -> (root: URL, profileId: String, directory: URL)? {
        guard let directory = profilesDirectory ?? FilingProfileStore.defaultDirectory(),
              let id = FilingProfileStore.activeProfileId(in: directory),
              let profile = FilingProfileStore.profile(id: id, in: directory) else { return nil }
        return (URL(fileURLWithPath: (profile.root as NSString).expandingTildeInPath), id, directory)
    }

    /// What the user decided in the app, kept as the `missing` section of the survey's
    /// `restructure.json`. Empty when there is none or it does not read.
    static func choices(profileId: String, in directory: URL) -> MissingStatements.Choices {
        struct Ledger: Decodable { let missing: MissingStatements.Choices? }
        let url = directory.appendingPathComponent("\(profileId)/restructure.json")
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return .init() }
        return ledger.missing ?? .init()
    }

    /// Walks `folder`, or the surveyed folder when none is named, and reports on it. The user's
    /// choices apply only to the surveyed folder: they are keyed by paths inside it.
    public static func report(folder: URL?, profilesDirectory: URL? = nil, now: Date = Date(),
                              calendar: Calendar = .current, fileManager: FileManager = .default) throws -> Output {
        let surveyed = surveyedRoot(profilesDirectory: profilesDirectory)
        guard let root = folder ?? surveyed?.root else { throw Failure.noFolder }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.notAFolder(path: root.path)
        }
        var choices = MissingStatements.Choices()
        if let surveyed, surveyed.root.standardizedFileURL.path == root.standardizedFileURL.path {
            choices = Self.choices(profileId: surveyed.profileId, in: surveyed.directory)
        }
        let tree = walk(root, fileManager: fileManager)
        let found = MissingStatements.find(paths: tree.files, notChecked: tree.notChecked, now: now,
                                           calendar: calendar, choices: choices)
        return output(for: found, root: root.path)
    }

    /// The `missing` command's body: the report, rendered as JSON or text, handed to `write`.
    public static func run(folder: URL?, profilesDirectory: URL?, json: Bool, now: Date = Date(),
                           calendar: Calendar = .current, write: (String) -> Void) throws {
        let output: Output
        do {
            output = try report(folder: folder, profilesDirectory: profilesDirectory, now: now, calendar: calendar)
        } catch let failure as Failure {
            throw CLIValidationError(message: failure.errorDescription ?? "\(failure)")
        }
        write(json ? try renderJSON(output) : renderText(output))
    }

    static func output(for report: MissingStatements.Report, root: String) -> Output {
        Output(schemaVersion: 1, root: root, asOf: report.asOf.iso, counted: report.counted,
               countedAccounts: report.countedAccounts, recent: report.counted(.recent),
               sinceNewest: report.counted(.sinceNewest), older: report.counted(.older),
               accounts: report.accounts.map { account in
                   Output.Account(path: account.path, card: account.isCard, tracking: account.tracking.rawValue,
                                  hidden: account.isHidden, statements: account.statements,
                                  first: account.first.iso, newest: account.newest.iso, counted: account.counted,
                                  gaps: account.gaps.map { gap in
                                      Output.Gap(kind: gap.kind.rawValue, first: gap.first.iso, last: gap.last.iso,
                                                 months: gap.months.map(\.iso), statements: gap.statements,
                                                 age: gap.age?.rawValue, estimate: gap.estimate,
                                                 series: gap.series.isEmpty ? nil : gap.series,
                                                 unnamedFiles: gap.unnamedFiles > 0 ? gap.unnamedFiles : nil,
                                                 waitingFile: gap.waitingFile,
                                                 notExpected: gap.notExpected.isEmpty ? nil : gap.notExpected.map(\.iso))
                                  },
                                  missingSummaries: account.missingSummaries)
               },
               notChecked: report.notChecked)
    }

    // MARK: - Rendering

    /// The `--json` rendering: sorted keys so two runs over one tree diff clean.
    public static func renderJSON(_ output: Output) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    /// The months a gap names, in the tool's ASCII: `Sep 2026`, `Aug-Dec 2025`,
    /// `Dec 2019 - May 2020`, and `Aug, Oct, Dec 2025` for an account not billed every month.
    static func monthsText(_ gap: Output.Gap) -> String {
        let months = gap.months.compactMap(MissingStatements.Month.init(iso:))
        let exact = gap.kind != "silence"
        let contiguous = zip(months, months.dropFirst()).allSatisfy { $1.index - $0.index == 1 }
        if exact, months.count == 1 { return months[0].label }
        if exact, !contiguous, let first = months.first, let last = months.last {
            return first.year == last.year
                ? months.map(\.shortName).joined(separator: ", ") + " \(first.year)"
                : months.map(\.label).joined(separator: ", ")
        }
        guard let first = MissingStatements.Month(iso: gap.first), let last = MissingStatements.Month(iso: gap.last) else { return gap.first }
        if first == last { return first.label }
        return first.year == last.year ? "\(first.shortName)-\(last.label)" : "\(first.label) - \(last.label)"
    }

    /// One account's line: what is counted first, then what is waiting, then what is not counted.
    static func line(_ account: Output.Account) -> String {
        var counted: [String] = [], other: [String] = []
        for gap in account.gaps {
            let text = monthsText(gap) + (gap.series.map { " \($0)" } ?? "") + (gap.kind == "csvOnly" ? " (CSV only)" : "")
            switch gap.kind {
            case "expectedNext": continue
            case "waiting": counted.append("\(text) (waiting in \(gap.waitingFile ?? "an inbox folder"))")
            default:
                if gap.statements > 0 {
                    counted.append("\(text) (\(gap.statements))")
                } else if (gap.unnamedFiles ?? 0) > 0 {
                    other.append("\(text) (name \(count(gap.unnamedFiles ?? 0, "unnamed file")) first)")
                } else if gap.kind == "silence" {
                    other.append(text + (gap.estimate.map { " (about \($0))" } ?? ""))
                } else {
                    other.append("\(text) (not expected)")
                }
            }
        }
        other += account.missingSummaries.map { "0. Summary \($0)" }
        if !other.isEmpty { counted.append("not counted: " + other.joined(separator: ", ")) }
        return "  \(account.path): " + counted.joined(separator: "; ")
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The default rendering: one line per account, the ones worth fetching first.
    public static func renderText(_ output: Output) -> String {
        let asOf = MissingStatements.Month(iso: output.asOf)?.label ?? output.asOf
        var lines = ["Missing statements in \(output.root), \(asOf)"]
        let shown = output.accounts.filter { !$0.hidden }
        if shown.isEmpty {
            lines.append("No folder here holds statements named like \"3. Mar 2026.pdf\".")
        } else if output.counted == 0 {
            lines.append("Nothing is missing. \(count(shown.count, "account")) checked.")
        } else {
            lines.append("\(count(output.counted, "statement")) missing from \(count(output.countedAccounts, "account")): "
                         + "\(output.recent) recent, \(output.sinceNewest) since a last statement, "
                         + "\(output.older) older than two years.")
        }

        func counted(_ account: Output.Account, _ age: String) -> Int {
            account.gaps.filter { $0.age == age }.reduce(0) { $0 + $1.statements }
        }
        func newest(_ account: Output.Account) -> String { account.gaps.filter { $0.statements > 0 }.map(\.last).max() ?? "" }
        func uncounted(_ account: Output.Account) -> Bool {
            account.gaps.contains { $0.statements == 0 && $0.kind != "expectedNext" && $0.kind != "waiting" }
        }
        var rest = shown
        func take(_ title: String, _ belongs: (Output.Account) -> Bool, by order: (Output.Account, Output.Account) -> Bool) {
            let group = rest.filter(belongs).sorted(by: order)
            rest.removeAll(where: belongs)
            guard !group.isEmpty else { return }
            lines.append("")
            lines.append(title + ":")
            lines += group.map(line)
        }
        let newestFirst: (Output.Account, Output.Account) -> Bool = { (newest($0), $1.path) > (newest($1), $0.path) }
        let byPath: (Output.Account, Output.Account) -> Bool = { $0.path < $1.path }
        take("Recent", { counted($0, "recent") > 0 }, by: newestFirst)
        take("Since the last statement", { counted($0, "sinceNewest") > 0 }, by: { ($0.counted, $1.path) > ($1.counted, $0.path) })
        take("Older than two years", { $0.counted > 0 }, by: newestFirst)
        take("Not counted - long silences", { !$0.card && uncounted($0) }, by: byPath)
        take("Not counted - cards with a silence", { $0.card && uncounted($0) }, by: byPath)
        take("Not counted - year summaries", { !$0.missingSummaries.isEmpty }, by: byPath)

        var footer: [String] = []
        let next = shown.filter { $0.gaps.contains { $0.kind == "expectedNext" } }.count
        if next > 0 { footer.append("Expected next: \(count(next, "account"))") }
        let idle = shown.filter { $0.tracking != "tracked" }.count
        if idle > 0 { footer.append("Not tracked: \(count(idle, "account"))") }
        let hidden = output.accounts.count - shown.count
        if hidden > 0 { footer.append("Hidden: \(count(hidden, "account"))") }
        if !footer.isEmpty {
            lines.append("")
            lines.append(footer.joined(separator: " · "))
        }
        if !output.notChecked.isEmpty {
            lines.append("Not checked (could not be listed): " + output.notChecked.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
