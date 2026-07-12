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
    /// Whether the rule is active. A disabled rule is kept (so the user's teaching isn't lost) but
    /// the engine skips it when suggesting homes. Defaults to `true`; excluded from `id` so
    /// disabling a rule never changes its identity.
    public var enabled: Bool

    /// Stable identity: the trigger set plus the destination. Deliberately independent of
    /// `enabled` — forgetting or replacing a rule matches on this id.
    public var id: String { tokens.joined(separator: "+") + "→" + destinationPath }

    /// The last path component of the destination — for compact display.
    public var destinationName: String { (destinationPath as NSString).lastPathComponent }

    public init(tokens: [String], destinationPath: String, enabled: Bool = true) {
        self.tokens = tokens
        self.destinationPath = destinationPath
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, destinationPath, enabled
    }

    /// Tolerant decode: rules persisted before `enabled` existed have no such key, so treat a
    /// missing `enabled` as `true` rather than throwing — otherwise a single legacy rule would
    /// fail the whole `[FilingRule]` decode and silently drop every rule the user taught.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decode([String].self, forKey: .tokens)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
