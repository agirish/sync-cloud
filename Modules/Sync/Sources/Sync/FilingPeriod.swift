import Foundation

/// Month words and ordinal prefixes are periods, not topics: `05. May 2026.pdf` says *when*, the
/// way `2026` does, and nothing about *what*. Treated like years by the keyword engine and the
/// router, so a month folder (`Trade Confirms/2024/05. May 2024`) can be picked only through its
/// year and month, never because a file name says "May".
public enum FilingPeriod {

    private static let months: [String: Int] = {
        let names = ["january", "february", "march", "april", "may", "june", "july", "august",
                     "september", "october", "november", "december"]
        var out: [String: Int] = [:]
        for (i, name) in names.enumerated() {
            out[name] = i + 1
            out[String(name.prefix(3))] = i + 1
        }
        out["sept"] = 9
        return out
    }()

    /// 1–12 for a month word (`may`, `Sep`, `September`, `sept`), lower-cased first; nil otherwise.
    public static func month(of token: String) -> Int? { months[token.lowercased()] }

    public static func isMonthWord(_ token: String) -> Bool { month(of: token) != nil }

    /// A bare one- or two-digit number: the `05` of `05. May 2026`, a day of the month. Never a
    /// category.
    public static func isShortNumber(_ token: String) -> Bool {
        token.count <= 2 && !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    /// A token that names a period rather than a topic, unless it is also a word that names a
    /// person in this tree (`april`, `june`), which keeps its meaning.
    public static func isPeriodToken(_ token: String, keeping kept: Set<String> = []) -> Bool {
        (isMonthWord(token) || isShortNumber(token)) && !kept.contains(token.lowercased())
    }

    /// The month a folder is for, from its own name: `05. May 2024`, `May`, `2021-03`. nil when the
    /// name isn't a month slot.
    public static func monthSlot(ofFolderNamed name: String) -> Int? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let named = words.compactMap { month(of: $0) }
        // One month word and otherwise only numbers: `05. May 2024`, `July`, never `Jan Smith`.
        if named.count == 1, words.allSatisfy({ month(of: $0) != nil || Int($0) != nil }) { return named[0] }
        // `2021-03`: a year and a month number, nothing else.
        if words.count == 2, words[0].count == 4, Int(words[0]) != nil, let m = Int(words[1]), (1...12).contains(m) {
            return m
        }
        return nil
    }

    /// The one month a file name names, or nil for none or several (`Jan-Mar 2026`).
    public static func month(inFileName name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let named = Set(stem.split(whereSeparator: { !$0.isLetter }).compactMap { month(of: String($0)) })
        if named.count == 1 { return named.first }
        if !named.isEmpty { return nil }
        // `Statement 2026-11.pdf`, `eStmt_2026-11-28.pdf`, `11. Nov…` was handled above.
        if let r = stem.range(of: #"(?<!\d)(?:19|20)\d\d[-_.](\d\d)(?:[-_.]\d\d)?(?!\d)"#, options: .regularExpression) {
            let m = Int(stem[r].dropFirst(5).prefix(2)) ?? 0
            if (1...12).contains(m) { return m }
        }
        // A leading `NN.` ordinal, when it is a month number.
        if let r = stem.range(of: #"^(\d{1,2})\.\s"#, options: .regularExpression),
           let m = Int(stem[r].filter(\.isNumber)), (1...12).contains(m) { return m }
        return nil
    }

    /// The tokens of `stem`, in order, that say when rather than what: month words, and a one- or
    /// two-digit number that leads the name (`05. May 2026`) or sits beside a month word
    /// (`May 05`). `Class 10` keeps its 10.
    public static func periodTokens(inStem stem: String, keeping kept: Set<String> = []) -> Set<String> {
        let words = stem.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var out = Set<String>()
        for (i, w) in words.enumerated() {
            if isMonthWord(w), !kept.contains(w) { out.insert(w); continue }
            guard isShortNumber(w) else { continue }
            let besideMonth = (i > 0 && isMonthWord(words[i - 1])) || (i + 1 < words.count && isMonthWord(words[i + 1]))
            if i == 0 || besideMonth { out.insert(w) }
        }
        return out
    }
}
