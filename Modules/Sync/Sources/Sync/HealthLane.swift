import Foundation

/// Medical papers file by who they are about and what they are, in the tree's own layout:
/// `Health/Medical/<Person>/{Visits/<year>, Test Results, Immunizations}` for a person's care, and
/// `Health/Medical/Insurance/{EOBs, Bills, Claims}/<year>` for the family's billing and coverage,
/// whoever they name.
///
/// **The person is the medical record number, not a name.** Names on medical pages mislead: a
/// newborn's first records say `Female Maiden`, the children print his first name as their surname,
/// and the account holder's name rides on every family member's record. The number is one per
/// person and printed on almost every page, so it is looked up in what the filing memory learned:
/// every folder whose filed pages printed it (``FilingMemory``'s hashed identifiers), rolled up to
/// the person folder above them. With no number, or one the memory doesn't know, a person's paper
/// is left to the other lanes.
///
/// Runs over the cards after every other lane, like ``TaxLane``.
enum HealthLane {

    enum Kind: Equatable {
        case visit(label: String)
        case testResult
        case immunization
        case eob
        case bill(label: String)
        case claim

        /// The folder it goes in: under the person, or under `Insurance`.
        var folder: String {
            switch self {
            case .visit: return "Visits"
            case .testResult: return "Test Results"
            case .immunization: return "Immunizations"
            case .eob: return "EOBs"
            case .bill: return "Bills"
            case .claim: return "Claims"
            }
        }
        var isInsurance: Bool {
            switch self { case .eob, .bill, .claim: return true; default: return false }
        }
    }

    private static let compiled = RegexCache()
    private static func has(_ pattern: String, _ text: String) -> Bool {
        compiled.regex(pattern).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// What page 1 says the paper is, from its first 800 characters.
    static func kind(of lower: String) -> Kind? {
        let head = String(lower.prefix(800))
        if has(#"\bexplanation of benefits\b"#, head) { return .eob }
        if has(#"\bprofessional medical bill\b"#, head) { return .bill(label: "Physician Bill") }
        if has(#"\bhospital (?:medical )?bill\b"#, head) { return .bill(label: "Hospital Bill") }
        if has(#"\bclaims? report\b|\bclaim number\b"#, head), has(#"\b(?:provider|your plan covers|date received)\b"#, head) {
            return .claim
        }
        if has(#"\bafter visit summary\b|\byou were seen on\b|\byou saw [a-z .,'-]{2,60} on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, head) {
            return .visit(label: "After Visit Summary")
        }
        if has(#"\bcontinuity of care document\b"#, head) { return .visit(label: "Visit Record (CCD)") }
        if has(#"\bsummary of care\b"#, head) { return .visit(label: "Summary of Care") }
        if has(#"\b(?:visit|progress|clinic(?:al)?) notes?\b"#, head), has(#"\b(?:mrn|medical record)\b"#, head) {
            return .visit(label: "Visit Notes")
        }
        if has(#"\b(?:immunization|vaccination) (?:record|history)\b|\bimmunizations\b"#, head),
           has(#"\b(?:mrn|medical record|member name|patient)\b"#, head) { return .immunization }
        if has(#"\b(?:test|lab) results?\b"#, head), has(#"\b(?:mrn|medical record|member name|patient)\b"#, head) {
            return .testResult
        }
        return nil
    }

    /// The medical record numbers page 1 prints.
    static func recordNumbers(in page: String) -> [String] {
        let text = page.lowercased()
        let ns = text as NSString
        return compiled.regex(#"\b(?:mrn|medical record (?:number|no\.?|#))\s*[:#]?\s*(\d{5,12})\b"#)
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The paper's own date: one a bill, visit, service or statement label names, else the first
    /// full date that isn't a birth date, the day it was printed, a due date or a plan year's.
    ///
    /// A test result prints the history it shows; he files it by when it was printed, so for a
    /// result the newest date that isn't a birth date counts.
    static func newestDate(in lower: String) -> DocumentFacts.Period? {
        let ns = lower as NSString
        var lastEnd = 0
        var newest: DocumentFacts.Period?
        for m in compiled.regex(DocumentFacts.dateRE).matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let from = max(lastEnd, m.range.location - 24)
            let before = ns.substring(with: NSRange(location: from, length: m.range.location - from))
            lastEnd = m.range.location + m.range.length
            if has(#"birth|born|\bdob\b"#, before) { continue }
            if let p = DocumentFacts.parseDate(ns.substring(with: m.range)), p.day != nil, newest.map({ $0 < p }) ?? true { newest = p }
        }
        return newest
    }

    static func date(in lower: String) -> DocumentFacts.Period? {
        let ns = lower as NSString
        let date = DocumentFacts.dateRE
        let all = NSRange(location: 0, length: ns.length)
        if let m = compiled.regex(#"(?:bill date|visit date|date of visit|date of service|service date|encounter date|statement date|appointment date|date received)[\s:&a-z]{0,12}?("# + date + ")")
            .firstMatch(in: lower, range: all), let p = DocumentFacts.parseDate(ns.substring(with: m.range(at: 1))) {
            return p
        }
        var lastEnd = 0
        for m in compiled.regex(date).matches(in: lower, range: all) {
            // Only the words since the previous date: a label belongs to the date right after it.
            let from = max(lastEnd, m.range.location - 24)
            let before = ns.substring(with: NSRange(location: from, length: m.range.location - from))
            lastEnd = m.range.location + m.range.length
            if has(#"birth|born|\bdob\b|printed|generated|revised|\bdue\b|plan year|through"#, before) { continue }
            if let p = DocumentFacts.parseDate(ns.substring(with: m.range)), p.day != nil { return p }
        }
        return nil
    }

    /// The tree's medical folder: one holding person folders (each with a `Visits` folder) and an
    /// `Insurance` folder. Relative to the walk's root.
    static func medicalRoot(in taxonomy: [FileNode]) -> (path: String, node: FileNode)? {
        var found: (String, FileNode)?
        func visit(_ nodes: [FileNode], _ prefix: String, depth: Int) {
            guard depth < 4, found == nil else { return }
            for n in nodes where n.isDirectory {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if FolderProfile.refusesNewFiles(rel) || AccountIndex.isArchiveName(n.name) { continue }
                let kids = (n.children ?? []).filter(\.isDirectory)
                let people = kids.filter { k in (k.children ?? []).contains { $0.isDirectory && $0.name == "Visits" } }
                if people.count >= 2, kids.contains(where: { $0.name == "Insurance" }) { found = (rel, n); return }
                visit(kids, rel, depth: depth + 1)
            }
        }
        visit(taxonomy, "", depth: 0)
        return found
    }

    /// The person folder (name) whose filed pages printed one of `numbers`, by the memory's hashed
    /// identifiers; nil when none does or two different people do.
    static func person(for numbers: [String], memory: FilingMemory?, medicalRoot: String,
                       people: Set<String>) -> String? {
        guard let memory, !numbers.isEmpty else { return nil }
        let hashes = Set(numbers.map { FilingMemory.hash($0, salt: memory.salt) })
        var found: Set<String> = []
        for (folder, entry) in memory.folders where folder.hasPrefix(medicalRoot + "/") {
            guard entry.idHashes.contains(where: { hashes.contains($0.token) }) else { continue }
            let first = folder.dropFirst(medicalRoot.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if people.contains(first) { found.insert(first) }
        }
        return found.count == 1 ? found.first : nil
    }

    // MARK: Names

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static func dayLabel(_ d: DocumentFacts.Period) -> String {
        "\(monthNames[d.month - 1]) \(d.day.map(String.init).map { $0 + " " } ?? "")\(d.year)"
    }
    private static let numberedRE = try! NSRegularExpression(pattern:
        #"^(\d{1,2})\. (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(?: (\d{1,2}))? ((?:19|20)\d\d)\b"#)

    /// `N. Mon D YYYY - <kind>`, N the visit's place by date among the year folder's numbered
    /// visits: after the last, or sharing a same-day visit's number. A visit dated before the
    /// folder's newest would renumber the rest, which is his to do: nil then.
    static func visitName(_ d: DocumentFacts.Period, label: String, existing: [String], ext: String) -> String? {
        var dated: [(n: Int, width: Int, date: DocumentFacts.Period)] = []
        for name in existing {
            let ns = name as NSString
            guard let m = numberedRE.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))),
                  let mon = monthNames.firstIndex(of: ns.substring(with: m.range(at: 2))),
                  let y = Int(ns.substring(with: m.range(at: 4))) else { continue }
            let day = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)))
            dated.append((n, ns.substring(with: m.range(at: 1)).count, .init(year: y, month: mon + 1, day: day)))
        }
        let number: Int
        if let same = dated.first(where: { $0.date.year == d.year && $0.date.month == d.month && $0.date.day == d.day }) {
            number = same.n
        } else if let newest = dated.max(by: { $0.date < $1.date }) {
            guard !(d < newest.date) else { return nil }
            number = (dated.map(\.n).max() ?? 0) + 1
        } else {
            number = 1
        }
        let wide = dated.contains { $0.width >= 2 } || Set(dated.map(\.n)).count + 1 >= 12
        let n = wide ? String(format: "%02d", number) : String(number)
        return "\(n). \(dayLabel(d)) - \(label)" + (ext.isEmpty ? "" : "." + ext)
    }

    /// `Kaiser EOB - Dec 2 2025`, when the page names the issuer.
    static func insuranceName(_ kind: Kind, issuer: String, date d: DocumentFacts.Period, ext: String) -> String {
        let doc: String
        switch kind {
        case .eob: doc = "EOB"
        case .bill(let label): doc = label
        default: doc = "Claim"
        }
        return "\(issuer) \(doc) - \(dayLabel(d))" + (ext.isEmpty ? "" : "." + ext)
    }

    static func issuer(in lower: String) -> String? {
        has(#"\bkaiser\b"#, String(lower.prefix(1200))) ? "Kaiser" : nil
    }

    // MARK: The pass

    static func placing(_ suggestions: [FilingSuggestion], pages: [String: String], taxonomy: [FileNode],
                        root: String, memory: FilingMemory?) -> [FilingSuggestion] {
        guard let (medPath, medNode) = medicalRoot(in: taxonomy) else { return suggestions }
        let kids = (medNode.children ?? []).filter(\.isDirectory)
        let people = Set(kids.filter { k in (k.children ?? []).contains { $0.isDirectory && $0.name == "Visits" } }.map(\.name))
        return suggestions.map { s in
            guard let page = pages[s.filePath], !(s.best?.remembered ?? false) else { return s }
            let lower = page.lowercased()
            guard let kind = kind(of: lower),
                  let d = kind == .testResult ? newestDate(in: lower) : date(in: lower) else { return s }
            let ext = (s.fileName as NSString).pathExtension.lowercased()
            var segments: [String]
            var reason: String
            var name: String?
            let confidence: FilingConfidence
            if kind.isInsurance {
                segments = ["Insurance", kind.folder]
                reason = "Billing and coverage go to Insurance, whoever they name"
                name = issuer(in: lower).map { insuranceName(kind, issuer: $0, date: d, ext: ext) }
                confidence = .medium
            } else {
                guard let who = person(for: recordNumbers(in: page), memory: memory, medicalRoot: medPath,
                                       people: people) else { return s }
                segments = [who, kind.folder]
                reason = "Medical record number on page 1 is \(who)’s"
                confidence = .high
            }
            // Inside the kind's folder, a year folder when it keeps them; for a folder this person
            // doesn't have yet, as the same kind of folder does for anyone else.
            let kindNode = AccountProposal.node(at: medPath + "/" + segments.joined(separator: "/"), in: taxonomy)
            func keepsYears(_ n: FileNode?) -> Bool {
                (n?.children ?? []).contains { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name) }
            }
            // Billing kinds sit side by side under Insurance; a person's kinds repeat across people.
            let yearly = kindNode.map(keepsYears) ?? (kind.isInsurance
                ? ((kids.first { $0.name == "Insurance" }?.children ?? []).contains { $0.isDirectory && keepsYears($0) })
                : kids.contains { k in keepsYears((k.children ?? []).first { $0.isDirectory && $0.name == kind.folder }) })
            let filesHere = yearly ? (kindNode?.children ?? []).first { $0.isDirectory && $0.name == String(d.year) } : kindNode
            if yearly { segments.append(String(d.year)) }
            if case .visit(let label) = kind {
                let existing = (filesHere?.children ?? []).filter { !$0.isDirectory }.map(\.name)
                name = visitName(d, label: label, existing: existing, ext: ext)
            }
            let rel = medPath + "/" + segments.joined(separator: "/")
            let path = root + "/" + rel
            let dest = FilingDestination(path: path, confidence: confidence, reasons: [reason], newSegments: AccountProposal.missing(rel, in: taxonomy),
                                         fromContent: true, proposedName: name, nameOrigin: name == nil ? .planner : .template)
            let rest = s.candidates.filter { $0.path != path }
            return s.replacingCandidates([dest] + rest)
        }
    }
}
