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

/// Compare ▸ Differences' remembered table choice, here so Settings can offer it beside the table
/// in FileExplorer that reads it. The string is a persistence format: never reword it.
public enum DifferencesSettings {
    /// Whether the Differences table breaks its rows into a section per top-level folder.
    public static let groupByFolderKey = "differencesGroupByFolder"
    public static let groupByFolderDefault = true
}
