import Foundation

/// A chip that a later same-family token can supersede. The token grammars' `Chip` types conform
/// so ``TokenQuery/lastWinsChips(_:parse:)`` can dim the earlier occurrence generically.
public protocol DimmableTokenChip {
    /// Whether this chip is part of the effective query (see the grammars' last-wins semantics).
    var isActive: Bool { get set }
}

/// The shared core of the app's token-search grammars (Compare's `DifferenceSearch`, the Duplicates
/// lens's `DuplicateSearch`, the Activity Log's `LogSearch`): one tokenizer, one all-occurrences
/// word removal, one family-last-wins chip builder, and the number+unit value parsers. Each grammar
/// keeps its own token table and `matches()`; this core is the mechanics they must agree on, so one
/// vocabulary across surfaces can't drift copy by copy.
///
/// Pure, and pinned indirectly by the three grammars' full-grammar snapshot tests
/// (`LogSearchTests`, `DifferenceSearchTests`, `DuplicateSearchTests`), which pin the parse↔chips
/// contract this core implements.
public enum TokenQuery {

    // MARK: Tokenizing

    /// A raw query split into words on spaces and tabs — the one splitter every grammar's
    /// `parse`, `chips`, and `removing` share, so a word always means the same thing.
    public static func words(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Runs the shared parse loop: feeds each word to `consume` (the grammar's token table, which
    /// says whether it recognized the word) and returns the free text: the unconsumed words joined
    /// by single spaces or, when no word was recognized, the raw string verbatim. So a query with
    /// no tokens is a plain substring search, spacing intact, and phrase and trailing-space
    /// searches keep working.
    public static func freeText(_ raw: String, consumingTokens consume: (String) -> Bool) -> String {
        var freeWords: [String] = []
        var matchedAnyToken = false
        for word in words(raw) {
            if consume(word) {
                matchedAnyToken = true
            } else {
                freeWords.append(word)
            }
        }
        return matchedAnyToken ? freeWords.joined(separator: " ") : raw
    }

    /// Removes every occurrence of `word` from `raw`, leaving every other word as typed. Backs a
    /// chip's ✕. All occurrences, because chips are keyed by raw text: with
    /// `kind:pdf kind:png kind:pdf`, dropping only the first pdf would leave the last-wins filter
    /// unchanged and the ✕ looking dead.
    public static func removing(_ raw: String, word: String) -> String {
        words(raw).filter { $0 != word }.joined(separator: " ")
    }

    // MARK: Chips

    /// Builds display chips for every recognized token word in `raw`, in typed order. `parse` is
    /// last-wins within a single-valued family, so when a family appears twice only the last word
    /// filters; the earlier chip gets `isActive` false so the chips read as the query the filter
    /// runs. A `nil` family marks a conjunctive token (never superseded). Free text yields no chip
    /// (`parse` returns nil).
    public static func lastWinsChips<Chip: DimmableTokenChip>(
        _ raw: String,
        parse: (String) -> (chip: Chip, family: String?)?
    ) -> [Chip] {
        var out: [Chip] = []
        var lastIndexByFamily: [String: Int] = [:]
        for word in words(raw) {
            guard let (chip, family) = parse(word) else { continue }
            if let family {
                if let previous = lastIndexByFamily[family] { out[previous].isActive = false }
                lastIndexByFamily[family] = out.count
            }
            out.append(chip)
        }
        return out
    }

    // MARK: Number + unit parsers

    /// "10mb" / "1.5gb" / "500kb" / "1024" → bytes. SI (1000-base) to match the app's displayed
    /// sizes (`ByteCountFormatter` `.file`). Returns nil for anything that isn't a number + known
    /// unit, so an unrecognized size word stays plain free text.
    public static func parseSizeBytes(_ string: String) -> Int? {
        guard !string.isEmpty else { return nil }
        let (number, unit) = numberAndUnit(string)
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "m", "mb": multiplier = 1_000_000
        case "g", "gb": multiplier = 1_000_000_000
        default: return nil
        }
        // Guard the Double→Int conversion: `Int(_: Double)` traps when the value isn't
        // representable, and this parses on every keystroke, so a huge token (`>99999999999gb`)
        // would crash the window. Strict `<`: `Double(Int.max)` rounds up to 2^63, one past
        // `Int.max`.
        let bytes = (value * multiplier).rounded()
        guard bytes >= 0, bytes < Double(Int.max) else { return nil }
        return Int(bytes)
    }

    /// "1h" / "30m" / "2d" / "45s" → seconds. Returns nil for anything else, so an unrecognized
    /// duration word falls through to plain free text rather than silently filtering everything
    /// out. No overflow guard needed: the result stays a Double (`TimeInterval`).
    public static func parseDurationSeconds(_ string: String) -> TimeInterval? {
        let (number, unit) = numberAndUnit(string)
        guard let magnitude = Double(number), magnitude.isFinite, magnitude >= 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "s", "sec": multiplier = 1
        case "m", "min": multiplier = 60
        case "h", "hr": multiplier = 3600
        case "d", "day", "days": multiplier = 86_400
        default: return nil
        }
        return magnitude * multiplier
    }

    /// Splits "1.5gb" into ("1.5", "gb"): digits and "." accumulate into the number, everything
    /// else into the unit, so interleaved forms are tolerated.
    private static func numberAndUnit(_ string: String) -> (number: String, unit: String) {
        var number = "", unit = ""
        for character in string {
            if character.isNumber || character == "." { number.append(character) } else { unit.append(character) }
        }
        return (number, unit)
    }
}
