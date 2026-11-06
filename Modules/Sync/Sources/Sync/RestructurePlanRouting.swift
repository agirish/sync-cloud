import Foundation

/// Which plan surface a finding opens: the geometry question, answered once in a pure function.
/// Every fix a finding states is a pair, two paths one of which stops existing, and what matters is
/// where the two sit:
///
/// - Under one parent (a sibling echo, a shadowed year): the pair is one row of the family mapping,
///   so it opens the mapping sheet seeded, and the derivation, drafts, Export and Apply follow the
///   usual path.
/// - Across parents (an inbox mirroring its destination, a loose folder beside its container, a
///   child echoing its parent): a mapping row renames a child within its member and can't move a
///   folder to another parent. These get
///   ``RestructurePlanner/pairMergeManifest(source:destination:kind:in:profileId:manifestId:createdAt:note:)``
///   and a confirm sheet over the derived operations.
public enum RestructurePlanRoute: Equatable, Sendable {
    /// The whole family, with the mapping editor's shape step: `shape`'s own route.
    case familyMapping(family: String)
    /// The mapping sheet over one member, seeded with the pair's row. `member` is a child name of
    /// `family`, so `family/member` is the folder both paths sit in.
    case seededMapping(family: String, member: String, source: String, target: String)
    /// A cross-parent merge, derived directly. `destination` is where the source's contents end up:
    /// an existing folder to merge into, or a name that doesn't exist yet, which makes it one
    /// `move-dir`.
    case pairMerge(source: String, destination: String)
}

public enum RestructurePlanRouting {

    /// The route a finding opens, or nil for the kinds that don't end in a plan. Exhaustive over
    /// ``StructureFinding/Detail`` on purpose, so a new detector must be decided here to compile.
    public static func route(for finding: StructureFinding) -> RestructurePlanRoute? {
        switch finding.detail {
        case nil where finding.kind == .shape:
            return .familyMapping(family: finding.family)

        case .shadowAxis(let target, _):
            // Both spellings are children of the family: one mapping row, and the planner decides
            // rename or merge from whether the bare year is standing. The detector's `targetExists`
            // says the same; deriving it twice invites the two to disagree.
            return seeded(finding, target: target)

        case .echoName(let counterpart, .sibling):
            return seeded(finding, target: (counterpart as NSString).lastPathComponent)

        case .echoName(let counterpart, .parentChild):
            // The child's contents move up into the parent: a different parent, so not a mapping
            // row.
            return .pairMerge(source: finding.subject, destination: counterpart)

        case .mirroredInbox(let destination):
            return .pairMerge(source: finding.subject, destination: destination)

        case .looseBesideContainer(let container):
            // The folder itself moves into the container, keeping its name. When the container has
            // no such child yet (the usual case) the planner emits one `move-dir` and the files
            // ride along, as the card promises.
            return .pairMerge(
                source: finding.subject,
                destination: (container as NSString)
                    .appendingPathComponent((finding.subject as NSString).lastPathComponent))

        // Named rather than defaulted, so a new detail case has to be decided here.
        //
        // `duplicatedTaxonomy` stays unrouted. Its pair is a merge, but most of what it fires on
        // (pinned in `StructureDuplicatedTaxonomyTests`) are correct parallels: one statement
        // covering two accounts, filed under both, makes the smaller folder a `.sameText` partner
        // of the larger, and `Plan…` would offer to merge two accounts' folders. No share threshold
        // separates them; it needs a rule that tells "the same document belongs in both" from
        // "these are two taxonomies".
        case .backlog, .looseAboveSeries, .duplicatedTaxonomy, nil:
            return nil
        }
    }

    /// Whether this finding's card offers a plan trigger at all.
    public static func carriesPlanSurface(_ finding: StructureFinding) -> Bool {
        route(for: finding) != nil
    }

    /// The pair-under-one-parent route: the family is the pair's grandparent and the single member
    /// is the folder they both sit in, because the mapping's unit is a child name inside a member.
    /// Pointing the family at the parent would map the parent's siblings instead.
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
