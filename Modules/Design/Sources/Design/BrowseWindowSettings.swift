import Foundation

/// The Browse window's View-menu switches, as stored keys and defaults. Here, below the app, so
/// Settings ▸ Browse can offer them; `ContentView` reads the same keys through `@AppStorage`.
/// The strings are a persistence format: never reword one.
public enum BrowseWindowSettings {
    /// Whether the tab bar shows above each pane.
    public static let tabBarVisibleKey = "browseTabBarVisible"
    public static let tabBarVisibleDefault = false
    /// Whether the status bar shows under the Browse pane.
    public static let statusBarVisibleKey = "browseStatusBarVisible"
    public static let statusBarVisibleDefault = true
    /// Whether the folder sidebar shows, in every workspace but Edit, which keeps its own.
    public static let sidebarVisibleKey = "browseSidebarVisible"
    public static let sidebarVisibleDefault = true
    /// What the sidebar's Recents heading lists: a ``RecentsMode`` raw value.
    public static let sidebarRecentsModeKey = "browseSidebarRecentsMode"
}
