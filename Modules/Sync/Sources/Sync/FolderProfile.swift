import Foundation

/// What a folder is: role, axes, naming convention, and whether it may receive files. Records once
/// the stable facts a classifier would otherwise re-derive per file: `TODO/` is an inbox, Indian tax
/// years span two calendar years, a folder's files are named `NN. Mon YYYY`.
///
/// Learned state about one person's tree; nothing here generalises, and no default profile ships.
/// Without one, filing works from folder paths alone. Keyed by profile id, so a second tree is
/// additive.
public struct FolderProfile: Sendable, Equatable {
    public let profileId: String
    /// The tree this profile describes, as written in the file (e.g. `~/Documents`), or `~` when
    /// the file names none.
    public var root: String { recordedRoot ?? "~" }
    /// The tree as the file records it; nil when it records none. **Nothing that writes under the
    /// profile may act on ``root``'s `~` fallback**: the corpus, memory and reorganisation ledger are
    /// relative to the profile's own folder, so using the home folder would read every learned
    /// document as gone or reorganise the wrong tree. Those passes use ``recordedFolderPath``.
    public let recordedRoot: String?

    /// The folder the file records, `~` expanded; nil when it records none, or one still relative
    /// after expanding. The only folder a pass that writes under this profile may act on: Refresh,
    /// the document survey and Restructure landings refuse when it is nil.
    public var recordedFolderPath: String? {
        guard let recordedRoot else { return nil }
        let expanded = (recordedRoot as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : nil
    }
    public let folders: [String: FolderProfileEntry]
    /// Values of the person axis, lowercased (`father`, `mother`, …), plus the aliases the tree
    /// uses for the same people (`Family/Mom` is Immigration's `Granny`).
    public let personTokens: Set<String>
    /// Which of those tokens are the same person, lowercased alias → canonical (`mom` → `granny`),
    /// so "is `mom` the same person as `granny`?" can be answered. Read by
    /// ``PersonRegistry/seeded(from:)``.
    public let personAliases: [String: String]

    /// What wrote this profile, verbatim from the file's `builtBy` header; nil when absent. Lets the
    /// store replace the app's own derived profile (re-derivable in seconds) while never replacing a
    /// hand-built one. Callers ask ``provenance``.
    public let builtBy: String?

    /// The profile id this one was re-derived from after a Restructure apply; nil for a hand-built
    /// profile and a plain walk. The old file is never deleted: *Undo this reorganisation* re-points
    /// `profiles.json` back to it, and it names the last hand-built copy when the chain began at one.
    public let derivedFrom: String?

    /// `role` strings this build has no case for, and how many folders carried each. A generator
    /// outside this app can add roles first. Usually empty; otherwise reported once on open
    /// (``FilingProfileStore/profile(id:in:)``), since a folder demoted to "no role" files
    /// differently.
    public let unknownRoles: [String: Int]
    /// Folder entries that could not be decoded at all, even leniently. Also reported once.
    public let undecodableFolders: Int

    /// Who produced a profile, and so what the app may do with it. A hand-built profile records
    /// judgements a walk can't (`naming`, `folderSemantics`, `outbound-pack` refusals), so replacing
    /// it with a derived one would silently degrade To File and renaming. Replacing the app's own
    /// derivation costs nothing.
    public enum Provenance: Equatable, Sendable {
        /// Written by this app's folder survey. The app may supersede it with a fresh one.
        case derived
        /// Written by anything else (the out-of-repo builder, a hand edit), including any profile
        /// without a `builtBy` header. **Never replaced.**
        case handBuilt
    }

    /// Whether this profile is the app's own work. An absent or unrecognised `builtBy` reads as
    /// hand-built, which errs toward refusing a replacement rather than making a wrong one.
    public var provenance: Provenance {
        builtBy?.hasPrefix(FolderProfile.derivedBuiltByPrefix) == true ? .derived : .handBuilt
    }

    /// The prefix `writeProfile` stamps into every profile the app derives. A prefix, so the rest
    /// can carry a version or date without turning older derived profiles hand-built, and so
    /// unreplaceable.
    public static let derivedBuiltByPrefix = "SyncCloud"

    public init(profileId: String, root: String, folders: [String: FolderProfileEntry],
                personTokens: Set<String>, personAliases: [String: String] = [:],
                builtBy: String? = nil, derivedFrom: String? = nil,
                unknownRoles: [String: Int] = [:], undecodableFolders: Int = 0) {
        self.profileId = profileId
        self.recordedRoot = root
        self.folders = folders
        self.personTokens = personTokens
        self.personAliases = personAliases
        self.builtBy = builtBy
        self.derivedFrom = derivedFrom
        self.unknownRoles = unknownRoles
        self.undecodableFolders = undecodableFolders
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// Whether a folder may be proposed as a destination. Not just `acceptsNewFiles`: the role and
    /// the path's own words are checked too, because a tree grows inboxes the profile never saw.
    public func acceptsNewFiles(_ relativePath: String) -> Bool {
        if let e = folders[relativePath] {
            if e.acceptsNewFiles == false { return false }
            if e.role == .inbox { return false }
        }
        return !FolderProfile.isInboxPath(relativePath)
    }

    /// Whether any component of a path names an inbox, on the name alone. The one implementation,
    /// used here, by the router's destination list, and for a backend's context, so no copy drifts
    /// into filing into `TODO`. Whole words, not substrings: `EDD - TODO` and `New (TODO)` are
    /// inboxes, `Mastodon` is not.
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
    /// Why filing here is refused, when `acceptsNewFiles` is `false` and the author said
    /// (`outbound-pack`, `todo-inbox`, …). Re-derivation carries the pair forward together: a
    /// refusal without its reason can't be audited or revisited.
    public let noIntakeReason: String?
    public let fileCount: Int
    public let subfolderCount: Int
    /// The axis values in play for this folder: `year`, `fiscalYear`, `jurisdiction`, `person`,
    /// `lifecycle`.
    public let axes: [String: String]

    public init(path: String, role: FolderRole?, naming: String?, anchors: [String],
                acceptsNewFiles: Bool?, noIntakeReason: String? = nil,
                fileCount: Int, subfolderCount: Int, axes: [String: String]) {
        self.path = path
        self.role = role
        self.naming = naming
        self.anchors = anchors
        self.acceptsNewFiles = acceptsNewFiles
        self.noIntakeReason = noIntakeReason
        self.fileCount = fileCount
        self.subfolderCount = subfolderCount
        self.axes = axes
    }

    /// The year or fiscal year this folder is keyed by, from the axes or its own name. The name
    /// fallback matters: a folder like `IRS Docs - 2023` with no `year` axis would otherwise never be
    /// compared with the bare-year folders beside it. US tax years are one calendar year, Indian
    /// ones span two.
    ///
    /// When a folder has both `year` and `fiscalYear` and both are components of its path, the
    /// deeper one wins: in `2015/2014-2015` the span describes the folder, and
    /// `FilingRouter.foldersByYear` and `RenamePlanner`'s wrong-year flag both read this. Otherwise
    /// `year ?? fiscalYear`.
    ///
    /// Caveat: ``looksLikeYear`` accepts any two 4-digit parts, so a non-fiscal range (a petition
    /// span like `2016-2019`) still reads as an Indian Apr–Mar fiscal year in `FilingRouter.yearFit`
    /// and `RenamePlanner.yearFits`, and deeper-wins can hand such a key to a folder below a year.
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

    public static func looksLikeYear(_ s: String) -> Bool {
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
        case profileId, root, folders, axes, builtBy, derivedFrom
    }
    private struct AxisBox: Decodable {
        let values: [String]?
        let aliases: [String: String]?
    }

    /// One folder entry with `role` as a plain string, so an unknown value costs the role, not the
    /// file. Every other field is optional too, so the retry salvages the entry.
    private struct LenientEntry: Decodable {
        let path: String
        let role: String?
        let naming: String?
        let anchors: [String]?
        let acceptsNewFiles: Bool?
        let noIntakeReason: String?
        let fileCount: Int?
        let subfolderCount: Int?
        let axes: [String: String]?

        /// The entry as this build can use it: an unrecognised role reads as `nil`, "the survey
        /// said nothing".
        var entry: FolderProfileEntry {
            FolderProfileEntry(path: path, role: role.flatMap(FolderRole.init(rawValue:)),
                               naming: naming, anchors: anchors ?? [],
                               acceptsNewFiles: acceptsNewFiles,
                               noIntakeReason: noIntakeReason, fileCount: fileCount ?? 0,
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
        recordedRoot = try c.decodeIfPresent(String.self, forKey: .root)
        // Tolerated as absent or the wrong type: a hand-edited header costs the file its provenance
        // (reading as hand-built, the cautious answer), not its folders.
        builtBy = try? c.decodeIfPresent(String.self, forKey: .builtBy)
        // Same tolerance as `builtBy`: a bad header costs the provenance chain, never the folders.
        derivedFrom = (try? c.decodeIfPresent(String.self, forKey: .derivedFrom)) ?? nil
        // **Decoded entry by entry, so one bad entry can't fail the profile.** An optional
        // raw-value enum still throws on an unknown present value, and `??` doesn't catch a throw;
        // a failed profile takes the whole filing layer down with no in-app repair. As in
        // `PersonTagFile`, an unknown role costs only that folder's role, an undecodable entry only
        // itself, and both are counted and reported on open.
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
                    // A failed decode doesn't advance the container, so consume the element or the
                    // loop never moves past it.
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
            // The tree names one person both `Mom` and `Granny`, so both tokens route, and the
            // pairing is kept so a file named `Mom` doesn't contradict a folder whose axis says
            // `granny`.
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
