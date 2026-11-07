import Foundation

/// One page inside a Settings tab, shown in the strip under the title row (TE332). A tab with
/// none is a single page (`SettingsView.SettingsTab.subTabs` is empty).
///
/// The raw values are a stored format: `settingsSelectedSubTabs` holds them, so never rename one.
public enum SettingsSubTab: String, CaseIterable, Sendable {
    // Appearance
    case look, textAndSpacing
    // Sources
    case cloudProviders, localFolders, nameChecks
    // Browse
    case panes, window
    // Compare
    case differences, ignored, oneWaySync
    // Organize
    case toFile, suggestions, people, duplicates
    // Edit
    case text, pdf
    // Ask Claude
    case claudeGeneral, privacy, keyAndSpending

    /// The tab whose strip shows this page.
    public var tab: SettingsView.SettingsTab {
        switch self {
        case .look, .textAndSpacing: return .appearance
        case .cloudProviders, .localFolders, .nameChecks: return .providers
        case .panes, .window: return .browse
        case .differences, .ignored, .oneWaySync: return .sync
        case .toFile, .suggestions, .people, .duplicates: return .filing
        case .text, .pdf: return .edit
        case .claudeGeneral, .privacy, .keyAndSpending: return .intelligence
        }
    }

    /// What the strip calls it. Title case, as the rail is.
    public var displayName: String {
        switch self {
        case .look: return "Look"
        case .textAndSpacing: return "Text & Spacing"
        case .cloudProviders: return "Cloud Providers"
        case .localFolders: return "Local Folders"
        case .nameChecks: return "Name Checks"
        case .panes: return "Panes"
        case .window: return "Window"
        case .differences: return "Differences"
        case .ignored: return "Ignored"
        case .oneWaySync: return "One-Way Sync"
        case .toFile: return "To File"
        case .suggestions: return "Suggestions"
        case .people: return "People"
        case .duplicates: return "Duplicates"
        case .text: return "Text"
        case .pdf: return "PDF"
        // "General", not "Chat": its model is the default for every chat (TE332 JU).
        case .claudeGeneral: return "General"
        case .privacy: return "Privacy"
        case .keyAndSpending: return "Key & Spending"
        }
    }
}

/// Where in Settings something is: a tab, and the page inside it when the tab has pages.
///
/// The search index, Claude's catalog and every deep link name a place, so landing on the right
/// tab can't leave the reader on the wrong page of it. A place with no sub-tab on a tab that has
/// pages opens the page last shown there.
public struct SettingsPlace: Hashable, Sendable {
    public let tab: SettingsView.SettingsTab
    public let subTab: SettingsSubTab?

    public init(_ tab: SettingsView.SettingsTab) {
        self.tab = tab
        subTab = nil
    }

    public init(_ subTab: SettingsSubTab) {
        tab = subTab.tab
        self.subTab = subTab
    }

    /// "Compare ▸ Ignored", or the tab's name alone. For prose that follows "Settings ▸ ".
    public var name: String {
        subTab.map { "\(tab.displayName) ▸ \($0.displayName)" } ?? tab.displayName
    }

    /// Where a stored `settingsSelectedTab` resolves to, including when it resolves to nothing.
    ///
    /// Here, not in `MacApp/ContentView.swift` where the launch read happens, so a test can reach
    /// it. The stored value comes from past builds and from `defaults`, outside the app's control:
    /// **never trap on it**, or a retired tab crashes the launch. A tab folded into another opens
    /// its new home.
    ///
    /// Falls back to Appearance, the tab that depends on nothing (no engine, provider list or
    /// roster), so it's safe whatever state the app is in.
    public static func resolvingStored(_ raw: String?) -> SettingsPlace {
        guard let raw else { return SettingsPlace(.appearance) }
        if let tab = SettingsView.SettingsTab(rawValue: raw) { return SettingsPlace(tab) }
        switch raw {
        case "readability": return SettingsPlace(.textAndSpacing)
        case "people": return SettingsPlace(.people)
        case "duplicates": return SettingsPlace(.duplicates)
        default: return SettingsPlace(.appearance)
        }
    }

    // The places the search index and the catalog name, one per page, so an entry can't name a
    // paged tab without saying which page.
    static let general = SettingsPlace(SettingsView.SettingsTab.general)
    static let advanced = SettingsPlace(SettingsView.SettingsTab.advanced)
    static let look = SettingsPlace(SettingsSubTab.look)
    static let textAndSpacing = SettingsPlace(SettingsSubTab.textAndSpacing)
    static let cloudProviders = SettingsPlace(SettingsSubTab.cloudProviders)
    static let localFolders = SettingsPlace(SettingsSubTab.localFolders)
    static let nameChecks = SettingsPlace(SettingsSubTab.nameChecks)
    static let panes = SettingsPlace(SettingsSubTab.panes)
    static let window = SettingsPlace(SettingsSubTab.window)
    static let differences = SettingsPlace(SettingsSubTab.differences)
    static let ignored = SettingsPlace(SettingsSubTab.ignored)
    static let oneWaySync = SettingsPlace(SettingsSubTab.oneWaySync)
    static let toFile = SettingsPlace(SettingsSubTab.toFile)
    static let suggestions = SettingsPlace(SettingsSubTab.suggestions)
    static let people = SettingsPlace(SettingsSubTab.people)
    static let duplicates = SettingsPlace(SettingsSubTab.duplicates)
    static let text = SettingsPlace(SettingsSubTab.text)
    static let pdf = SettingsPlace(SettingsSubTab.pdf)
    static let claudeGeneral = SettingsPlace(SettingsSubTab.claudeGeneral)
    static let privacy = SettingsPlace(SettingsSubTab.privacy)
    static let keyAndSpending = SettingsPlace(SettingsSubTab.keyAndSpending)
}

/// The page last shown on each paged tab, so coming back to a tab finds the page you left.
///
/// One string in defaults, `tab=page;tab=page`, read through `@AppStorage` so a deep link that
/// writes it while the sheet is open moves the open sheet too. An unknown pair is skipped, never
/// trapped on: the value outlives builds.
public enum SettingsSubTabMemory {
    public static let defaultsKey = "settingsSelectedSubTabs"

    static func decode(_ stored: String) -> [SettingsView.SettingsTab: SettingsSubTab] {
        var pages: [SettingsView.SettingsTab: SettingsSubTab] = [:]
        for pair in stored.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let tab = SettingsView.SettingsTab(rawValue: parts[0]),
                  let page = SettingsSubTab(rawValue: parts[1]), page.tab == tab else { continue }
            pages[tab] = page
        }
        return pages
    }

    static func encode(_ pages: [SettingsView.SettingsTab: SettingsSubTab]) -> String {
        pages.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
            .joined(separator: ";")
    }

    /// The page a tab opens on: the one last shown, else its first.
    static func page(for tab: SettingsView.SettingsTab, in stored: String) -> SettingsSubTab? {
        decode(stored)[tab] ?? tab.subTabs.first
    }

    /// `stored` with `page` remembered for its tab.
    static func remembering(_ page: SettingsSubTab, in stored: String) -> String {
        var pages = decode(stored)
        pages[page.tab] = page
        return encode(pages)
    }

    /// Remembers a place's page, so the sheet opens on it. A place without one changes nothing.
    public static func remember(_ place: SettingsPlace, in defaults: UserDefaults = .standard) {
        guard let page = place.subTab else { return }
        defaults.set(remembering(page, in: defaults.string(forKey: defaultsKey) ?? ""), forKey: defaultsKey)
    }
}
