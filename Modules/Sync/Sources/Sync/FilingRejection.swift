import Foundation

/// A remembered rejection, the negative counterpart to `FilingRule`. When the user says "not that
/// folder" via "Try another", the file's salient tokens and the folder are recorded so this scan's
/// re-ask and later scans steer clear. A file matches when its tokens contain all of `tokens`.
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

/// "This word is not a reason for this folder": what a rejection teaches about other files.
/// ``FilingRejection`` keys on every salient word of the rejected name, so it only matches that
/// file and its near-twins. This records the one word the match rested on, and is narrower the
/// other way: it refuses the folder only when a keyword match rests on rejected words alone. The
/// survey's own ranking, or a second shared word, still reaches it.
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
