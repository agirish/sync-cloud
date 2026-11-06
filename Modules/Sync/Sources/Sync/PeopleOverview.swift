import Foundation

/// The roster against the tree it describes: the whole-household view. Per-person facts describe
/// one person; this says how much of the tree the roster governs, and where it doesn't reach.
public struct PeopleOverview: Sendable, Equatable {
    /// Folders carrying a person axis that resolves to somebody on the roster.
    public let claimedFolders: Int
    /// Documents filed into those folders.
    public let claimedDocuments: Int
    /// People the tree files for who are not on the roster: an `axes.person` value the registry
    /// can't resolve. Documents naming them go to nobody and the cross-person veto can't protect
    /// their folders, so the section offers to add them.
    public let unclaimed: [UnclaimedPerson]
    /// People on the roster with no folder recorded as theirs. Not a fault (someone added today has
    /// none yet), but their record changes nothing until one exists.
    public let peopleWithNoFolders: [String]

    public init(claimedFolders: Int, claimedDocuments: Int, unclaimed: [UnclaimedPerson],
                peopleWithNoFolders: [String]) {
        self.claimedFolders = claimedFolders
        self.claimedDocuments = claimedDocuments
        self.unclaimed = unclaimed
        self.peopleWithNoFolders = peopleWithNoFolders
    }

    public static let empty = PeopleOverview(claimedFolders: 0, claimedDocuments: 0,
                                             unclaimed: [], peopleWithNoFolders: [])

    /// A name the tree files for that the roster does not know.
    public struct UnclaimedPerson: Sendable, Equatable {
        /// The axis value exactly as the survey recorded it: the spelling to offer as a name.
        public let name: String
        public let folders: Int
        public let documents: Int
        /// One folder, so the offer can show what it is talking about rather than asserting a count.
        public let exampleFolder: String

        public init(name: String, folders: Int, documents: Int, exampleFolder: String) {
            self.name = name
            self.folders = folders
            self.documents = documents
            self.exampleFolder = exampleFolder
        }
    }

    public static func make(registry: PersonRegistry, profile: FolderProfile?,
                            memory: FilingMemory?) -> PeopleOverview {
        guard let profile else {
            return PeopleOverview(claimedFolders: 0, claimedDocuments: 0, unclaimed: [],
                                  peopleWithNoFolders: registry.people.map(\.id))
        }
        var claimedFolders = 0
        var claimedDocuments = 0
        var withFolders: Set<String> = []
        var unknownFolders: [String: Int] = [:]
        var unknownDocs: [String: Int] = [:]
        var unknownExample: [String: String] = [:]

        for (path, entry) in profile.folders {
            guard let axis = entry.axes["person"] else { continue }
            let docs = memory?.folders[path]?.docs ?? 0
            if let id = registry.person(forAxisValue: axis) {
                claimedFolders += 1
                claimedDocuments += docs
                withFolders.insert(id)
            } else {
                // Grouped by the axis value as written: the offer proposes that spelling as a
                // name, and normalising it would propose something the tree doesn't say.
                unknownFolders[axis, default: 0] += 1
                unknownDocs[axis, default: 0] += docs
                if let existing = unknownExample[axis] {
                    // The shallowest folder is the most recognisable one to show.
                    if path.split(separator: "/").count < existing.split(separator: "/").count {
                        unknownExample[axis] = path
                    }
                } else {
                    unknownExample[axis] = path
                }
            }
        }

        // An explicit loop and type: a map-then-sort one-liner over the tuples is too slow for the
        // type checker.
        var unclaimed: [UnclaimedPerson] = []
        for (name, count) in unknownFolders {
            unclaimed.append(UnclaimedPerson(name: name, folders: count,
                                             documents: unknownDocs[name] ?? 0,
                                             exampleFolder: unknownExample[name] ?? ""))
        }
        unclaimed.sort { a, b in
            if a.folders != b.folders { return a.folders > b.folders }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let missing = registry.people.map(\.id).filter { !withFolders.contains($0) }
        return PeopleOverview(claimedFolders: claimedFolders, claimedDocuments: claimedDocuments,
                              unclaimed: unclaimed, peopleWithNoFolders: missing)
    }
}
