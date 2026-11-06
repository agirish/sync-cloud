import Foundation

/// What a folder's emptiness is, when it is empty enough to classify (ROADMAP v5 §5.2).
///
/// Crowding is a property of the scope, not a finding (it is never zero on a real tree), so these
/// never become cards or badges. The lens shows them as the crowding strip's three counts, and only
/// ``empty`` has an action, the removal sheet (see `StructureDeadWeight` for why).
public enum DeadWeightClass: String, Equatable, Sendable, CaseIterable {
    /// No files, exactly one subfolder — `A/B/…` that could be `A/…`.
    case passThrough
    /// Exactly one file, no subfolders.
    case singleFileLeaf
    /// Nothing at all.
    case empty
}

/// Everything the structure detectors saw in one profile: the findings, and the per-folder
/// crowding classification the strip counts.
public struct StructureReport: Equatable, Sendable {
    public let findings: [StructureFinding]
    /// Path → its dead-weight class, for every folder that has one.
    public let deadWeight: [String: DeadWeightClass]

    public init(findings: [StructureFinding], deadWeight: [String: DeadWeightClass]) {
        self.findings = findings
        self.deadWeight = deadWeight
    }

    public static let empty = StructureReport(findings: [], deadWeight: [:])
}

/// The whole detector set behind one call — pure functions of the profile, like the shape
/// detector that ships (ROADMAP v5 §5.8).
///
/// Scope is deliberately not a parameter. The report is computed once per profile and cached
/// behind `FileSyncManager.structureReport`; the lens scopes it by path prefix at render time. A
/// scoped cache would add invalidation to get wrong, for no measured win.
public enum StructureDetectors {

    public static func run(in profile: FolderProfile) -> StructureReport {
        // Built once and handed to every detector: rebuilt per detector or per family child, the
        // work is O(folders²) and stalls Organize's first visit.
        let children = StructureDivergence.families(in: profile)
        var findings = StructureDivergence.findings(in: profile, childrenByParent: children)
        findings += StructureBacklog.findings(in: profile, childrenByParent: children)
        findings += StructureShadowAxis.findings(in: profile, childrenByParent: children)
        findings += StructureEchoName.findings(in: profile, childrenByParent: children)
        findings += StructureMirroredInbox.findings(in: profile)
        findings += StructureLooseFiles.aboveSeries(in: profile, childrenByParent: children)
        findings += StructureLooseFiles.besideContainer(in: profile, childrenByParent: children)
        return StructureReport(findings: grouped(findings),
                               deadWeight: StructureDeadWeight.classify(profile))
    }

    /// §5.2's grouping rule: two detectors may name one folder, but scattered down the list that
    /// reads as a bug. So a folder's rows sort together, kinds in declared order, and the lens lets
    /// the first carry the path as a heading. No precedence table has to rank the observations.
    static func grouped(_ findings: [StructureFinding]) -> [StructureFinding] {
        let order = Dictionary(uniqueKeysWithValues:
            FindingKind.allCases.enumerated().map { ($0.element, $0.offset) })
        let sorted = findings.sorted {
            ($0.subject, order[$0.kind] ?? .max) < ($1.subject, order[$1.kind] ?? .max)
        }
        // One row per identity: one kind's two sub-rules can see a folder twice (a child echoing
        // its parent and a sibling), and `ForEach` over two rows with one id renders one twice.
        // The sort makes "first wins" stable.
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.id).inserted }
    }

    /// Name → tokens, for the rules that compare names: lowercased runs of letters and digits.
    /// Deliberately not `FilingRouter.tokenize`; see `FolderSurveyBuilder.anchorWords` on why
    /// tokenizers aren't unified.
    static func tokens(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A name reduced to its letters and digits — the echo test: `PG&E` and `PGE` are one name,
    /// `Form W-2` and `Form W2` are one name.
    static func normalized(_ name: String) -> String {
        tokens(name).joined()
    }
}
