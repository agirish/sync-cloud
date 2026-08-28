import Foundation

/// Two names for one thing — and it is two rules, not one (ROADMAP_V5 §5.2).
///
/// A **child echoing its parent** (`PG&E/PGE`) and **two siblings echoing each other** (`Form W-2`
/// beside `Form W2`) need different code and return different things, but they are one kind with
/// two sub-rules: the card says which shape it found through
/// ``StructureFinding/EchoRelation``, and the store suppresses them under one raw value.
///
/// The echo test is ``StructureDetectors/normalized(_:)`` — names reduced to their letters and
/// digits — so punctuation, case and spacing differences are echoes and genuinely different
/// names are not. The sibling rule's only real hit here is a **merge** (`Form W2 → Form W-2`),
/// which is why this detector's plan inherits §5.4 whole.
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

            // Two siblings spelling one name differently. One finding per pair; the subject is
            // each spelling AFTER the lexicographic first, so three spellings of one name yield
            // two findings with two distinct subjects rather than one id twice — the counterpart
            // is a stable anchor, not a judgement about which spelling the mapping should keep.
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
