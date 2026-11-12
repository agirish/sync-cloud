import Foundation

/// The note at the top of a new chat (TE347a). Its ✕ hides it from every new chat on this Mac
/// until Settings ▸ Ask Claude ▸ General turns it back on (decision NM).
public enum AskClaudeIntro {

    /// On by default.
    public static let shownKey = "askClaudeIntro"

    public static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: shownKey) as? Bool ?? true
    }
}
