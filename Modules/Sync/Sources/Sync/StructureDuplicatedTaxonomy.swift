import Foundation

/// §5.9: duplicated taxonomy — two folders holding the same documents under parallel taxonomies.
///
/// Built on content only. Matching siblings by child names finds mostly correct parallels (two
/// IRAs, Chase accounts foldered by year). The real case (`Work/Archive/Acme/Compensation/Forms/`
/// against `Finance/US/Income Tax/2016/Forms/`) has the same documents in both: two folders are
/// duplicated taxonomy when a material share of their contents are `.sameText` partners, never
/// merely when their child names agree.
///
/// The one detector that reads a scan, not the profile, so it can be stale. The caller shows its
/// findings only beside the scan they came from, and says when none has run; this is pure over the
/// groups it is handed.
public enum StructureDuplicatedTaxonomy {

    public enum Rule {
        /// Distinct same-text pairs two folders must share before they are a taxonomy claim; one
        /// shared document is a stray copy, the Duplicates lens's business.
        public static let minimumMatchedDocuments = 3
        /// …and that many must be a material share of the smaller folder's files, or a large
        /// archive would be flagged against every folder it absorbed three files from.
        public static let minimumShare = 0.5
    }

    /// Every duplicated-taxonomy pair visible in `groups`, in path order.
    ///
    /// - Parameters:
    ///   - groups: the duplicate scan's current groups; only `.sameText` file groups are read.
    ///   - profile: supplies the folders and file counts. Both folders must be ones the survey
    ///     knows: the claim is about two organised branches, not an unrecorded copy stash.
    /// - Parameter minimumShare: injected only so the §5.9 measurement can sweep it; the app
    ///   always passes the default.
    public static func findings(groups: [DuplicateGroup],
                                in profile: FolderProfile,
                                minimumShare: Double = Rule.minimumShare) -> [StructureFinding] {
        let root = (profile.root as NSString).expandingTildeInPath
        let prefix = root.hasSuffix("/") ? root : root + "/"

        func relativeFolder(of absolutePath: String) -> String? {
            guard absolutePath.hasPrefix(prefix) else { return nil }
            let relative = String(absolutePath.dropFirst(prefix.count))
            let folder = (relative as NSString).deletingLastPathComponent
            guard !folder.isEmpty, profile.folders[folder] != nil else { return nil }
            return folder
        }

        // Distinct matched documents per unordered folder pair; each group is one document, so it
        // adds at most one to any pair. The key is a real pair, not a joined string: `|` is legal
        // in a folder name, so joined keys could merge different pairs.
        struct PairKey: Hashable { let a: String, b: String }
        var matched: [PairKey: Int] = [:]
        for group in groups where group.matchType == .sameText && !group.isDirectory {
            let folders = Set(group.copies.compactMap { relativeFolder(of: $0.path) })
            guard folders.count >= 2 else { continue }
            let sorted = folders.sorted()
            for i in sorted.indices {
                for j in sorted.indices where j > i {
                    let a = sorted[i], b = sorted[j]
                    // Ancestor and descendant are one branch, not two taxonomies.
                    guard !b.hasPrefix(a + "/") else { continue }
                    matched[PairKey(a: a, b: b), default: 0] += 1
                }
            }
        }

        let qualifying = matched
            .filter { $0.value >= Rule.minimumMatchedDocuments }
            .filter { pair, count in
                let filesA = profile.folders[pair.a]?.fileCount ?? 0
                let filesB = profile.folders[pair.b]?.fileCount ?? 0
                // `max(1, …)` reads a recorded zero as one, so a folder the survey saw empty falls
                // back to the floor rule: the survey knows nothing else about it.
                let smaller = max(1, min(filesA, filesB))
                return Double(count) / Double(smaller) >= minimumShare
            }
            .sorted { ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }

        // One finding per subject folder: everything downstream keys on `kind × subject`, so a
        // folder with two counterparts must not mint two findings under one id. Each pair takes
        // whichever folder is still free; a pair with both taken is dropped this pass and
        // resurfaces once either is resolved.
        var used: Set<String> = []
        var findings: [StructureFinding] = []
        for (pair, count) in qualifying {
            let subject: String, counterpart: String
            if !used.contains(pair.a) {
                subject = pair.a; counterpart = pair.b
            } else if !used.contains(pair.b) {
                subject = pair.b; counterpart = pair.a
            } else {
                continue
            }
            used.insert(subject)
            findings.append(StructureFinding(
                kind: .duplicatedTaxonomy,
                family: (subject as NSString).deletingLastPathComponent,
                subject: subject,
                detail: .duplicatedTaxonomy(counterpart: counterpart, matchedDocuments: count)))
        }
        return findings.sorted { $0.subject < $1.subject }
    }
}
