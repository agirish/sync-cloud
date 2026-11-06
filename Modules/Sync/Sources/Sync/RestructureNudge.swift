import Foundation

/// When a backlog finding (a year folder its siblings have shapes for and it lacks) is worth saying
/// outside the Restructure lens. It matters most early in that year, so it shouldn't wait for the
/// lens to be opened. Deliberately narrow:
///
/// - The current year only. An older backlog is a fact about the tree, which the lens already
///   shows.
/// - Once per finding per year. Acknowledging records the year, so the same folder can raise it
///   again next January when a new year arrives with the same gap.
/// - A line, never a card. The overview's counted lenses have ratio invariants a nudge in the count
///   would break. It reports and offers the verb.
public enum RestructureNudge {

    /// A backlog finding whose subject names the current year, with the year it names.
    public struct Due: Equatable, Sendable {
        public let finding: StructureFinding
        /// The four-digit year the subject's last component spells. Also what an acknowledgement
        /// records, so next year's gap is a fresh nudge rather than a suppressed one.
        public let year: String

        public init(finding: StructureFinding, year: String) {
            self.finding = finding
            self.year = year
        }
    }

    /// The findings worth one quiet line right now.
    ///
    /// `acknowledged` maps a finding's key to the year it was last dismissed for: a year, not a
    /// flag, so dismissing 2026 doesn't silence 2027. A suppressed finding never reaches
    /// `visibleStructureFindings`, so it can't reach this either.
    ///
    /// Pass `alreadyScaffolded`, the set the card and menu read. `applyScaffold` doesn't re-derive
    /// the profile, so a backlog finding stays visible after its folders are created; without the
    /// set the nudge would claim folders are missing that now exist, and its Set up… would be
    /// refused.
    public static func due(in findings: [StructureFinding],
                           now: Date,
                           acknowledged: [RestructureKey: String],
                           alreadyScaffolded: Set<String> = [],
                           calendar: Calendar = .current) -> [Due] {
        let thisYear = String(calendar.component(.year, from: now))
        return findings.compactMap { finding -> Due? in
            guard finding.kind == .backlog else { return nil }
            // Only a scaffold with something to create: a line with no verb to offer is a caution
            // people learn to scroll past.
            guard case .backlog(let scaffold, _)? = finding.detail, !scaffold.isEmpty else {
                return nil
            }
            guard !alreadyScaffolded.contains(finding.subject) else { return nil }
            guard year(of: finding.subject) == thisYear else { return nil }
            guard acknowledged[RestructureKey(kind: finding.kind, path: finding.subject)]
                    != thisYear else { return nil }
            return Due(finding: finding, year: thisYear)
        }
    }

    /// The four-digit year a subject's last component spells, or nil. Bare years only:
    /// `looksLikeYear` also accepts a fiscal span (`2014-2015`), a deliberate two-year folder that
    /// neither half should make "this year".
    public static func year(of subject: String) -> String? {
        let last = (subject as NSString).lastPathComponent
        guard FolderProfileEntry.looksLikeYear(last), !last.contains("-") else { return nil }
        return last
    }

    /// The line itself: one sentence naming what has no folders yet. A statement about the tree,
    /// not an instruction, since the verb beside it is where acting happens. Names two families,
    /// then counts the rest.
    public static func sentence(for due: [Due]) -> String? {
        guard let year = due.first?.year, !due.isEmpty else { return nil }
        let families = due.map { ($0.finding.subject as NSString).deletingLastPathComponent }
        let unique = NSOrderedSet(array: families).array as? [String] ?? families
        let named: String
        switch unique.count {
        case 1: named = unique[0]
        case 2: named = "\(unique[0]) and \(unique[1])"
        default:
            named = "\(unique[0]), \(unique[1]) and \(unique.count - 2) more"
        }
        return "\(year) has files but no folders yet in \(named)."
    }
}
