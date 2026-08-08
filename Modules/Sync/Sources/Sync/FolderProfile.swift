import Foundation

/// What a folder **is** — role, axes, naming convention, and whether it may receive files at all.
///
/// `FilingClassifier` has only ever been handed bare folder paths, so it re-derives per file facts
/// that are stable properties of the tree: that `TODO/` is an inbox rather than a destination, that
/// Indian tax years span two calendar years while US ones do not, that a folder's files are named
/// `NN. Mon YYYY`. A profile records those once.
///
/// **A profile is learned state about one person's tree, and nothing here generalises.** The
/// conventions were mined from one `~/Documents`; another tree would yield a different and possibly
/// contradictory set. There is no default profile to ship — a missing profile simply restores the
/// behaviour the app had before this existed. The store is keyed by profile id so a second tree is
/// additive rather than destructive.
public struct FolderProfile: Sendable, Equatable {
    public let profileId: String
    /// The tree this profile describes, as written in the file (e.g. `~/Documents`).
    public let root: String
    public let folders: [String: FolderProfileEntry]
    /// Values of the person axis, lowercased — `abhishek`, `shweta`, … plus the aliases the tree
    /// uses for the same people (`Family/Mom` is Immigration's `Muktha`).
    public let personTokens: Set<String>
    /// Which of those tokens are the *same person*, lowercased alias → canonical (`mom` →
    /// `muktha`). This used to be flattened into ``personTokens`` and discarded, after which
    /// nothing could answer "is `mom` the same person as `muktha`?" — only "is this token some
    /// person?". ``PersonRegistry/seeded(from:)`` is what reads it.
    public let personAliases: [String: String]

    public init(profileId: String, root: String, folders: [String: FolderProfileEntry],
                personTokens: Set<String>, personAliases: [String: String] = [:]) {
        self.profileId = profileId
        self.root = root
        self.folders = folders
        self.personTokens = personTokens
        self.personAliases = personAliases
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// Whether a folder may be proposed as a destination.
    ///
    /// Three ways to fail, and the last two are why this is not simply `acceptsNewFiles`: the
    /// profile marks the inboxes it found, but a tree grows new ones, and a first cut of a
    /// destination list leaked 105 inbox folders while the prose above it said never to file there.
    /// Matching `TODO` as a whole path **component** rather than as a suffix is what closes that.
    public func acceptsNewFiles(_ relativePath: String) -> Bool {
        if let e = folders[relativePath] {
            if e.acceptsNewFiles == false { return false }
            if e.role == .inbox { return false }
        }
        return !FolderProfile.isInboxPath(relativePath)
    }

    /// Whether any component of a path names an inbox, on the name alone.
    ///
    /// **The one implementation of this rule.** It is asked in three places — here, when the router
    /// builds its destination list, and when a context is handed to a backend — and three copies
    /// would be three chances for one of them to start filing into `TODO`.
    ///
    /// Matching is on whole *words* inside a component, not on a substring: `EDD - TODO` and
    /// `New (TODO)` are inboxes, but a folder called `Mastodon` is not, and a `contains("todo")`
    /// test refuses it. That folder does not exist in the surveyed tree, which is precisely why the
    /// bug would have gone unnoticed until it hit someone else's.
    public static func isInboxPath(_ relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/") {
            for word in component.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                if word == "todo" || word == "inbox" || word == "unfiled" { return true }
            }
        }
        return false
    }
}

/// One folder's stable properties.
public struct FolderProfileEntry: Sendable, Equatable, Decodable {
    public let path: String
    public let role: FolderRole?
    /// How this folder's own files are named, when the survey found a consistent convention
    /// (`ordinal-month`, `descriptive`, …). nil when there is none or the folder holds no files.
    public let naming: String?
    /// Tokens mined from the folder's own name and its files' names.
    public let anchors: [String]
    /// nil when the survey said nothing; only an explicit `false` forbids filing here.
    public let acceptsNewFiles: Bool?
    public let fileCount: Int
    public let subfolderCount: Int
    /// The axis values in play for this folder — `year`, `fiscalYear`, `jurisdiction`, `person`,
    /// `lifecycle`.
    public let axes: [String: String]

    public init(path: String, role: FolderRole?, naming: String?, anchors: [String],
                acceptsNewFiles: Bool?, fileCount: Int, subfolderCount: Int, axes: [String: String]) {
        self.path = path
        self.role = role
        self.naming = naming
        self.anchors = anchors
        self.acceptsNewFiles = acceptsNewFiles
        self.fileCount = fileCount
        self.subfolderCount = subfolderCount
        self.axes = axes
    }

    /// The year or fiscal-year this folder is keyed by, from the axes or from its own name.
    ///
    /// **The name fallback is not a convenience.** `IRS Docs - 2023` sits beside the bare-year
    /// folders `2012`–`2025` and the survey recorded no `year` axis for it, so without a fallback it
    /// lands in a different family and is never compared with the years it belongs to. A jurisdiction
    /// also changes the shape: US tax years are one calendar year, Indian ones span two.
    public var yearKey: String? {
        if let y = axes["year"] ?? axes["fiscalYear"] { return y }
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return FolderProfileEntry.looksLikeYear(base) ? base : nil
    }

    static func looksLikeYear(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { p in
            p.count == 4 && p.allSatisfy(\.isNumber) && (p.hasPrefix("19") || p.hasPrefix("20"))
        }
    }
}

public enum FolderRole: String, Sendable, Equatable, Decodable {
    case destination, yearBucket = "year-bucket", container, personBucket = "person-bucket"
    case archive, inbox, empty, passThrough = "pass-through"
}

// MARK: - Decoding the on-disk shape

extension FolderProfile: Decodable {
    private enum Key: String, CodingKey {
        case profileId, root, folders, axes
    }
    private struct AxisBox: Decodable {
        let values: [String]?
        let aliases: [String: String]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? "~"
        let list = try c.decodeIfPresent([FolderProfileEntry].self, forKey: .folders) ?? []
        folders = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        var people: Set<String> = []
        var aliasMap: [String: String] = [:]
        if let axes = try? c.decodeIfPresent([String: AxisBox].self, forKey: .axes),
           let person = axes["person"] {
            for v in person.values ?? [] { people.insert(v.lowercased()) }
            // `Family/Mom` and Immigration's `Muktha` are the same person; the tree names her both
            // ways, so both tokens have to route — and the *pairing* has to survive, or a file
            // named `Mom` reads as a contradiction against a folder whose axis says `muktha`.
            for (alias, canonical) in person.aliases ?? [:] {
                people.insert(alias.lowercased())
                people.insert(canonical.lowercased())
                aliasMap[alias.lowercased()] = canonical.lowercased()
            }
        }
        personTokens = people
        personAliases = aliasMap
    }
}
