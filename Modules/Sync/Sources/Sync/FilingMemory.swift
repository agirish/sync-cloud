import CryptoKit
import Foundation

/// What a folder has **received** — the discriminative content of the documents already filed in it.
///
/// The companion to ``FolderProfile``, and the distinction is the point: the profile records what a
/// folder *is*, mined from names, while this records what it has *been given*, mined from page 1.
/// Names are frequently useless — a tree holds fourteen payslips called `Nov 30 Paycheck HPE.pdf`
/// belonging with files called `Payslip_2025-11-28.pdf`, and screenshots carrying nothing but a case
/// number that only an already-filed confirmation can attribute. Measured over 9,558 filed documents
/// choosing one of ~2,950 folders, adding this to the profile takes top-1 routing from 28.9% to
/// 58.2% and top-3 from 40.2% to 77.5%.
///
/// **Not portable, for the same reason the profile is not.** It is a description of one person's
/// documents; a missing memory restores the profile-only behaviour exactly.
public struct FilingMemory: Sendable, Equatable {
    public let profileId: String
    /// Salt for ``hash(_:)``. Stored beside the hashes it produces, necessarily — this keeps the
    /// file from being a readable list of account numbers, which is worth doing because it sits in
    /// Application Support and gets backed up. It is **obfuscation, not a security boundary.**
    public let salt: String
    public let folders: [String: FilingMemoryEntry]
    /// How many folders the weights were computed against — used to age a weight that was learned
    /// against a much smaller tree.
    public let folderBase: Int

    public init(profileId: String, salt: String, folders: [String: FilingMemoryEntry], folderBase: Int) {
        self.profileId = profileId
        self.salt = salt
        self.folders = folders
        self.folderBase = folderBase
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// The stored form of a digit-bearing token. Matching is equality on this, so a candidate file's
    /// tokens are hashed the same way and compared — the raw account number never has to be stored.
    public func hash(_ token: String) -> String {
        FilingMemory.hash(token, salt: salt)
    }

    /// `sha256(salt + token)`, first 16 hex characters.
    ///
    /// The exact form matters: the builder that writes the file produces these, so a change here
    /// silently stops every identifier matching — the failure is a quiet loss of accuracy, not an
    /// error, which is why ``FilingMemoryTests`` pins a known token/salt pair against a literal.
    static func hash(_ token: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + token).utf8))
        var hex = ""
        hex.reserveCapacity(16)
        for byte in digest {
            hex += String(format: "%02x", byte)
            if hex.count >= 16 { break }
        }
        return String(hex.prefix(16))
    }
}

/// One folder's learned content.
public struct FilingMemoryEntry: Sendable, Equatable {
    /// How many filed documents this was learned from. Scores divide by its square root so a folder
    /// does not win on sheer volume.
    public let docs: Int
    /// Readable words — provider, document type, clinician, plan name — with their rarity weight.
    /// Readable on purpose: these are also the useful half of a prompt for the paid tier.
    public let anchors: [FilingMemoryToken]
    /// Digit-bearing tokens (account last-4, case, member and policy numbers), hashed.
    public let idHashes: [FilingMemoryToken]

    public init(docs: Int, anchors: [FilingMemoryToken], idHashes: [FilingMemoryToken]) {
        self.docs = docs
        self.anchors = anchors
        self.idHashes = idHashes
    }
}

/// A token and how much it discriminates — higher means it appears in fewer folders.
public struct FilingMemoryToken: Sendable, Equatable {
    public let token: String
    public let weight: Double

    public init(token: String, weight: Double) {
        self.token = token
        self.weight = weight
    }
}

// MARK: - Decoding the on-disk shape

extension FilingMemoryToken: Decodable {
    /// Stored as a two-element array `["kaiser", 3.9]` rather than an object, because at ~58,000
    /// tokens the key names would be a third of the file.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        token = try c.decode(String.self)
        weight = (try? c.decode(Double.self)) ?? 1.0
    }
}

extension FilingMemoryEntry: Decodable {
    private enum Key: String, CodingKey { case docs, anchors, idHashes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        docs = try c.decodeIfPresent(Int.self, forKey: .docs) ?? 0
        anchors = try c.decodeIfPresent([FilingMemoryToken].self, forKey: .anchors) ?? []
        idHashes = try c.decodeIfPresent([FilingMemoryToken].self, forKey: .idHashes) ?? []
    }
}

extension FilingMemory: Decodable {
    private enum Key: String, CodingKey {
        case profileId, salt, folders, idfFolderBase
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        salt = try c.decodeIfPresent(String.self, forKey: .salt) ?? ""
        folders = try c.decodeIfPresent([String: FilingMemoryEntry].self, forKey: .folders) ?? [:]
        folderBase = try c.decodeIfPresent(Int.self, forKey: .idfFolderBase) ?? max(folders.count, 1)
    }
}
