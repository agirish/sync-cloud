import Foundation

/// Which statements an account folder lacks, read from file and folder names alone.
///
/// The house convention names a statement by its position and period (`3. Mar 2026.pdf`,
/// `4. Apr-Jun 2026.pdf`, `1. Nov 2023-Feb 2024.pdf`) inside an account folder, usually under a
/// year folder. That is enough to say which periods never arrived, without opening a file.
///
/// Pure: the caller hands over relative paths, today's date and what the user has decided
/// (``Choices``), so the same answer comes from the app's walk, the command line and a test's
/// made-up tree.
///
/// ## What it reports
///
/// | Kind | Meaning | Counted |
/// |---|---|---|
/// | ``Gap/Kind/missing`` | a hole between statements of a steady account, with a known number | yes |
/// | ``Gap/Kind/behind`` | statements due after the newest one of a steady account | yes |
/// | ``Gap/Kind/open`` | months after the newest statement of an account with no steady rhythm | yes |
/// | ``Gap/Kind/csvOnly`` | a month holding the CSV without the PDF the account normally keeps | yes |
/// | ``Gap/Kind/silence`` | a stretch whose number of statements the names cannot give | only by choice |
/// | ``Gap/Kind/waiting`` | a month whose named statement sits in an inbox folder | no |
/// | ``Gap/Kind/expectedNext`` | the newest finished month, never late yet | no |
///
/// A gap beside files that do not follow the naming is reported and never counted: one of those
/// files may be the statement.
public enum MissingStatements {

    // MARK: - Months

    /// A calendar month, ordered. Encoded as `2026-09`.
    public struct Month: Hashable, Comparable, Sendable, Codable {
        /// `year * 12 + month - 1`, so months subtract.
        public let index: Int

        public init(index: Int) { self.index = index }
        public init(year: Int, month: Int) { self.index = year * 12 + month - 1 }

        public var year: Int { index / 12 }
        /// 1 to 12.
        public var month: Int { index % 12 + 1 }
        /// `2026-09`.
        public var iso: String { String(format: "%04d-%02d", year, month) }
        /// `Sep 2026`.
        public var label: String { "\(OrdinalMonthName.monthAbbreviations[month - 1]) \(year)" }
        /// `Sep`.
        public var shortName: String { OrdinalMonthName.monthAbbreviations[month - 1] }

        public static func < (a: Month, b: Month) -> Bool { a.index < b.index }

        public init?(iso: String) {
            let parts = iso.split(separator: "-")
            guard parts.count == 2, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]),
                  (1...12).contains(m) else { return nil }
            self.init(year: y, month: m)
        }

        public init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let month = Month(iso: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "not a YYYY-MM month: \(text)"))
            }
            self = month
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(iso)
        }
    }

    // MARK: - What the user decided

    /// The user's decisions, keyed by an account's path relative to the walked root. Everything
    /// else is recomputed from names on every run.
    public struct Choices: Sendable, Equatable, Codable {
        /// Accounts left out of every count.
        public var hidden: Set<String>
        /// Accounts the user stopped tracking, with the newest statement each had then. A newer
        /// statement starts tracking again, so the entry stops applying on its own.
        public var stopped: [String: Month]
        /// Quiet accounts the user started tracking, with the first month a statement is expected.
        public var started: [String: Month]
        /// Months taken off the count, per account.
        public var notExpected: [String: Set<Month>]
        /// Months of a silence put on the count, per account.
        public var counted: [String: Set<Month>]
        /// When this root was first checked. An account whose newest statement was already more
        /// than ``MissingStatements/quietAfter`` months old then is quiet; every other account is
        /// tracked and never goes quiet by itself. nil reads as today.
        public var firstChecked: Month?

        public init(hidden: Set<String> = [], stopped: [String: Month] = [:], started: [String: Month] = [:],
                    notExpected: [String: Set<Month>] = [:], counted: [String: Set<Month>] = [:],
                    firstChecked: Month? = nil) {
            self.hidden = hidden
            self.stopped = stopped
            self.started = started
            self.notExpected = notExpected
            self.counted = counted
            self.firstChecked = firstChecked
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            stopped = try c.decodeIfPresent([String: Month].self, forKey: .stopped) ?? [:]
            started = try c.decodeIfPresent([String: Month].self, forKey: .started) ?? [:]
            notExpected = try c.decodeIfPresent([String: Set<Month>].self, forKey: .notExpected) ?? [:]
            counted = try c.decodeIfPresent([String: Set<Month>].self, forKey: .counted) ?? [:]
            firstChecked = try c.decodeIfPresent(Month.self, forKey: .firstChecked)
        }
    }

    // MARK: - The report

    public struct Gap: Sendable, Equatable {
        public enum Kind: String, Sendable { case missing, behind, open, csvOnly, silence, waiting, expectedNext }
        /// Where a counted gap sits in the lens's split.
        public enum Age: String, Sendable { case recent, sinceNewest, older }

        public let kind: Kind
        public let first: Month
        public let last: Month
        /// The months a statement was due. For a silence, every uncovered month.
        public let months: [Month]
        /// Statements on the count once the user's choices are applied; 0 when the gap is not
        /// counted.
        public let statements: Int
        /// For a silence in a steady account: how many statements it would hold had the account
        /// kept its rhythm. An estimate, never counted.
        public let estimate: Int?
        /// The name suffix this gap's series carries (`(NRO)`), or empty.
        public let series: String
        /// PDFs beside this gap that do not follow the naming. Above zero, the gap is not counted.
        public let unnamedFiles: Int
        /// For ``Kind/waiting``: the file in an inbox folder, relative to the root.
        public let waitingFile: String?
        /// The due months the user marked Not Expected.
        public let notExpected: [Month]
        /// nil when nothing in the gap is counted.
        public let age: Age?

        public var isCounted: Bool { statements > 0 }
    }

    public struct Account: Sendable, Equatable {
        public enum Tracking: String, Sendable {
            /// A statement is expected after the newest one.
            case tracked
            /// Already silent at the first check; nothing is expected.
            case quiet
            /// The user stopped it; its next statement starts it again.
            case stopped
        }

        /// The folder holding the statements or their year folders, relative to the root.
        public let path: String
        public let isCard: Bool
        public let tracking: Tracking
        public let isHidden: Bool
        /// Distinct statements read (a PDF and its CSV are one).
        public let statements: Int
        public let first: Month
        public let newest: Month
        public let gaps: [Gap]
        /// Years lacking the `0. Summary YYYY` the two years before them have.
        public let missingSummaries: [Int]

        public var counted: Int { gaps.reduce(0) { $0 + $1.statements } }
        public func counted(_ age: Gap.Age) -> Int { gaps.filter { $0.age == age }.reduce(0) { $0 + $1.statements } }
    }

    public struct Report: Sendable, Equatable {
        /// The month the report was made in.
        public let asOf: Month
        /// Every account checked, hidden ones included, by path.
        public let accounts: [Account]
        /// Folders that could not be listed. Never reported as empty.
        public let notChecked: [String]

        public var visible: [Account] { accounts.filter { !$0.isHidden } }
        /// Statements on the count: every counted gap of every account that is not hidden.
        public var counted: Int { visible.reduce(0) { $0 + $1.counted } }
        public var countedAccounts: Int { visible.filter { $0.counted > 0 }.count }
        public func counted(_ age: Gap.Age) -> Int { visible.reduce(0) { $0 + $1.counted(age) } }
    }

    // MARK: - Settings

    /// How many statements on each side of a break set the account's rhythm there.
    static let neighborhood = 12
    /// How far from a break, in months, a statement still counts as its neighbor.
    static let reach = 36
    /// The longest gap that gets an exact count. A longer one is a silence with an estimate.
    static let countCap = 12
    /// Months of silence at the first check after which an account is quiet.
    public static let quietAfter = 14
    /// A counted gap this recent, in months, is "recent"; older ones are history.
    static let recentWindow = 24
    /// The shortest stretch reported as a silence in an account with no steady rhythm.
    static let shortestLooseSilence = 6
    /// A card's hole is counted only up to this many statements, in an otherwise unbroken run.
    static let cardCountCap = 2
    /// A folder is an account, and a suffix its own series, from this many statements.
    static let fewestStatements = 4
    /// Unnamed PDFs in the account folder itself cast doubt on its gaps from this many.
    static let fewestLooseFilesToDoubt = 3

    // MARK: - Reading a name

    enum Named: Equatable {
        /// The months a statement covers, and whatever its name carries after the date.
        case statement(start: Int, end: Int, suffix: String)
        case summary(year: Int)
        /// `05. Jan 15 2026`: a dated document, not a month's statement.
        case dayDated
    }

    /// What a file name says it is, or nil when it does not follow the naming.
    static func read(_ name: String) -> Named? {
        guard let parsed = OrdinalMonthName.parse(name) else { return nil }
        if let period = period(ofBody: parsed.body) { return period }
        if parsed.isSummarySlot, parsed.month == nil, let year = parsed.year { return .summary(year: year) }
        return nil
    }

    /// The period a name's body spells: `Mar 2026`, `Apr-Jun 2026`, `Nov 2023-Feb 2024`,
    /// `Apr 2007 to Aug 2007`, full month names in any case. A same-year range that runs backward
    /// (`Nov-Feb 2024`) started the year before.
    static func period(ofBody body: String) -> Named? {
        var tokens: [(text: Substring, end: String.Index)] = []
        var start: String.Index?
        for i in body.indices {
            let c = body[i]
            if c.isLetter || c.isNumber {
                if start == nil { start = i }
            } else if let s = start {
                tokens.append((body[s..<i], i))
                start = nil
            }
        }
        if let s = start { tokens.append((body[s...], body.endIndex)) }

        func month(_ i: Int) -> Int? {
            i < tokens.count ? OrdinalMonthName.monthIndex(tokens[i].text.lowercased()) : nil
        }
        func year(_ i: Int) -> Int? {
            guard i < tokens.count, tokens[i].text.count == 4, tokens[i].text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let y = Int(tokens[i].text), (1900...2199).contains(y) else { return nil }
            return y
        }
        func suffix(after i: Int) -> String {
            String(body[tokens[i].end...]).trimmingCharacters(in: .whitespaces)
        }
        guard let first = month(0) else { return nil }
        if let end = month(1), let y = year(2) {
            let e = y * 12 + end - 1
            var s = y * 12 + first - 1
            if s > e { s -= 12 }
            return .statement(start: s, end: e, suffix: suffix(after: 2))
        }
        if tokens.count > 2, tokens[1].text.count <= 2, let d = Int(tokens[1].text), (1...31).contains(d), year(2) != nil {
            return .dayDated
        }
        guard let y = year(1) else { return nil }
        let s = y * 12 + first - 1
        let next = tokens.count > 2 && tokens[2].text.lowercased() == "to" ? 3 : 2
        if let end = month(next), let y2 = year(next + 1) {
            let e = y2 * 12 + end - 1
            guard e >= s else { return nil }
            return .statement(start: s, end: e, suffix: suffix(after: next + 1))
        }
        return .statement(start: s, end: s, suffix: suffix(after: 1))
    }

    // MARK: - The rule

    struct Found: Equatable {
        enum Kind: Equatable { case hole, silence, behind, behindUnknown, open, next }
        let kind: Kind
        let first: Int
        let last: Int
        /// The months a statement was due; empty for a silence.
        let due: [Int]
        var estimate: Int?
    }

    /// The gaps in one series.
    ///
    /// - Parameters:
    ///   - series: each statement's last month, mapped to its first.
    ///   - neutral: months of years that hold only a summary. They are cut out of the timeline, so
    ///     such a year is neither a gap nor a twelve-month pause to its neighbors.
    ///   - now: the month in progress. The month before it is the newest finished one.
    ///   - expectsMore: whether anything is expected after the newest statement.
    static func gaps(in series: [Int: Int], neutral: Set<Int> = [], now: Int, isCard: Bool = false,
                     expectsMore: Bool = true) -> [Found] {
        let cut = neutral.sorted()
        func lowerBound(_ value: Int) -> Int {
            var lo = 0, hi = cut.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cut[mid] < value { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        /// A month's position once the neutral months are cut out.
        func place(_ month: Int) -> Int { month - lowerBound(month) }
        /// The month at a position: the inverse of `place`, skipping neutral months.
        func month(at position: Int) -> Int {
            var month = position
            while true {
                let next = position + lowerBound(month + 1)
                if next == month { return month }
                month = next
            }
        }

        // A quarter-to-date folder (`Jul`, `Jul-Aug`, `Jul-Sep`): a file that contains an earlier
        // file's last month stands only for what that file does not cover.
        let ends = series.keys.sorted()
        var periods: [(start: Int, end: Int)] = []
        for end in ends {
            var start = series[end] ?? end
            if start < end, let inner = ends.last(where: { $0 >= start && $0 < end }) { start = inner + 1 }
            periods.append((start, end))
        }
        let n = periods.count
        guard n >= fewestStatements else { return [] }

        let pause = (0..<(n - 1)).map { place(periods[$0 + 1].start) - place(periods[$0].end) - 1 }
        let step = (0..<(n - 1)).map { place(periods[$0 + 1].end) - place(periods[$0].end) }

        /// The breaks near break `k`; `k == n - 1` is the open end, which has only a past.
        func around(_ k: Int) -> [Int] {
            let leftEdge = place(periods[k].end)
            let rightEdge = place(periods[min(k + 1, n - 1)].end)
            var near = (max(0, k - neighborhood)..<k).filter { leftEdge - place(periods[$0].end) <= reach }
            let upper = min(n - 1, k + 1 + neighborhood)
            if k + 1 < upper {
                near += ((k + 1)..<upper).filter { place(periods[$0 + 1].end) - rightEdge <= reach }
            }
            return near
        }
        struct Rhythm { let pause: Int, cycle: Int, steady: Bool, even: Bool, others: Int }
        /// The account's habit among `near`: its usual pause, how far apart statements end, whether
        /// at most one other break differs, and whether the usual ones are evenly spaced.
        func rhythm(_ near: [Int]) -> Rhythm? {
            guard near.count >= 3 else { return nil }
            let pauses = near.map { pause[$0] }.sorted()
            let usualPause = pauses[(pauses.count - 1) / 2]
            let odd = near.filter { pause[$0] != usualPause }.count
            let steps = near.filter { pause[$0] == usualPause }.map { step[$0] }.sorted()
            let cycle = steps[(steps.count - 1) / 2]
            let even = Double(steps.filter { $0 == cycle }.count) >= 0.8 * Double(steps.count)
            return Rhythm(pause: usualPause, cycle: cycle, steady: odd <= (near.count >= 6 ? 1 : 0),
                          even: even, others: odd)
        }

        var out: [Found] = []
        for k in 0..<(n - 1) {
            let lo = periods[k].end + 1, hi = periods[k + 1].start
            guard lo < hi else { continue }
            let months = (lo..<hi).filter { !neutral.contains($0) }
            guard let first = months.first, let last = months.last else { continue }
            let near = around(k)
            guard let r = rhythm(near) else { continue }
            if r.steady, pause[k] > r.pause {
                let extra = pause[k] - r.pause
                let count = extra / r.cycle
                let countable = extra % r.cycle == 0 && count >= 1 && r.even
                if countable, count <= countCap, !isCard || (count <= cardCountCap && r.others == 0) {
                    let due = (1...count).map { month(at: place(periods[k].end) + $0 * r.cycle) }
                    out.append(Found(kind: .hole, first: first, last: last, due: due))
                } else if !isCard || months.count >= 3 {
                    out.append(Found(kind: .silence, first: first, last: last, due: [], estimate: countable ? count : nil))
                }
            } else if !r.steady, pause[k] >= shortestLooseSilence, near.count >= 4 {
                let pauses = near.map { pause[$0] }.sorted()
                if pause[k] > 2 * pauses[pauses.count / 2] {
                    out.append(Found(kind: .silence, first: first, last: last, due: []))
                }
            }
        }

        guard expectsMore else { return out }
        let newest = periods[n - 1].end
        let r = rhythm(around(n - 1))
        if let r, r.steady, r.even {
            // The newest finished month is `now - 1`. A statement due then is only expected next;
            // every one due before it is missing.
            var due: [Int] = []
            var j = 1
            while true {
                let d = month(at: place(newest) + j * r.cycle)
                if d > now - 1 { break }
                due.append(d)
                j += 1
            }
            let late = due.filter { $0 <= now - 2 }
            if let end = late.last { out.append(Found(kind: .behind, first: newest + 1, last: end, due: late)) }
            if due.last == now - 1 { out.append(Found(kind: .next, first: now - 1, last: now - 1, due: [now - 1])) }
        } else {
            let owed = newest + 1 < now - 1 ? ((newest + 1)..<(now - 1)).filter { !neutral.contains($0) } : []
            if let first = owed.first, let last = owed.last {
                // Steady coverage of mixed lengths is behind by an unknown number; an account with
                // no rhythm owes a month at a time.
                let steadyButUneven = r?.steady ?? false
                out.append(Found(kind: steadyButUneven ? .behindUnknown : .open, first: first, last: last,
                                 due: steadyButUneven ? [] : owed))
            }
            if newest < now - 1 { out.append(Found(kind: .next, first: now - 1, last: now - 1, due: [now - 1])) }
        }
        return out
    }

    // MARK: - Accounts

    private struct Folder {
        /// Suffix to series; a series maps each statement's last month to its first.
        var series: [String: [Int: Int]] = [:]
        /// The statements, by suffix and last month, that have a PDF.
        var pdf: [String: Set<Int>] = [:]
        var summaries: Set<Int> = []
        /// Unnamed PDFs, by the year folder holding them.
        var unnamedByYear: [String: Int] = [:]
        var unnamedHere = 0
    }

    private static let yearFolder = try! NSRegularExpression(pattern: #"^(19|20)\d{2}(-(19|20)\d{2})?$"#)

    static func isYearFolder(_ name: String) -> Bool {
        yearFolder.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Whether an account's path says it is a card: a card sends nothing in a month it was not
    /// used, so its silences are probably not missing statements.
    public static func pathNamesACard(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            for word in component.lowercased().split(whereSeparator: { !$0.isLetter }) {
                if word == "credit" || word == "card" || word == "cards" { return true }
            }
        }
        return false
    }

    /// Reads a tree's names and reports what each account lacks.
    ///
    /// - Parameters:
    ///   - paths: every file, relative to the walked root, `/`-separated.
    ///   - notChecked: folders that could not be listed, passed through to the report.
    ///   - now: today. Only its month matters.
    ///   - isArchived: the profile's word on a folder; a folder named `Archive` counts either way.
    ///   - isInbox: where files wait to be filed. A named statement there is "waiting".
    ///   - isCard: whether an account's path names a card.
    public static func find(paths: [String], notChecked: [String] = [], now: Date, calendar: Calendar = .current,
                            choices: Choices = Choices(),
                            isArchived: (String) -> Bool = { _ in false },
                            isInbox: (String) -> Bool = { FolderProfile.isInboxPath($0) },
                            isCard: (String) -> Bool = { pathNamesACard($0) }) -> Report {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let nowIndex = (parts.year ?? 1970) * 12 + (parts.month ?? 1) - 1
        let firstChecked = choices.firstChecked?.index ?? nowIndex

        var folders: [String: Folder] = [:]
        struct Waiting { let folder: [String]; let start: Int; let end: Int; let path: String }
        var waiting: [Waiting] = []

        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            guard let name = components.popLast(), !name.hasPrefix("."),
                  !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            let directory = components.joined(separator: "/")
            guard !FolderProfile.isDeletedPath(directory) else { continue }
            let inYear = components.last.map(isYearFolder) ?? false
            let accountComponents = inYear ? Array(components.dropLast()) : components
            let named = read(name)
            if isInbox(directory) {
                if case .statement(let start, let end, _)? = named {
                    waiting.append(Waiting(folder: accountComponents.filter { !isInbox($0) }, start: start, end: end, path: path))
                }
                continue
            }
            let key = accountComponents.joined(separator: "/")
            switch named {
            case .statement(let start, let end, let suffix)?:
                // Two files ending the same month are one statement; the shorter period is the
                // statement, the longer a consolidated copy.
                let known = folders[key]?.series[suffix]?[end] ?? start
                folders[key, default: Folder()].series[suffix, default: [:]][end] = max(start, known)
                if (name as NSString).pathExtension.lowercased() == "pdf" {
                    folders[key, default: Folder()].pdf[suffix, default: []].insert(end)
                }
            case .summary(let year)?:
                folders[key, default: Folder()].summaries.insert(year)
            case .dayDated?:
                break
            case nil:
                guard (name as NSString).pathExtension.lowercased() == "pdf" else { continue }
                if inYear, let year = components.last {
                    folders[key, default: Folder()].unnamedByYear[year, default: 0] += 1
                } else {
                    folders[key, default: Folder()].unnamedHere += 1
                }
            }
        }

        var accounts: [Account] = []
        for (path, folder) in folders {
            let components = path.split(separator: "/").map(String.init)
            guard !components.contains(where: AccountIndex.isArchiveName), !isArchived(path) else { continue }

            // A suffix is its own series only when it recurs; a stray one joins the plain series.
            var series: [String: [Int: Int]] = [:]
            var pdf: [String: Set<Int>] = [:]
            for (suffix, statements) in folder.series {
                let key = !suffix.isEmpty && statements.count >= fewestStatements ? suffix : ""
                series[key, default: [:]].merge(statements) { max($0, $1) }
                pdf[key, default: []].formUnion(folder.pdf[suffix] ?? [])
            }
            series = series.filter { $0.value.count >= fewestStatements }
            guard !series.isEmpty else { continue }

            let card = isCard(path)
            let newest = series.values.compactMap { $0.keys.max() }.max() ?? nowIndex
            let first = series.values.compactMap { $0.values.min() }.min() ?? newest
            let quiet = firstChecked - newest > quietAfter
            let tracking: Account.Tracking
            if quiet {
                tracking = choices.started[path] != nil ? .tracked : .quiet
            } else {
                tracking = choices.stopped[path]?.index == newest ? .stopped : .tracked
            }

            // A file waiting in an inbox belongs to the account whose folder name ends its path.
            let leaf = components.last(where: { $0.lowercased() != "statements" }) ?? ""
            let mine = waiting.filter { $0.folder.last?.caseInsensitiveCompare(leaf) == .orderedSame }
            let dismissed = choices.notExpected[path] ?? []
            let chosen = choices.counted[path] ?? []
            let doubtHere = folder.unnamedHere >= fewestLooseFilesToDoubt ? folder.unnamedHere : 0
            func unnamed(_ first: Int, _ last: Int) -> Int {
                (first / 12...last / 12).reduce(doubtHere) { $0 + (folder.unnamedByYear[String($1)] ?? 0) }
            }
            func age(_ kind: Gap.Kind, _ last: Int) -> Gap.Age {
                kind == .open ? .sinceNewest : (last >= nowIndex - recentWindow ? .recent : .older)
            }
            func exact(_ kind: Gap.Kind, first: Int, last: Int, due: [Int], suffix: String) -> Gap {
                let doubt = unnamed(first, last)
                let off = due.filter { dismissed.contains(Month(index: $0)) }
                let count = doubt > 0 ? 0 : due.count - off.count
                return Gap(kind: kind, first: Month(index: first), last: Month(index: last), months: due.map(Month.init(index:)),
                           statements: count, estimate: nil, series: suffix, unnamedFiles: doubt, waitingFile: nil,
                           notExpected: off.map(Month.init(index:)), age: count > 0 ? age(kind, last) : nil)
            }

            var list: [Gap] = []
            var covered: Set<Int> = []
            for (suffix, statements) in series {
                for (end, start) in statements { covered.formUnion(start...end) }
                var neutral: Set<Int> = []
                for year in folder.summaries where !(0..<12).contains(where: { m in
                    statements.contains { $0.value <= year * 12 + m && year * 12 + m <= $0.key }
                }) {
                    neutral.formUnion((year * 12)..<(year * 12 + 12))
                }
                let seriesNewest = statements.keys.max() ?? newest
                let expectsMore = !quiet && tracking == .tracked && firstChecked - seriesNewest <= quietAfter
                for found in gaps(in: statements, neutral: neutral, now: nowIndex, isCard: card, expectsMore: expectsMore) {
                    switch found.kind {
                    case .next:
                        list.append(Gap(kind: .expectedNext, first: Month(index: found.first), last: Month(index: found.last),
                                        months: found.due.map(Month.init(index:)), statements: 0, estimate: nil, series: suffix,
                                        unnamedFiles: 0, waitingFile: nil, notExpected: [], age: nil))
                    case .silence, .behindUnknown:
                        let months = (found.first...found.last).filter { !neutral.contains($0) }
                        let doubt = unnamed(found.first, found.last)
                        let count = doubt > 0 ? 0 : months.filter { chosen.contains(Month(index: $0)) }.count
                        list.append(Gap(kind: .silence, first: Month(index: found.first), last: Month(index: found.last),
                                        months: months.map(Month.init(index:)), statements: count, estimate: found.estimate,
                                        series: suffix, unnamedFiles: doubt, waitingFile: nil, notExpected: [],
                                        age: count > 0 ? age(.silence, found.last) : nil))
                    case .hole, .behind, .open:
                        var due = found.due
                        var anyWaiting = false
                        for month in found.due {
                            guard let file = mine.first(where: { $0.start <= month && month <= $0.end }) else { continue }
                            due.removeAll { $0 == month }
                            anyWaiting = true
                            list.append(Gap(kind: .waiting, first: Month(index: month), last: Month(index: month),
                                            months: [Month(index: month)], statements: 0, estimate: nil, series: suffix,
                                            unnamedFiles: 0, waitingFile: file.path, notExpected: [], age: nil))
                        }
                        guard let dueFirst = due.first, let dueLast = due.last else { continue }
                        let kind: Gap.Kind = found.kind == .hole ? .missing : (found.kind == .behind ? .behind : .open)
                        // The stretch as found, unless a waiting file split it; then only what is still due.
                        let whole = !anyWaiting
                        list.append(exact(kind, first: whole ? found.first : dueFirst, last: whole ? found.last : dueLast,
                                          due: due, suffix: suffix))
                    }
                }
                // Where the account normally keeps a PDF, a month with only the CSV lacks its statement.
                let withPDF = pdf[suffix] ?? []
                if Double(withPDF.count) >= 0.8 * Double(statements.count) {
                    for end in statements.keys.sorted() where !withPDF.contains(end) {
                        list.append(exact(.csvOnly, first: end, last: end, due: [end], suffix: suffix))
                    }
                }
            }
            // A quiet account the user started: every month from the one they chose is expected.
            if quiet, tracking == .tracked, let from = choices.started[path]?.index {
                let owed = from < nowIndex - 1 ? (from..<(nowIndex - 1)).filter { !covered.contains($0) } : []
                if let owedFirst = owed.first, let owedLast = owed.last {
                    list.append(exact(.open, first: owedFirst, last: owedLast, due: owed, suffix: ""))
                }
                if from <= nowIndex - 1, !covered.contains(nowIndex - 1) {
                    list.append(Gap(kind: .expectedNext, first: Month(index: nowIndex - 1), last: Month(index: nowIndex - 1),
                                    months: [Month(index: nowIndex - 1)], statements: 0, estimate: nil, series: "",
                                    unnamedFiles: 0, waitingFile: nil, notExpected: [], age: nil))
                }
            }
            list.sort { ($0.first, $0.last, $0.kind.rawValue, $0.series) < ($1.first, $1.last, $1.kind.rawValue, $1.series) }

            // A summary is expected for a year with statements when the two years before have one.
            let summaries = folder.summaries
            var missingSummaries: [Int] = []
            if let earliest = summaries.min(), earliest + 2 < nowIndex / 12 {
                missingSummaries = ((earliest + 2)..<(nowIndex / 12)).filter { year in
                    !summaries.contains(year) && summaries.contains(year - 1) && summaries.contains(year - 2)
                        && (0..<12).contains { covered.contains(year * 12 + $0) }
                }
            }

            accounts.append(Account(path: path, isCard: card, tracking: tracking, isHidden: choices.hidden.contains(path),
                                    statements: series.values.reduce(0) { $0 + $1.count },
                                    first: Month(index: first), newest: Month(index: newest), gaps: list,
                                    missingSummaries: missingSummaries))
        }
        accounts.sort { $0.path < $1.path }
        return Report(asOf: Month(index: nowIndex), accounts: accounts, notChecked: notChecked.sorted())
    }
}
