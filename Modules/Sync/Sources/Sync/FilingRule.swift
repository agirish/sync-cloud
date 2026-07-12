import Foundation

/// A remembered filing rule (F3): "files whose tokens include all of `tokens` go into
/// `destinationPath`." Learned when the user corrects a suggestion and opts to remember it, then
/// consulted on every later scan so the next matching file files itself.
///
/// Matching is a subset test — a file matches when its tokens (filename ∪ content) contain *all*
/// of the rule's trigger tokens. Rules are kept deliberately small and distinctive (usually a
/// single anchor like "tesla") so they generalize without over-firing on a common word.
public struct FilingRule: Sendable, Equatable, Codable, Identifiable, Hashable {
    /// The trigger tokens — canonical (lowercased, sorted). All must be present for a match.
    public let tokens: [String]
    /// Absolute path of the folder the matching file should be filed into.
    public let destinationPath: String

    /// Stable identity: the trigger set plus the destination.
    public var id: String { tokens.joined(separator: "+") + "→" + destinationPath }

    /// The last path component of the destination — for compact display.
    public var destinationName: String { (destinationPath as NSString).lastPathComponent }

    public init(tokens: [String], destinationPath: String) {
        self.tokens = tokens
        self.destinationPath = destinationPath
    }
}
