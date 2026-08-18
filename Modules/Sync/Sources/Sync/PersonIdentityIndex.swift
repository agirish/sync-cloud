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
    /// - Parameter rejectedIdentifiers: `personId` → identifier hashes the user has said are **not**
    ///   that person's, from ``rejectedIdentifiers(tags:corpus:)``. A claim withdrawn here is
    ///   withdrawn before the single-owner filter below, which is what makes the correction do
    ///   something rather than nothing — see the discussion there.
    public static func make(registry: PersonRegistry, profile: FolderProfile?,
                            memory: FilingMemory?,
                            rejectedIdentifiers: [String: Set<String>] = [:]) -> PersonIdentityIndex {
        guard let profile, let memory, !registry.isEmpty else { return .empty }
        var claims: [String: Set<String>] = [:]
        for (path, entry) in memory.folders {
            guard let axis = profile.folders[path]?.axes["person"],
                  let personId = registry.person(forAxisValue: axis) else { continue }
            for token in entry.idHashes { claims[token.token, default: []].insert(personId) }
        }
        // **The user's "no" un-teaches the identifier, and it has to happen HERE — before the
        // single-owner filter — or it does nothing at all.**
        //
        // A misfile does not merely add a wrong owner; it usually SILENCES the identifier. Muktha's
        // passport number sits in eleven of her folders and, once the scan lands in `School/Aditi`,
        // in one of Aditi's — so the hash is claimed by two people, `people.count == 1` is false,
        // and it is dropped. The number that identified her best now identifies nobody.
        //
        // Withdrawing Aditi's claim first therefore does two things with one line: it stops the
        // wrong attribution, and it hands the identifier back to its real owner. Filtering the
        // finished `owner` map instead could only ever do the first, and in this — the common —
        // shape there would have been nothing there to filter.
        //
        // The index is otherwise rebuilt from the tree as surveyed and takes no correction at all:
        // the People queue wrote a verdict that `attribute`, `personVeto` and `personIs` never
        // consulted, so the only un-learn was moving the file and re-surveying. That matters more
        // since the cross-person rule began sweeping every card rather than only backend verdicts.
        for (personId, hashes) in rejectedIdentifiers {
            for hash in hashes { claims[hash]?.remove(personId) }
        }
        var owner: [String: String] = [:]
        for (hash, people) in claims where people.count == 1 { owner[hash] = people.first! }
        return PersonIdentityIndex(owner: owner, salt: memory.salt)
    }

    /// The identifiers a rejection withdraws, keyed by the person it was withdrawn from.
    ///
    /// A tag says "this DOCUMENT is not theirs"; the index reasons in identifier hashes. The corpus
    /// is what joins the two — it holds each document's own `idHashes`, keyed by the same
    /// root-relative path the tag records — so this is the whole translation and it is a lookup per
    /// rejection rather than a pass over 10,000 documents.
    ///
    /// **Only `.rejected`.** A confirmation adds nothing: the identifier already reached the index
    /// through the folder the document sits in, and inventing a claim from a tag would let a "yes"
    /// on a joint statement hand a household account to one person.
    ///
    /// Returns empty when the corpus and the index disagree about their salt, since the hashes
    /// would name nothing in common. That is the survey's own invariant; asserted rather than
    /// assumed because a stale corpus beside a rebuilt memory is exactly when this would go quiet.
    public static func rejectedIdentifiers(tags: [PersonTag], corpus: FilingCorpus,
                                           salt: String) -> [String: Set<String>] {
        guard corpus.salt == salt else { return [:] }
        var out: [String: Set<String>] = [:]
        for tag in tags where tag.verdict == .rejected {
            // The path the verdict was recorded at, which is the corpus's own key. A
            // fingerprint-keyed tag carries it too — see `PersonTag.recordedPath`.
            let path: String
            switch tag.key {
            case .path(let p): path = tag.recordedPath.isEmpty ? p : tag.recordedPath
            case .fingerprint: path = tag.recordedPath
            }
            guard !path.isEmpty, let document = corpus.documents[path], !document.idHashes.isEmpty
            else { continue }
            out[tag.personId, default: []].formUnion(document.idHashes)
        }
        return out
    }
}
