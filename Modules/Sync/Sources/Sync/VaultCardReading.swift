import Foundation

/// One value a card prints beside its label: "Subscriber ID" and "W288319115". What the editor's
/// On this card row offers in place of a misread ID.
public struct VaultCardValue: Equatable, Hashable, Sendable {
    /// The label as the card prints it, without its colon: "Subscriber ID", "RxBIN".
    public let label: String
    /// The value, as printed, spaces between its groups kept.
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Every labeled value one card prints, read when the editor asks about that card alone: not
/// just the ID-shaped ones the account reader takes, and wherever the card is filed. The account
/// reader only runs on papers under Health, Home, Vehicles and School, and only takes a value with
/// four digits or more beside a label it knows; a card's Subscriber ID beside a Member ID, or a
/// passport card's number, is neither.
///
/// A value holds a digit and at least four letters and digits. What is not an ID is left out: a
/// plan's group number (it belongs to the plan, and the account reader keeps it apart), a date, a
/// phone number (dashed, or in groups a space apart), an amount or a rate.
extension VaultReading {
    /// At most this many words make a label: "Member ID Number" is three.
    static let cardLabelWords = 4

    /// Labels whose value is never an ID: a group's, a date's, a phone's, an amount's.
    private static let notIDLabels: [String] = [
        "group", "grp", "date", "dob", "born", "birth", "exp", "expires", "expiry", "expiration", "issued",
        "issue", "effective", "eff", "valid", "phone", "tel", "telephone", "fax", "call", "toll", "copay",
        "deductible", "coinsurance", "visit", "er", "urgent", "office", "specialist", "amount", "balance",
        "due", "total", "pay", "zip", "postal", "page", "rxgrp", "rxgroup",
    ]

    /// Every labeled value the pages print, each value once, in reading order: on a label's own
    /// line ("Member ID: W288319115", two columns read as one line "Member ID W288 Group 0012"),
    /// or under a label that stands alone ("Subscriber ID" over "W288319115").
    public static func cardValues(on pages: [[String]]) -> [VaultCardValue] {
        var out: [VaultCardValue] = []
        var seen = Set<String>()
        func keep(_ label: [String], _ value: String, code: Bool = false) {
            let raw = label.map(trimmedWord).filter { !$0.isEmpty }
            let words = labelWords(raw)
            // "Group Number" is cut back to "Number": what it is comes from the words before.
            // A letter alone is no label: it is a number's first letter, read apart ("V 7531864").
            guard !words.isEmpty, !(words.count == 1 && words[0].count == 1 && words[0].allSatisfy(\.isLetter)),
                  !isNotIDLabel(Array(raw.suffix(3))), code || isID(value), seen.insert(normalized(value)).inserted else { return }
            out.append(VaultCardValue(label: words.joined(separator: " "), value: value))
        }
        for page in pages {
            var waiting: [String]?
            var waitingLine: String?
            for line in page {
                let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { continue }
                // A label alone on its line names the value that starts the next one.
                if tokens.allSatisfy(isWord), tokens.count <= cardLabelWords, isLabelLine(tokens) {
                    waiting = tokens
                    waitingLine = line
                    continue
                }
                // A header row of labels over a row of values, as many cells each ("Group No    Member ID"
                // over "0012345    W123456789"): each label names the value in its own column, never
                // all of them the first (the second review).
                if let header = waitingLine.map(PrintedPage.cells), header.count > 1 {
                    let row = PrintedPage.cells(line)
                    if row.count == header.count {
                        for (label, cell) in zip(header, row) {
                            let parts = cell.split(whereSeparator: \.isWhitespace).map(String.init)
                            if parts.count == 1, let value = valueToken(parts[0]), !isDateOrPhone(parts[0]) {
                                keep(label.split(whereSeparator: \.isWhitespace).map(String.init), value)
                            }
                        }
                        waiting = nil
                        waitingLine = nil
                        continue
                    }
                }
                waitingLine = nil
                var label: [String] = tokens.first.flatMap(valueToken) != nil ? (waiting ?? []) : []
                waiting = nil
                // After "Name:", the words that follow are its value, and the next label starts
                // after them: "Member Name: ANNA ERIKSSON Member ID: XZB123456789".
                var closed = false
                var index = 0
                while index < tokens.count {
                    let token = tokens[index]
                    // A plan's processor code is letters alone: "RxPCN ADV".
                    if let code = planCode(token, after: label) {
                        keep(label, code, code: true)
                        label = []
                        index += 1
                        continue
                    }
                    if isWord(token) {
                        if closed { label = []; closed = false }
                        label.append(token)
                        if label.count > cardLabelWords { label.removeFirst() }
                        if token.hasSuffix(":") { closed = true }
                        index += 1
                        continue
                    }
                    closed = false
                    let candidate = valueToken(token)
                    guard let first = candidate else { label = []; index += 1; continue }
                    closed = false
                    // Groups of digits a space apart are one number: "1234 5678 9012".
                    var value = first
                    var groups = [first]
                    var next = index + 1
                    if first.allSatisfy(\.isNumber) {
                        while next < tokens.count, let more = valueToken(tokens[next]), more.allSatisfy(\.isNumber),
                              !isDateOrPhone(tokens[next]) {
                            value += " " + more
                            groups.append(more)
                            next += 1
                        }
                    }
                    let phone = isPhone(groups, before: next < tokens.count ? tokens[next] : nil)
                    if !label.isEmpty, !isDateOrPhone(token), !phone { keep(label, value) }
                    label = []
                    index = next
                }
            }
        }
        return out
    }

    /// Words labels are made of, lower case: the end of a run of them is a label ("ANNA ERIKSSON
    /// Member ID" is "Member ID"), and a label of other words keeps its last two.
    private static let labelVocabulary: Set<String> = [
        "member", "subscriber", "id", "identification", "number", "no", "num", "#", "policy", "account",
        "acct", "patient", "enrollee", "student", "customer", "card", "plan", "rx", "rxbin", "rxpcn",
        "bin", "pcn", "health", "record", "medical", "mrn", "insured", "holder",
        "reference", "ref", "case", "claim", "contract", "certificate", "cert", "license",
        "passport", "document", "permit", "receipt", "confirmation", "service", "provider", "npi",
        "pharmacy", "vehicle", "vin", "loan", "unique", "personal", "tax", "employee", "code",
        "dependent", "suffix", "prefix", "alpha", "issuer", "carrier", "payer", "unit", "dl", "a/c",
    ]

    /// `words` cut back to the label that ends them.
    static func labelWords(_ words: [String]) -> [String] {
        var start = words.count
        while start > 0, labelVocabulary.contains(words[start - 1].lowercased()) { start -= 1 }
        if start == words.count { return Array(words.suffix(2)) }
        return Array(words[start...])
    }

    /// Whether a line of words alone is a label for the next line's value: it ends with a colon
    /// or `#`, or in one of ``labelVocabulary``'s words. "Delta Dental" over a number is not one.
    private static func isLabelLine(_ tokens: [String]) -> Bool {
        guard let last = tokens.last else { return false }
        return last.hasSuffix(":") || last.hasSuffix("#") || labelVocabulary.contains(trimmedWord(last).lowercased())
    }

    /// Labels whose value may be letters alone: a plan's processor control number.
    private static let letterCodeLabels: Set<String> = ["rxpcn", "pcn"]

    /// `token` as a letters-only plan code when `label` ends in one of ``letterCodeLabels``.
    private static func planCode(_ token: String, after label: [String]) -> String? {
        guard let last = label.last.map(trimmedWord)?.lowercased(), letterCodeLabels.contains(last) else { return nil }
        let core = trimmedWord(token)
        guard (2...10).contains(core.count), core.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return core
    }

    /// A word of a label: letters, with a colon, a `#` or a full stop after it ("ID:", "No.",
    /// "#"), or an "Rx" code's letters.
    private static func isWord(_ token: String) -> Bool {
        let core = trimmedWord(token)
        if token.allSatisfy({ $0 == "#" || $0 == ":" }) { return true }
        return !core.isEmpty && core.allSatisfy { $0.isLetter || $0 == "/" || $0 == "-" || $0 == "'" }
            && core.contains(where: \.isLetter)
    }

    private static func trimmedWord(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ":#.,;()"))
    }

    /// The value a token holds: letters, digits and dashes, a digit among them, a trailing full
    /// stop, comma or semicolon let go. Nil for anything else ("$25.00", "05/16/2030", "20%").
    private static func valueToken(_ token: String) -> String? {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()"))
        guard !core.isEmpty, core.contains(where: \.isNumber),
              core.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              core.first != "-", core.last != "-" else { return nil }
        return core
    }

    /// Four letters and digits or more, a digit among them, and not one digit over and over
    /// ("111111111" fills a box on a form; it is nobody's number).
    private static func isID(_ value: String) -> Bool {
        let letters = value.filter { $0.isLetter || $0.isNumber }
        return letters.count >= 4 && value.contains(where: \.isNumber) && Set(letters).count > 1
    }

    private static func isNotIDLabel(_ words: [String]) -> Bool {
        words.contains { notIDLabels.contains($0.lowercased()) }
    }

    private static let dateOrPhone = try! NSRegularExpression(
        pattern: #"^(?:[0-9]{1,4}[-/.][0-9]{1,2}[-/.][0-9]{2,4}|(?:1-)?[0-9]{3}-[0-9]{3}-[0-9]{4})$"#)

    private static let localNumber = try! NSRegularExpression(pattern: #"^[0-9]{3}-[0-9]{4}$"#)

    /// Groups of digits a space apart that are a phone number: "800 555 0142", "1 800 555 0142",
    /// or an area code before the rest of its number, "1 (800) 555-0142" (`next` is "555-0142").
    private static func isPhone(_ groups: [String], before next: String?) -> Bool {
        let lengths = groups.map(\.count)
        if lengths == [3, 3, 4] || lengths == [1, 3, 3, 4] { return true }
        guard lengths.last == 3, lengths.count <= 2, let next else { return false }
        let core = next.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()"))
        return localNumber.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil
    }

    /// "05-16-2030", "2030-05-16", "510-555-0142", "1-800-555-0142": a date or a phone number.
    private static func isDateOrPhone(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()"))
        return dateOrPhone.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil
    }
}
