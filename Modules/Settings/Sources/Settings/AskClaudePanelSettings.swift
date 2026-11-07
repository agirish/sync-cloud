import Foundation

/// The pinned Ask Claude panel's own settings: whether it is pinned to the window's right edge,
/// and the column's width. Apart from the floating panel's place and width, which keep their own
/// keys. Neither is in the settings catalog: the pin has a row in Settings, and Reset All clears
/// both with everything else.
public enum AskClaudePanelSettings {
    /// Whether the panel is pinned. The choice, not whether the window has the room for it now.
    public static let pinnedKey = "askClaudePanelPinned"
    /// The pinned column's width in points.
    public static let pinnedWidthKey = "askClaudePinnedWidth"
}
