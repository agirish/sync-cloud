import Foundation

/// The number a label's line starts with, read token by token: runs of letters and digits, the
/// one space or dash between them, and what follows a run. ``VaultReading/accountNumber(_:)``
/// vets what this returns.
///
/// A number is groups joined by a dash, every group holding a digit but a prefix of one to four
/// letters a dash ties to the rest ("XZB-45-1234", "CA-123-4567-89"), and groups of digits joined by a space ("1234 5678
/// 9012", "8155 60 012 3456789", a scan's "123456 789012"). A group between two others may hold a
/// letter, as an insurer's policy number does ("01234 56 78U 7101 2"). Seven groups at most.
///
/// It stops before what the line prints next, when that can be told from the number: the word of
/// "12345 Due"; an ordinal ("123456 5th Grade"); one or two digits counting the word after them, or
/// tied to it ("0123456789 30 Year Fixed", "… 30-Year Fixed", "… 6 Month Policy", a class's "5-A");
/// a date, its month in digits or spelled, its slashes spaced or not ("12345678 01/02/1990", "…
/// 05-Jan-2025", "… 01 / 02 / 2025", "12345-67-89 2022-01-01", a card's columns read as one line);
/// an amount or a rate ("12345 1,234.56", "12345 5%"); a phone number, toll-free or not ("98765
/// 510-555-0142", "… 1-800-555-0142", "… 1 (800) 555-0142"). The words of "write your account
/// number on your check" or "is 987654" are no number at all.
///
/// What cannot be told is left joined: a second run of three digits or more after a space ("12345
/// 987654321") may be the rest of the number or the next column. A last group that holds a letter
/// ("1234 5678 A1") is left off: it is as often a plan's name ("5G Home"). A seventh group holding
/// a letter still needs digits after it, but they are left off: "1 2 3 4 5 6 7A 8" reads "1 2 3 4
/// 5 6 7A".
///
/// Its letters are ASCII's, either case, with the two that fold to one of them, ſ and K (Kelvin),
/// as the case-blind pattern this replaced matched them.
struct VaultAccountValue {
    private let text: [Unicode.Scalar]

    /// The most groups after the first.
    private static let moreGroups = 6

    /// The number `printed` starts with, or nil when it starts with none.
    static func leading(_ printed: String) -> String? {
        VaultAccountValue(text: Array(printed.unicodeScalars)).read()
    }

    private func read() -> String? {
        let firstEnd = run(from: 0)
        // A group with a digit, or a prefix of letters alone a dash ties to one: "XZB-45-1234".
        let prefix = (1...4).contains(firstEnd) && self[firstEnd] == "-" && holdsDigit(firstEnd + 1, run(from: firstEnd + 1))
        guard firstEnd > 0, holdsDigit(0, firstEnd) || prefix else { return nil }
        var at = firstEnd
        for _ in 0..<Self.moreGroups {
            guard let end = group(after: at) else { break }
            at = end
        }
        return string(0, at)
    }

    /// Where the group that the space or dash at `at` joins on ends, or nil.
    private func group(after at: Int) -> Int? {
        switch self[at] {
        case " ":
            let start = at + 1
            if let end = spacedDigits(at: start) { return end }
            // A group holding a letter, only with a group of digits after it, and never an ordinal.
            let end = run(from: start)
            guard end > start, holdsLetter(start, end), holdsDigit(start, end), !isOrdinal(start, end),
                  self[end] == " ", spacedDigits(at: end + 1) != nil else { return nil }
            return end
        case "-":
            let start = at + 1
            let end = run(from: start)
            guard end > start, holdsDigit(start, end), !isFigure(after: end) else { return nil }
            return end
        default:
            return nil
        }
    }

    /// The end of a group of digits alone, after a space: not a date, a phone number, a count, an
    /// amount or a rate.
    private func spacedDigits(at start: Int) -> Int? {
        let end = run(from: start)
        guard end > start, digits(from: start) == end,
              !isDate(at: start), !isPhone(at: start), !isCount(at: start),
              !isFigure(after: end), self[end] != "%" else { return nil }
        return end
    }

    // MARK: What follows a number

    /// A date at `start`: day or month first, however a scan spaces the slashes ("01 / 02 / 2025");
    /// year first only with a month and a day that could be one ("3456-78-90" is the rest of a
    /// policy number).
    private func isDate(at start: Int) -> Bool {
        dayOrMonthFirst(at: start) || yearFirst(at: start)
    }

    private func dayOrMonthFirst(at start: Int) -> Bool {
        var at = start
        for _ in 0..<2 {
            let end = digits(from: at)
            guard (1...2).contains(end - at) else { return false }
            guard let next = spaceAndSeparator(after: end) else { return false }
            at = next
        }
        return (2...4).contains(digits(from: at) - at)
    }

    /// Past an optional space, a slash, dash or dot, and another optional space; nil without the
    /// separator.
    private func spaceAndSeparator(after end: Int) -> Int? {
        var at = end
        if self[at] == " " { at += 1 }
        guard isDateSeparator(self[at]) else { return nil }
        at += 1
        if self[at] == " " { at += 1 }
        return at
    }

    private func yearFirst(at start: Int) -> Bool {
        let yearEnd = digits(from: start)
        guard yearEnd - start == 4, ["19", "20"].contains(string(start, start + 2)),
              isDateSeparator(self[yearEnd]) else { return false }
        let month = yearEnd + 1, monthEnd = digits(from: month)
        guard isDateSeparator(self[monthEnd]), let monthNumber = Int(string(month, monthEnd)),
              (1...12).contains(monthNumber), (1...2).contains(monthEnd - month) else { return false }
        let day = monthEnd + 1, dayEnd = digits(from: day)
        guard let dayNumber = Int(string(day, dayEnd)), (1...31).contains(dayNumber),
              (1...2).contains(dayEnd - day) else { return false }
        return true
    }

    /// A phone number at `start`, toll-free or not: "510-555-0142", "1-800-555-0142", "1 (800) 555-0142".
    private func isPhone(at start: Int) -> Bool {
        if self[start] == "1", let mark = self[start + 1], ["-", ".", " "].contains(mark), phoneNumber(at: start + 2) {
            return true
        }
        return phoneNumber(at: start)
    }

    private func phoneNumber(at start: Int) -> Bool {
        var at = start
        if self[at] == "(" {
            guard digits(from: at + 1) == at + 4, self[at + 4] == ")" else { return false }
            at += 5
            if self[at] == " " { at += 1 }
        } else {
            guard digits(from: at) == at + 3, let mark = self[at + 3], ["-", ".", " "].contains(mark) else { return false }
            at += 4
        }
        guard digits(from: at) == at + 3, let mark = self[at + 3], ["-", "."].contains(mark) else { return false }
        at += 4
        return digits(from: at) == at + 4
    }

    /// One or two digits before a word of letters alone, or tied to it: its count, or a date's day.
    private func isCount(at start: Int) -> Bool {
        let end = digits(from: start)
        guard (1...2).contains(end - start), let mark = self[end], [" ", "/", "-"].contains(mark) else { return false }
        let word = end + 1, wordEnd = run(from: word)
        return wordEnd > word && !holdsDigit(word, wordEnd)
    }

    /// Digits and a two-letter suffix: "5th", "21ST".
    private func isOrdinal(_ start: Int, _ end: Int) -> Bool {
        let digitsEnd = digits(from: start)
        guard digitsEnd > start, end - digitsEnd == 2 else { return false }
        let suffix = String(String.UnicodeScalarView([fold(text[digitsEnd]), fold(text[digitsEnd + 1])]))
        return ["st", "nd", "rd", "th"].contains(suffix)
    }

    /// A slash, dot, colon or comma with a digit after it: an amount, a time, a date's rest.
    private func isFigure(after end: Int) -> Bool {
        guard let mark = self[end], ["/", ".", ":", ","].contains(mark), let next = self[end + 1] else { return false }
        return isDigit(next)
    }

    // MARK: Runs

    /// The scalar at `index`, or nil past the end.
    private subscript(index: Int) -> Unicode.Scalar? {
        index < text.count ? text[index] : nil
    }

    /// Where the run of letters and digits from `start` ends.
    private func run(from start: Int) -> Int {
        var end = start
        while let scalar = self[end], isLetter(scalar) || isDigit(scalar) { end += 1 }
        return end
    }

    /// Where the run of digits from `start` ends.
    private func digits(from start: Int) -> Int {
        var end = start
        while let scalar = self[end], isDigit(scalar) { end += 1 }
        return end
    }

    private func holdsDigit(_ start: Int, _ end: Int) -> Bool {
        text[start..<end].contains(where: isDigit)
    }

    private func holdsLetter(_ start: Int, _ end: Int) -> Bool {
        text[start..<end].contains(where: isLetter)
    }

    private func string(_ start: Int, _ end: Int) -> String {
        String(String.UnicodeScalarView(text[start..<end]))
    }

    private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || scalar == "\u{17F}" || scalar == "\u{212A}"
    }

    private func isDateSeparator(_ scalar: Unicode.Scalar?) -> Bool {
        scalar.map { ["-", "/", "."].contains($0) } ?? false
    }

    /// A letter in lower case, ſ as s.
    private func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{17F}": "s"
        case "A"..."Z": Unicode.Scalar(scalar.value + 32)!
        default: scalar
        }
    }
}
