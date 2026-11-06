import Foundation

/// Which survey To File placed the last scan's files with, and why. Each tree gets its own answer:
/// applying one survey to every tree by relative path is right only for a copy of that tree, and
/// quietly wrong for one laid out differently.
///
/// - `.primary` — the tree is the primary survey's (iCloud's Documents), or inside it.
/// - `.borrowed` — another source using the primary survey: half or more of its folders exist in
///   the primary survey (Dropbox, say), or the user chose it.
/// - `.own` — the source's own survey, learned from its folders (Google Drive).
/// - `.byName` — fewer than half match and it has no survey of its own, so files are placed by name.
public struct FilingSurveyInUse: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case primary, borrowed, own, byName
    }

    public let kind: Kind
    /// The tree filed into: the scan's provider root.
    public let root: String
    /// Folders of `root` that exist, at the same relative path, in the primary survey.
    public let matched: Int
    /// Folders of `root`, below the root itself.
    public let total: Int
    /// Whether a choice the user made decided it, rather than the measurement.
    public let chosen: Bool
    /// The source's own survey, when it has one, whether or not it is the one in use.
    public let ownProfileId: String?
    public let ownLearnedAt: Date?
    public let ownFolderCount: Int?
    /// When the own survey's documents were read, and how many; nil until Read Documents finishes.
    public let ownDocumentsReadAt: Date?
    public let ownDocumentsRead: Int?

    public init(kind: Kind, root: String, matched: Int, total: Int, chosen: Bool,
                ownProfileId: String? = nil, ownLearnedAt: Date? = nil, ownFolderCount: Int? = nil,
                ownDocumentsReadAt: Date? = nil, ownDocumentsRead: Int? = nil) {
        self.kind = kind
        self.root = root
        self.matched = matched
        self.total = total
        self.chosen = chosen
        self.ownProfileId = ownProfileId
        self.ownLearnedAt = ownLearnedAt
        self.ownFolderCount = ownFolderCount
        self.ownDocumentsReadAt = ownDocumentsReadAt
        self.ownDocumentsRead = ownDocumentsRead
    }

    /// The share of `root`'s folders the primary survey also has, 0…1; 1 for an empty tree.
    public var matchFraction: Double { total == 0 ? 1 : Double(matched) / Double(total) }

    /// "91%", rounded down so 49.6% never reads as the 50% that would have borrowed.
    public var matchPercent: String { "\(Int((matchFraction * 100).rounded(.down)))%" }

    /// Half or more of a source's folders found in the primary survey means it borrows.
    public static let borrowThreshold = 0.5

    /// Which survey a tree uses, with the user's choice over the measurement.
    ///
    /// - Parameters:
    ///   - primaryRoot: the primary survey's folder, expanded; nil when there is no survey at all.
    ///   - hasOwn: the source's own survey is on disk and readable.
    public static func resolve(providerRoot: String, primaryRoot: String?, entry: SourceSurveyEntry?,
                               hasOwn: Bool, matched: Int, total: Int) -> (kind: Kind, chosen: Bool) {
        if let primaryRoot, isAtOrInside(providerRoot, primaryRoot) { return (.primary, false) }
        switch entry?.choice {
        case .own? where hasOwn: return (.own, true)
        case .primary? where primaryRoot != nil: return (.borrowed, true)
        default: break
        }
        if hasOwn { return (.own, false) }
        guard primaryRoot != nil else { return (.byName, false) }
        let fraction = total == 0 ? 1 : Double(matched) / Double(total)
        return (fraction >= borrowThreshold ? .borrowed : .byName, false)
    }

    /// `path` is the survey's folder or inside it: the test that makes a tree the primary one.
    public static func isAtOrInsideSurvey(_ path: String, _ root: String) -> Bool { isAtOrInside(path, root) }

    /// `path` is `root` or a folder inside it, in either spelling of a link on the way.
    static func isAtOrInside(_ path: String, _ root: String) -> Bool {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        for (p, r) in [(path, root), (real(path), real(root))] {
            let p = p.lowercased(), r = r.hasSuffix("/") ? String(r.dropLast()).lowercased() : r.lowercased()
            if p == r || p.hasPrefix(r + "/") { return true }
        }
        return false
    }

    /// "Dropbox’s", "Documents’": a source's name as owner of a survey, shared by To File's menu
    /// and Settings so the two say it alike.
    public static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "’" : name + "’s"
    }

    /// The name of the source holding `path`, through a linked folder too (iCloud Drive's
    /// `Documents` is a link to `~/Documents`): the one whose root holds it most closely, so a
    /// folder in iCloud's Documents is named after iCloud rather than a Home folder source that
    /// also contains it. Nil when no source holds it.
    public static func sourceName(for path: String, sources: [(name: String, root: String)]) -> String? {
        sources.filter { !$0.root.isEmpty && (isAtOrInside(path, $0.root) || PathBoundary.contains(path, under: $0.root)) }
            .max { ($0.root as NSString).pathComponents.count < ($1.root as NSString).pathComponents.count }?
            .name
    }

    /// How many of `folders` (relative to their tree) the primary survey also has, ignoring case,
    /// and how many there are. The tree's own root entry is not a folder of it.
    public static func overlap(folders: some Collection<String>,
                               primaryFolders: some Collection<String>) -> (matched: Int, total: Int) {
        let known = Set(primaryFolders.lazy.map { $0.lowercased() })
        var matched = 0, total = 0
        for folder in folders where !folder.isEmpty && folder != FolderSurveyBuilder.rootEntryPath {
            total += 1
            if known.contains(folder.lowercased()) { matched += 1 }
        }
        return (matched, total)
    }
}
