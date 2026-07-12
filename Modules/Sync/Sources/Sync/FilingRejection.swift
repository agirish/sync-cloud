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
