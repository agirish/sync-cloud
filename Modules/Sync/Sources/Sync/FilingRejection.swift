import Foundation

/// A remembered *rejection* — the negative-feedback counterpart to `FilingRule`. When the user says
/// "not that folder" for a file (via "Try another"), the file's salient tokens and the rejected
/// folder are recorded, so later suggestions — this scan's re-ask and future scans — steer clear.
///
/// Matching mirrors `FilingRule`: a file matches when its tokens contain all of `tokens`.
public struct FilingRejection: Sendable, Equatable, Codable, Hashable {
    /// Trigger tokens (canonical, sorted) that identify files this rejection applies to.
    public let tokens: [String]
    /// Absolute path of the folder that was rejected.
    public let path: String

    public init(tokens: [String], path: String) {
        self.tokens = tokens
        self.path = path
    }
}

/// "This word is not a reason for this folder" (GU) — what a rejection teaches about OTHER files.
///
/// ``FilingRejection`` keys on every salient word of the rejected file's name, so it only ever
/// matches that file and its near-twins: rejecting `Health/Medical/India` for
/// `FedEx invoice - India courier.pdf` said nothing about `India passport scan.pdf`, which got the
/// same wrong home on the same one word. This records the word the match rested on instead, and
/// is narrower in the other direction: it refuses the folder only when a keyword match on it rests
/// on rejected words alone. The survey's own ranking, or a second shared word, still reaches it.
public struct FilingWordRejection: Sendable, Equatable, Codable, Hashable {
    /// A canonical token, as ``FilingEngine/nameTokens(_:)`` produces it.
    public let word: String
    /// Absolute path of the folder that word is no longer a reason for.
    public let path: String

    public init(word: String, path: String) {
        self.word = word
        self.path = path
    }
}
