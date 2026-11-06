import Foundation

/// Two loose-file detectors: files parked above a year run, and a folder beside the container it
/// belongs in (ROADMAP v5 §5.2).
enum StructureLooseFiles {

    /// A year run needs this many bare-year children before files beside it read as parked.
    /// Below three, a folder with a couple of years and some files is just a folder.
    static let minimumSeriesFolders = 3

    /// And this many parked files before the parking reads as a habit rather than an accident. On
    /// the reference tree, 4 is where single stray files above a closed account's archive stop
    /// dominating the list, and the roadmap's named hits all survive.
    static let minimumLooseFiles = 4

    /// Loose above a series: files parked in the parent of a year run that has folders for them,
    /// such as `Fidelity/Statements` holding 22 files above 4 year folders, because statements get
    /// saved to the folder rather than into the year.
    ///
    /// Its fix is per-file (which year each belongs to is a judgement), so it hands off to To File
    /// like the scaffold and carries no plan (``FindingKind/carriesPlan``). `family == subject`, so
    /// it groups with a shape finding about the same folder.
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

    /// Loose beside a container: a leaf whose name restates a container sibling's and adds to it
    /// (`Home/ATT Bill` beside `Home/ATT/`). Token subset, not string prefix, so `City Pre-K` finds
    /// `Pre-K`.
    ///
    /// Three guards, each removing a class of junk hits:
    /// - names need a letter: version numbers tokenise into subsets of each other (`5.2.1` "inside"
    ///   `5.1.1`);
    /// - the loose one is a leaf with files: `H-4 EAD` with era subfolders is a parallel family;
    /// - the container has subfolders: `Archive/HDFC Savings` beside a flat `Archive/HDFC` would
    ///   be the finding backwards.
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
