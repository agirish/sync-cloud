import Foundation

/// Rules taught by a pick on Ask Claude's filing card (TE331): a row sent to a folder other than
/// the card's goes there, and at Apply the card offers a rule for files like it.
///
/// **The Mac picks the words (decision JA).** Each file gives one: the word of its name that says
/// whose it is ("JAL"), or for a name with none, the phrase To File's Save as Rule keys on. Claude
/// isn't asked, so nothing is sent and saved chats keep their instructions. The words widen as later picks add theirs to the
/// same rule, through the correction's closest-rule step (TE286, HG and HH).
///
/// **One card per rule (JD).** Files whose picks make one rule share its card: each pick is
/// weighed against the saved rules with the offers already made in their place, so a second
/// ticket for the same trip adds its words to the first ticket's offer.
extension AutomationRuleProposer {

    /// One file they sent to a folder of their own choosing.
    public struct CardExample: Sendable, Equatable {
        /// As the card showed it.
        public let fileName: String
        /// Where it went, relative to `surveyRoot`.
        public let destinationRelativePath: String
        /// The survey whose tree the rule acts in.
        public let surveyRoot: String
        /// Page 1 as read on this Mac, nil when unread.
        public let pageSample: String?
        public let modificationDate: Date?
        /// The rule's words from this file, as one phrase: "jal receipt".
        public let phrase: String
        /// A name for a new rule: "IN-US".
        public let ruleName: String

        public init(fileName: String, destinationRelativePath: String, surveyRoot: String, pageSample: String?,
                    modificationDate: Date?, phrase: String, ruleName: String) {
            self.fileName = fileName
            self.destinationRelativePath = destinationRelativePath
            self.surveyRoot = surveyRoot
            self.pageSample = pageSample
            self.modificationDate = modificationDate
            self.phrase = phrase
            self.ruleName = ruleName
        }
    }

    /// A rule offered for one or more picks.
    public struct CardOffer: Sendable, Equatable {
        public var correction: Correction
        /// The files it was checked on, in card order.
        public var fileNames: [String]
        /// Where each went, relative.
        public var examples: [String]
    }

    /// The words and name a pick teaches. The file's name leads: its first word that says whose
    /// paper it is rather than what kind ("JAL" in "JAL eTicket Receipt.pdf"). A name with none
    /// ("Scan 0042.pdf") takes the phrase To File's Save as Rule would key on, from page 1 and the
    /// survey's memory (`index`); with no index that is a guess from word length, so nothing is
    /// offered. Nil when nothing can be keyed on.
    public static func cardWords(fileName: String, destinationRelativePath: String, pageSample: String?,
                                 index: FilingRouter.Index?, modificationDate: Date?,
                                 now: Date = Date()) -> (phrase: String, ruleName: String)? {
        let dest = destinationRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let name = cardRuleName(dest, pageSample: pageSample, fileName: fileName, modificationDate: modificationDate, now: now)
        if let word = cardNameWord(fileName) { return (word, name) }
        guard let index,
              // Saved rules are left out: a rule that already covers it is the correction's to find.
              let proposal = propose(fileName: fileName, destinationRelativePath: dest,
                                     evidence: Evidence(pageSample: pageSample, index: index, existingRules: []),
                                     modificationDate: modificationDate, now: now) else { return nil }
        // A phrasing that files somewhere else (each person's own folder) isn't a pick's.
        for variant in proposal.variants where variant.destinationTemplate == nil {
            for case .mentionsAll(let tokens) in variant.conditions {
                let phrase = canonicalPhrase(tokens.joined(separator: " "))
                if !phrase.isEmpty { return (phrase, name) }
            }
        }
        return nil
    }

    /// The first word of a file's name that says whose it is: not a kind of paper, a year, a
    /// month or a number.
    static func cardNameWord(_ fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        return canonicalPhrase(stem).split(separator: " ").map(String.init).first { word in
            !cardKindWords.contains(word) && !FilingEngine.stopwords.contains(word)
                && !word.allSatisfy(\.isNumber) && AutomationTravelDate.month(named: word) == nil
        }
    }

    /// Words that say what kind of paper a file is, not whose: a rule on any of them alone would
    /// take every receipt or ticket.
    static let cardKindWords: Set<String> = [
        "receipt", "receipts", "invoice", "invoices", "order", "orders", "purchase", "bill", "bills", "billing",
        "statement", "statements", "ticket", "tickets", "eticket", "itinerary", "confirmation", "booking",
        "reservation", "boarding", "pass", "policy", "form", "letter", "report", "notice", "scan", "scanned",
        "summary", "payment", "tax", "taxes", "return", "signed", "page", "pages", "travel", "trip", "flight",
        "hotel", "account", "card", "bank", "copy", "final", "draft", "document", "file", "image", "photo",
    ]

    /// A new rule's name: its folder's last literal name, "IN-US" for Travel/Trips/IN-US/2026/Sep.
    static func cardRuleName(_ dest: String, pageSample: String?, fileName: String, modificationDate: Date?, now: Date) -> String {
        let facts = correctionFacts(fileName: fileName, destination: dest, pageSample: pageSample, modificationDate: modificationDate)
        let template = generalizing(dest, travel: facts.snippet.flatMap(AutomationTravelDate.first(in:)),
                                    fileName: fileName, modificationDate: modificationDate, now: now)
        return template.split(separator: "/").map(String.init).last { !$0.contains("{") } ?? (dest as NSString).lastPathComponent
    }

    /// The offers for the picks on one card, at most `limit`, and how many more rules there were.
    /// A pick a saved rule already makes offers nothing.
    public static func cardOffers(_ picks: [CardExample], existingRules: [AutomationRule], limit: Int = 3,
                                  now: Date = Date()) -> (offers: [CardOffer], more: Int) {
        var offers: [CardOffer] = []
        var more = 0
        for pick in picks {
            // The saved rules for this tree, with each offer standing where it would be saved.
            var rules = existingRules.filter { $0.acts(in: pick.surveyRoot) }
            for offer in offers where offer.correction.rule.acts(in: pick.surveyRoot) {
                switch offer.correction.kind {
                case .addWords:
                    if let at = rules.firstIndex(where: { $0.id == offer.correction.rule.id }) { rules[at] = offer.correction.rule }
                case .new:
                    rules.append(offer.correction.rule)
                case .sibling(let of, _):
                    rules.insert(offer.correction.rule, at: rules.firstIndex { $0.id == of } ?? rules.endIndex)
                }
            }
            func attempt(_ also: [String]) -> Result<Correction, CorrectionRefusal> {
                correction(fileName: pick.fileName, destinationRelativePath: pick.destinationRelativePath,
                           name: pick.ruleName, phrases: [pick.phrase], also: also, pageSample: pick.pageSample,
                           modificationDate: pick.modificationDate, existingRules: rules, now: now)
            }
            var answer = attempt([])
            // Their rule files these words elsewhere: the words this file shares with its own
            // folder tell it apart ("Dubai" for Trips/Dubai beside Trips/IN-US).
            if case .failure(.needsAlso(_, let folder)) = answer {
                let also = cardAlso(pick, apartFrom: folder)
                if !also.isEmpty { answer = attempt(also) }
            }
            switch answer {
            case .success(let found):
                var rule = found.rule
                if case .addWords = found.kind {} else { rule.surveyRoot = pick.surveyRoot }
                let made = Correction(kind: found.kind, rule: rule, example: found.example, checkedDate: found.checkedDate)
                if let at = offers.firstIndex(where: { $0.correction.rule.id == made.rule.id }) {
                    offers[at].merge(made, pick)
                } else if offers.count < limit {
                    offers.append(CardOffer(correction: made, fileNames: [pick.fileName], examples: [made.example]))
                } else {
                    more += 1
                }
            case .failure(.covered):
                // By an offer's own rule: checked on this file too. By a saved rule: nothing to offer.
                if let at = offers.firstIndex(where: { cardFiles($0.correction.rule, pick, now: now) }) {
                    offers[at].fileNames.append(pick.fileName)
                    offers[at].examples.append(pick.destinationRelativePath)
                }
            case .failure:
                break
            }
        }
        return (offers, more)
    }

    /// The words of the pick's own folder, not in `folder`, that the file carries: in its name or
    /// on page 1. Years and months are left out: the rule's folders name those.
    static func cardAlso(_ pick: CardExample, apartFrom folder: String) -> [String] {
        func words(_ path: String) -> Set<String> {
            path.split(separator: "/").reduce(into: Set<String>()) { $0.formUnion(FilingEngine.nameTokens(String($1))) }
        }
        let own = words(pick.destinationRelativePath).subtracting(words(folder))
        let inFile = FilingEngine.nameTokens(pick.fileName).union(pick.pageSample.map { FilingEngine.nameTokens($0) } ?? [])
        return own.intersection(inFile).filter { word in
            !(word.count == 4 && FolderProfileEntry.looksLikeYear(word)) && AutomationTravelDate.month(named: word) == nil
        }.sorted()
    }

    /// The rule sends the pick where they put it.
    static func cardFiles(_ rule: AutomationRule, _ pick: CardExample, now: Date) -> Bool {
        let facts = correctionFacts(fileName: pick.fileName, destination: pick.destinationRelativePath,
                                    pageSample: pick.pageSample, modificationDate: pick.modificationDate)
        guard AutomationEvaluator.matches(rule, facts, now: now) else { return false }
        guard case .resolved(let path) = AutomationEvaluator.resolveDestination(
                rule.destinationTemplate, for: facts, providerName: nil, now: now) else {
            // Page 1 unread: its year and month can't be checked, as the card says.
            return AutomationTravelDate.isUsed(in: rule.destinationTemplate) && pick.pageSample == nil
        }
        return sameFolder(path, pick.destinationRelativePath)
    }
}

extension AutomationRuleProposer.CardOffer {
    /// Another pick that `made` updated this offer's rule for: its words join, and the offer keeps
    /// what it is to the saved rules (new, words for a saved rule, or a rule beside one).
    mutating func merge(_ made: AutomationRuleProposer.Correction, _ pick: AutomationRuleProposer.CardExample) {
        var kind = correction.kind
        if case .addWords(let before) = kind, case .addWords(let added) = made.kind {
            kind = .addWords(added: before + added.filter { !before.contains($0) })
        }
        correction = AutomationRuleProposer.Correction(kind: kind, rule: made.rule, example: correction.example,
                                                       checkedDate: correction.checkedDate && made.checkedDate)
        fileNames.append(pick.fileName)
        examples.append(made.example)
    }
}
