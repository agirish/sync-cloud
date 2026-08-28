import Foundation

/// Which plan surface a finding opens — the **geometry** question, answered once, in a pure
/// function (ROADMAP_V5 §5.4/§5.9; the audit's G2).
///
/// The shipped build offered `Plan…` on shape findings alone, so five kinds stated their fix in
/// the card's blast-radius sentence and then offered only *Reveal*. Every one of those fixes is a
/// **pair** — two paths, one of which stops existing — and the difference that matters is where
/// the two sit relative to each other:
///
/// - **Under one parent** (a sibling echo, a shadowed year) the pair is one row of the family
///   mapping, so it opens the mapping sheet seeded and everything downstream — the derivation,
///   drafts, Export, Apply — is the shipped path, unchanged.
/// - **Across parents** (an inbox mirroring its destination, a loose folder beside its container,
///   a child echoing its parent) the one-level family mapping *cannot express it*: a mapping row
///   renames a child within its member, and these move a folder to a different parent entirely.
///   Those get ``RestructurePlanner/pairMergeManifest(source:destination:kind:in:profileId:manifestId:createdAt:note:)``
///   and a confirm sheet over the derived operations.
public enum RestructurePlanRoute: Equatable, Sendable {
    /// The whole family, with the mapping editor's shape step — `shape`'s own route, unchanged.
    case familyMapping(family: String)
    /// The mapping sheet over ONE member, seeded with the pair's row. `member` is a child name
    /// of `family`, so `family/member` is the folder both paths sit in.
    case seededMapping(family: String, member: String, source: String, target: String)
    /// A cross-parent merge, derived directly. `destination` is where the source's contents end
    /// up — an existing folder to merge into, or a name that does not exist yet, which makes the
    /// whole thing one `move-dir`.
    case pairMerge(source: String, destination: String)
}

public enum RestructurePlanRouting {

    /// The route a finding opens, or nil for the kinds that do not end in a plan.
    ///
    /// Exhaustive over ``StructureFinding/Detail`` on purpose: a detector added later fails to
    /// compile here rather than silently joining the kinds that offer nothing.
    public static func route(for finding: StructureFinding) -> RestructurePlanRoute? {
        switch finding.detail {
        case nil where finding.kind == .shape:
            return .familyMapping(family: finding.family)

        case .shadowAxis(let target, _):
            // Both spellings are children of the family — one mapping row, and the planner
            // decides rename-or-merge from whether the bare year is standing. The detector's
            // `targetExists` says the same thing; deriving it twice is how the two disagree.
            return seeded(finding, target: target)

        case .echoName(let counterpart, .sibling):
            return seeded(finding, target: (counterpart as NSString).lastPathComponent)

        case .echoName(let counterpart, .parentChild):
            // The child's contents move UP into the parent — a different parent, so not a
            // mapping row.
            return .pairMerge(source: finding.subject, destination: counterpart)

        case .mirroredInbox(let destination):
            return .pairMerge(source: finding.subject, destination: destination)

        case .looseBesideContainer(let container):
            // The folder itself moves into the container, keeping its name. When the container
            // has no such child yet — the ordinary case — the planner emits one `move-dir` and
            // the files ride along, which is exactly what the card promises.
            return .pairMerge(
                source: finding.subject,
                destination: (container as NSString)
                    .appendingPathComponent((finding.subject as NSString).lastPathComponent))

        // Named rather than defaulted, so a new detail case has to be decided here.
        // `duplicatedTaxonomy` resolves two branches holding the same documents; its pair is
        // only trustworthy once a duplicate scan has measured it, so it waits for that
        // measurement rather than shipping a plan over an unmeasured claim.
        case .backlog, .looseAboveSeries, .duplicatedTaxonomy, nil:
            return nil
        }
    }

    /// Whether this finding's card offers a plan trigger at all.
    public static func carriesPlanSurface(_ finding: StructureFinding) -> Bool {
        route(for: finding) != nil
    }

    /// The pair-under-one-parent route: the family is the pair's grandparent and the single
    /// member is the folder they both sit in, because the mapping's unit is *a child name inside
    /// a member* — pointing the family straight at the parent would leave the planner mapping
    /// the parent's siblings instead.
    private static func seeded(_ finding: StructureFinding,
                               target: String) -> RestructurePlanRoute {
        let parent = finding.family
        return .seededMapping(
            family: (parent as NSString).deletingLastPathComponent,
            member: (parent as NSString).lastPathComponent,
            source: (finding.subject as NSString).lastPathComponent,
            target: target)
    }
}
