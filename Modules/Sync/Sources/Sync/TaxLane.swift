import Foundation

/// Tax forms file by tax year, into the tree's own `Income Tax/<year>` layout.
///
/// His layout (`Finance/US/Income Tax/2025/Income/Form 1099`, `…/Deductions/Form 1098-T`,
/// `…/Tax Returns`) is learned from the folders themselves: a form goes into the folder named for it
/// in the newest tax year that has one, under the form's own year. A 1099 matched to its account
/// still gets a copy in that account's `Tax` folder (his rule: in its tax year, and also with its
/// account). The year is the one the form prints, never the date it was fetched.
///
/// Runs over the cards after every other lane, like ``PolicyTerms``: a form's tax year and kind
/// decide its home whatever folder its issuer's name or number found.
enum TaxLane {

    /// A form's kind, as his folders name it: the folder for it is the one whose name ends with
    /// `folder` (`Form 1099-R` before `Form 1099`).
    struct Kind: Equatable {
        /// What the form calls itself in a name: `1099-DIV`, `W-2`, `1040`.
        let label: String
        /// The folder name it files under: `Form 1099`, `Tax Returns`.
        let folder: String
    }

    private static let compiled = RegexCache()

    /// The form page 1 says this is, from its first 600 characters (the title, not a mention).
    static func kind(of lower: String) -> Kind? {
        let head = String(lower.prefix(600))
        func has(_ pattern: String) -> Bool {
            compiled.regex(pattern).firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) != nil
        }
        // A notice that a form is ready is not the form.
        if has(#"\b(?:is|are)\s+(?:now\s+)?(?:available|ready|online)\b"#) { return nil }
        let taxAuthority = #"(?:\birs\b|internal revenue|franchise tax|\bftb\b|department of the treasury|direct pay|taxrfd)"#
        // A transcript prints the return it reports on (`Form 1040 Tax Return Transcript`): it is a
        // record, not the return, so it is read first.
        if has(#"\btranscript\b"#), has(taxAuthority + #"|tax period"#) { return Kind(label: "Transcript", folder: "Tax Records") }
        if has(#"\brefund\b|taxrfd"#), has(taxAuthority) { return Kind(label: "Refund", folder: "Refund") }
        if has(#"\bdirect pay\b|\beftps\b|\bweb pay\b|\bpayment confirmation\b|\bestimated tax payment\b"#), has(taxAuthority) {
            return Kind(label: "Payment", folder: "Payments")
        }
        if has(#"\bform\s*1040\b|\bu\.?s\.? individual income tax return\b"#) { return Kind(label: "1040", folder: "Tax Returns") }
        if has(#"\bform\s*1099-r\b|\b1099-r\b"#) { return Kind(label: "1099-R", folder: "Form 1099-R") }
        if has(#"\bform\s*w-?2\b|\bwage and tax statement\b"#) { return Kind(label: "W-2", folder: "Form W-2") }
        if has(#"\bform\s*1098-t\b|\btuition statement\b"#) { return Kind(label: "1098-T", folder: "Form 1098-T") }
        if has(#"\bform\s*1095-[abc]\b|\bhealth (?:insurance marketplace|coverage) statement\b"#) {
            return Kind(label: "1095", folder: "Form 1095")
        }
        if has(#"\bform\s*5498\b"#) { return Kind(label: "5498", folder: "Form 5498") }
        if has(#"\bform\s*1099\b|\b1099-(?:div|int|b|misc|nec|g|composite|oid|k|sa)\b|\bcomposite form 1099\b"#) {
            for v in ["div", "int", "b", "misc", "nec", "g", "oid", "k", "sa"] where has(#"\b1099-"# + v + #"\b"#) {
                // A composite names several; it is the composite.
                if has(#"\bcomposite\b"#) { break }
                return Kind(label: "1099-" + v.uppercased(), folder: "Form 1099")
            }
            return Kind(label: "1099", folder: "Form 1099")
        }
        return nil
    }

    /// The tax year page 1 prints: `Tax Year 2025`, `2025 Form 1099-DIV`, `Form 1040 (2025)`,
    /// `For calendar year 2025`.
    static func taxYear(of lower: String) -> Int? {
        if let y = DocumentFacts.taxYear(in: lower) { return y }
        let head = String(lower.prefix(1500))
        let ns = head as NSString
        for p in [#"tax period(?: ending)?[:\s]+(?:[a-z]+\.? \d{1,2},? |\d{1,2}[-/]\d{1,2}[-/])(\d{4})"#,
                  #"(\d{4})\s*form\s*(?:1040|1095|w-?2)"#, #"form\s*(?:1040|1095-[abc]|w-?2)[^0-9]{0,40}(\d{4})"#,
                  #"(?:for )?calendar year\s*(\d{4})"#, #"tax period[:\s]+[a-z]*\.?\s*\d{0,2},?\s*(\d{4})"#] {
            if let m = compiled.regex(p).firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
               let y = Int(ns.substring(with: m.range(at: 1))), (1990...2100).contains(y) { return y }
        }
        return nil
    }

    /// A refund or payment that prints no tax year: one dated January to April settles the year
    /// before (his rule); a later date says nothing about which year it is for.
    static func springYear(of lower: String, for kind: Kind) -> Int? {
        guard kind.folder == "Refund" || kind.folder == "Payments" else { return nil }
        let ns = lower as NSString
        guard let m = compiled.regex(DocumentFacts.dateRE).firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              let d = DocumentFacts.parseDate(ns.substring(with: m.range)), d.month <= 4 else { return nil }
        return d.year - 1
    }

    /// The tree's tax folder: the `Income Tax` folder holding year folders, outside any archive.
    static func incomeTaxRoot(in taxonomy: [FileNode]) -> (path: String, node: FileNode)? {
        var found: (String, FileNode)?
        func visit(_ nodes: [FileNode], _ prefix: String, depth: Int) {
            guard depth < 5, found == nil else { return }
            for n in nodes where n.isDirectory {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if AccountIndex.isArchiveName(n.name) || FolderProfile.refusesNewFiles(rel) { continue }
                if n.name.compare("Income Tax", options: .caseInsensitive) == .orderedSame,
                   (n.children ?? []).contains(where: { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name) }) {
                    found = (rel, n); return
                }
                visit(n.children ?? [], rel, depth: depth + 1)
            }
        }
        visit(taxonomy, "", depth: 0)
        return found
    }

    /// Where `kind` goes inside a tax year, as the newest year holding its folder lays it out
    /// (`Income/Form 1099`): relative to the year folder, nil when no year has one.
    static func layout(for kind: Kind, in taxRoot: FileNode) -> String? {
        let years = (taxRoot.children ?? []).filter { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name) }
            .sorted { $0.name > $1.name }
        func find(_ nodes: [FileNode], _ prefix: String, depth: Int) -> String? {
            guard depth < 3 else { return nil }
            for n in nodes where n.isDirectory {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if n.name.compare(kind.folder, options: .caseInsensitive) == .orderedSame { return rel }
                if let deeper = find(n.children ?? [], rel, depth: depth + 1) { return deeper }
            }
            return nil
        }
        for y in years { if let r = find(y.children ?? [], "", depth: 0) { return r } }
        return nil
    }

    /// `suggestions` with every tax form leading into its tax year's folder for its kind. A 1099
    /// whose card led into its account keeps that as a copy.
    static func placing(_ suggestions: [FilingSuggestion], pages: [String: String],
                        taxonomy: [FileNode], root: String) -> [FilingSuggestion] {
        guard let (taxPath, taxNode) = incomeTaxRoot(in: taxonomy) else { return suggestions }
        return suggestions.map { s in
            guard let page = pages[s.filePath], !(s.best?.remembered ?? false) else { return s }
            let lower = page.lowercased()
            guard let kind = kind(of: lower),
                  let year = taxYear(of: lower) ?? springYear(of: lower, for: kind),
                  let inside = layout(for: kind, in: taxNode) else { return s }
            // An information return must read as a form, not a statement that mentions one
            // (`… your Form 1099 information`); a return, a 1095 and a 1098-T name themselves.
            if ["Form 1099", "Form 1099-R", "Form W-2", "Form 5498"].contains(kind.folder),
               DocumentFacts(page: page).kind != .taxForm { return s }
            // A bank statement listing a refund deposit is the bank's statement.
            if ["Refund", "Payments"].contains(kind.folder), DocumentFacts(page: page).kind == .statement { return s }
            let yearName = String(year)
            let rel = taxPath + "/" + yearName + "/" + inside
            let path = root + "/" + rel
            guard s.best?.path != path else { return s }
            let missing = AccountProposal.missing(rel, in: taxonomy)
            var home = FilingDestination(path: path, confidence: .medium,
                                         reasons: ["Form \(kind.label) for \(year) · filed by its tax year"],
                                         newSegments: missing, fromContent: true, evidenceToken: "Form \(kind.label)")
            // A 1099 led into its account's folder: that stays, as a copy (his rule).
            if kind.folder == "Form 1099", let best = s.best, let account = best.account {
                home.alsoCopiesTo = [FilingCopy(path: best.path, proposedName: best.proposedName, account: account)]
            }
            let rest = s.candidates.filter { $0.path != path }
            return s.replacingCandidates([home] + rest)
        }
    }
}
