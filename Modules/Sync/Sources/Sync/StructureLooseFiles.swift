import Foundation

/// The two detectors `ROADMAP.md` 20 listed and every draft after it dropped, recovered and
/// measured on 2026-08-20 (ROADMAP_V5 §5.2).
enum StructureLooseFiles {

    /// A year run needs this many bare-year children before files beside it read as parked.
    /// Below three, a folder with a couple of years and some files is just a folder.
    static let minimumSeriesFolders = 3

    /// And this many parked files before the parking reads as a habit rather than an accident.
    /// Swept against the reference tree on 2026-08-28: 1 → 38 hits, 2 → 20, 3 → 15, 4 → 10 —
    /// and at 4 the one-stray-closure-letter hits (a single file above a closed account's
    /// archive) stop dominating the list. The three hits the roadmap names survive at 4 with
    /// room (22, 5, 5).
    static let minimumLooseFiles = 4

    /// **Loose above a series**: files parked in the parent of a year run that has folders for
    /// them — `Fidelity/Statements` holding 22 files above 4 year folders, because a statement
    /// gets saved to the folder rather than into the year. The second-best detector on this tree
    /// after backlog, and the closest thing here to an everyday one.
    ///
    /// Its fix is per-file — *which* year each file belongs to is a judgement — so it hands off
    /// to To File exactly as the scaffold does, and carries no plan of its own
    /// (``FindingKind/carriesPlan``).
    ///
    /// The family is the subject itself: the finding is about the folder's own files against its
    /// own children, and setting `family == subject` is what groups it with a shape finding about
    /// the same folder (`Finance/US/Income Tax` produces both).
    static func aboveSeries(in profile: FolderProfile,
                            childrenByParent: [String: [String]]) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for (parent, children) in childrenByParent {
            guard let entry = profile.folders[parent],
                  entry.fileCount >= minimumLooseFiles else { continue }
            let seriesFolders = children.count {
                StructureDivergence.isBareYear(($0 as NSString).lastPathComponent)
            }
            guard seriesFolders >= minimumSeriesFolders else { continue }
            out.append(StructureFinding(
                kind: .looseAboveSeries, family: parent, subject: parent,
                detail: .looseAboveSeries(looseFiles: entry.fileCount,
                                          seriesFolders: seriesFolders)))
        }
        return out
    }

    /// **Loose beside a container**: a leaf whose name restates a container sibling's and adds to
    /// it — `Home/ATT Bill` beside `Home/ATT/`, `Products/Nova PE` beside `Nova/` — token
    /// subset, not string prefix, so `City Pre-K` finds `Pre-K`.
    ///
    /// Three guards, each killing a measured junk class (reference tree, 2026-08-28):
    /// - **all-digits, on both sides** — version numbers tokenise into subsets of each other
    ///   (`5.2.1` "inside" `5.1.1`), the 2026-08-20 measurement's original junk;
    /// - **the loose one is a leaf with files** — `H-4 EAD` has four era subfolders and is a
    ///   parallel family, not a stray;
    /// - **the container has subfolders** — `Archive/HDFC Savings` beside a flat `Archive/HDFC`
    ///   is six accounts sharing a brand word with a pile of loose files, and "move the accounts
    ///   into the pile" is the finding backwards. The name-token rule alone fired 38 here; with
    ///   the shape conditions it is 2 for 2 — the roadmap's own two hits.
    static func besideContainer(in profile: FolderProfile,
                                childrenByParent: [String: [String]]) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for (family, children) in childrenByParent {
            let named = children.compactMap { path -> (path: String, tokens: Set<String>)? in
                let tokens = Set(StructureDetectors.tokens((path as NSString).lastPathComponent))
                guard !tokens.isEmpty,
                      tokens.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
                return (path, tokens)
            }
            guard named.count >= 2 else { continue }
            for loose in named {
                guard let looseEntry = profile.folders[loose.path],
                      looseEntry.subfolderCount == 0, looseEntry.fileCount > 0 else { continue }
                // The smallest container whose name the loose sibling restates, so `ATT Bill`
                // beside both `ATT` and (hypothetically) `ATT Bill Archive` points at `ATT`.
                let container = named
                    .filter {
                        $0.path != loose.path && $0.tokens.isStrictSubset(of: loose.tokens)
                            && (profile.folders[$0.path]?.subfolderCount ?? 0) > 0
                    }
                    .min { $0.tokens.count < $1.tokens.count }
                guard let container else { continue }
                out.append(StructureFinding(
                    kind: .looseBesideContainer, family: family, subject: loose.path,
                    detail: .looseBesideContainer(container: container.path)))
            }
        }
        return out
    }
}
