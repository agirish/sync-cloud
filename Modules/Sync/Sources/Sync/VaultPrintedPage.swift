import Foundation

/// How a document writes a date's month and day in digits: India and most of the world day
/// first, the US month first. A spelled month ("02 Oct 2024", "02OCT2024", "14/FEB/2023") needs
/// neither.
enum DateOrder: Sendable { case dayFirst, monthFirst }

extension VaultReading {
    /// A passport number as a page prints it beside its label: up to two letters, then six to
    /// nine digits ("A12345678", "Z1234567", "123456789").
    static let passportNumber = try! NSRegularExpression(pattern: #"[A-Z]{0,2}\s?[0-9]{6,9}(?![A-Za-z0-9])"#,
                                                         options: [.caseInsensitive])
}

/// A document's recognised lines, as every Vault reader questions them: what it says, the dates
/// printed on it in any of the forms documents use, and the value beside a label wherever the
/// scan put it. Readers name what they look for (the labels a kind of document prints, in all
/// its variants) and leave how it is found to this, so two documents of one kind that print a
/// field a little differently are read alike.
struct PrintedPage {
    let lines: [String]
    let text: String
    /// Lower case with no white space, for a cue a scan broke up ("Permanent Account Numbe r").
    let squeezed: String
    /// The same with the lines joined by a space, as the identity readers have always matched
    /// their cues. The two differ where a line starts with what joins the character before it (a
    /// combining mark, a zero-width joiner), which a space takes with it and a line break does not,
    /// or ends with one that joins the character after it (U+0600).
    let spacedSqueezed: String

    /// Each line's letters with spaces left out, worked out once for every label asked about.
    /// Made here, with the page: made at first use instead (a lazy class holding the lines, tried in
    /// batch 6), three of the owner's account papers read differently, the cause not found.
    let lettered: [Lettered]

    init(_ lines: [String]) {
        self.lines = lines
        text = lines.joined(separator: "\n")
        squeezed = Self.squeeze(text)
        spacedSqueezed = Self.squeeze(lines.joined(separator: " "))
        lettered = lines.map(Lettered.init)
    }

    /// A line's characters that are not white space, lower case, and where each one is in the
    /// line: what ``labelHit(_:in:)`` matches labels against.
    struct Lettered {
        let line: String
        let kept: [String.Index]
        let letters: [Character]

        init(_ line: String) {
            self.line = line
            kept = line.indices.filter { !line[$0].isWhitespace }
            letters = kept.map { index -> Character in
                let lower = String(line[index]).lowercased()
                return lower.count == 1 ? Character(lower) : line[index]
            }
        }
    }

    static func squeeze(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// Whether the page says `cue` anywhere, spaces ignored.
    func says(_ cue: String) -> Bool { squeezed.contains(Self.squeeze(cue)) }
    func saysAny(_ cues: [String]) -> Bool { cues.contains(where: says) }

    // MARK: Dates

    /// "02 Oct 2024", "02OCT2024", "14/FEB/2023", and a passport's bilingual "14 FEB /FÉV 2023".
    private static let spelled = try! NSRegularExpression(
        pattern: #"(?<![0-9])([0-9]{1,2})[ \t/.-]?([A-Za-z]{3,9})\.?(?:[ \t]?/[ \t]?\p{L}{3,9}\.?)?[ \t/.-]?((?:19|20)[0-9]{2})(?![0-9])"#)
    /// "Jun 12, 2026", "June 12 2026": the month first, as the US writes it out.
    private static let spelledMonthFirst = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-Za-z]{3,9})\.?[ \t]+([0-9]{1,2}),?[ \t]+((?:19|20)[0-9]{2})(?![0-9])"#)
    /// "05/06/2018", "05-06-2018", "05.06.2018": which is the day is the caller's to say.
    static let numeric = try! NSRegularExpression(
        pattern: #"(?<![0-9])([0-9]{1,2})\s*[/.-]\s*([0-9]{1,2})\s*[/.-]\s*((?:19|20)[0-9]{2})(?![0-9])"#)

    private static let yearFirst = try! NSRegularExpression(
        pattern: #"(?<![0-9])((?:19|20)[0-9]{2})[/.-]([0-9]{1,2})[/.-]([0-9]{1,2})(?![0-9])"#)

    /// "November 12, 2019": the month written out in full, a comma after the day, as an IRS
    /// notice prints its dates (the day and year may be on two lines). ``spelledMonthFirst`` also
    /// takes "Jun 12 2026", on one line.
    private static let fullMonthFirst = try! NSRegularExpression(
        pattern: #"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+([0-9]{1,2}),\s+((?:19|20)[0-9]{2})\b"#)

    /// Every "November 12, 2019" in `text`, in order.
    static func fullMonthDates(in text: String) -> [Date] {
        let ns = text as NSString
        return fullMonthFirst.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let month = VaultReading.monthNumber(ns.substring(with: m.range(at: 1))),
                  let day = Int(ns.substring(with: m.range(at: 2))),
                  let year = Int(ns.substring(with: m.range(at: 3))) else { return nil }
            return VaultReading.calendarDate(year: year, month: month, day: day)
        }
    }

    /// Every date printed in `text` with where it starts, in order: "02 Oct 2024", "02 OCT/OCT
    /// 2024", "02OCT2024", "14/FEB/2023", "2030-01-01", "05/06/2018". A date in digits is read in `order`; with
    /// none, both ways round where both are dates, for a caller that can tell them apart.
    static func dates(in text: String, order: DateOrder?) -> [(date: Date, at: Int)] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var out: [(date: Date, at: Int)] = []
        for m in spelled.matches(in: text, range: whole) {
            guard let day = Int(ns.substring(with: m.range(at: 1))),
                  let month = VaultReading.monthNumber(ns.substring(with: m.range(at: 2))),
                  let year = Int(ns.substring(with: m.range(at: 3))),
                  let date = VaultReading.calendarDate(year: year, month: month, day: day) else { continue }
            out.append((date, m.range.location))
        }
        for m in spelledMonthFirst.matches(in: text, range: whole) {
            guard let month = VaultReading.monthNumber(ns.substring(with: m.range(at: 1))),
                  let day = Int(ns.substring(with: m.range(at: 2))),
                  let year = Int(ns.substring(with: m.range(at: 3))),
                  let date = VaultReading.calendarDate(year: year, month: month, day: day) else { continue }
            out.append((date, m.range.location))
        }
        for m in yearFirst.matches(in: text, range: whole) {
            let parts = (1...3).compactMap { Int(ns.substring(with: m.range(at: $0))) }
            if parts.count == 3, let date = VaultReading.calendarDate(year: parts[0], month: parts[1], day: parts[2]) {
                out.append((date, m.range.location))
            }
        }
        for m in numeric.matches(in: text, range: whole) {
            let parts = (1...3).compactMap { Int(ns.substring(with: m.range(at: $0))) }
            guard parts.count == 3 else { continue }
            let dayFirst = VaultReading.calendarDate(year: parts[2], month: parts[1], day: parts[0])
            let monthFirst = VaultReading.calendarDate(year: parts[2], month: parts[0], day: parts[1])
            let read: [Date?]
            switch order {
            case .dayFirst?: read = [dayFirst]
            case .monthFirst?: read = [monthFirst]
            case nil: read = dayFirst == monthFirst ? [dayFirst] : [dayFirst, monthFirst]
            }
            for date in read.compactMap({ $0 }) { out.append((date, m.range.location)) }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The date `text` starts with, if it starts with one.
    static func leadingDate<S: StringProtocol>(_ text: S, order: DateOrder?) -> Date? {
        let found = dates(in: String(text), order: order).filter { $0.at == 0 }
        return found.count == 1 ? found[0].date : nil
    }

    /// Every date on the page.
    func dates(order: DateOrder?) -> [Date] { Self.dates(in: text, order: order).map(\.date) }

    // MARK: Labelled fields

    /// Where the first of `labels` is printed on `line`: matched with spaces ignored, so a scan's
    /// "Date o f Issue" is still Date of Issue, but only as whole words, so ISS is never the start
    /// of ISSUE. Of two labels starting at one place the longer wins ("Date of issue of ETA" over
    /// "Date of issue").
    static func labelHit(_ labels: [String], in line: String) -> Range<String.Index>? {
        labelHit(labels, in: Lettered(line))
    }

    static func labelHit(_ labels: [String], in lettered: Lettered) -> Range<String.Index>? {
        let (line, kept, letters) = (lettered.line, lettered.kept, lettered.letters)
        var best: (start: Int, end: Int)?
        for label in labels {
            let wanted = Array(squeeze(label))
            guard !wanted.isEmpty, wanted.count <= letters.count else { continue }
            for start in 0...(letters.count - wanted.count) where letters[start] == wanted[0] {
                let end = start + wanted.count
                guard letters[start..<end].elementsEqual(wanted) else { continue }
                let before = kept[start] > line.startIndex ? line[line.index(before: kept[start])] : " "
                let afterIndex = line.index(after: kept[end - 1])
                let after = afterIndex < line.endIndex ? line[afterIndex] : " "
                // Whole words: no letter runs into the label from either side.
                guard !(before.isLetter && wanted[0].isLetter), !(after.isLetter && wanted[wanted.count - 1].isLetter)
                else { continue }
                if best == nil || start < best!.start || (start == best!.start && end > best!.end) { best = (start, end) }
                break
            }
        }
        return best.map { kept[$0.start]..<line.index(after: kept[$0.end - 1]) }
    }

    static let separators: Set<Character> = [" ", "\t", ":", ".", "-", "*", "#"]

    /// A date's label, abbreviated or not, for finding a layout's columns and rows: "Date of
    /// Issue", "Issue Date", "D.O.I.", "DOB", "ISS", "EXP", "Valid upto".
    private static let dateLabel = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:date\s+of\s+[a-z]+|(?:issue|expiration|expiry|birth|entry)\s+date|d\.\s?o\.\s?[a-z]\.?|dob|iss|exp|valid\s+(?:up\s*to|until|from)|issued|expiry|expires)(?![A-Za-z])"#,
        options: [.caseInsensitive])

    /// A label that names a date and nothing else, for counting a row's date columns.
    private static let dateColumn = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:date\s+of\s+[a-z]+|(?:issue|expiration|expiry|birth|entry)\s+date|valid\s+(?:up\s*to|until))(?![A-Za-z])"#,
        options: [.caseInsensitive])

    /// Whether `line` is a date's label and nothing else: no date of its own.
    private func isBareDateLabel(_ line: String, order: DateOrder?) -> Bool {
        Self.dateLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            && Self.dates(in: line, order: order).isEmpty
    }

    /// The date printed after one of `labels`, wherever the layout puts it:
    ///
    /// - on the label's own line: "Date of Issue : 01-02-2010 Date of Expiry …" gives the first
    ///   date, never a later one, as the date has to start the text after the label;
    /// - on the next line, in the label's column: "Date of Issue   Date of Expiry" over
    ///   "01-02-2010   31-01-2030";
    /// - labels stacked over their dates in the same order, as a visa foil is read: "Issue Date",
    ///   "Expiration Date", then "02SEP2014", "25AUG2019".
    ///
    /// A label on a line that also says one of `unless` is another field's ("Passport Date of
    /// Issue" on an e-Visa page) and is passed over.
    func date(_ labels: [String], order: DateOrder?, unless: [String] = []) -> Date? {
        let others = unless.map(Self.squeeze)
        for (index, line) in lines.enumerated() {
            guard let hit = Self.labelHit(labels, in: lettered[index]) else { continue }
            // The label qualified by another field's word just before it: "Passport Date of
            // Issue", not "Passport No: A1234567  Date of Issue: …" or "Passport Number   Visa
            // Expiry Date", whose dates are still the visa's.
            if !others.isEmpty, case let before = Self.squeeze(String(line[..<hit.lowerBound])),
               others.contains(where: { before.hasSuffix($0) }) { continue }
            if let found = Self.leadingDate(line[hit.upperBound...].drop(while: Self.separators.contains), order: order) {
                return found
            }
            guard index + 1 < lines.count else { continue }
            if let stacked = stackedDate(at: index, order: order) {
                if let found = stacked { return found }
                continue
            }
            let below = lines[index + 1]
            let printed = Self.dates(in: below, order: order)
            let column = Self.dateLabel.numberOfMatches(in: line, range: NSRange(line.startIndex..<hit.lowerBound, in: line))
            // Only a date's own label makes a column: "Date of Issue   Date of Expiry", never the
            // "Issued By" beside it, whose value is a place.
            let columns = Self.dateColumn.numberOfMatches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            let starts = Array(Set(printed.map(\.at))).sorted()
            // Fewer dates under a row of labels than labels: which date is whose cannot be told.
            if columns > 1, starts.count < columns { continue }
            if starts.count > 1 {
                let inColumn = column < starts.count ? printed.filter { $0.at == starts[column] } : []
                if inColumn.count == 1 { return inColumn[0].date }
                continue
            }
            if let found = Self.leadingDate(below.drop(while: Self.separators.contains), order: order) { return found }
        }
        return nil
    }

    /// The date beside the first of `labels`, in the order given, that has one: for a field a kind
    /// of document labels several ways, the most telling label first.
    func date(preferring labels: [String], order: DateOrder?, unless: [String] = []) -> Date? {
        labels.lazy.compactMap { self.date([$0], order: order, unless: unless) }.first
    }

    /// For a label in a run of bare date labels, the date in the same place in the run of dates
    /// below: `.some(date)`, or `.some(nil)` when that run is too short to say. Nil when the
    /// label stands alone, so the line below is its date.
    private func stackedDate(at index: Int, order: DateOrder?) -> Date?? {
        guard isBareDateLabel(lines[index], order: order) else { return nil }
        var first = index
        while first > 0, isBareDateLabel(lines[first - 1], order: order) { first -= 1 }
        var end = index + 1
        while end < lines.count, isBareDateLabel(lines[end], order: order) { end += 1 }
        guard end - first > 1 else { return nil }
        let target = end + (index - first)
        guard target < lines.count, (end...target).allSatisfy({ Self.leadingDate(lines[$0], order: order) != nil })
        else { return .some(nil) }
        return .some(Self.leadingDate(lines[target], order: order))
    }

    /// The value after one of `labels`, on its line or within `below` lines under it, where `value`
    /// matches at its very start: "Passport No. A12345678", "Passport No." over "A12345678". The
    /// value is as ``reader(_:)`` takes it from the pattern's match.
    ///
    /// `keeping` vets each candidate, and the search goes on past one it turns down: "write your
    /// account number on your check" is a label with no number, and the real one comes later.
    /// `skipping` is what may stand between the label and its value; a reader that must see a
    /// mask's asterisks ("****1234") leaves `*` out.
    func value(_ labels: [String], _ value: NSRegularExpression, below: Int = 1,
               skipping: Set<Character> = separators, keeping: (String) -> String? = { $0 }) -> String? {
        self.value(labels, Self.reader(value), below: below, skipping: skipping, keeping: keeping)
    }

    /// The same, with a reader in place of a pattern: `reader` takes the text after the label, or a
    /// line under it, and returns the value it starts with, or nil.
    func value(_ labels: [String], _ reader: (String) -> String?, below: Int = 1,
               skipping: Set<Character> = separators, keeping: (String) -> String? = { $0 }) -> String? {
        values(labels, reader, below: below, skipping: skipping, keeping: keeping, first: true).first?.value
    }

    /// A pattern as a reader, matched at the very start of the text: its first group when that took
    /// part, else its whole match, trimmed of spaces.
    static func reader(_ value: NSRegularExpression) -> (String) -> String? {
        { s in
            let ns = s as NSString
            guard let m = value.firstMatch(in: s, options: .anchored, range: NSRange(location: 0, length: ns.length))
            else { return nil }
            let range = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
            return ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        }
    }

    /// One value found beside a label: the value, the line the label is on, and the line the
    /// value is on (the same, or one under it).
    struct Hit: Equatable {
        let value: String
        let label: Int
        let line: Int
    }

    /// Every value `value(_:_:below:skipping:keeping:)` would find, one for each line the label
    /// is on, in page order: a family's card prints a member ID row for each person.
    func values(_ labels: [String], _ value: NSRegularExpression, below: Int = 1,
                skipping: Set<Character> = separators, keeping: (String) -> String? = { $0 },
                first: Bool = false) -> [Hit] {
        values(labels, Self.reader(value), below: below, skipping: skipping, keeping: keeping, first: first)
    }

    /// The same, with a reader in place of a pattern.
    func values(_ labels: [String], _ reader: (String) -> String?, below: Int = 1,
                skipping: Set<Character> = separators, keeping: (String) -> String? = { $0 },
                first: Bool = false) -> [Hit] {
        func leading<S: StringProtocol>(_ text: S) -> String? { reader(String(text)) }
        var out: [Hit] = []
        for (index, line) in lines.enumerated() {
            guard let hit = Self.labelHit(labels, in: lettered[index]) else { continue }
            if let found = leading(line[hit.upperBound...].drop(while: skipping.contains)).flatMap(keeping) {
                out.append(Hit(value: found, label: index, line: index))
            } else if let next = ((index + 1)..<min(lines.count, index + 1 + below)).first(where: {
                leading(lines[$0].drop(while: skipping.contains)).flatMap(keeping) != nil
            }), let found = leading(lines[next].drop(while: skipping.contains)).flatMap(keeping) {
                out.append(Hit(value: found, label: index, line: next))
            } else {
                continue
            }
            if first { break }
        }
        return out
    }

    /// Whether `word` is printed as a word of its own: "OCI", never the oci inside "Social".
    func hasWord(_ word: String) -> Bool {
        lettered.contains { Self.labelHit([word], in: $0) != nil }
    }

    /// The first of `labels`, in the order given, that has a value: for a field one kind of
    /// document labels several ways, the most telling label first.
    func value(preferring labels: [String], _ value: NSRegularExpression, skipping: Set<Character> = separators,
               keeping: (String) -> String? = { $0 }) -> String? {
        self.value(preferring: labels, Self.reader(value), skipping: skipping, keeping: keeping)
    }

    /// The same, with a reader in place of a pattern.
    func value(preferring labels: [String], _ reader: (String) -> String?, skipping: Set<Character> = separators,
               keeping: (String) -> String? = { $0 }) -> String? {
        for label in labels {
            if let found = self.value([label], reader, skipping: skipping, keeping: keeping) { return found }
        }
        return nil
    }

    // MARK: Issue dates

    /// How documents label their date of issue, in English and as passports print it in French.
    static let issueLabels = ["date of issue", "issue date", "issued on", "date issued", "date de délivrance",
                              "date of grant", "grant date"]

    /// The most years a passport, a visa or a card printed with an issue date runs: ten.
    static let longestTerm = 10

    /// When a document was issued that names `born` and runs until `expires` (either may be
    /// unknown), from its printed page, by the first of three rules that answers:
    ///
    /// 1. The date beside an issue label.
    /// 2. The date the expiry is a whole number of years after, to the day or a day or two
    ///    before, as passports and many visas run: no other date falls there.
    /// 3. The only date printed between the birth and the expiry: a passport page or a visa foil
    ///    prints just those three.
    ///
    /// Never a date on or before the birth, on or after the expiry, or more than ten years before
    /// it, the longest any of these runs. A date in digits is read in `order`; with none, both
    /// ways, and only a reading the rules single out counts.
    func issueDate(born: Date?, expires: Date?, order: DateOrder? = nil) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let earliest = expires.flatMap {
            calendar.date(byAdding: DateComponents(year: -Self.longestTerm, day: -3), to: $0)
        }
        func fits(_ date: Date) -> Bool {
            if let born, date <= born { return false }
            if let expires, date >= expires { return false }
            if let earliest, date < earliest { return false }
            return true
        }
        // A reading is taken only when it is the only one: a label's date read both ways is no
        // answer unless one way does not fit.
        let labelled = (order.map { [$0] } ?? [.dayFirst, .monthFirst]).compactMap { date(Self.issueLabels, order: $0) }
        let fitting = Set(labelled.filter(fits))
        if fitting.count == 1 { return fitting.first }

        let candidates = dates(order: order).filter(fits)
        if let expires {
            let anniversaries = Set(candidates.filter { date in
                (1...Self.longestTerm).contains { years in
                    guard let anniversary = calendar.date(byAdding: .year, value: years, to: date),
                          let gap = calendar.dateComponents([.day], from: expires, to: anniversary).day else { return false }
                    return (0...2).contains(gap)
                }
            })
            if anniversaries.count == 1 { return anniversaries.first }
        }
        let only = Set(candidates)
        return only.count == 1 ? only.first : nil
    }
}
