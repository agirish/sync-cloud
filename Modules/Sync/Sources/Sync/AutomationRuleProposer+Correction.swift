import Foundation

/// A rule taught by a correction in Ask Claude's chat (TE286): "no, JAL tickets go in
/// Travel/Trips". Claude generalizes from the one file to its kind — JAL is an airline, so the
/// words are every airline's (decision HF) — and this turns those words into a free rule on the Mac
/// (HG), checked against the file it was taught on, and never saved without his click.
///
/// **One rule per kind, kept up to date (HG, HH).** A later correction looks for the closest rule
/// already saved — one sharing words, or filing into the same folder:
/// - its folder fits this file too: the new words are added to it (Singapore Airlines joins
///   Airline tickets);
/// - its folder doesn't (a Singapore trip): a sibling rule with the same words, plus the words
///   that tell this file apart, saved before the first so it wins for the files it matches.
extension AutomationRuleProposer {

    public struct Correction: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case new
            /// The rule `id`, updated: `added` joins its words.
            case addWords(added: [String])
            /// A rule beside `of`, for another folder; saved before it.
            case sibling(of: UUID, ruleName: String)
        }

        public let kind: Kind
        /// The rule as it would be saved — for `addWords`, the existing rule with the words added.
        public let rule: AutomationRule
        /// Where the file it was taught on goes, relative: "Travel/Trips/IN-US/2026/Sep".
        public let example: String
        /// The year and month folders were checked against page 1. False when page 1 wasn't read:
        /// the card says so.
        public let checkedDate: Bool
    }

    public enum CorrectionRefusal: Error, Sendable, Equatable {
        /// No usable words: every one was a stop-word or too short.
        case noWords
        /// None of the words is in the file's name or page 1, so the rule wouldn't file the very
        /// file it was taught on.
        case notInFile
        /// A folder named with braces can't be a rule's destination.
        case unusableFolder
        /// A saved rule already files this file there.
        case covered(ruleName: String)
        /// The closest rule shares these words but files elsewhere, and nothing tells this file
        /// apart from those.
        case needsAlso(ruleName: String, folder: String)
    }

    /// A word or phrase as a rule matches it: canonical tokens in the order written,
    /// "Japan Airlines" → "japan airlines"; empty when nothing in it can be matched.
    public static func canonicalPhrase(_ phrase: String) -> String {
        let tokens = FilingEngine.nameTokens(phrase)
        var seen = Set<String>()
        return phrase.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { tokens.contains($0) && seen.insert($0).inserted }
            .joined(separator: " ")
    }

    /// The offer for a correction: `fileName` goes into `destinationRelativePath` (relative to the
    /// root rules resolve against), and `phrases` are the words of its kind, Claude's
    /// generalization. `also` are words that must hold too, telling this file apart from a rule
    /// that files the same words elsewhere. `pageSample` is page 1 as read on this Mac.
    public static func correction(fileName: String,
                                  destinationRelativePath: String,
                                  name: String,
                                  phrases: [String],
                                  also: [String] = [],
                                  pageSample: String?,
                                  modificationDate: Date?,
                                  existingRules: [AutomationRule],
                                  now: Date = Date()) -> Result<Correction, CorrectionRefusal> {
        let dest = destinationRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !dest.isEmpty, !dest.contains("{"), !dest.contains("}") else { return .failure(.unusableFolder) }

        var seen = Set<String>()
        let words = phrases.map(canonicalPhrase).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !words.isEmpty else { return .failure(.noWords) }
        let alsoTokens = Array(FilingEngine.nameTokens(also.joined(separator: " "))).sorted()

        let facts = correctionFacts(fileName: fileName, destination: dest, pageSample: pageSample,
                                    modificationDate: modificationDate)
        let day = facts.snippet.flatMap(AutomationTravelDate.first(in:))
        let template = generalizing(dest, travel: day, fileName: fileName, modificationDate: modificationDate, now: now)
        let checked = !AutomationTravelDate.isUsed(in: template) || day != nil

        func conditions(_ words: [String]) -> [AutomationCondition] {
            [.mentionsAny(words)] + (alsoTokens.isEmpty ? [] : [.mentionsAll(alsoTokens)])
        }
        func filesHere(_ rule: AutomationRule) -> Bool {
            guard AutomationEvaluator.matches(rule, facts, now: now) else { return false }
            if !checked { return true }
            guard case .resolved(let path) = AutomationEvaluator.resolveDestination(
                rule.destinationTemplate, for: facts, providerName: nil, now: now) else { return false }
            return sameFolder(path, dest)
        }

        let probe = AutomationRule(name: name, matchMode: .all, conditions: conditions(words), destinationTemplate: template)
        guard AutomationEvaluator.matches(probe, facts, now: now) else { return .failure(.notInFile) }

        let saved = AutomationRuleSet.eligible(existingRules).rules
        if let covering = saved.first(where: filesHere) { return .failure(.covered(ruleName: covering.name)) }

        let ruleName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Rule for " + (dest as NSString).lastPathComponent : name.trimmingCharacters(in: .whitespaces)

        if let closest = closestRule(to: words, template: template, in: saved) {
            let theirs = anyWords(of: closest) ?? []
            if closest.destinationTemplate == template {
                // The folder fits: the words join it, unless its other conditions keep this file out.
                var updated = closest
                let added = words.filter { !theirs.contains($0) }
                updated.conditions = closest.conditions.map { condition in
                    if case .mentionsAny(let existing) = condition { return .mentionsAny(existing + added) }
                    return condition
                }
                if !added.isEmpty, filesHere(updated) {
                    return .success(Correction(kind: .addWords(added: added), rule: updated, example: dest, checkedDate: checked))
                }
            } else {
                // Another folder, same words: a sibling with both sets, which needs words of its own.
                guard !alsoTokens.isEmpty else {
                    return .failure(.needsAlso(ruleName: closest.name, folder: closest.destinationTemplate))
                }
                let union = theirs + words.filter { !theirs.contains($0) }
                let siblingName = ruleName == closest.name ? "\(ruleName) – \(distinguishingSegment(template, from: closest.destinationTemplate))" : ruleName
                let sibling = AutomationRule(name: siblingName, matchMode: .all, conditions: conditions(union),
                                             destinationTemplate: template)
                if filesHere(sibling) {
                    return .success(Correction(kind: .sibling(of: closest.id, ruleName: closest.name), rule: sibling,
                                               example: dest, checkedDate: checked))
                }
            }
        }
        let rule = AutomationRule(name: ruleName, matchMode: .all, conditions: conditions(words), destinationTemplate: template)
        guard filesHere(rule) else { return .failure(.notInFile) }
        return .success(Correction(kind: .new, rule: rule, example: dest, checkedDate: checked))
    }

    /// The file as a scan sees it: its name, and page 1 as the scan reads it — the whole sample, as
    /// the scan's rule pass uses it, not the router's first 400 characters.
    static func correctionFacts(fileName: String, destination: String, pageSample: String?,
                                modificationDate: Date?) -> AutomationFileFacts {
        AutomationFileFacts(path: destination + "/" + fileName, name: fileName,
                            parentFolderName: (destination as NSString).lastPathComponent,
                            parentPath: destination, sizeBytes: 0, modificationDate: modificationDate,
                            isDirectory: false, snippet: pageSample?.lowercased(),
                            contentTokens: pageSample.map { FilingEngine.nameTokens($0) } ?? [])
    }

    /// `Travel/Trips/IN-US/2026/Sep` → `Travel/Trips/IN-US/{travel-year}/{travel-month}` when
    /// 2026 and Sep are the trip's (decision HI). Page 1 unread, a year folder followed by a month
    /// folder at the end is taken as the trip's all the same, and the card says it wasn't checked.
    /// A year folder alone at the end is Organize's own `{year}`, from the name or the file's date.
    static func generalizing(_ dest: String, travel day: AutomationTravelDate.Day?, fileName: String,
                             modificationDate: Date?, now: Date) -> String {
        var parts = dest.split(separator: "/").map(String.init)
        func isYear(_ s: String) -> Bool { s.count == 4 && FolderProfileEntry.looksLikeYear(s) }
        if parts.count >= 2, isYear(parts[parts.count - 2]),
           let month = AutomationTravelDate.month(ofFolder: parts[parts.count - 1]),
           day.map({ String($0.year) == parts[parts.count - 2] && $0.month == month }) ?? true {
            parts[parts.count - 2] = AutomationTravelDate.yearToken
            parts[parts.count - 1] = AutomationTravelDate.monthToken
            return parts.joined(separator: "/")
        }
        return generalizingTrailingYear(in: dest, fileName: fileName, modificationDate: modificationDate, now: now)
    }

    /// Two relative paths name the same folder: the month segment may be spelled either way.
    static func sameFolder(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "/").map { $0.lowercased() }
        let y = b.split(separator: "/").map { $0.lowercased() }
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { p, q in
            p == q || (AutomationTravelDate.month(named: p) != nil
                       && AutomationTravelDate.month(named: p) == AutomationTravelDate.month(ofFolder: q))
        }
    }

    /// The rule's any-of words, when it has them.
    static func anyWords(of rule: AutomationRule) -> [String]? {
        for case .mentionsAny(let words) in rule.conditions { return words }
        return nil
    }

    /// The saved rule a correction should update or stand beside: the one sharing the most words,
    /// a rule filing into the same folder first. Only rules keyed on any-of words take words.
    static func closestRule(to words: [String], template: String, in rules: [AutomationRule]) -> AutomationRule? {
        let mine = Set(words)
        let scored: [(rule: AutomationRule, same: Bool, shared: Int)] = rules.compactMap { rule in
            guard let theirs = anyWords(of: rule) else { return nil }
            let shared = mine.intersection(theirs).count
            let same = rule.destinationTemplate == template
            return shared > 0 || same ? (rule, same, shared) : nil
        }
        return scored.max { a, b in (a.same ? 1 : 0, a.shared) < (b.same ? 1 : 0, b.shared) }?.rule
    }

    /// The first folder where two templates part: "Singapore" for Trips/Singapore/Flights beside
    /// Trips/IN-US/{travel-year}.
    static func distinguishingSegment(_ template: String, from other: String) -> String {
        let a = template.split(separator: "/").map(String.init)
        let b = other.split(separator: "/").map(String.init)
        for (i, segment) in a.enumerated() where i >= b.count || b[i] != segment {
            return segment
        }
        return a.last ?? template
    }
}
