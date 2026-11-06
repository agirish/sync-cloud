import Foundation

/// The account, case and member numbers that belong to one person, learned from what their
/// folders have already received.
///
/// The only way a scan with no readable name gets attributed: a passport number filed into one
/// person's folders many times before is a stronger claim than any word in the document.
/// ``FilingMemory`` already stores each folder's identifiers as salted hashes, so this is cheap
/// and keeps the numbers themselves out of memory.
///
/// Only identifiers posted to exactly one person survive. A number two people's folders both
/// received is a household account, and attributing on it would file a joint statement under
/// whoever sorted first.
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
    /// Usually empty, sometimes one. A set because a document can carry two people's numbers (a
    /// joint tax return), and the caller must see that rather than be handed one of them.
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
    /// - Parameter rejectedIdentifiers: `personId` → identifier hashes the user said are not that
    ///   person's, from ``rejectedIdentifiers(tags:corpus:salt:)``. Withdrawn before the
    ///   single-owner filter, which is what lets the correction take effect.
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
        // The user's "no" un-teaches the identifier, and it must happen here, before the
        // single-owner filter. A misfile usually silences an identifier rather than adding an
        // owner: one wrong folder makes the hash claimed by two people, so it is dropped. Withdrawing
        // the wrong claim first both stops that attribution and hands the identifier back to its
        // real owner; filtering the finished `owner` map could do neither. Apart from this the
        // index is rebuilt from the surveyed tree and takes no correction.
        for (personId, hashes) in rejectedIdentifiers {
            for hash in hashes { claims[hash]?.remove(personId) }
        }
        var owner: [String: String] = [:]
        for (hash, people) in claims where people.count == 1 { owner[hash] = people.first! }
        return PersonIdentityIndex(owner: owner, salt: memory.salt)
    }

    /// The identifiers a rejection withdraws, keyed by the person it was withdrawn from.
    ///
    /// A tag says "this document is not theirs"; the index reasons in identifier hashes. The corpus
    /// joins them: it holds each document's `idHashes` under the same root-relative path the tag
    /// records, so this is one lookup per rejection.
    ///
    /// Only `.rejected`: a confirmation adds nothing the folder didn't already teach, and a claim
    /// invented from a "yes" on a joint statement would hand a household account to one person.
    ///
    /// Returns empty when the corpus and index salts differ, since the hashes would name nothing in
    /// common. Checked rather than assumed: a stale corpus beside a rebuilt memory would go quiet.
    public static func rejectedIdentifiers(tags: [PersonTag], corpus: FilingCorpus,
                                           salt: String) -> [String: Set<String>] {
        guard corpus.salt == salt else { return [:] }
        var out: [String: Set<String>] = [:]
        for tag in tags where tag.verdict == .rejected {
            // The path the verdict was recorded at, the corpus's own key. A fingerprint-keyed tag
            // carries it too (`PersonTag.recordedPath`).
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
