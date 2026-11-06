import Foundation

/// A remembered filing rule: files whose tokens include all of `tokens` go into `destinationPath`.
/// Learned when the user corrects a suggestion and opts to remember it, then consulted on every
/// later scan. Matching is a subset test over filename and content tokens; rules stay small and
/// distinctive (often one anchor like "tesla") so they generalize without firing on common words.
public struct FilingRule: Sendable, Equatable, Codable, Identifiable, Hashable {
    /// The trigger tokens, canonical (lowercased, sorted). All must be present for a match.
    public let tokens: [String]
    /// Absolute path of the folder the matching file should be filed into.
    public let destinationPath: String
    /// Whether the rule is active. A disabled rule is kept, so the user's teaching isn't lost, but
    /// the engine skips it. Excluded from `id`, so disabling never changes a rule's identity.
    public var enabled: Bool

    /// Stable identity: the trigger set plus the destination, independent of `enabled`. Forgetting
    /// or replacing a rule matches on this.
    public var id: String { tokens.joined(separator: "+") + "→" + destinationPath }

    /// The destination's last path component, for compact display.
    public var destinationName: String { (destinationPath as NSString).lastPathComponent }

    public init(tokens: [String], destinationPath: String, enabled: Bool = true) {
        self.tokens = tokens
        self.destinationPath = destinationPath
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, destinationPath, enabled
    }

    /// Tolerant decode: a rule saved without `enabled` decodes as enabled. Throwing instead would
    /// fail the whole `[FilingRule]` decode and silently drop every rule the user taught.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decode([String].self, forKey: .tokens)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
