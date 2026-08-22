import Foundation

/// One Settings tab, as a surface *outside* this module needs it — a title, a line of prose saying
/// what is on it, a symbol, and the words a person might type to look for it.
///
/// **It exists because the ⌘K palette and this module cannot see each other.** `FileExplorer` and
/// `Settings` are sibling packages: neither depends on the other, and both sit on `Sync`, `Events`
/// and `Design`. So the palette's routing table cannot read `SettingsSearchIndex`, and the wiring
/// that hands it over has to live in `MacApp`, which belongs to no SPM package. Everything a test
/// could get wrong is therefore pulled *down* into here, where `SettingsTests` compiles it: the
/// derivation is the value below, and `MacApp`'s remaining job is a `map` that a call-site scan can
/// check.
///
/// A separate type from the palette's own `PaletteSettingsTab` rather than a shared one, because a
/// shared one would have to live in `Sync` or `Design` — a dependency added for a struct with five
/// stored properties, to save a one-line `map`.
public struct SettingsTabDigest: Equatable, Sendable {

    /// `SettingsTab.rawValue`. The raw value, not the case, because the palette's route carries it
    /// across the package wall and back — see `SettingsView.SettingsTab.init(rawValue:)` at the
    /// receiving end in `CommandPaletteHost`.
    public let id: String

    /// What the rail calls this tab: `displayName`, so a name that moves (Providers → Sources)
    /// moves here in the same edit.
    public let name: String

    /// One line saying what is on the tab.
    ///
    /// **The only prose here that is not already on screen somewhere**, and it earns its place: a
    /// palette row reading "Settings ▸ Intelligence" alone tells somebody who typed `api key`
    /// nothing about why it answered. The detail is what makes a vocabulary match legible, since a
    /// row matched through its keywords draws no emphasis in the title — `PaletteRouter.matchRange`
    /// only bolds text the query is actually in.
    public let detail: String

    /// The rail row's SF Symbol, so the palette row and the rail row wear the same glyph.
    public let symbol: String

    /// Every word that should reach this tab: the title of each control on it, plus each control's
    /// keywords, from ``SettingsSearchIndex``.
    ///
    /// **Derived, never hand-written.** Ten hand-kept keyword lists would drift from the index the
    /// first time a control was renamed, and nothing would fail — the index is the catalog with a
    /// scan test behind it (`everyControlLabelInTheTabSourcesIsIndexed`), so folding it down means
    /// that scan now guards ⌘K as well. `everyTabsVocabularyIsItsIndexEntries` pins the derivation.
    ///
    /// Sorted and de-duplicated: two controls on one tab commonly share a keyword ("cache" is on
    /// both of Intelligence's suggestion rows), and a stable order makes the value comparable in a
    /// test without the test having to sort it first.
    public let vocabulary: [String]

    public init(id: String, name: String, detail: String, symbol: String, vocabulary: [String]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.vocabulary = vocabulary
    }
}

extension SettingsView.SettingsTab {

    /// What is on this tab, in one line.
    ///
    /// Written for somebody reading a palette row, not a settings header: it names the *things you
    /// would come here to change*, in the words the tab itself uses. Deliberately not a description
    /// of the tab's purpose — "Appearance settings" under a row titled "Settings ▸ Appearance" is a
    /// line of text that says nothing twice.
    ///
    /// **These have a measured width budget**, because the palette's list is as wide as the Go to
    /// field, which is 620pt at the ceiling and **320pt at the floor**. The row draws the detail on
    /// one line with tail truncation, so an over-long line is not lost — it is cut — but a line cut
    /// mid-clause says less than a shorter one that finishes. `everyDetailFitsTheFloorWidth` in
    /// `SyncCloudTests` measures each against the real opening the row leaves for it.
    ///
    /// Internal, not public: `digest` is the door, and a second public spelling of the same string
    /// is a second thing to keep in step.
    var paletteDetail: String {
        switch self {
        case .general: return "Startup, sorting, and notifications"
        case .appearance: return "Theme, accent, glass, and surfaces"
        case .readability: return "Text size and row spacing"
        // Not "…and folder sources": the tab is called Sources, so that ending repeated the row's
        // own title back at the reader. Naming the two kinds is what the line is for.
        //
        // **And not "Cloud accounts and the local folders you added"**, which is what replacing the
        // repetition first produced: at 249.8pt it was the longest of the ten and the only one that
        // truncated at the floor width *at the default text size*, measured. Fixing the repetition
        // without measuring traded a line that said something twice for a line that did not finish.
        case .providers: return "Cloud accounts and local folders"
        // Not "The household": the tab is *why* the household is here, and a palette row is where
        // somebody who has never opened it decides whether it is what they want. Shortened from
        // "Who the filing rules attribute documents to", which at 225.0pt does not fit the real
        // 215.0pt opening at all — it only looked like it did against a hand-estimated 228.
        case .people: return "Who filing attributes documents to"
        case .sync: return "Conflicts, confirmations, and ignores"
        // The serial comma goes rather than a word: at 220.0pt against a 215.0pt opening this was
        // the second line the width guard caught, after Sources — and the hand-arithmetic that
        // preceded the guard put the opening at 228 and would have passed it.
        case .filing: return "Inbox, remembered rules, kept names"
        case .duplicates: return "Thresholds, and how copies are found"
        case .intelligence: return "On-device AI, Claude, and what it costs"
        case .advanced: return "Logging, digests, and maintenance"
        }
    }
}

public extension SettingsView.SettingsTab {

    /// This tab as a destination something outside the module can offer.
    var digest: SettingsTabDigest {
        let entries = SettingsSearchIndex.all.filter { $0.tab == self }
        let words = Set(entries.map(\.title) + entries.flatMap(\.keywords))
        return SettingsTabDigest(id: rawValue, name: displayName, detail: paletteDetail,
                                 symbol: symbolName, vocabulary: words.sorted())
    }

    /// Every tab as a destination, **in the rail's own order**.
    ///
    /// `railGroups.flatMap`, not `allCases`: the two agree today, and only one of them is the order
    /// a person has actually looked at. It also means a tab regrouped in the rail is regrouped in
    /// ⌘K without a second edit, and `railGroupsCoverEveryTab` already fails on a case that joins
    /// no group — so nothing can fall out of this list silently.
    ///
    /// A `let`, not a computed `var`: the palette reads this once per ⌘K, and as a computed
    /// property that was ten `SettingsSearchIndex` filters, ten `Set` builds and ten sorts of ~37
    /// strings, rebuilt every time, for a value that cannot change while the app is running.
    static let digests: [SettingsTabDigest] = railGroups.flatMap { $0 }.map(\.digest)
}
