import Foundation

/// Turns a single "the user filed THIS file into THAT folder" example into a proposed
/// ``AutomationRule`` — the deterministic, learn-by-example complement to the AI filing backend.
///
/// The heuristic favors the most *distinctive* signal: a token the file name shares with the
/// destination folder (e.g. filing "T-Mobile-bill-Mar.pdf" into "Home/Utilities/T-Mobile" proposes
/// `name contains "T-Mobile"`). When nothing is shared it falls back to the file's kind (by
/// extension). Content is offered as an alternative only when an excerpt was read. Pure and
/// framework-free so it's unit-testable and lives in Sync.
public enum AutomationRuleProposer {

    /// A proposed rule plus the alternative conditions the user can pick instead (for the inline
    /// "Save a rule?" offer). `rule` already carries `conditions == [defaultCondition]`.
    public struct Proposal: Sendable, Equatable {
        public let rule: AutomationRule
        /// The condition presented first (also the one in `rule`).
        public let defaultCondition: AutomationCondition
        /// Other conditions the user can swap to (name / content / kind), most-distinctive first,
        /// excluding the default. Each yields the same destination.
        public let alternatives: [AutomationCondition]
        public let destinationTemplate: String
    }

    /// English/tech stop-words and generic filing words that make useless match tokens on their own.
    private static let stopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "doc",
        "document", "file", "scan", "img", "image", "photo", "untitled", "report", "bill",
        "invoice", "receipt", "statement", "letter", "note", "notes",
    ]

    /// Proposes a rule for `fileName` filed into `destinationRelativePath` (provider-root-relative,
    /// e.g. "Home/Utilities/T-Mobile"). `contentSnippet` is an optional excerpt of the file's text.
    /// Returns nil when the destination is empty (nothing to file into).
    public static func propose(fileName: String,
                               destinationRelativePath: String,
                               contentSnippet: String? = nil,
                               modificationDate: Date? = nil,
                               now: Date = Date()) -> Proposal? {
        let dest = destinationRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !dest.isEmpty else { return nil }
        // A relative destination is stored as a TEMPLATE, and the evaluator surfaces any leftover
        // `{…}` as an unresolvable token — deliberately, so a user's typo'd `{yaer}` is reported
        // rather than guessed at. But this path is not a template the user typed: it is the literal
        // name of a folder they just filed into, and a real folder may legitimately be called
        // "Q3 {final}". Proposing it would mint a rule that can never run — every dry run reporting
        // it "needs {final}, which this file doesn't have" — with no way to express the real folder
        // short of renaming it. `resolveDestination`'s carve-out only exempts ABSOLUTE literals, so
        // decline instead of offering a rule that is inert from birth. Same call as the
        // extension-less fallback below: no offer beats a bad one.
        guard !dest.contains("{"), !dest.contains("}") else { return nil }

        let nameTokens = tokens(in: (fileName as NSString).deletingPathExtension)
        // Folded: `tokens(in:)` preserves case, and the overlap test must be case-blind on BOTH
        // sides — comparing a lowercased name token against original-case dest tokens meant a
        // capitalized folder ("Acme", "T-Mobile") never anchored, and the fallback's longest
        // token could propose an unrelated term for the rule.
        let destTokens = Set(dest.split(whereSeparator: { $0 == "/" })
            .flatMap { tokens(in: String($0)) }
            .map { $0.lowercased() })

        // The strongest signal: a name token that also names (part of) the destination folder.
        let shared = nameTokens.first(where: { destTokens.contains($0.lowercased()) })
        // Otherwise the longest non-stop name token (most specific), if any.
        let distinctive = shared ?? nameTokens
            .filter { !stopTokens.contains($0.lowercased()) && $0.count >= 3 }
            .max(by: { $0.count < $1.count })

        var ordered: [AutomationCondition] = []
        if let distinctive { ordered.append(.nameMatches("*\(distinctive)*")) }
        if let kind = FileKind.of(fileName: fileName) { ordered.append(.kindIs(kind)) }
        if let snippet = contentSnippet, let term = shared ?? distinctive,
           snippet.range(of: term, options: .caseInsensitive) != nil {
            ordered.append(.contentContains(term))
        }
        // Guarantee at least one condition — a name glob on the extension. With no distinctive name
        // token, no content match, AND no extension to anchor on, the only fallback would be
        // `name matches *` — a match-EVERYTHING rule that files every loose file into this folder.
        // One token-less, extension-less example (e.g. "ab", "2024") isn't enough signal to learn a
        // rule from, so decline to propose rather than offer a dangerous universal glob.
        if ordered.isEmpty {
            let ext = (fileName as NSString).pathExtension
            guard !ext.isEmpty else { return nil }
            ordered.append(.nameMatches("*.\(ext)"))
        }

        // Applied to the TEMPLATE only, and only here: the conditions above are derived from the
        // folder's real name, and the brace guard is about a folder literally called "Q3 {final}".
        let template = generalizingTrailingYear(in: dest, fileName: fileName,
                                                modificationDate: modificationDate, now: now)
        let defaultCondition = ordered[0]
        let ruleName = distinctive.map { $0.capitalized } ?? (dest as NSString).lastPathComponent
        let rule = AutomationRule(name: ruleName,
                                  matchMode: .all,
                                  conditions: [defaultCondition],
                                  destinationTemplate: template)
        return Proposal(rule: rule,
                        defaultCondition: defaultCondition,
                        alternatives: Array(ordered.dropFirst()),
                        destinationTemplate: template)
    }

    /// A destination ending in the example's own year becomes `{year}`.
    ///
    /// **A literal year freezes the one axis that varies.** A rule learned from a bill filed into
    /// `Home/Utilities/T-Mobile/2025` files every future bill into 2025 — and a rule learned in
    /// December misfiles everything from January. This is not a rare shape: the surveyed tree has
    /// 738 year-bucket folders, and they are where recurring documents go, which is exactly the
    /// kind of document a learned rule is for. Seen in the wild as a `DetailedBill` rule pinned to
    /// `Home/Utilities/T-Mobile/2026` that sent an April 2025 statement to an empty 2026 folder.
    ///
    /// **Only when the literal is the year this example resolves to.** `{year}` reads the filename
    /// first and the modification date second (see `AutomationEvaluator`), so substituting when
    /// they agree is a rewrite that cannot change where THIS file goes — it only generalises to the
    /// next one. When they disagree the user filed a 2025 document into 2026 on purpose, and that
    /// intent is kept verbatim.
    ///
    /// Spans (`2024-2026`) are left alone: `{year}` cannot reproduce one, so there is nothing to
    /// generalise to.
    static func generalizingTrailingYear(in dest: String, fileName: String,
                                         modificationDate: Date?, now: Date) -> String {
        let parts = dest.split(separator: "/").map(String.init)
        guard let last = parts.last, last.count == 4, Int(last) != nil,
              FolderProfileEntry.looksLikeYear(last) else { return dest }
        let resolved = FilingEngine.filenameYear(in: FilingEngine.fileTokens(fileName), now: now)
            ?? modificationDate.map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) }
        guard resolved == last else { return dest }
        return (parts.dropLast() + ["{year}"]).joined(separator: "/")
    }

    /// Splits a stem into word-ish tokens on every non-alphanumeric boundary (so "T-Mobile-bill"
    /// yields "Mobile" and "bill", which overlap a "T-Mobile" destination on "Mobile"). Drops pure
    /// numbers and 1-character fragments.
    static func tokens(in stem: String) -> [String] {
        stem.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 2 && !$0.allSatisfy(\.isNumber) }
    }
}
