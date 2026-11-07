import Foundation

/// A filing rule learned by example: files whose tokens include all of `tokens` go into
/// `destinationPath`. `FilingEngine.rule(forFileNamed:contentTokens:filedInto:)` derives one from a
/// correction, and `rememberAutomationRule` saves it as an automation. Matching is a subset test
/// over filename and content tokens; rules stay small and distinctive (often one anchor like
/// "tesla") so they generalize without firing on common words.
///
/// No longer stored: builds 2.1 through 7.0 converted the old `tidyFilingRules` store into
/// automations at launch.
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
}
