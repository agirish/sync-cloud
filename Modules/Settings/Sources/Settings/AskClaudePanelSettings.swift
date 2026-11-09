import Foundation

/// Ask Claude's column in the window: whether it is open, and its width. Neither is in the settings
/// catalog and neither has a row in Settings: the window remembers whether the column was left open
/// or closed, and Reset All clears both with everything else.
public enum AskClaudePanelSettings {
    /// Whether the column was left open (`"open"`) or closed (`"closed"`). Absent until it has been
    /// opened or closed once, which is how the first time is told: the column opens by itself once an
    /// API key is saved, then keeps whatever the person chooses.
    public static let openKey = "askClaudeColumnOpen"
    /// The column's width in points. The key keeps the name the pinned column gave it.
    public static let widthKey = "askClaudePinnedWidth"
}
