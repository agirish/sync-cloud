import Foundation

/// §5.9: duplicated taxonomy — two folders holding the same documents under parallel taxonomies.
///
/// **Held back until the evidence was content, and built only on content.** Matching siblings by
/// child names is dominated by correct parallels on this tree (Vanguard's two IRAs, four Chase
/// accounts foldered by year) — identical sibling structure is usually a sign of health. What
/// separates the real case (`Work/Archive/MapR/Compensation/Forms/` against
/// `Finance/US/Income Tax/2016/Forms/`) is that **the same documents sit in both**, and the PDF
/// content fingerprint's `.sameText` pass is the evidence: two folders are duplicated taxonomy
/// when a material share of their contents are `.sameText` partners of each other, never merely
/// when their child names agree.
///
/// **The one detector that reads a scan, not the profile** — so it is the one that can be stale.
/// The caller renders its findings only alongside the scan they came from, and says when no scan
/// has run; this function is pure over the groups it is handed.
public enum StructureDuplicatedTaxonomy {

    public enum Rule {
        /// Distinct same-text pairs two folders must share before they are a taxonomy claim —
        /// one shared document is a stray copy, which is the Duplicates lens's ordinary business.
        public static let minimumMatchedDocuments = 3
        /// …and that many must be a material share of the SMALLER folder's files, or a large
        /// archive folder would be flagged against every folder it ever absorbed three files
        /// from.
        public static let minimumShare = 0.5
    }

    /// Every duplicated-taxonomy pair visible in `groups`, in path order.
    ///
    /// - Parameters:
    ///   - groups: the duplicate scan's current groups; only `.sameText` file groups are read.
    ///   - profile: supplies the folder universe and file counts — both folders must be folders
    ///     the survey knows, because the claim is about two organised branches, not about a copy
    ///     stash the profile never recorded.
    public static func findings(groups: [DuplicateGroup],
                                in profile: FolderProfile) -> [StructureFinding] {
        let root = (profile.root as NSString).expandingTildeInPath
        let prefix = root.hasSuffix("/") ? root : root + "/"

        func relativeFolder(of absolutePath: String) -> String? {
            guard absolutePath.hasPrefix(prefix) else { return nil }
            let relative = String(absolutePath.dropFirst(prefix.count))
            let folder = (relative as NSString).deletingLastPathComponent
            guard !folder.isEmpty, profile.folders[folder] != nil else { return nil }
            return folder
        }

        // Distinct matched documents per unordered folder pair: a group names one document that
        // exists in several places, so each group contributes at most one to any pair.
        var matched: [String: (a: String, b: String, count: Int)] = [:]
        for group in groups where group.matchType == .sameText && !group.isDirectory {
            let folders = Set(group.copies.compactMap { relativeFolder(of: $0.path) })
            guard folders.count >= 2 else { continue }
            let sorted = folders.sorted()
            for i in sorted.indices {
                for j in sorted.indices where j > i {
                    let a = sorted[i], b = sorted[j]
                    // Ancestor and descendant are one branch, not two taxonomies — a stash
                    // inside its own archive is the Duplicates lens's ordinary case.
                    guard !b.hasPrefix(a + "/") else { continue }
                    let key = a + "|" + b
                    var entry = matched[key] ?? (a: a, b: b, count: 0)
                    entry.count += 1
                    matched[key] = entry
                }
            }
        }

        return matched.values.compactMap { pair -> StructureFinding? in
            guard pair.count >= Rule.minimumMatchedDocuments else { return nil }
            let filesA = profile.folders[pair.a]?.fileCount ?? 0
            let filesB = profile.folders[pair.b]?.fileCount ?? 0
            let smaller = max(1, min(filesA, filesB))
            guard Double(pair.count) / Double(smaller) >= Rule.minimumShare else { return nil }
            return StructureFinding(
                kind: .duplicatedTaxonomy,
                family: (pair.a as NSString).deletingLastPathComponent,
                subject: pair.a,
                detail: .duplicatedTaxonomy(counterpart: pair.b, matchedDocuments: pair.count))
        }
        .sorted { $0.subject < $1.subject }
    }
}
