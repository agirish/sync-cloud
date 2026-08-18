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

    /// `role` strings this build has no case for, and how many folders carried each.
    ///
    /// **The profile is written by a generator that is not this app**, so a role added there
    /// arrives here before any code knows it. Empty is the ordinary state; anything else is
    /// reported once when the file is opened (see ``FilingProfileStore/profile(id:in:)``), because
    /// a folder silently demoted to "no role" files differently and nothing else would say so.
    public let unknownRoles: [String: Int]
    /// Folder entries that could not be decoded at all, even leniently. Also reported once.
    public let undecodableFolders: Int

    public init(profileId: String, root: String, folders: [String: FolderProfileEntry],
                personTokens: Set<String>, personAliases: [String: String] = [:],
                unknownRoles: [String: Int] = [:], undecodableFolders: Int = 0) {
        self.profileId = profileId
        self.root = root
        self.folders = folders
        self.personTokens = personTokens
        self.personAliases = personAliases
        self.unknownRoles = unknownRoles
        self.undecodableFolders = undecodableFolders
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
    /// **When a folder carries both a `year` and a `fiscalYear`, the deeper one wins**, and the
    /// path is what settles which that is.
    ///
    /// The two are separate keys and a path can set both — `…/H-1B/2016-2019/…/2016` does, on the
    /// reference tree, four times — so a fixed `year ?? fiscalYear` precedence answers with whichever
    /// key happens to be named first rather than with the folder the value describes. On those four
    /// it is right by luck: the bare year is the deeper component there, so the first arm already
    /// returns it, and **nothing on the reference tree changes answer here**. The case it gets wrong
    /// is the reverse nesting — a fiscal span under a calendar-year parent, `2015/2014-2015` — which
    /// this tree does not currently contain but the domain produces wherever Indian fiscal folders
    /// sit under a year. There the ancestor's calendar year came back for a folder about the span,
    /// and `FilingRouter.foldersByYear` groups on this while `RenamePlanner` compares its wrong-year
    /// flag against it, so a correctly filed November 2014 statement gets questioned.
    ///
    /// **A caveat this inherits rather than introduces:** ``looksLikeYear`` accepts any two 4-digit
    /// parts, so it cannot tell a fiscal span from any other range. `2016-2019` on the reference
    /// tree is an H-1B *petition* span, and both `FilingRouter.yearFit` and `RenamePlanner.yearFits`
    /// read an `A-B` key as an Indian Apr-Mar fiscal year. That mis-reading already applies to every
    /// folder whose own name is such a range and which carries no bare year — it is not new here —
    /// but the deeper-wins rule can now hand such a key to a folder that previously answered with an
    /// ancestor's calendar year. Not on this tree: all four both-axes folders are bare-year-deeper,
    /// so nothing changes answer. Worth knowing before extending the rule.
    ///
    /// The scan runs **only when both values are components of this entry's own path**, which is
    /// what makes it a depth question at all. That holds for every entry either builder produces
    /// today — verified across all 3,013 folders of the hand-built profile — but a profile that
    /// recorded an axis as a fact rather than as a component would otherwise have its answer
    /// silently changed by a scan that found only one of the two. Falling back to the old precedence
    /// there keeps this a strict refinement.
    public var yearKey: String? {
        let year = axes["year"], fiscal = axes["fiscalYear"]
        if let year, let fiscal {
            let components = path.split(separator: "/")
            if components.contains(where: { $0 == year }) && components.contains(where: { $0 == fiscal }) {
                for component in components.reversed() {
                    if component == year { return year }
                    if component == fiscal { return fiscal }
                }
            }
        }
        if let y = year ?? fiscal { return y }
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

    /// One folder entry with `role` as a plain string, so a value this build has no case for costs
    /// the ROLE rather than the file. Every other field is optional here for the same reason: the
    /// retry exists to salvage an entry, and refusing it over a missing count would defeat that.
    private struct LenientEntry: Decodable {
        let path: String
        let role: String?
        let naming: String?
        let anchors: [String]?
        let acceptsNewFiles: Bool?
        let fileCount: Int?
        let subfolderCount: Int?
        let axes: [String: String]?

        /// The entry as this build can use it — an unrecognised role reads as no role, which is
        /// what `role: nil` already means everywhere: "the survey said nothing".
        var entry: FolderProfileEntry {
            FolderProfileEntry(path: path, role: role.flatMap(FolderRole.init(rawValue:)),
                               naming: naming, anchors: anchors ?? [],
                               acceptsNewFiles: acceptsNewFiles, fileCount: fileCount ?? 0,
                               subfolderCount: subfolderCount ?? 0, axes: axes ?? [:])
        }
    }

    /// Consumes one element of an unkeyed container without caring what it was.
    private struct AnyIgnoredEntry: Decodable {
        init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? "~"
        // **One unknown `role` string used to kill the whole filing layer, unrepairably.**
        //
        // `FolderRole` is a raw-value enum and `role` is optional, but *optional* only makes an
        // ABSENT key fine: a present value the enum has no case for throws `dataCorrupted`, and the
        // throw escapes `decodeIfPresent` and the `?? []` alike — a `??` handles nil, not a throw.
        // One entry out of 3,013 carrying a role a newer generator wrote therefore took the entire
        // profile down, and with it `filingFolderProfile`, `filingMemory`, `filingProfilesDirectory`,
        // `contentIndexDirectory`, the people store and the tag store — all six left unset by one
        // `if let` in `SyncCloudApp`. Organize reports "not scanned", the roster and every person
        // verdict are unreachable, and it cannot be repaired from inside the app: `writeProfile`
        // refuses to overwrite, so the user has to delete the JSON by hand. The schema-version
        // probe does not catch it either — a new role INSIDE the current schema is not a new schema.
        //
        // Decoded entry by entry, each with a lenient retry, on the pattern `PersonTagFile` already
        // uses: an unknown role costs that folder its role, a truly undecodable entry costs itself,
        // and neither costs the file. Both are counted and reported at the door rather than
        // swallowed — a folder demoted to "no role" files differently.
        var list: [FolderProfileEntry] = []
        var unknown: [String: Int] = [:]
        var undecodable = 0
        if var array = try? c.nestedUnkeyedContainer(forKey: .folders) {
            while !array.isAtEnd {
                if let entry = try? array.decode(FolderProfileEntry.self) {
                    list.append(entry)
                } else if let lenient = try? array.decode(LenientEntry.self) {
                    if let raw = lenient.role, FolderRole(rawValue: raw) == nil {
                        unknown[raw, default: 0] += 1
                    }
                    list.append(lenient.entry)
                } else {
                    // A failed decode does not advance the container, so the element still has to
                    // be consumed or the loop cannot move past it.
                    _ = try? array.decode(AnyIgnoredEntry.self)
                    undecodable += 1
                }
            }
        }
        unknownRoles = unknown
        undecodableFolders = undecodable
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
