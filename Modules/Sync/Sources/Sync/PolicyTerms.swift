import Foundation

/// Insurance policy papers, filed by the policy term they belong to.
///
/// A folder that keeps a policy's papers in year folders, named by term
/// (`Home/Insurance/2025/GEICO-Homesite Policy - Jan 2025-Jan 2026.pdf`), files each paper in the
/// year its term **starts**, not the year on the letter. A renewal issued in November 2025 for the
/// term from January 2026 belongs in `2026`, named `GEICO-Homesite Renewal - Jan 2026-Jan 2027.pdf`.
///
/// Every other lane places by the folder the policy already lives in (its number, its insurer's
/// name), which is right about the policy and wrong about the year, since the letter's own date is
/// the only date most of them see. So this runs last, over whatever home a card leads with, and
/// moves only the year and the name.
///
/// The term comes from the page when page 1 prints one (`Policy Period 02/19/2023 to 02/19/2024`,
/// `Effective Date … Expiration Date …`, `covers … from … through …`). Most renewal letters
/// print only their own date, so otherwise the term follows the folder's own: the terms its
/// files are named for, stepped forward by their length. A renewal takes the first term starting
/// in or after the letter's month; any other paper the term in force on its date. A term worked out
/// that way is never High: the month was not on the page.
enum PolicyTerms {

    struct Month: Comparable, Hashable {
        let year: Int
        let month: Int
        var index: Int { year * 12 + (month - 1) }
        init(year: Int, month: Int) { self.year = year; self.month = month }
        init(index: Int) { year = index / 12; month = index % 12 + 1 }
        static func < (a: Month, b: Month) -> Bool { a.index < b.index }
        var label: String { "\(PolicyTerms.monthNames[month - 1]) \(year)" }
    }

    struct Term: Equatable {
        let start: Month
        let end: Month
        var label: String { "\(start.label)-\(end.label)" }
    }

    /// A file named for a term: who and what, then the term (`Hippo Declarations - Feb 2024-Feb 2025.pdf`).
    struct NamedPaper: Equatable {
        let insurer: String
        let term: Term
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let monthAlternation = monthNames.joined(separator: "|")
    private static let namedRE = try! NSRegularExpression(pattern:
        #"^(.+?) - ("# + monthAlternation + #") (\d{4})-("# + monthAlternation + #") (\d{4})(?:\.[A-Za-z0-9]+)?$"#)

    /// What a paper is, as its name says it, from the end of the part before the term. Longest
    /// first, so `Renewal Package` is not read as a bare `Package`.
    static let documentWords = ["Evidence of Insurance", "Proof of Insurance", "Terms and Conditions",
                                "Welcome Booklet", "Renewal Package", "Declarations", "Renewal",
                                "Policy", "ID Card", "Invoice", "Bill"]

    /// The insurer and term a file's name carries, or nil for a name not built that way.
    static func namedPaper(_ fileName: String) -> NamedPaper? {
        let ns = fileName as NSString
        guard let m = namedRE.firstMatch(in: fileName, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func month(_ i: Int) -> Int { (monthNames.firstIndex(of: ns.substring(with: m.range(at: i))) ?? 0) + 1 }
        guard let y1 = Int(ns.substring(with: m.range(at: 3))), let y2 = Int(ns.substring(with: m.range(at: 5))) else { return nil }
        let term = Term(start: Month(year: y1, month: month(2)), end: Month(year: y2, month: month(4)))
        guard term.start < term.end else { return nil }
        let head = ns.substring(with: m.range(at: 1))
        var insurer = head
        for word in documentWords where head.hasSuffix(" " + word) {
            insurer = String(head.dropLast(word.count + 1))
            break
        }
        if insurer == head { insurer = String(head.split(separator: " ").first ?? Substring(head)) }
        return NamedPaper(insurer: insurer, term: term)
    }

    /// The folder `path` names when it is a term-named policy folder, or the year folder inside
    /// one: the series folder (relative to the walk's root) and every named paper in it.
    /// A series needs two papers named by term, so one stray name doesn't make a folder one.
    static func series(containing relativePath: String, in taxonomy: [FileNode]) -> (folder: String, papers: [NamedPaper])? {
        var parts = relativePath.split(separator: "/").map(String.init)
        if let last = parts.last, last.count == 4, FolderProfileEntry.looksLikeYear(last) { parts.removeLast() }
        guard !parts.isEmpty else { return nil }
        let folder = parts.joined(separator: "/")
        guard let node = AccountProposal.node(at: folder, in: taxonomy) else { return nil }
        var papers: [NamedPaper] = []
        for child in node.children ?? [] {
            if child.isDirectory {
                guard child.name.count == 4, FolderProfileEntry.looksLikeYear(child.name) else { continue }
                for f in child.children ?? [] where !f.isDirectory { if let p = namedPaper(f.name) { papers.append(p) } }
            } else if let p = namedPaper(child.name) {
                papers.append(p)
            }
        }
        return papers.count >= 2 ? (folder, papers) : nil
    }

    /// Whether page 1 reads as a policy's own paper, and which: nil for anything else (a claim, a
    /// bill), which this leaves to the other lanes.
    static func documentWord(onPage lower: String) -> String? {
        guard lower.contains("policy"), lower.contains("insurance") || lower.contains("underwritten") else { return nil }
        if lower.contains("evidence of insurance") || lower.contains("evidence of property insurance") { return "Evidence of Insurance" }
        if lower.contains("declarations") && !lower.contains("renew") { return "Declarations" }
        if lower.range(of: #"\brenew(?:al|ed|ing)?\b"#, options: .regularExpression) != nil { return "Renewal" }
        if lower.contains("declarations") { return "Declarations" }
        return nil
    }

    private static let compiled = RegexCache()
    private static var date: String { DocumentFacts.dateRE }

    /// The term page 1 prints, if it prints one.
    static func printedTerm(onPage lower: String) -> Term? {
        let patterns = [
            #"(?:policy|coverage)\s+(?:term|period)[\s:|*]*("# + date + #")\s*(?:to|through|thru|-|–)\s*("# + date + ")",
            #"effective(?:\s+date)?[\s:|*]*("# + date + #")[\s\S]{0,80}?expiration(?:\s+date)?[\s:|*]*("# + date + ")",
            #"cover\w*[\s\S]{0,60}?from\s+("# + date + #")\s*(?:to|through|thru)\s+("# + date + ")",
        ]
        let ns = lower as NSString
        for p in patterns {
            guard let m = compiled.regex(p).firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
                  let a = DocumentFacts.parseDate(ns.substring(with: m.range(at: 1))),
                  let b = DocumentFacts.parseDate(ns.substring(with: m.range(at: 2))) else { continue }
            let term = Term(start: Month(year: a.year, month: a.month), end: Month(year: b.year, month: b.month))
            if term.start < term.end { return term }
        }
        return nil
    }

    /// The letter's own date: the first full date on the page.
    static func letterDate(onPage lower: String) -> Month? {
        let ns = lower as NSString
        guard let m = compiled.regex(date).firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              let p = DocumentFacts.parseDate(ns.substring(with: m.range)) else { return nil }
        return Month(year: p.year, month: p.month)
    }

    /// The term a paper dated `date` belongs to, stepping the folder's own `known` term forward or
    /// back by its length: for a renewal the first one starting in or after the letter's month,
    /// for anything else the one in force then.
    static func term(for date: Month, renewal: Bool, following known: Term) -> Term? {
        let length = known.end.index - known.start.index
        guard length > 0 else { return nil }
        // The start of the term in force at `date`, on the known term's cadence.
        let offset = date.index - known.start.index
        let steps = offset >= 0 ? offset / length : -((-offset + length - 1) / length)
        var start = known.start.index + steps * length
        if renewal, start < date.index { start += length }
        return Term(start: Month(index: start), end: Month(index: start + length))
    }

    struct Placement: Equatable {
        let folder: String
        let year: Int
        let name: String
        let term: Term
        let printed: Bool
    }

    /// Where a policy paper read as `page` goes when its card leads into `relativePath`.
    static func placement(page: String, fileName: String, leadingInto relativePath: String,
                          taxonomy: [FileNode]) -> Placement? {
        let lower = page.lowercased()
        guard let word = documentWord(onPage: lower),
              let (folder, papers) = series(containing: relativePath, in: taxonomy) else { return nil }
        // The insurer is the one the page names, among those the folder's papers are named for.
        let named = papers.filter { p in
            let words = p.insurer.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
            return !words.isEmpty && words.contains { lower.range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }
        }
        guard let latest = named.max(by: { $0.term.start < $1.term.start }) else { return nil }
        let printed = printedTerm(onPage: lower)
        let term: Term
        if let printed {
            term = printed
        } else {
            guard let date = letterDate(onPage: lower),
                  let worked = PolicyTerms.term(for: date, renewal: word == "Renewal", following: latest.term) else { return nil }
            term = worked
        }
        let ext = (fileName as NSString).pathExtension
        let name = "\(latest.insurer) \(word) - \(term.label)" + (ext.isEmpty ? "" : "." + ext.lowercased())
        return Placement(folder: folder, year: term.start.year, name: name, term: term, printed: printed != nil)
    }

    /// `suggestions` with every card leading into a term-named policy folder moved to its term's
    /// year and named for it.
    static func placing(_ suggestions: [FilingSuggestion], pages: [String: String],
                        taxonomy: [FileNode], root: String) -> [FilingSuggestion] {
        suggestions.map { s in
            guard let page = pages[s.filePath], let best = s.best, !best.remembered,
                  PathBoundary.contains(best.path, under: root), best.path != root else { return s }
            let rel = String(best.path.dropFirst(root.count + 1))
            guard let place = placement(page: page, fileName: s.fileName, leadingInto: rel, taxonomy: taxonomy) else { return s }
            let yearName = String(place.year)
            let node = AccountProposal.node(at: place.folder, in: taxonomy)
            let exists = (node?.children ?? []).contains { $0.isDirectory && $0.name == yearName }
            let path = root + "/" + place.folder + "/" + yearName
            let confidence = place.printed ? best.confidence : min(best.confidence, .medium)
            let why = place.printed
                ? "Policy term \(place.term.label) on page 1, filed by the year it starts"
                : "Policy term \(place.term.label), worked out from this folder’s terms and the letter’s date"
            var reasons = best.reasons.filter { !$0.hasPrefix("Policy term ") }
            reasons.append(why)
            let moved = FilingDestination(path: path, confidence: confidence, reasons: reasons,
                                          newSegments: exists ? [] : [yearName], fromContent: true,
                                          remembered: false, fromAI: best.fromAI,
                                          evidenceToken: best.evidenceToken, neighborMatches: best.neighborMatches,
                                          proposedName: place.name, fromSurvey: best.fromSurvey,
                                          account: best.account, nameOrigin: .template)
            let rest = s.candidates.dropFirst().filter { $0.path != path }
            return s.replacingCandidates([moved] + rest)
        }
    }
}
