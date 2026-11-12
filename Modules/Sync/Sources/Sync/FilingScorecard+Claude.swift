import Foundation

// MARK: - What Claude is told (decision NJ)

extension FilingScorecard {

    /// The range filing_scorecard was asked for: "30", "90" or "all"; 30 days otherwise.
    public static func range(named name: String?) -> Range {
        switch name?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "90", "90 days", "days90": return .days90
        case "all", "all time": return .all
        default: return .days30
        }
    }

    /// The scorecard as filing_scorecard tells it: counts, and the names of top-level areas, never
    /// a file or a folder below them. A filing whose file, offered folder or landing folder is
    /// hidden from Claude is left out before anything is counted, so no total can say it happened.
    public static func forClaude(_ records: [Record], range: Range, isHidden: (String) -> Bool,
                                 now: Date = Date()) -> String {
        let visible = records.filter { r in
            ![r.file, r.landed, r.offered].compactMap { $0 }.contains(where: isHidden)
        }
        let s = summary(visible, range: range, now: now)
        let span: String = switch range {
        case .days30: "Last 30 days"
        case .days90: "Last 90 days"
        case .all: "Since counting began"
        }
        func share(_ t: Tally) -> String { "\(t.label) \(t.kept)/\(t.total)" }
        var lines: [String] = []
        if s.all.total == 0 {
            lines.append("\(span): no filing of this Mac’s first pick counted yet.")
        } else {
            var changed = "changed \(s.all.changed)"
            let kinds = [(s.runnerUp, "to the runner-up"), (s.newFolder, "to a folder they made"), (s.other, "elsewhere")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            if !kinds.isEmpty { changed += " (" + kinds.joined(separator: ", ") + ")" }
            lines.append("\(span): kept the first folder offered \(s.all.kept) of \(s.all.total), one folder deeper \(s.all.deeper), \(changed).")
            if !s.byConfidence.isEmpty { lines.append("By confidence: " + s.byConfidence.map(share).joined(separator: ", ") + ".") }
            if !s.byEvidence.isEmpty { lines.append("By what picked it: " + s.byEvidence.map(share).joined(separator: ", ") + ".") }
            let areas = s.byArea.filter { $0.total >= 5 }
            if !areas.isEmpty { lines.append("Areas with 5 or more: " + areas.map(share).joined(separator: ", ") + ".") }
        }
        if s.refine.total > 0 { lines.append("Claude’s picks (Refine and its new folders): kept \(s.refine.kept) of \(s.refine.total).") }
        if s.rules > 0 { lines.append("Filed by their rules: \(s.rules).") }
        lines.append("Counts only, from filings they applied; nothing is counted for files hidden from you. It says how often the folder offered first was the one they kept, not whether a folder is right.")
        return lines.joined(separator: "\n")
    }
}
