import Foundation

/// The newest instance of a recurring series has no folders yet (ROADMAP_V5 §5.2).
///
/// `Health/Dental/2025` holds this year's claims flat while `2019`–`2024` each hold `Claims/` and
/// `Statements/` — worth saying the month it happens rather than thirteen years later, which is
/// what makes this the everyday detector in a set whose flagship case took a decade to build up.
///
/// Its fix is the cheapest one in the file: a **scaffold** — create the folders the family's
/// vouched vocabulary expects, nothing else — and a hand-off of the flat files to To File, the
/// surface that already makes per-file judgements. Where the shaped siblings vouch for no shared
/// scheme (all drift), the finding still fires but the scaffold is empty and the card says so:
/// there is nothing to copy, which is itself the observation.
enum StructureBacklog {

    /// The scaffold copies only a scheme this many shaped members vouch for. Two independent
    /// folders agreeing is the cheapest evidence a convention exists — the same bar
    /// ``StructureDivergence/AgreementRule/minimumMembers`` sets, for the same reason.
    static let minimumVouchingMembers = 2

    /// The firing bar is lower than the scaffold's: **one** older shaped sibling makes the newest
    /// member's flatness a finding ("its siblings have folders; this one doesn't yet"), because
    /// requiring two silences `Health/Dental/2025` — a family whose older years are shaped one at
    /// a time. Swept against the reference tree on 2026-08-28: two-shaped returns 2, one-shaped
    /// returns 11, all plausible, both of the roadmap's named examples among them.
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

    /// What to create: the vouched vocabulary of the shaped members — the scheme the most recent
    /// of them belongs to, so a family mid-migration scaffolds its *current* shape, not its
    /// oldest one. Empty when no two shaped members agree, which the card states rather than
    /// papering over with one member's layout: a lone shaped sibling's idiosyncrasy
    /// (`Benefits/2024/Archive`) must not become next year's convention.
    ///
    /// The names are the **most recent vouching member's own child names**, not the vocabulary —
    /// ``StructureDivergence/vocabulary(of:in:)`` lowercases for comparison, and a scaffold of
    /// `claims/` on a tree that spells it `Claims/` would be a new divergence created by the tool
    /// that exists to remove them.
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
        return displayNames(of: recentPath, in: profile, childrenByParent: childrenByParent)
            .filter { shared.contains($0.lowercased()) }
            .sorted()
    }

    /// A folder's non-axis child names as they are spelled on disk — the display-cased twin of
    /// ``StructureDivergence/vocabulary(of:in:childrenByParent:)``, and it reads the same sibling
    /// map for the same reason: it walked every folder in the profile per call.
    static func displayNames(of path: String, in profile: FolderProfile,
                             childrenByParent: [String: [String]]) -> [String] {
        var names: [String] = []
        let prefix = path + "/"
        let parent = profile.folders[path]
        for childPath in childrenByParent[path] ?? [] {
            guard childPath.hasPrefix(prefix) else { continue }
            let relative = String(childPath.dropFirst(prefix.count))
            guard !relative.isEmpty, !relative.contains("/") else { continue }
            guard let entry = profile.folders[childPath] else { continue }
            guard !StructureDivergence.isAxisValued(path: childPath, name: relative, entry: entry,
                                                    parent: parent) else { continue }
            names.append(relative)
        }
        return names
    }
}
