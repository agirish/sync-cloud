import Foundation

/// What a folder's emptiness is, when it is empty enough to classify (ROADMAP_V5 §5.2).
///
/// **Crowding is a property of the scope, not a finding** — always non-zero on a real tree — so
/// these never become cards or take a badge. The lens renders them as the crowding strip's three
/// filtered counts, and only the ``empty`` class has a rule-backed action (the removal sheet):
/// a single-file leaf can be a destination waiting for its next file, and a pass-through folder
/// costs one click in a column view against a rename of every path beneath it.
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
/// detector that ships (ROADMAP_V5 §5.8).
///
/// **Scope is deliberately not a parameter.** The report is computed once per profile and cached
/// behind `FileSyncManager.structureReport`; the lens scopes it at render time by path prefix,
/// which is how `LensWorkspaceView` already treats `structureFindings`. A scoped cache would be a
/// second cache dimension with its own invalidation to get wrong, for no measured win.
public enum StructureDetectors {

    public static func run(in profile: FolderProfile) -> StructureReport {
        let children = StructureDivergence.families(in: profile)
        var findings = StructureDivergence.findings(in: profile)
        findings += StructureBacklog.findings(in: profile, childrenByParent: children)
        findings += StructureShadowAxis.findings(in: profile, childrenByParent: children)
        findings += StructureEchoName.findings(in: profile, childrenByParent: children)
        findings += StructureMirroredInbox.findings(in: profile)
        findings += StructureLooseFiles.aboveSeries(in: profile, childrenByParent: children)
        findings += StructureLooseFiles.besideContainer(in: profile, childrenByParent: children)
        return StructureReport(findings: grouped(findings),
                               deadWeight: StructureDeadWeight.classify(profile))
    }

    /// §5.2's grouping rule, applied at the source: two detectors naming one folder is correct —
    /// they are different observations — but two cards about one folder scattered down the list
    /// reads as a bug. **Sort a folder's rows together**, kinds in their declared order within a
    /// subject, so the lens can let the first row carry the path as a heading. Cheaper than a
    /// precedence table, and it never has to decide which observation matters more.
    static func grouped(_ findings: [StructureFinding]) -> [StructureFinding] {
        let order = Dictionary(uniqueKeysWithValues:
            FindingKind.allCases.enumerated().map { ($0.element, $0.offset) })
        let sorted = findings.sorted {
            ($0.subject, order[$0.kind] ?? .max) < ($1.subject, order[$1.kind] ?? .max)
        }
        // One row per identity, deterministically: a folder can be seen twice by one kind's two
        // sub-rules (a child echoing its parent AND a sibling), and `ForEach` over two rows with
        // one id renders one of them twice. The sort above makes "first wins" stable.
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.id).inserted }
    }

    /// Name → tokens, for the rules that compare names: lowercased runs of letters and digits.
    /// (`FilingRouter.tokenize` deliberately not reused — see `FolderSurveyBuilder`'s measured
    /// .320-vs-.997 note on unifying tokenizers because both make tokens out of names.)
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
