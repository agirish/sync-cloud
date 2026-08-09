import Foundation

/// The account, case and member numbers that belong to one person — learned from what their
/// folders have already received.
///
/// **This is the only way a scan with no readable name gets attributed at all.** A passport scan
/// called `Scan 2026-08-02.pdf` whose text is an image says nothing; but the passport *number* on
/// page 1 has been filed into Muktha's folder eleven times before, and nobody else's. That is a
/// stronger claim than any word in the document, and it is already recorded — ``FilingMemory``
/// stores each folder's identifiers as salted hashes, which is what makes this cheap and what keeps
/// the numbers themselves out of memory.
///
/// **Only identifiers posted to exactly ONE person survive.** A number two people's folders have
/// both received is a household account, not a personal one, and attributing on it would file a
/// joint statement into whichever person happened to sort first. Measured on the real tree: of
/// Muktha's 28 identifiers, 15 are hers alone; Abhishek has 193 of 235.
public struct PersonIdentityIndex: Sendable, Equatable {
    /// Hashed identifier → the one person whose folders have received it.
    let owner: [String: String]
    /// The salt those hashes were produced with, so a candidate token can be hashed the same way.
    let salt: String

    public var isEmpty: Bool { owner.isEmpty }

    public init(owner: [String: String], salt: String) {
        self.owner = owner
        self.salt = salt
    }

    public static let empty = PersonIdentityIndex(owner: [:], salt: "")

    /// How many identifiers are known to be this person's alone.
    public func count(for personId: String) -> Int {
        owner.values.reduce(into: 0) { $0 += ($1 == personId ? 1 : 0) }
    }

    /// The people named by the identifiers in this text.
    ///
    /// Usually one, and empty is the common case. Returns a set rather than a single person because
    /// a document can carry two people's numbers — a joint tax return — and the caller must be able
    /// to see that rather than be handed one of them.
    public func people(in text: String) -> Set<String> {
        guard !owner.isEmpty else { return [] }
        var found: Set<String> = []
        for token in FilingRouter.tokenize(text) where FilingRouter.isIdentifier(token) {
            if let person = owner[FilingMemory.hash(token, salt: salt)] { found.insert(person) }
        }
        return found
    }

    /// Builds the index from the surveyed tree.
    ///
    /// A folder's identifiers count for the person that folder belongs to; an identifier claimed by
    /// two different people is dropped rather than assigned.
    public static func make(registry: PersonRegistry, profile: FolderProfile?,
                            memory: FilingMemory?) -> PersonIdentityIndex {
        guard let profile, let memory, !registry.isEmpty else { return .empty }
        var claims: [String: Set<String>] = [:]
        for (path, entry) in memory.folders {
            guard let axis = profile.folders[path]?.axes["person"],
                  let personId = registry.person(forAxisValue: axis) else { continue }
            for token in entry.idHashes { claims[token.token, default: []].insert(personId) }
        }
        var owner: [String: String] = [:]
        for (hash, people) in claims where people.count == 1 { owner[hash] = people.first! }
        return PersonIdentityIndex(owner: owner, salt: memory.salt)
    }
}
