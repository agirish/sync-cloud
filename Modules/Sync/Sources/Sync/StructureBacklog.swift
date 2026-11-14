import Foundation

/// The newest instance of a recurring series has no folders yet (ROADMAP v5 §5.2).
///
/// `Health/Dental/2025` holds this year's claims flat while `2019`–`2024` each hold `Claims/` and
/// `Statements/`. Worth saying the month it happens, so this is the everyday detector.
///
/// The fix is a scaffold: create the folders the family's vouched vocabulary expects, nothing
/// else, and hand the flat files to To File for per-file judgements. When the shaped siblings
/// vouch for no shared scheme, the finding still fires with an empty scaffold, and the card says
/// there is nothing to copy.
enum StructureBacklog {

    /// The scaffold copies only a scheme this many shaped members vouch for: two folders agreeing
    /// is the least evidence of a convention, as in
    /// ``StructureDivergence/AgreementRule/minimumMembers``.
    static let minimumVouchingMembers = 2

    /// The firing bar is lower than the scaffold's: one older shaped sibling makes the newest
    /// member's flatness a finding. Requiring two would silence families like `Health/Dental`,
    /// whose older years are shaped one at a time; on the reference tree, two finds 2 and one
    /// finds 11, all plausible.
    static func findings(in profile: FolderProfile,
                         childrenByParent: [String: [String]]) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for (family, children) in childrenByParent {
            let years = children.compactMap { path -> (path: String, year: Int)? in
                let name = (path as NSString).lastPathComponent
                guard StructureDivergence.isBareYear(name), let year = Int(name) else { return nil }
                return (path, year)
            }
            guard years.count >= 2 else { continue }

            guard let newest = years.max(by: { $0.year < $1.year }),
                  let entry = profile.folders[newest.path],
                  entry.subfolderCount == 0, entry.fileCount > 0 else { continue }

            let shaped = years.filter {
                $0.path != newest.path && (profile.folders[$0.path]?.subfolderCount ?? 0) > 0
            }
            guard !shaped.isEmpty else { continue }

            out.append(StructureFinding(
                kind: .backlog, family: family, subject: newest.path,
                detail: .backlog(scaffold: scaffold(for: shaped.map(\.path), in: profile,
                                                    childrenByParent: childrenByParent),
                                 looseFiles: entry.fileCount)))
        }
        return out
    }

    /// What to create: the vouched vocabulary of the scheme the most recent shaped member belongs
    /// to, so a family mid-migration scaffolds its current shape. Empty when no two shaped members
    /// agree: one sibling's quirk (`Benefits/2024/Archive`) must not become next year's convention.
    ///
    /// The names are that member's own child names, as spelled on disk:
    /// ``StructureDivergence/vocabulary(of:in:)`` lowercases, and scaffolding `claims/` beside
    /// `Claims/` would create a new divergence.
    static func scaffold(for shapedPaths: [String], in profile: FolderProfile,
                         childrenByParent: [String: [String]]) -> [String] {
        let vocabularies = shapedPaths.compactMap { path -> (name: String, words: Set<String>)? in
            let words = StructureDivergence.vocabulary(of: path, in: profile,
                                                       childrenByParent: childrenByParent)
            guard !words.isEmpty else { return nil }
            return ((path as NSString).lastPathComponent, words)
        }
        let vouched = StructureDivergence.cluster(vocabularies)
            .filter { $0.count >= minimumVouchingMembers }
        // Members arrive sorted by path, and bare years sort chronologically — so the group
        // holding the largest name holds the most recent shaped member.
        guard let current = vouched.max(by: { ($0.last?.name ?? "") < ($1.last?.name ?? "") }),
              let recent = current.last,
              let recentPath = shapedPaths.first(where: {
                  ($0 as NSString).lastPathComponent == recent.name
              })
        else { return [] }
        let shared = current.dropFirst().reduce(current[0].words) { $0.intersection($1.words) }
        return StructureDivergence.displayNames(of: recentPath, in: profile, childrenByParent: childrenByParent)
            .filter { shared.contains($0.lowercased()) }
            .sorted()
    }
}
