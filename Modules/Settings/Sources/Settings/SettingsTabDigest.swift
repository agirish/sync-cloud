import Foundation

/// One Settings tab, as a surface *outside* this module needs it — a title, a line of prose saying
/// what is on it, a symbol, and the words a person might type to look for it.
///
/// Exists because the ⌘K palette and this module can't see each other: `FileExplorer` and
/// `Settings` are sibling packages, so the handover lives in `MacApp`, outside any SPM package.
/// The derivation lives here, where `SettingsTests` compiles it, leaving `MacApp` a `map` that a
/// call-site scan checks. Separate from the palette's `PaletteSettingsTab`, since a shared type
/// would have to move into `Sync` or `Design` to save one `map`.
public struct SettingsTabDigest: Equatable, Sendable {

    /// `SettingsTab.rawValue`, not the case, because the palette's route carries it across the
    /// package wall and back (`SettingsView.SettingsTab.init(rawValue:)` in `CommandPaletteHost`).
    public let id: String

    /// What the rail calls this tab: `displayName`, so a name that moves (Providers → Sources)
    /// moves here in the same edit.
    public let name: String

    /// One line saying what is on the tab — the only prose here not already on screen. It explains
    /// a keyword match: "Settings ▸ Ask Claude" alone doesn't say why `api key` found it, and
    /// `PaletteRouter.matchRange` bolds only text the query is in.
    public let detail: String

    /// The rail row's SF Symbol, so the palette row and the rail row wear the same glyph.
    public let symbol: String

    /// Every word that should reach this tab: the title of each control on it, plus each control's
    /// keywords, from ``SettingsSearchIndex``.
    ///
    /// Derived, never hand-written, so a renamed control can't leave ⌘K behind: the index has a
    /// scan test (`everyControlLabelInTheTabSourcesIsIndexed`) that now guards ⌘K too, and
    /// `everyTabsVocabularyIsItsIndexEntries` pins the derivation. Sorted and de-duplicated, since
    /// controls on one tab share keywords and a stable order compares directly in a test.
    public let vocabulary: [String]

    /// The pages each vocabulary word is on, lowercased word to `SettingsSubTab.rawValue`s in
    /// strip order, so ⌘K can open the page a query is most about. Empty for a one-page tab.
    public let pages: [String: [String]]

    /// The tab's pages' raw values in strip order.
    public let pageOrder: [String]

    public init(id: String, name: String, detail: String, symbol: String, vocabulary: [String],
                pages: [String: [String]] = [:], pageOrder: [String] = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.vocabulary = vocabulary
        self.pages = pages
        self.pageOrder = pageOrder
    }
}

extension SettingsView.SettingsTab {

    /// What is on this tab, in one line.
    ///
    /// Written for a palette row: it names the things you would come here to change, in the tab's
    /// own words, not the tab's purpose ("Appearance settings" would say nothing twice).
    ///
    /// **Each line has a width budget**: the palette is as wide as the Go to field, 320pt at the
    /// floor, and the row truncates the detail to one line, so a line cut mid-clause says less
    /// than a shorter one. `everyDetailFitsTheFloorWidth` in `SyncCloudTests` measures each
    /// against the row's real opening. Internal: `digest` is the public door.
    var paletteDetail: String {
        switch self {
        case .general: return "Startup, copying, notifications"
        case .appearance: return "Theme, accent, glass, text size"
        case .providers: return "Accounts, folders, name checks"
        case .browse: return "Hidden files, sorting, sidebar"
        case .sync: return "Differences, ignores, One-Way Sync"
        case .filing: return "Suggestions, people, duplicates"
        case .edit: return "Text, Markdown, and PDF"
        case .intelligence: return "Model, privacy, key, spending"
        case .advanced: return "Logging, digests, setup, resets"
        }
    }
}

public extension SettingsView.SettingsTab {

    /// This tab as a destination something outside the module can offer.
    var digest: SettingsTabDigest {
        let entries = SettingsSearchIndex.all.filter { $0.tab == self }
        let words = Set(entries.map(\.title) + entries.flatMap(\.keywords))
        var pages: [String: [String]] = [:]
        for page in subTabs {
            for entry in entries where entry.place.subTab == page {
                for word in [entry.title] + entry.keywords where pages[word.lowercased(), default: []].last != page.rawValue {
                    pages[word.lowercased(), default: []].append(page.rawValue)
                }
            }
        }
        return SettingsTabDigest(id: rawValue, name: displayName, detail: paletteDetail,
                                 symbol: symbolName, vocabulary: words.sorted(), pages: pages,
                                 pageOrder: subTabs.map(\.rawValue))
    }

    /// Every tab as a destination, in the rail's own order.
    ///
    /// `railGroups.flatMap`, not `allCases`, so a tab regrouped in the rail is regrouped in ⌘K too;
    /// `railGroupsCoverEveryTab` fails on a case in no group, so none drops out silently. A `let`,
    /// because the value can't change while the app runs and the palette reads it on every ⌘K.
    static let digests: [SettingsTabDigest] = railGroups.flatMap { $0 }.map(\.digest)
}
