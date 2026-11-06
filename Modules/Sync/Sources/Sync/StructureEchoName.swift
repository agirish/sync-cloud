import Foundation

/// Two names for one thing — and it is two rules, not one (ROADMAP v5 §5.2).
///
/// A child echoing its parent (`PG&E/PGE`) and two siblings echoing each other (`Form W-2` beside
/// `Form W2`) need different code, but are one kind with two sub-rules: the card says which through
/// ``StructureFinding/EchoRelation``, and the store suppresses both under one raw value.
///
/// The echo test is ``StructureDetectors/normalized(_:)`` (letters and digits only), so
/// punctuation, case and spacing differences are echoes. The sibling rule's fix is a merge
/// (`Form W2 → Form W-2`), so this detector's plan inherits §5.4 whole.
enum StructureEchoName {

    static func findings(in profile: FolderProfile,
                         childrenByParent: [String: [String]]) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for (family, children) in childrenByParent {
            let parentName = (family as NSString).lastPathComponent
            let parentNormal = StructureDetectors.normalized(parentName)

            // A child restating its parent. The parent's normal form can be empty for a name of
            // pure punctuation; an empty echo is no echo.
            if !parentNormal.isEmpty {
                for child in children
                where StructureDetectors.normalized((child as NSString).lastPathComponent)
                    == parentNormal {
                    out.append(StructureFinding(
                        kind: .echoName, family: family, subject: child,
                        detail: .echoName(counterpart: family, relation: .parentChild)))
                }
            }

            // Two siblings spelling one name differently. The subject is each spelling after the
            // lexicographic first, so three spellings yield two findings with distinct ids. The
            // counterpart is a stable anchor, not a judgement about which spelling to keep.
            let byNormal = Dictionary(grouping: children) {
                StructureDetectors.normalized(($0 as NSString).lastPathComponent)
            }
            for (normal, paths) in byNormal where !normal.isEmpty && paths.count > 1 {
                let sorted = paths.sorted()
                for subject in sorted.dropFirst() {
                    out.append(StructureFinding(
                        kind: .echoName, family: family, subject: subject,
                        detail: .echoName(counterpart: sorted[0], relation: .sibling)))
                }
            }
        }
        return out
    }
}
