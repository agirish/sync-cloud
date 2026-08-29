import Foundation

/// The one moment a backlog finding is worth saying out loud (ROADMAP_V5 §5.6; proposal O15).
///
/// **§5.6's argument is "say it the month it happens", and the build only says it if the lens is
/// open.** A backlog finding — a year folder its siblings have shapes for and it does not — is
/// most useful in January, and least useful in November when the year is nearly filed. Nothing
/// carried it out of the Restructure lens, so the one detector whose value is time-sensitive was
/// the one that waited to be visited.
///
/// This is the rule that decides. It is deliberately narrow:
///
/// - **The current year only.** A backlog for 2024 in 2026 is a fact about the tree, not news;
///   the lens has said so all along and the overview does not repeat it.
/// - **Once per finding per year.** Acknowledging records the year, so the same folder can raise
///   it again next January when a fresh year arrives with the same gap — which is exactly the
///   recurrence §5.6 describes and not a nag about the same one.
/// - **A line, never a card.** The overview's counted lenses have documented can't-close-the-ratio
///   invariants; a nudge that joined the count would break them. It reports, and offers the verb.
public enum RestructureNudge {

    /// A backlog finding whose subject names the current year, with the year it names.
    public struct Due: Equatable, Sendable {
        public let finding: StructureFinding
        /// The four-digit year the subject's last component spells — also what an acknowledgement
        /// records, so next year's gap is a fresh nudge rather than a suppressed one.
        public let year: String

        public init(finding: StructureFinding, year: String) {
            self.finding = finding
            self.year = year
        }
    }

    /// The findings worth one quiet line right now.
    ///
    /// `acknowledged` maps a finding's key to the year it was last dismissed for — a *year*, not a
    /// flag, because "I know about 2026" must not silence 2027. Suppression is separate and
    /// stronger: a suppressed finding never reaches `visibleStructureFindings` at all, so it
    /// cannot reach this.
    ///
    /// `alreadyScaffolded` is the same set the card and the menu read, and **not passing it was a
    /// defect**: `applyScaffold` deliberately does not re-derive the profile, so a backlog finding
    /// stays in `visibleStructureFindings` verbatim after its folders have been created. The card
    /// handles that by swapping its button for "Scaffolded — the survey hasn't caught up yet"; a
    /// nudge that did not would keep saying "2026 has files but no folders yet" about folders that
    /// now exist, and its Set up… would hand off to a resolver that refuses with "there is no
    /// longer a finding for that folder" — false in both clauses.
    public static func due(in findings: [StructureFinding],
                           now: Date,
                           acknowledged: [RestructureKey: String],
                           alreadyScaffolded: Set<String> = [],
                           calendar: Calendar = .current) -> [Due] {
        let thisYear = String(calendar.component(.year, from: now))
        return findings.compactMap { finding -> Due? in
            guard finding.kind == .backlog else { return nil }
            // Only a scaffold that has something to create: a backlog whose siblings vouch for
            // nothing has no verb to offer, and a line with no action is the caution people learn
            // to scroll past.
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

    /// The four-digit year a subject's last component spells, or nil.
    ///
    /// `looksLikeYear` also accepts a fiscal span (`2014-2015`), which a nudge must not treat as
    /// "this year" on the strength of either half — a span is a deliberate two-year folder and
    /// the month it happens is not a thing about it. So this takes bare years only, and reuses
    /// the shared shape test rather than growing a second year parser.
    public static func year(of subject: String) -> String? {
        let last = (subject as NSString).lastPathComponent
        guard FolderProfileEntry.looksLikeYear(last), !last.contains("-") else { return nil }
        return last
    }

    /// The line itself — one sentence naming what has no folders yet.
    ///
    /// Written as a statement about the tree, not an instruction: the overview reports, and the
    /// verb beside it is where acting happens. Two families are named; beyond that it counts,
    /// because a sentence listing nine is a list wearing a sentence's punctuation.
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
