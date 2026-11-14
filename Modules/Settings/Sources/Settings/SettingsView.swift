import Events
import Foundation
import ServiceManagement
import SwiftUI
import Sync
import Design
import UserNotifications

/// UserDefaults keys for General settings that are read outside the Settings module — the app
/// delegate's quit guard and ContentView's launch-time seeding both reference the same literals,
/// so they live here as the single source of truth.
public enum GeneralSettings {
    /// Bool (default true). When false, the app quits immediately even with file operations in flight.
    public static let warnBeforeQuitKey = "warnBeforeQuitDuringOperations"
    /// Bool (default false). Seeds `FileSyncManager.showHiddenFiles` at launch.
    public static let showHiddenByDefaultKey = "showHiddenFilesByDefault"
    /// Bool (default true). When false, Delete acts immediately — items still go to the Trash
    /// and remain undoable. Read by `FileActionHandler.confirmDelete`.
    public static let confirmBeforeDeleteKey = "confirmBeforeDelete"
    /// Bool (default true). When false, copies and moves start immediately without the
    /// what-goes-where confirmation. Read by the app's `transferConfirmer` wiring.
    public static let confirmBeforeTransferKey = "confirmBeforeCopyMove"

    /// Bool (default true). When false, the tab strip each pane had when the app last quit is not
    /// restored, so every pane opens with one tab at its source's landing folder. A pane with no
    /// saved strip takes the source's own opening folder.
    public static let restoreLastFocusKey = "restoreLastFocusOnLaunch"
    /// Bool (default false). Posts a system notification when an operation banner lands
    /// while SyncCloud is not the active app. Read by `OperationNotifier`.
    public static let notifyOnBackgroundCompletionKey = "notifyOnBackgroundCompletion"

    /// String (default "TODO"). The provider-root-relative folder where loose files pile up. It
    /// names a folder and moves nothing: `ContentView.filingInboxFolder` resolves it for Organize's
    /// overview to offer as a one-click scope.
    ///
    /// Empty is a real value and means "no offer". The Settings field shows `None` as its
    /// placeholder rather than this default, so an emptied field can't pass for an untouched one.
    public static let filingInboxRelativePathKey = "filingInboxRelativePath"

    /// The delete-confirmation flag with its default-true semantics (a bare `bool(forKey:)`
    /// would read an unset key as false and silently skip the alert).
    public static func shouldConfirmBeforeDelete(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: confirmBeforeDeleteKey) as? Bool) ?? true
    }

    /// The copy/move-confirmation flag with the same default-true semantics.
    public static func shouldConfirmBeforeTransfer(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: confirmBeforeTransferKey) as? Bool) ?? true
    }

    /// The restore-last-focus flag with its default-true semantics.
    public static func shouldRestoreLastFocus(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: restoreLastFocusKey) as? Bool) ?? true
    }
}

/// The app's settings window, hosted in the SwiftUI `Settings` scene. Follows the standard
/// macOS preferences layout: toolbar tabs (Appearance / Providers / Sync) over grouped forms.
public struct SettingsView: View {
    /// The rail's rows, in rail order — and the format of the `settingsSelectedTab` default read
    /// at window creation, so the raw values are stable. `CaseIterable` backs both the rail and the
    /// search index's "every entry points at a real tab" invariant.
    ///
    /// Never rename a case: a label can change (`providers` shows as "Sources", `sync` as
    /// "Compare", `intelligence` as "Ask Claude"), but the raw value is what a stored
    /// `settingsSelectedTab` holds. A tab folded into another (Readability, People, Duplicates)
    /// loses its case and keeps its raw value in `SettingsPlace.resolvingStored(_:)`, which opens
    /// its new home.
    public enum SettingsTab: String, CaseIterable, Sendable {
        case general
        /// Look, and Text & Spacing (Readability until TE332).
        case appearance
        case providers
        /// The Browse workspace's panes and window, most of which apply in every workspace.
        case browse
        /// Shown as "Compare", the workspace's own name.
        case sync
        /// Shown as "Organize". Named for `Workspace.filing`, not the label, so the tab is one
        /// grep away from the code it governs. People and Duplicates are its sub-tabs.
        case filing
        /// The Edit workspace's remembered choices, otherwise set only from its menus.
        case edit
        /// Shown as "Ask Claude": the chat, its privacy, the key and what Claude costs.
        case intelligence
        case advanced

        /// The human-readable tab name shown in the rail and as the dim subtitle on a search
        /// result. Kept here so the labels have a single source of truth.
        public var displayName: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            // "Sources", not "Providers": the tab lists plain folders beside the cloud accounts,
            // and a folder is not a provider. The case keeps its name for the stored raw value.
            case .providers: return "Sources"
            case .browse: return "Browse"
            // The workspace bar's name for the same feature.
            case .sync: return "Compare"
            case .filing: return "Organize"
            case .edit: return "Edit"
            // One tab for everything Claude (TE332 JT). `SettingsSearchIndex` carries "API key"
            // and "Anthropic" here.
            case .intelligence: return "Ask Claude"
            case .advanced: return "Advanced"
            }
        }

        /// The rail row's SF Symbol. Outline weight throughout: mixed filled and outline glyphs
        /// read as though the filled ones meant something. Browse, Compare, Organize and Edit use
        /// their workspaces' glyphs (`Workspace.symbol`), since the row and the bar button reach
        /// the same feature.
        public var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .providers: return "cloud"
            case .browse: return "folder"
            case .sync: return "arrow.left.arrow.right"
            case .filing: return "folder.badge.gearshape"
            case .edit: return "square.and.pencil"
            case .intelligence: return "sparkles"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        /// The tab's sub-tabs, in strip order. Empty for a tab that is one page.
        public var subTabs: [SettingsSubTab] {
            SettingsSubTab.allCases.filter { $0.tab == self }
        }

        /// Where the "set up Claude" offer on Organize's results deep-links to: the page that holds
        /// the key. A saved key is what turns Refine on (TE335), so that is the one thing to set up.
        ///
        /// Named here, not written at the call site, because that site is in `MacApp/`, which no
        /// package test can reach. A wrong page there would still compile and open Settings; this
        /// constant lets `theCloudRefineOfferLandsOnThePageThatHoldsTheKey` check it.
        public static let cloudRefineSetup = SettingsPlace(.keyAndSpending)

        /// The pages the layout fit-guard (`SettingsLayoutTests`) does not hold to fitting the
        /// sheet's opening without scrolling. `everyPageIsEitherFitTestedOrExplicitlyExempt`
        /// measures every page minus this set, so a new page either fits or earns a line here:
        /// - Cloud Providers and Local Folders grow with the Mac's provider and folder lists.
        /// - Name Checks grows with the allowed-names list (`KeptNamesList`, one row per name),
        ///   passing a 1280×800 display's opening at about the 20th name.
        /// - People grows with the roster (`PeopleList` draws one row per person).
        /// - To File grows with the cloud sources, a Folder surveys row each; seven fill it.
        /// - Compare ▸ Ignored grows with the ignored items and name patterns, a row each.
        /// - One-Way Sync is drawn by the app (`SettingsView.oneWaySync`), so a test here has
        ///   nothing to measure.
        /// - Ask Claude ▸ Privacy grows with the hidden and shared lists.
        ///
        /// **A fit-guard fixture built with a nil dependency measures only the empty state**, so a
        /// page with an unbounded list belongs here however well its `else` branch fits. Name
        /// Checks' empty state is still fit-tested, by `theNameChecksPageFitsItsOpeningWithNothingAllowed`,
        /// and its exemption by `theNameChecksPageOutgrowsItsOpeningOnceNamesAreAllowed`.
        /// Revisit an exemption when a page's shape changes.
        public static let exemptFromFitGuard: Set<SettingsPlace> = [
            SettingsPlace(.cloudProviders), SettingsPlace(.localFolders), SettingsPlace(.nameChecks),
            SettingsPlace(.people), SettingsPlace(.oneWaySync), SettingsPlace(.privacy),
            SettingsPlace(.toFile), SettingsPlace(.ignored),
        ]

        /// The rail's rows in groups, separated by a hairline.
        ///
        /// Flat rows read as a pile, but the rail is fixed-height and doesn't scroll, so each
        /// separator costs space; `theRailFitsItsOpening` measures the rail with them. Groups are by
        /// question asked: the app itself, where files come from, the workspaces in the workspace
        /// bar's order, then Claude and the engine room. Spelled out, not derived, so a new case
        /// must name its group (`railGroupsCoverEveryTab`).
        public static let railGroups: [[SettingsTab]] = [
            [.general, .appearance],
            [.providers],
            [.browse, .sync, .filing, .edit],
            [.intelligence, .advanced],
        ]
    }

    /// UserDefaults key holding the tab the Settings overlay opens on (a `SettingsTab` raw
    /// value). ContentView reads it once at launch to honor the GUI-verification recipe, which
    /// writes it via `defaults`; the literal is a stable format.
    public static let selectedTabDefaultsKey = "settingsSelectedTab"

    /// Selected tab, owned by the host (ContentView) so it survives an overlay open/close cycle
    /// and can be preset — e.g. the invalid-pane fix-it action opens straight to Providers.
    @Binding private var selectedTab: SettingsTab

    /// Dismisses the overlay. Invoked by the ✕ button and the Escape shortcut; the host also
    /// dismisses on a click outside the card.
    private let onClose: () -> Void

    /// The app's sync engine, for the settings that read or act on live engine state (the
    /// ignored-items list, the orphan sweep). Optional so previews and hosts without an
    /// engine still render; the dependent controls hide when nil.
    private let syncManager: FileSyncManager?
    /// The sources, for Organize's Folder surveys. The host injects it, as it does for every tab.
    @EnvironmentObject private var settings: SettingsManager

    /// Runs the full settings reset (defaults wipe plus the host's re-seeding of live state).
    /// Provided by the host; the Reset control hides when nil.
    private let onResetAllSettings: (() -> Void)?
    /// Opens the guided setup sheet from General.
    private let onRunSetup: (() -> Void)?
    /// Forgets that setup has run, from Advanced.
    private let onResetSetup: (() -> Void)?
    /// Hands a person to the app's gather, the same surface ⌘K's People rows reach. nil where
    /// there is no app behind the sheet (tests, previews), which hides the button.
    private let onShowPerson: ((Person) -> Void)?
    /// Opens the app's Help book at a topic id. A callback because `HelpBook` lives in `MacApp`,
    /// which this module can't see. nil in tests and previews, which hides the pointer.
    ///
    /// Settings and Help are mutually exclusive overlays on one window, so the host closes this
    /// sheet on the way and the reader lands on the article.
    private let onOpenHelp: ((String) -> Void)?

    /// The header search text. While non-empty it takes over the content area with a list of
    /// matching settings across every tab; selecting one jumps to its tab and clears this.
    @State private var searchQuery = ""

    /// Whether the search field currently has meaningful (non-whitespace) input. Drives the
    /// swap between the normal tab content and the search results.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entries matching the current query, in index order. Empty while the field is empty.
    private var searchResults: [SettingsSearchEntry] {
        filterSettings(SettingsSearchIndex.all, query: searchQuery)
    }

    /// The window's accent hue, for the rail's selected row. Read here rather than passed in so
    /// the sheet keeps tracking the hue while the user changes it on the Appearance tab.
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue }

    /// The app's text-size setting. The sheet is sized in points but its contents in scaled type,
    /// so the sheet grows with the type or the taller tabs scroll at Large.
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent: Int = FontSize.medium.percent
    private var fontSize: FontSize { FontSize(percent: fontSizePercent) }

    /// The space the host has to place the sheet in, or `nil` when the host doesn't say. The
    /// window's own minimum is 760×560, which after `hostMargin` is smaller than the sheet wants
    /// in both axes at any text size, so without this the sheet would hang off a small window.
    private let availableSize: CGSize?

    public init(
        selection: Binding<SettingsTab>,
        onClose: @escaping () -> Void,
        syncManager: FileSyncManager? = nil,
        onResetAllSettings: (() -> Void)? = nil,
        onRunSetup: (() -> Void)? = nil,
        onResetSetup: (() -> Void)? = nil,
        onShowPerson: ((Person) -> Void)? = nil,
        onOpenHelp: ((String) -> Void)? = nil,
        onOpenRules: (() -> Void)? = nil,
        availableSize: CGSize? = nil,
        oneWaySync: AnyView? = nil,
        onCustomizePaneBar: (() -> Void)? = nil,
        savedSignatures: AnyView? = nil
    ) {
        _selectedTab = selection
        self.onClose = onClose
        self.syncManager = syncManager
        self.onResetAllSettings = onResetAllSettings
        self.onRunSetup = onRunSetup
        self.onResetSetup = onResetSetup
        self.onShowPerson = onShowPerson
        self.onOpenHelp = onOpenHelp
        self.onOpenRules = onOpenRules
        self.availableSize = availableSize
        self.oneWaySync = oneWaySync
        self.onCustomizePaneBar = onCustomizePaneBar
        self.savedSignatures = savedSignatures
    }

    /// Compare ▸ One-Way Sync, supplied by the app because its state lives above Settings.
    private let oneWaySync: AnyView?

    /// Opens the pane bar's Customize sheet, for Browse ▸ Panes' "Customize Pane Bar…". A callback
    /// because the sheet is Dashboard's, which this module can't see; nil hides the row.
    private let onCustomizePaneBar: (() -> Void)?

    /// Edit ▸ PDF's saved Fill & Sign signatures, each with Delete…, drawn by FileExplorer, which
    /// owns the store and the pictures. Supplied by the app; nil leaves the section out.
    private let savedSignatures: AnyView?

    /// Opens the Organize workspace on its Rules, for To File's "Open Rules". A callback because
    /// the workspace lives in `MacApp`; nil hides the button.
    private let onOpenRules: (() -> Void)?

    /// The page last shown on each paged tab — see `SettingsSubTabMemory`.
    @AppStorage(SettingsSubTabMemory.defaultsKey) private var subTabMemory = ""

    /// The page the selected tab shows, or nil for a one-page tab.
    private var selectedPage: SettingsSubTab? {
        SettingsSubTabMemory.page(for: selectedTab, in: subTabMemory)
    }

    /// The one way to a place inside the sheet: a search result, a page in the strip, or a jump
    /// from one page to another. Remembers the page before switching the tab, so the tab never
    /// draws a page it is about to leave.
    private func go(to place: SettingsPlace) {
        if let page = place.subTab {
            subTabMemory = SettingsSubTabMemory.remembering(page, in: subTabMemory)
        }
        selectedTab = place.tab
        searchQuery = ""
    }

    /// The sheet's size: see `SettingsSheetMetrics`, which owns the arithmetic.
    private var sheetSize: CGSize {
        SettingsSheetMetrics.resolvedSize(textScale: fontSize.scale, available: availableSize)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .scaledFont(.headline)
                Spacer()
                CloseButton(action: onClose)
                    // Escape closes the overlay even when focus is elsewhere in the card.
                    .keyboardShortcut(.cancelAction)
                    .shortcutKeycap("esc")
                    .help(ShortcutHint.tooltip("Close settings", "esc"))
                    .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 16)
            // Fixed, not padding-derived: the content opening is computed as
            // `height − headerHeight − 1`, and every layout assertion rests on that.
            .frame(height: SettingsSheetMetrics.headerHeight * fontSize.scale)

            Divider()

            HStack(spacing: 0) {
                // Search and the tabs stand down the left, the macOS Settings convention, so the
                // content column keeps its full height.
                SettingsRail(selection: $selectedTab, query: $searchQuery, hue: selectedHue)
                    .background(Color.primary.opacity(0.035))

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        // The sheet's switches, the Tint and text-size sliders and its checkboxes take the hue
        // being picked here, not the Mac's accent, and follow it as it changes.
        .nativeControlAccent(selectedHue)
    }

    /// The right-hand column: the selected page, or the search results standing in for it.
    @ViewBuilder
    private var content: some View {
        if isSearching {
            SettingsSearchResults(results: searchResults) { place in
                // The jump: land on the matching page and drop back to normal content.
                go(to: place)
            }
        } else {
            VStack(spacing: 0) {
                if let selectedPage {
                    SettingsSubTabStrip(tab: selectedTab,
                                        selection: Binding(get: { selectedPage },
                                                           set: { go(to: SettingsPlace($0)) }),
                                        hue: selectedHue)
                        // A strip per tab: a lens kept across tabs glided in from the last tab's
                        // page, across labels that aren't this tab's.
                        .id(selectedTab)
                    Divider()
                }
                page(selectedTab, selectedPage)
                    // A page of its own, so one page's scroll position, open rows and drafts don't
                    // carry onto the next page drawn by the same view.
                    .id(selectedPage.map(\.rawValue) ?? selectedTab.rawValue)
            }
        }
    }

    /// One page: a one-page tab, or a tab's sub-tab.
    @ViewBuilder
    private func page(_ tab: SettingsTab, _ subTab: SettingsSubTab?) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab()
        case .appearance:
            if subTab == .textAndSpacing { ReadabilitySettingsTab() } else { AppearanceSettingsTab() }
        case .providers:
            ProvidersSettingsTab(page: subTab ?? .cloudProviders, syncManager: syncManager)
        case .browse:
            BrowseSettingsTab(page: subTab ?? .panes, onCustomizePaneBar: onCustomizePaneBar)
        case .sync:
            SyncSettingsTab(page: subTab ?? .differences, syncManager: syncManager, oneWaySync: oneWaySync)
        case .filing:
            switch subTab ?? .toFile {
            case .people:
                PeopleSettingsTab(syncManager: syncManager, onShowPerson: onShowPerson)
            case .duplicates:
                DuplicatesSettingsTab(syncManager: syncManager)
            case .suggestions:
                OrganizeSuggestionsPage(syncManager: syncManager, onOpenHelp: onOpenHelp,
                                        onJump: { go(to: $0) })
            default:
                FilingSettingsTab(syncManager: syncManager,
                                  surveySources: settings.enabledProviders.filter { !$0.isLocalFolder }
                                      .map { ($0.displayName, settings.landingPath(for: $0.id)) },
                                  onOpenRules: onOpenRules)
            }
        case .edit:
            EditSettingsTab(page: subTab ?? .text, savedSignatures: savedSignatures)
        case .intelligence:
            IntelligenceSettingsTab(page: subTab ?? .claudeGeneral)
        case .advanced:
            AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings,
                                onRunSetup: onRunSetup, onResetSetup: onResetSetup,
                                resetAllRaises: { [settings, syncManager] in
                SettingsActions(settings: settings, sync: syncManager,
                                lookup: SettingsLookup(defaults: .standard, settings: settings, keyIsSaved: { false },
                                                       hiddenCount: { 0 }, isHidden: { _ in false },
                                                       loginItemIsOn: { false })).resetAllRaises()
            })
        }
    }
}

/// The strip of a paged tab's sub-tabs, centred over its page. Drawn as the rail's rows are, not
/// as a system segmented control: the chosen page takes the same accent fill as the chosen tab
/// beside it (a glass lens that glides between pages in Frosted and Clear), and its labels follow
/// the app's text size. A `.segmented` picker here drew its selection grey, under its own glass.
///
/// Fixed in height, like the title row, so each page's opening is arithmetic
/// (`SettingsSheetMetrics.pageOpening`).
struct SettingsSubTabStrip: View {
    let tab: SettingsView.SettingsTab
    @Binding var selection: SettingsSubTab
    let hue: LiquidGlassHue
    @Environment(\.appFontScale) private var scale

    /// The strip's selection lens in Frosted and Clear — see `SelectionLens`. One channel per tab,
    /// so a lens never travels from one tab's strip to another's.
    static func lensChannel(_ tab: SettingsView.SettingsTab) -> SelectionLensChannel {
        SelectionLensChannel("settings.subtabs.\(tab.rawValue)")
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tab.subTabs, id: \.self) { page in
                pageButton(page)
            }
        }
        // The lens first, then the track behind it: a track applied inside the host is drawn over
        // the lens, and its grey wash took the accent out of the chosen page.
        .selectionLensHost(Self.lensChannel(tab), selected: selection,
                           style: .fill(.roundedRect(Radius.chip), color: hue.accentFillColor))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Radius.chip + 2, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .frame(maxWidth: .infinity)
        .frame(height: SettingsSheetMetrics.subTabStripHeight * scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.displayName) pages")
    }

    private func pageButton(_ page: SettingsSubTab) -> some View {
        let isSelected = page == selection
        return Button { selection = page } label: {
            Text(page.displayName)
                .scaledFont(.callout)
                .lineLimit(1)
                .selectionLensLabelInk(isSelected: isSelected, onFill: hue.onAccentLabelColor, unselected: .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        SelectionLensTodayMarker {
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(hue.accentFillColor)
                        }
                    }
                }
                .selectionLensStop(Self.lensChannel(tab), id: page)
                .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        // As the rail's rows: at Solid the chosen one takes `.filled` with the on-fill tint; under
        // the lens, `.segment`.
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: hue.accentColor,
                                        filledTint: hue.onAccentLabelColor, shape: .roundedRect(Radius.chip))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Settings search

public extension SettingsPlace {
    /// The page that holds a setting or section named in words (“Ask Claude”, “monthly limit”,
    /// “API key”), by the same index Settings' own search reads: an exact title first, then a title
    /// containing it, then a keyword. Nil when nothing matches.
    static func holding(_ words: String) -> SettingsPlace? {
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let entries = SettingsSearchIndex.all
        // Whole words: "log" is Log level, not "Launch SyncCloud at login".
        func wordsOf(_ text: String) -> [Substring] { text.lowercased().split { !$0.isLetter && !$0.isNumber } }
        let wanted = wordsOf(needle)
        func holdsWords(_ title: String) -> Bool {
            let have = wordsOf(title)
            return !wanted.isEmpty && have.indices.contains { start in
                have.dropFirst(start).starts(with: wanted)
            }
        }
        return (entries.first { $0.title.lowercased() == needle }
                ?? entries.first { $0.keywords.contains { $0.lowercased() == needle } }
                ?? entries.first { holdsWords($0.title) }
                ?? entries.first { $0.matches(needle) })?.place
    }
}

/// One searchable settings control: the page it lives on, its display title, and a few
/// synonyms/keywords so a search for "blur" finds "Glass effect" and "trash" finds the
/// delete confirmation. Pure data with a pure match — no SwiftUI — so the filter is unit-testable.
struct SettingsSearchEntry: Identifiable, Sendable {
    let place: SettingsPlace
    let title: String
    let keywords: [String]

    init(at place: SettingsPlace, title: String, keywords: [String]) {
        self.place = place
        self.title = title
        self.keywords = keywords
    }

    var tab: SettingsView.SettingsTab { place.tab }

    /// Stable across renders: a title is unique within its tab, and tabs are distinct.
    var id: String { "\(tab.rawValue).\(title)" }

    /// Case-insensitive substring match against the title or any keyword. The query is trimmed,
    /// and an empty query never matches — the results stay hidden until the user types something.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }
}

/// The catalog of settings the header search can jump to: one entry per control that *changes*
/// something, across every page. An entry on a paged tab names its page, so the jump lands on it. One kind of on-screen label deliberately gets no entry of its own,
/// because it is not a setting: the `SettingsSection` headers that only group other controls
/// ("Conflicts", "Logging", "Inbox and rules"). Each is reached through a control it belongs to.
///
/// Titles mirror the on-screen label, or extend it where the label alone would be ambiguous in
/// the results ("Surface tint" for the section headed "Tint"). Keywords add the words people are
/// likely to type instead.
///
/// Keep this in sync when a control is added or renamed.
/// `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed` fails on a control label that
/// reaches nothing here, but can't see a title built at runtime.
enum SettingsSearchIndex {
    static let all: [SettingsSearchEntry] = [
        // General
        .init(at: .general, title: "Launch SyncCloud at login",
              keywords: ["launch", "login", "startup", "start", "open at login", "boot", "auto start"]),
        .init(at: .general, title: "Reopen panes where I left off",
              keywords: ["restore", "reopen", "last focus", "remember folders", "panes", "resume"]),
        .init(at: .general, title: "Notify when operations finish in the background",
              keywords: ["notification", "notify", "background", "alert", "banner", "system notification"]),
        .init(at: .general, title: "Notify when One-Way Sync needs attention",
              // Notification words only: "dropbox", "one way" and "mirror" belong to Sources and
              // One-Way Sync, and ⌘K would otherwise open General for them.
              keywords: ["notification", "notify", "needs attention", "needs you", "alert", "sync stopped"]),
        .init(at: .general, title: "Warn before quitting during file operations",
              keywords: ["quit", "warn", "confirm quit", "close", "exit"]),
        .init(at: .general, title: "When a file already exists",
              keywords: ["conflict", "conflict policy", "overwrite", "replace", "keep both", "duplicate handling"]),
        .init(at: .general, title: "Confirm before copying or moving",
              keywords: ["confirm copy", "confirm move", "transfer confirmation", "what goes where", "confirm before copy"]),
        .init(at: .general, title: "Confirm before deleting",
              keywords: ["confirm delete", "delete confirmation", "trash", "remove"]),

        // Appearance ▸ Look
        // "theme" lives here, not on Accent color: to users it means light/dark.
        .init(at: .look, title: "Theme",
              keywords: ["theme", "light", "dark", "dark mode", "light mode", "appearance",
                         "system", "night", "follow macos"]),
        .init(at: .look, title: "Accent color",
              keywords: ["accent", "color", "colour", "hue", "highlight"]),
        .init(at: .look, title: "Glass effect",
              keywords: ["glass", "translucency", "transparency", "frosted", "clear", "solid",
                         "blur", "liquid glass", "material", "opaque", "see-through"]),
        .init(at: .look, title: "Surface tint",
              keywords: ["tint", "wash", "color overlay", "vivid", "subtle"]),
        // "solid" belongs to Glass effect, not here: this control is shape only.
        .init(at: .look, title: "Content surface style",
              keywords: ["surface", "unified", "cards", "pane background", "content surface"]),

        // Appearance ▸ Text & Spacing
        // Three entries for one section: the heading a search for "spacing" should land on, and
        // the two controls inside it, which people look for by name. "list density" stays a
        // keyword of Row spacing because users learned the control by that name.
        .init(at: .textAndSpacing, title: "Size & spacing",
              keywords: ["size", "spacing", "size and spacing", "preset", "presets", "scale",
                         "zoom", "how much fits", "bigger", "smaller", "readability", "legibility",
                         // Anyone who knows these controls as part of Appearance types that.
                         "appearance"]),
        .init(at: .textAndSpacing, title: "Text size",
              keywords: ["text size", "font", "font size", "type size", "bigger text", "larger text",
                         "smaller text", "readability", "zoom", "scale", "percent", "percentage"]),
        .init(at: .textAndSpacing, title: "Row spacing",
              keywords: ["density", "list density", "compact", "comfortable", "row height",
                         "spacing", "row spacing", "tighter rows", "row size"]),

        // Sources ▸ Cloud Providers. The per-source rows are on both lists, indexed here once.
        // Display name and Open at are the two the setup sheet also offers, under More options.
        .init(at: .cloudProviders, title: "Cloud providers",
              keywords: ["providers", "cloud", "discover", "refresh", "cloudstorage", "sources",
                         "icloud", "dropbox", "onedrive", "google drive"]),
        .init(at: .cloudProviders, title: "Source name",
              keywords: ["rename", "name", "provider name", "custom name", "label"]),
        .init(at: .cloudProviders, title: "Synchronized path",
              keywords: ["path", "location", "root", "folder", "directory", "sync path", "browse"]),
        .init(at: .cloudProviders, title: "Display name",
              keywords: ["rename", "display name", "name", "provider name", "custom name",
                         "label", "setup"]),
        .init(at: .cloudProviders, title: "Open at",
              keywords: ["open at", "landing", "starting folder", "opens at", "default folder",
                         "where panes open", "setup"]),
        .init(at: .cloudProviders, title: "Enable or disable a source",
              keywords: ["enable", "disable", "show", "hide", "toggle provider",
                         "toggle source"]),

        // Sources ▸ Local Folders
        .init(at: .localFolders, title: "Local folders",
              keywords: ["folder", "local", "add folder", "choose folder", "mac", "home folder",
                         "volume", "disk", "external drive", "source", "remove folder"]),

        // Sources ▸ Name Checks
        .init(at: .nameChecks, title: "Check folder names against",
              keywords: ["names", "risky names", "rename", "name rules", "onedrive rules",
                         "reserved", "check names", "folder names"]),
        // Most queries miss the label: the menu items say "Always Allow This Name" and "Stop
        // Allowing This Name", so "allow" is the word users have read, and they describe the
        // problem ("risky name", "trailing space", "badge") more than the state.
        .init(at: .nameChecks, title: "Allowed names",
              keywords: ["kept names", "kept name", "keep name", "allow name", "always allow", "stop allowing",
                         "allowed names", "risky name", "risky names", "badge", "name badge",
                         "trailing space", "forbidden character", "rename", "exceptions"]),

        // Browse ▸ Panes: they apply to every pane, in every workspace.
        .init(at: .panes, title: "Show hidden files by default",
              keywords: ["hidden", "dotfiles", "invisible", "show hidden"]),
        .init(at: .panes, title: "Sort panes by",
              keywords: ["sort", "order", "sorting", "name", "size", "date", "default sort"]),
        .init(at: .panes, title: "Column widths",
              keywords: ["column width", "column widths", "columns", "resize columns", "width",
                         "each column", "all columns", "divider", "wider", "narrower", "fit"]),
        // Its row says "Pane bar"; people type the button's words or what the sheet changes.
        .init(at: .panes, title: "Pane bar",
              keywords: ["customize pane bar", "customize", "toolbar", "customize toolbar", "pane bar buttons",
                         "buttons", "icon size", "bar"]),
        .init(at: .panes, title: "Rescan when files change",
              keywords: ["rescan", "auto rescan", "watch", "folder watching", "file changes", "changed on disk",
                         "refresh automatically", "live", "fsevents"]),

        // Browse ▸ Window: the View menu’s switches.
        .init(at: .window, title: "View as",
              keywords: ["view as", "columns", "tree", "list", "browse view", "view mode", "outline"]),
        .init(at: .window, title: "Show sidebar",
              keywords: ["sidebar", "folder sidebar", "favorites", "places", "hide sidebar"]),
        .init(at: .window, title: "Sidebar recents",
              keywords: ["recents", "revisited", "frequent", "recent folders", "history"]),
        .init(at: .window, title: "Show tab bar",
              keywords: ["tab bar", "tabs", "hide tabs"]),
        .init(at: .window, title: "Show status bar",
              keywords: ["status bar", "item count", "footer"]),

        // Compare ▸ Differences
        .init(at: .differences, title: "Treat dates as equal within",
              keywords: ["date tolerance", "date", "timestamp", "tolerance", "modified date", "rounding"]),
        .init(at: .differences, title: "Verify same-size files during scans",
              keywords: ["verify", "checksum", "same size", "scan verification", "hash"]),
        .init(at: .differences, title: "Ignore “newer on Google Drive” when same size",
              keywords: ["google drive", "newer", "ignore date", "gdrive"]),
        .init(at: .differences, title: "Group by folder",
              keywords: ["group", "grouping", "sections", "folder sections", "flat list", "differences list"]),

        // Compare ▸ Ignored
        .init(at: .ignored, title: "Remember ignored items across rescans",
              keywords: ["ignored items", "remember ignores", "hidden differences", "ignore"]),
        .init(at: .ignored, title: "Ignored name patterns",
              keywords: ["ignore patterns", "glob", "exclude", "wildcard", "ds_store", "node_modules", "patterns"]),

        // Compare ▸ One-Way Sync
        .init(at: .oneWaySync, title: "One-Way Sync",
              keywords: ["one-way", "one way", "mirror", "sync now", "icloud to dropbox", "dropbox", "pause", "synccloud removed",
                         "stopped syncing", "first run", "turn off"]),

        // Organize ▸ To File. "tidy" and "filing" are old names for Organize that users still type.
        // "loose files" is needed because the title hyphenates it, and "todo" is the default value,
        // not in the label.
        .init(at: .toFile, title: "Loose-files inbox",
              keywords: ["inbox", "loose files", "todo", "default folder", "scan folder",
                         "organize", "tidy", "filing"]),
        .init(at: .toFile, title: "Rules you taught by correcting",
              keywords: ["filing rules", "rules", "remembered rules", "open rules", "corrections", "manage rules", "automation", "automations"]),
        .init(at: .toFile, title: "Filing scorecard",
              keywords: ["scorecard", "first pick", "kept", "how filing is doing", "filing accuracy", "hide scorecard"]),
        .init(at: .toFile, title: "Folder surveys",
              keywords: ["survey", "folder survey", "learn folders", "learn its folders", "profile",
                         "google drive", "dropbox", "onedrive", "icloud", "layout", "forget survey"]),

        // Organize ▸ Suggestions. "organize" and "filing" stay for anyone who learned these as Organize’s.
        .init(at: .suggestions, title: "Suggest folders with Apple Intelligence",
              keywords: ["filing", "apple intelligence", "on-device ai", "on-device", "suggestions", "suggest folders",
                         "sort files", "organize", "tidy", "intelligence"]),
        .init(at: .suggestions, title: "Read file contents on this Mac",
              keywords: ["read contents", "content signals", "on-device", "excerpt", "ocr", "text", "pdf", "vision"]),
        // "cache" is the word the UI never says but an engineer types, so it lives here.
        .init(at: .suggestions, title: "Reuse suggestions for files that haven’t changed",
              keywords: ["reuse", "cache", "cached suggestions", "rescan", "re-ask", "cost", "save money"]),
        .init(at: .suggestions, title: "Saved suggestions",
              keywords: ["saved suggestions", "clear cache", "cache", "forget suggestions", "reset suggestions"]),

        // Organize ▸ People. Indexed by what it’s about as much as by its label: people type a
        // relationship or the problem ("wrong person").
        .init(at: .people, title: "People",
              keywords: ["people", "person", "family", "household", "names", "full name",
                         "wife", "husband", "son", "daughter", "mother", "father", "kids",
                         "wrong person", "whose document", "who", "aliases", "privacy",
                         "what is stored", "data", "organize", "filing"]),
        // The Add button is its own entry: "add person" is what someone types when the roster is
        // missing somebody, and the section title doesn't contain it.
        .init(at: .people, title: "Add Person…",
              keywords: ["add person", "new person", "add family member", "add someone",
                         "remove person", "delete person", "edit person", "rename person",
                         "relationship", "brother", "sister", "roster",
                         // The row's other buttons, by the words someone reaches for.
                         "look for names", "find names", "suggest names", "name suggestions",
                         "reorder", "move up", "move down", "order", "show files", "their files"]),
        // The tester, indexed by what someone wants from it: who a document would be filed for.
        .init(at: .people, title: "Try a filename",
              keywords: ["try a filename", "test a filename", "test", "who does this belong to",
                         "which person", "match", "attribute", "explain"]),

        // Organize ▸ Duplicates
        .init(at: .duplicates, title: "Ignore files smaller than",
              keywords: ["minimum size", "min file size", "small files", "duplicates", "threshold size", "tidy"]),
        .init(at: .duplicates, title: "Folders overlap at",
              keywords: ["overlap", "threshold", "folder overlap", "percent", "duplicates"]),
        .init(at: .duplicates, title: "Detect versions",
              keywords: ["versions", "final", "copy", "report (1)", "variants", "duplicates"]),
        // Nobody types this label; they type what they noticed: the same bill downloaded twice,
        // or a slow first scan.
        .init(at: .duplicates, title: "Read PDFs to find copies a byte hash misses",
              keywords: ["pdf", "text", "same text", "content", "fingerprint", "re-downloaded",
                         "downloaded twice", "re-stamped", "slow scan", "duplicates"]),
        // The Duplicates view's button says Keep Separate, and its way back Show Them Again.
        .init(at: .duplicates, title: "Groups kept separate",
              keywords: ["keep separate", "kept separate", "show again", "show them again", "flag again",
                         "unignore", "ignored duplicates", "duplicates"]),

        // Edit ▸ Text, by the names the Text and View menus give them.
        .init(at: .text, title: "Wrap lines",
              keywords: ["wrap", "word wrap", "line wrap", "soft wrap", "long lines", "editor"]),
        .init(at: .text, title: "Readable line length",
              keywords: ["readable", "line length", "margins", "measure", "editor"]),
        .init(at: .text, title: "Paper background",
              keywords: ["paper", "page", "background", "white page", "editor"]),
        .init(at: .text, title: "Typewriter scrolling",
              keywords: ["typewriter", "center line", "scrolling", "editor"]),
        .init(at: .text, title: "Check spelling while typing",
              keywords: ["spelling", "spell check", "spellcheck", "typos", "red underline", "editor"]),
        .init(at: .text, title: "Format bar",
              keywords: ["format bar", "markdown", "toolbar", "markup", "editor"]),
        .init(at: .text, title: "Labels on the format bar",
              keywords: ["icon and text", "icon only", "format bar labels", "words", "markdown"]),
        .init(at: .text, title: "Continue lists",
              keywords: ["lists", "bullets", "return", "indent", "markdown", "numbered list"]),
        .init(at: .text, title: "Edit in Preview (experimental)",
              keywords: ["edit in preview", "preview", "wysiwyg", "rendered", "markdown", "experimental"]),

        // Edit ▸ PDF
        .init(at: .pdf, title: "Page layout",
              keywords: ["pdf", "single page", "continuous", "two pages", "spread", "layout", "reader"]),
        .init(at: .pdf, title: "Cover page separately",
              keywords: ["cover", "cover page", "book", "spreads", "pdf", "two pages"]),
        .init(at: .pdf, title: "Saved signatures",
              keywords: ["signature", "signatures", "initials", "fill & sign", "fill and sign", "sign",
                         "delete signature", "remove signature"]),

        // Ask Claude ▸ General. Keywords matter most on this tab: nobody hunting for where the API
        // key goes types the tab’s name.
        .init(at: .claudeGeneral, title: "Ask Claude",
              keywords: ["chat", "assistant", "ask", "claude chat", "panel", "⌘J", "copilot", "help me"]),
        // The chat's model, which Refine, Try Another and Refine Names use too.
        .init(at: .claudeGeneral, title: "Chat model",
              keywords: ["model", "ask claude model", "sonnet", "opus", "haiku", "default model"]),
        .init(at: .claudeGeneral, title: "Answers",
              keywords: ["brief", "detailed", "verbose", "answer length", "concise", "ask claude answers"]),
        .init(at: .claudeGeneral, title: "Notes for Claude",
              keywords: ["notes", "memory", "remember", "about me", "instructions", "custom instructions", "preferences",
                         "what claude knows", "claude.md"]),
        .init(at: .claudeGeneral, title: "Show the intro in new chats",
              keywords: ["intro", "introduction", "welcome", "opening note", "new chat", "hide the intro"]),
        .init(at: .claudeGeneral, title: "Show suggestions above the text box",
              keywords: ["suggestions", "suggest", "chip", "nudge", "new files", "downloads", "differences", "Suggest Again"]),
        .init(at: .claudeGeneral, title: "Let Claude add to its notes",
              keywords: ["notes", "memory", "remember", "learn"]),

        // Ask Claude ▸ Privacy
        .init(at: .privacy, title: "Hidden from Claude",
              keywords: ["never show claude", "hide folder", "privacy", "exclude", "private folders"]),
        .init(at: .privacy, title: "Shared without asking",
              keywords: ["share without asking", "trusted folders", "don’t ask", "privacy", "ask each time", "share folder",
                         "let claude read files", "read files", "file contents", "passage", "send text"]),
        .init(at: .privacy, title: "Keep past chats",
              keywords: ["past chats", "chat history", "history", "old chats", "retention", "delete chats",
                         "clear all chats", "30 days", "7 days", "conversations"]),

        // Ask Claude ▸ Key & Spending: the key and the one monthly limit.
        // "claude" belongs on the key too, not only the toggle: someone pasting an `sk-ant-…`
        // types whichever name they last read, often "claude api key".
        .init(at: .keyAndSpending, title: "Claude API key",
              keywords: ["api key", "key", "keychain", "sk-ant", "anthropic key", "anthropic api key", "token",
                         "api", "credentials", "secret", "claude", "claude key",
                         // Refine has no switch of its own (TE335): the key turns it on, so someone looking
                         // for the old cloud switch lands here.
                         "refine", "cloud", "use claude", "cloud refine", "try another", "refine names"]),
        .init(at: .keyAndSpending, title: "Monthly limit",
              keywords: ["ask claude limit", "chat limit", "spend limit", "budget", "cap", "money",
                         "refine limit", "refine budget", "monthly cap", "total cap", "cloud model"]),
        .init(at: .keyAndSpending, title: "This month",
              keywords: ["ask claude spend", "chat cost", "spent", "usage", "cost"]),
        .init(at: .keyAndSpending, title: "Of that, Organize",
              keywords: ["organize spend", "refine spend", "refine cost", "try another", "refine names", "filing cost"]),
        // Advanced
        .init(at: .advanced, title: "Run Setup Again",
              keywords: ["setup", "guided setup", "first run", "onboarding", "welcome",
                         "run setup", "set up syncCloud"]),
        .init(at: .advanced, title: "Reset Setup",
              keywords: ["reset setup", "setup", "first run", "onboarding", "forget setup",
                         "run setup again", "start over"]),
        .init(at: .advanced, title: "Log level",
              keywords: ["log", "logging", "debug", "verbosity", "log level", "info", "warnings", "errors"]),
        .init(at: .advanced, title: "Log file",
              keywords: ["log file", "logs", "clear log", "show log"]),
        .init(at: .advanced, title: "Sweep orphaned temporary files",
              keywords: ["orphan", "temp files", "tmp", "sweep", "maintenance", "cleanup", "clean up"]),
        .init(at: .advanced, title: "File digests",
              keywords: ["digests", "checksums", "hashes", "content hash", "cache", "disk space",
                         "storage", "saved scan data", "duplicates", "verify"]),
        .init(at: .advanced, title: "Saved Storage reports",
              keywords: ["storage lens", "saved reports", "snapshots", "cache", "disk space",
                         "saved scan data"]),
        .init(at: .advanced, title: "Reset all settings",
              keywords: ["reset", "defaults", "restore defaults", "factory reset", "wipe"]),
    ]
}

/// Filters the search index for a query. Case-insensitive, whitespace-trimmed, matching the
/// title or any keyword; an empty (or whitespace-only) query returns nothing so the results
/// list stays hidden until the user types. Pure and free-standing for unit testing.
func filterSettings(_ entries: [SettingsSearchEntry], query: String) -> [SettingsSearchEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return entries.filter { $0.matches(trimmed) }
}

/// The search results that stand in for the tab content while the field has text: a scrollable
/// list of matching settings, each showing its title and — dimmed — the page it lives on. A tap
/// hands the place back to `SettingsView` for the jump. An empty result set shows a gentle miss.
private struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let onSelect: (SettingsPlace) -> Void

    var body: some View {
        if results.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No settings match your search.",
                layout: .compact
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { entry in
                        Button {
                            onSelect(entry.place)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .foregroundStyle(.primary)
                                    Text(entry.place.name)
                                        .scaledFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HoverChevron()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverAffordance(.row))
                        Divider().padding(.leading, 16)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - General

/// What the app does around your work: how it starts, how every copy and move behaves, and what it
/// tells you afterwards. Copying and moving came from Sync (TE332): the conflict policy and the two
/// confirmations govern every copy and move, not only Compare's.
struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    @AppStorage(GeneralSettings.warnBeforeQuitKey) private var warnBeforeQuit: Bool = true
    @AppStorage(GeneralSettings.restoreLastFocusKey) private var restoreLastFocus: Bool = true
    @AppStorage(GeneralSettings.confirmBeforeDeleteKey) private var confirmBeforeDelete: Bool = true
    @AppStorage(GeneralSettings.confirmBeforeTransferKey) private var confirmBeforeTransfer: Bool = true

    var body: some View {
        SettingsPage {
            SettingsSection("Startup") {
                LaunchAtLoginRow(showsCaption: false, logsChanges: true)
                Toggle("Reopen panes where I left off", isOn: $restoreLastFocus.loggingSettingsChange("general.reopenPanes"))
                    .help("Reopens each pane with the tabs and folders it had when you last quit. Off, every pane starts with one tab at its source’s opening folder.")
            }

            SettingsSection(
                "Copying and moving",
                caption: "For every copy, move and sync. Folder conflicts always ask; deleted items go to the Trash either way."
            ) {
                SettingsRow("When a file already exists") {
                    Picker("When a file already exists", selection: $settings.conflictPolicy.loggingSettingsChange("sync.whenFileExists")) {
                        ForEach(ConflictPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("What a copy, move, or sync does when a file of the same name is already there: ask, keep both, replace it (the old one goes to the Trash), or skip it. Folder conflicts always ask.")
                }
                Toggle("Confirm before copying or moving", isOn: $confirmBeforeTransfer.loggingSettingsChange("sync.confirmTransfer"))
                    .help("Shows what will be copied or moved, and where, before it starts. Off, copies and moves start at once.")
                Toggle("Confirm before deleting", isOn: $confirmBeforeDelete.loggingSettingsChange("sync.confirmDelete"))
                    .help("Asks before moving items to the Trash. They go to the Trash either way, and Undo brings them back.")
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit.loggingSettingsChange("general.warnBeforeQuit"))
                    .help("Asks before quitting while a copy, move, or delete is still running. Off, SyncCloud quits at once.")
            }

            SettingsSection("Notifications") {
                NotifyInBackgroundRow(showsCaption: false, logsChanges: true)
                OneWaySyncNotifyRow()
            }
        }
    }
}

// MARK: - Appearance

/// Appearance ▸ Look: theme, accent hue, glass material and surface shape, all shared with MacApp
/// through UserDefaults. No captions but Tint's (TE332): each control shows what it does.
///
/// Theme (light/dark), Glass effect (material) and Content surface (shape) are separate controls:
/// any combination is valid, and none overrides another.
///
/// Theme leads because the others decide how a surface reads within an appearance. Unlike them it
/// renders nothing here: `ContentView` pushes it to NSApp.
struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// Tint when the slider was grabbed, so its release logs one change, not every step.
    @State private var tintAtGrab: Double?

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Theme") {
                Picker("Theme", selection: $appearanceModeRaw.loggingSettingsChange("appearance.theme")) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
                .help("System follows the macOS appearance, including its automatic schedule. Light and Dark keep SyncCloud in one appearance whatever macOS is set to.")
            }

            AccentColorSection(selectedHue: selectedHue,
                               onSelect: { hue in
                                   SettingsWindowLog.log("appearance.accent", from: .string(selectedHueRaw), to: .string(hue.rawValue))
                                   selectedHueRaw = hue.rawValue
                               })

            SettingsSection("Glass effect") {
                Picker("Glass effect", selection: $glassLevelRaw.loggingSettingsChange("appearance.glass")) {
                    ForEach(GlassLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
                .help("How see-through the window’s surfaces are: Clear has no frost, Frosted is standard Liquid Glass, Solid is opaque.")
            }

            SettingsSection(
                "Tint",
                caption: selectedHue == .none
                    ? "Choose an accent color above to tint the window."
                    : "For no tint at all, choose None above."
            ) {
                HStack(spacing: 12) {
                    // Label hidden, not dropped: the section title already says "Tint", and it
                    // stays in the accessibility tree.
                    Slider(value: $surfaceTint, in: 0.0...1.0) {
                        Text("Tint")
                    } minimumValueLabel: {
                        Text("Subtle")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    } maximumValueLabel: {
                        Text("Vivid")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    } onEditingChanged: { editing in
                        if editing {
                            tintAtGrab = surfaceTint
                        } else if let grabbed = tintAtGrab {
                            tintAtGrab = nil
                            SettingsWindowLog.log("appearance.tint", from: .double(grabbed), to: .double(surfaceTint))
                        }
                    }
                    .labelsHidden()
                    .accessibilityValue("\(Int(surfaceTint * 100)) percent")
                    .help("How strongly the accent color tints the window.")
                    .disabled(selectedHue == .none)
                    Text("\(Int(surfaceTint * 100))%")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            SettingsSection("Content surface") {
                Picker("Content surface", selection: $surfaceStyleRaw.loggingSettingsChange("appearance.surface")) {
                    ForEach(SurfaceStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
                .help("Unified draws the window as one surface divided by hairlines. Cards floats each area as its own card on the background.")
            }

        }
    }
}

/// A selectable hue option for the liquid glass accent color.
/// Internal rather than file-private: `AccentColorSection` (the accent picker's own file) builds
/// the row of these, and the tests render it.
struct HueOptionView: View {
    let hue: LiquidGlassHue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    swatch
                        .frame(width: 32, height: 32)
                        .overlay {
                            // Today's marker — in Frosted and Clear the row's lens draws the ring.
                            if isSelected {
                                SelectionLensTodayMarker {
                                    Circle().strokeBorder(Self.ringColor, lineWidth: Self.ringWidth)
                                }
                            }
                        }
                        .shadow(color: swatchShadowColor, radius: isSelected ? 5 : 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .scaledFont(.system(size: 13, weight: .semibold))
                            // The checkmark pairs with its swatch's luminance, since white is
                            // unreadable on amber. "None" has no fill of its own, so it tracks the
                            // appearance via `.primary` like the disc does.
                            .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                .selectionLensStop(AccentColorSection.lensChannel, id: hue)
                Text(hue.displayName)
                    .scaledFont(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Every hue shares one row; the longest name ("Graphite") shrinks to stay on a
                    // single line rather than wrapping in its narrow slot.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment, tint: hue.accentColor, shape: .roundedRect(8)))
    }

    private var swatch: some View { HueSwatchDisc(hue: hue) }

    /// The chosen swatch's ring, named once because the row's selection lens wears it too.
    static let ringColor = Color.primary.opacity(0.4)
    static let ringWidth: CGFloat = 2

    private var swatchShadowColor: Color { HueSwatchDisc.shadowColor(hue) }
}

/// The colored disc for a hue, or a neutral slashed disc for "None", at whatever size its frame
/// gives it (32 pt here, 24 pt on an Ask Claude card). Shared with `AccentSwatchGrid`.
struct HueSwatchDisc: View {
    let hue: LiquidGlassHue

    var body: some View {
        if hue == .none {
            ZStack {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 1.5, height: 44)
                    .rotationEffect(.degrees(45))
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        } else {
            Circle().fill(hue.accentColor)
        }
    }

    static func shadowColor(_ hue: LiquidGlassHue) -> Color {
        hue == .none ? Color.black.opacity(0.2) : hue.accentColor.opacity(0.4)
    }
}

// MARK: - Appearance ▸ Text & Spacing

/// Appearance ▸ Text & Spacing (Readability until TE332): text size and row spacing, with a preset
/// row over them and a live preview under them.
///
/// Both controls answer one question, how much you want on screen, so they sit together. With the
/// presets, detent labels and preview the group is taller than Look, hence its own page.
/// `readabilityFitsItsOpeningWithoutScrolling` holds it to the same fit bar as the others.
///
/// Nothing here is stored by this view: `FontSize.defaultsKey` and `ListDensity.defaultsKey` stay
/// the two sources of truth, and the preset row reads them to decide which tile is lit.
struct ReadabilitySettingsTab: View {
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent: Int = FontSize.medium.percent
    /// Text size when the slider was grabbed, so its release logs one change, not every step.
    @State private var sizeAtGrab: Int?

    /// The resolved text size. `FontSize.init(percent:)` clamps, so an out-of-range stored value
    /// is honoured rather than discarded.
    private var fontSize: FontSize { FontSize(percent: fontSizePercent) }

    /// The resolved row spacing; `.comfortable` (the standard rows) if unrecognized.
    private var listDensity: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue }

    /// A preset tile sets both; each logs its own change.
    private var sizeBinding: Binding<FontSize> {
        Binding(get: { fontSize }, set: { fontSizePercent = $0.percent })
            .loggingSettingsChange("readability.textSize", as: { .int($0.percent) })
    }

    private var densityBinding: Binding<ListDensity> {
        Binding(get: { listDensity }, set: { listDensityRaw = $0.rawValue })
            .loggingSettingsChange("readability.rowSpacing")
    }

    /// The value the slider is fed for a stored percentage, and the value a slider position
    /// stores back. Both go through `FontSize`'s clamp, like the rest of the tab, so an
    /// out-of-range stored value never reaches the `Slider` while the tiles say otherwise. A
    /// rendering can't show the difference, hence pure functions;
    /// `theSliderReadsAndWritesThroughTheClamp` checks the call site uses them.
    static func sliderValue(forStored stored: Int) -> Double {
        Double(FontSize(percent: stored).percent)
    }

    static func storedValue(forSlider value: Double) -> Int {
        FontSize(percent: Int(value.rounded())).percent
    }

    private var smallAGlyph: some View {
        Text("A").scaledFont(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var largeAGlyph: some View {
        Text("A").scaledFont(.system(size: 15)).foregroundStyle(.secondary)
    }

    /// The percentage beside the slider, in a frame sized by the widest value it can show. A hidden
    /// maximum sets the frame, so it scales with the text size, the number never wraps and the
    /// slider never shifts as it changes. A fixed width would be too narrow at large sizes.
    private var readout: some View {
        Text("\(FontSize.maximumPercent)%")
            .scaledFont(.caption.weight(.semibold))
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .trailing) {
                Text("\(fontSize.percent)%")
                    .scaledFont(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    // The slider already announces this number as its value; leaving the readout
                    // in the tree makes VoiceOver say it twice for one control.
                    .accessibilityHidden(true)
            }
    }

    /// The hairline that separates the presets from the two controls they are a shortcut for.
    /// Labelled, because an unlabelled rule inside one section reads as a section break.
    private var fineTuningRule: some View {
        HStack(spacing: 8) {
            Text("Fine tuning")
                .scaledFont(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                // A group heading, so VoiceOver's heading navigation lands on it.
                .accessibilityAddTraits(.isHeader)
            VStack { Divider() }
        }
    }

    var body: some View {
        SettingsPage {
            // Titleless: the strip already says "Text & Spacing".
            SettingsSection {
                SizePresetRow(fontSize: sizeBinding, density: densityBinding, style: .named)

                Text(SizePreset.caption(fontSize: fontSize, density: listDensity))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                fineTuningRule
                    .padding(.top, 4)

                // The label is pinned to the top: `LabeledContent` centres it against the slider
                // row plus the detent labels, which would put it level with the labels.
                LabeledContent {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            smallAGlyph
                            Slider(
                                value: Binding(
                                    get: { Self.sliderValue(forStored: fontSizePercent) },
                                    set: { fontSizePercent = Self.storedValue(forSlider: $0) }
                                ),
                                in: Double(FontSize.minimumPercent)...Double(FontSize.maximumPercent),
                                step: Double(FontSize.step)
                            ) { editing in
                                if editing {
                                    sizeAtGrab = fontSizePercent
                                } else if let grabbed = sizeAtGrab {
                                    sizeAtGrab = nil
                                    SettingsWindowLog.log("readability.textSize", from: .int(grabbed), to: .int(fontSizePercent))
                                }
                            }
                            .labelsHidden()
                            .accessibilityValue("\(fontSize.percent) percent")
                            .help("Sets the size of text throughout SyncCloud, from \(FontSize.minimumPercent)% to \(FontSize.maximumPercent)%.")
                            largeAGlyph
                            readout
                        }
                        // The detent rail is flanked by the same views as the slider row, hidden.
                        // Those flanks grow with the text size, so fixed padding would leave the
                        // labels off their ticks; one definition of each keeps the rows aligned.
                        HStack(spacing: 10) {
                            smallAGlyph.hidden()
                            FontSizeDetentLabels(selected: fontSize)
                            largeAGlyph.hidden()
                            readout.hidden()
                        }
                    }
                } label: {
                    Text("Text size")
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                // "Row spacing", not "List density": spacing is what the person changes, and it
                // pairs with "Text size" above. The stored key is still `listDensity`.
                LabeledContent("Row spacing") {
                    Picker("Row spacing", selection: $listDensityRaw.loggingSettingsChange("readability.rowSpacing")) {
                        ForEach(ListDensity.allCases) { density in
                            Text(density.displayName).tag(density.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accentedSegments(selectedHue)
                    .fixedSize()
                    .help("How tightly lists pack their rows. Comfortable keeps the standard height; Compact fits more rows and hides the size-and-date line.")
                }

                SizeSpacingPreview(fontSize: fontSize, density: listDensity)
                    .padding(.top, 4)
            } caption: {
                // The prose lives inline under what it explains, so the caption slot is empty.
                EmptyView()
            }
        }
    }
}

// MARK: - Sources

/// The sources panes can be pointed at, a page each (TE332): the cloud accounts discovered on this
/// Mac, the plain folders the user added, and the name checks that apply to both. Separate pages,
/// because one is found and the other chosen: a cloud account can be refreshed but never removed, a
/// folder removed but never discovered. Each list grows on its own.
struct ProvidersSettingsTab: View {
    let page: SettingsSubTab
    /// Name Checks' allowed-names list reaches `keptNamesStore` through it. Optional because tests
    /// and previews build the tab without an engine.
    var syncManager: FileSyncManager? = nil
    @EnvironmentObject var settings: SettingsManager
    @State private var isRefreshingProviders = false
    /// Ids of the rows the user has opened. Collapsed by default, because the tab grows with every
    /// account and folder, and four expanded rows already scroll past the sheet. State, not a
    /// persisted default: which row you last opened isn't a preference.
    @State private var expandedIds: Set<String> = []

    private var cloudProviders: [CloudProvider] {
        settings.availableProviders.filter { !$0.isLocalFolder }
    }

    private var folderProviders: [CloudProvider] {
        settings.availableProviders.filter(\.isLocalFolder)
    }

    var body: some View {
        SettingsPage {
            switch page {
            case .localFolders: localFolders
            case .nameChecks: nameChecks
            default: cloudAccounts
            }
        }
    }

    // Each list's header names it in other words than the strip, which already says the page.
    @ViewBuilder
    private var cloudAccounts: some View {
        SettingsSection(caption: "Found on this Mac. A source you turn off keeps its settings.") {
            HStack {
                Text("Accounts")
                    .scaledFont(.body.weight(.medium))
                Spacer()
                Button(action: refreshProviders) {
                    Label(
                        isRefreshingProviders ? "Refreshing…" : "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshingProviders)
                .controlSize(.small)
                .help("Reads ~/Library/CloudStorage again, picking up cloud accounts added or removed since it last looked. At least one source must stay on.")
            }
        }

        // This page legitimately scrolls: it grows with every provider the Mac has. Collapsed
        // rows keep the growth to one row per source rather than four fields each.
        ForEach(cloudProviders) { provider in
            Divider()
            ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
        }
    }

    @ViewBuilder
    private var localFolders: some View {
        SettingsSection(caption: "Any folder on this Mac can be a source. Removing one leaves the folder untouched.") {
            HStack {
                Text("Added by you")
                    .scaledFont(.body.weight(.medium))
                Spacer()
                Button(action: addFolder) {
                    Label("Add Folder…", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Adds a folder on this Mac as a source. It appears in every workspace, and Compare and Organize work over it as over a cloud account.")
            }

            if folderProviders.isEmpty {
                Text("No folders added.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        ForEach(folderProviders) { provider in
            Divider()
            ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
        }
    }

    /// The rule that raises a risky-name badge, beside the names allowed past it: an allowed name
    /// clears its badge in every pane, so the two answer one question.
    @ViewBuilder
    private var nameChecks: some View {
        SettingsSection(caption: "Folder sources accept any name; this says which provider’s rules to hold them to.") {
            SettingsRow("Check folder names against") {
                Picker("Check folder names against", selection: $settings.folderNameRule.loggingSettingsChange("sources.folderNameRule")) {
                    ForEach(FolderNameRuleOption.all) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(
                    "A folder accepts any name, so “risky name” has no meaning until you say where the files are headed. Organize and the pane badges check names under a folder source against this."
                )
            }
        }

        SettingsSection(
            "Allowed names",
            caption: "Names you allowed with Always Allow This Name. Remove one to have it flagged again."
        ) {
            if let store = syncManager?.keptNamesStore {
                KeptNamesList(store: store)
            } else {
                // No engine attached (tests, previews): say what an empty store would.
                //
                // This branch is not the page. It is one fixed line; the real list grows a row per
                // name, which is why Name Checks is in `SettingsTab.exemptFromFitGuard`. A layout
                // test built with `syncManager: nil` measures only this line.
                KeptNamesList.nothingKeptNote
            }
        }
    }

    /// One row's open/closed state. A binding over the shared set, not per-row `@State`, so a row
    /// rebuilt when discovery republishes `availableProviders` (every path edit, rename and
    /// Refresh) doesn't snap shut mid-edit.
    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedIds.insert(id)
                } else {
                    expandedIds.remove(id)
                }
            }
        )
    }

    private func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        Task {
            await settings.discoverProviders()
            await MainActor.run { isRefreshingProviders = false }
        }
    }

    /// Picks a folder, adds it as a source and opens its row. A folder that is already a source
    /// opens that row instead of adding a second (see `SettingsManager.addFolderSource`).
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a source"
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        expandedIds.insert(settings.addFolderSource(path: url.path))
    }
}

/// The rulesets a folder source's names can be checked against, in the order the picker lists them.
///
/// Only the two that have rules, plus off. iCloud and Google Drive accept anything the local
/// filesystem does, so offering them would be two more spellings of "don't check".
struct FolderNameRuleOption: Identifiable {
    static let all: [FolderNameRuleOption] = [
        .init(value: .oneDrive, label: "OneDrive (strictest)"),
        .init(value: .dropBox, label: "Dropbox"),
        .init(value: .localFolder, label: "Don’t check"),
    ]

    let value: CloudProvider.ProviderType
    let label: String
    var id: String { value.rawValue }

    init(value: CloudProvider.ProviderType, label: String) {
        self.value = value
        self.label = label
    }
}

/// One source's rows: identity + enable switch, then — once opened — its root-path config.
struct ProviderSettingsSection: View {
    @Environment(\.cloudAppStatusLabels) private var cloudAppStatusLabels
    let provider: CloudProvider
    /// Whether the path configuration is showing. The header line is always there.
    @Binding var isExpanded: Bool
    @EnvironmentObject var settings: SettingsManager
    // A value type, not a bare String: focus-blur commit and the discovery refresh both move it.
    // See `ProviderPathDraft`.
    @State private var pathDraft = ProviderPathDraft()
    @State private var draftName: String = ""
    // Both editable fields share one commit model: Return or focus-loss commits,
    // so each needs its own focus state to observe its own blur.
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var pathFieldFocused: Bool

    /// The display name of the source that already owns a folder this row's Location edit was
    /// refused for, or nil when the last commit was accepted. The line under the field names
    /// which source holds the folder, or the user would retype the same path.
    @State private var refusedDuplicateOwner: String?

    /// Why the last "Open at" pick was declined, or nil. A folder outside the root can't be stored,
    /// since `openAt` is measured from the root, and a picker that did nothing would look broken.
    @State private var openAtRefusal: String?

    private var isEnabled: Bool {
        settings.isEnabled(provider.id)
    }

    /// A folder source's Remove: ask, and only then remove. Removing drops its custom name and
    /// switched-off state (`SettingsManager.removeFolderSource`); adding it again restores neither.
    /// - Returns: Whether the source was removed.
    @discardableResult
    static func removeFolderSourceIfConfirmed(id: String, from settings: SettingsManager,
                                              confirm: () -> Bool) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm) { settings.removeFolderSource(id: id) }
    }

    var body: some View {
        SettingsSection {
            HStack(spacing: 12) {
                ProviderLogo(provider.imageName, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    // The name is the rename affordance: click to edit in place. Return or
                    // clicking away commits; emptying it restores the default. labelsHidden keeps
                    // the Form from adding a label and right-aligning the name beside the icon.
                    TextField("Provider name", text: $draftName)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .scaledFont(.body.weight(.medium))
                        .focused($nameFieldFocused)
                        .onSubmit { commitName() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commitName() }
                        }
                        .help("Click to rename. Clear the name to restore the default.")
                    // What identifies the source while the row is shut: a cloud account's id
                    // (`OneDrive-Personal`), or a folder source's path, since its id is a UUID.
                    Text(provider.isLocalFolder ? provider.rootPath : provider.id)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(provider.isLocalFolder ? provider.rootPath : provider.id)
                }

                Spacer()

                // Its cloud app not syncing: the amber dot the sidebar draws.
                if let label = cloudAppStatusLabels[provider.id] {
                    HStack(spacing: 4) {
                        Circle().fill(SemanticColor.warning).frame(width: 6, height: 6)
                        Text(label)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .help("\(provider.displayName) — \(label)")
                }

                // SettingsManager owns validity (re-checked on discovery/refresh and
                // path edits), so re-renders here never stat the disk.
                StatusBadge(isValid: settings.isPathValid(for: provider.id))

                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // The title is empty, so without this VoiceOver reads every account's switch
                    // as just "switch, on".
                    .accessibilityLabel(provider.displayName)
                    .disabled(isEnabled && !settings.canDisable(provider.id))
                    .help(
                        isEnabled && !settings.canDisable(provider.id)
                            ? SettingsManager.ProviderToggleHelp.lastRemaining
                            : SettingsManager.ProviderToggleHelp.offer(provider.displayName)
                    )

                disclosureButton
            }
            .padding(.vertical, 2)
            .onAppear {
                pathDraft.adopt(provider.rootPath)
                draftName = provider.displayName
                // A refusal is about one edit, not about the row. Re-mounting starts clean.
                refusedDuplicateOwner = nil
                openAtRefusal = nil
            }
            .onChange(of: provider.rootPath) { _, updated in
                pathDraft.adoptExternalChange(to: updated, isEditing: pathFieldFocused)
            }
            .onChange(of: provider.displayName) { _, updated in
                if !nameFieldFocused && draftName != updated {
                    draftName = updated
                }
            }

            if isExpanded {
                if provider.isLocalFolder {
                    folderLocationEditor
                } else {
                    accountRootRow
                    openAtRow
                }
            }
        }
    }

    // MARK: - A cloud account: a root it does not choose, and a folder it does

    /// The account's root, shown and not offered for editing.
    ///
    /// An account has exactly one root, the folder `~/Library/CloudStorage` mounts it at, so a
    /// field here could only be wrong. What the user chooses is where inside it a pane opens: the
    /// row below.
    ///
    /// The exception: an install upgraded from a build with a free-form Location can carry a root
    /// (via `RootsMigration`) outside the account. Nothing else clears that key, so this row offers
    /// a note and Reset in that state only (`hasRootOverride`).
    private var accountRootRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Root")
            Text(provider.rootPath)
                .scaledFont(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(provider.rootPath)
            if hasRootOverride {
                Text("Carried over from a custom location you set in an earlier version. "
                     + "Reset to use the folder \(provider.displayName) is signed in at.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { openInFinder(provider.rootPath) }
                // The provider's own settings: System Settings for iCloud, the vendor's app or web
                // page for the rest (see `CloudProvider.settingsDoor`). Absent, not disabled, when
                // the vendor's app is missing.
                if let door = provider.settingsDoor, let title = provider.settingsDoorTitle,
                   ProviderSettingsOpener.canOpen(door) {
                    Button(title) { ProviderSettingsOpener.open(door) }
                }
                if hasRootOverride {
                    Button("Reset") { resetRootToDiscovered() }
                        .help("Stops using the carried-over location and goes back to the folder \(provider.displayName) is signed in at.")
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(.top, 2)
            // On the controls only, like `openAtRow`: a switched-off account's settings aren't
            // edited here, and `disabled` is cumulative, so gating the VStack would grey the note,
            // which stays true when the source is off.
            .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Re-read on every discovery rather than held as state: `resetRootToDiscovered` rediscovers
    /// asynchronously, and the note and button have to disappear when the override does.
    private var hasRootOverride: Bool {
        !provider.isLocalFolder && settings.hasRootOverride(for: provider.id)
    }

    private func resetRootToDiscovered() {
        // `setPath` reads the empty path as "clear the override", the only reachable use of its
        // account branch.
        settings.setPath("", for: provider.id)
    }

    /// The folder panes on this source open at, chosen from inside the root.
    private var openAtRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open at")
            // Monospaced only when it is a path: "The source root" is a phrase, not a value.
            // Selectable, like Root, since the relative path is likely to be pasted somewhere.
            Text(openAtDisplay)
                .scaledFont(provider.openAt.isEmpty ? .callout
                                                    : .system(.callout, design: .monospaced))
                .foregroundStyle(provider.openAt.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Both notes, not `else if`: the missing folder is a standing fact, the refusal is about
            // the click just made, and one mustn't hide the other.
            //
            // Gated on the root being valid too: with the whole account unmounted the landing is
            // invalid as well, and the row's status badge speaks for a missing root.
            if !provider.openAt.isEmpty, settings.isPathValid(for: provider.id),
               !settings.isLandingValid(for: provider.id) {
                // Panes open at the root instead (`openAtIfReachable`), and a user who chose this
                // folder needs to know why.
                Text("That folder isn’t there any more, so panes open at the root instead.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let openAtRefusal {
                Text(openAtRefusal)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Opening folder not changed. \(openAtRefusal)")
            }

            HStack(spacing: 8) {
                Button("Choose…") { selectOpenAtDirectory() }
                    .help("Picks the folder inside \(provider.displayName) that panes open at.")
                // Disabled when there is nothing to reset. For iCloud, whose default is the root,
                // the row reads the same chosen or inherited, so the button's state is the only
                // thing that tells them apart.
                Button("Reset") {
                    openAtRefusal = nil
                    settings.resetOpenAt(for: provider.id)
                }
                .disabled(!settings.hasOpenAtOverride(for: provider.id))
                .help("Forgets the folder you chose, so panes open at \(provider.displayName)’s default folder again.")
                Spacer()
            }
            .controlSize(.small)
            .padding(.top, 2)
            // On the controls, not the whole row: `disabled` is cumulative and a descendant can't
            // re-enable itself, so gating the VStack would grey the notes, which stay true.
            .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The landing folder as the row shows it — the root-relative path, or a phrase for the root.
    ///
    /// A phrase rather than an empty line or a bare `/`: "" is a real, chosen value here, and a
    /// blank row reads as unset.
    ///
    /// The value stays root-relative on purpose: the Root line above already anchors it. A full
    /// path would nearly duplicate that line, and a leading `/` would read as absolute. Don't
    /// change this without rendering the alternatives in the real row.
    private var openAtDisplay: String {
        provider.openAt.isEmpty ? "The source root" : provider.openAt
    }

    // MARK: - A folder source: one path, which the user chose

    /// A folder source is its own root, so it has a single Location field.
    ///
    /// A `Group`, so its two children flatten into the row's stack and the button strip keeps the
    /// account rows' spacing rather than the field's tighter 4pt.
    private var folderLocationEditor: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("Location")
                // Mirrors the name field: Return or clicking away commits, so no Save button.
                TextField("Synchronized path", text: $pathDraft.value)
                    .textFieldStyle(.plain)
                    .scaledFont(.system(.callout, design: .monospaced))
                    .labelsHidden()
                    .focused($pathFieldFocused)
                    .onSubmit { commitPath() }
                    .onChange(of: pathFieldFocused) { _, focused in
                        if !focused { commitPath() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A TextField scrolls rather than ellipsizing, so a long path hides its tail;
                    // the tooltip shows it whole.
                    .help(pathDraft.value)

                // Only ever set for a folder source, and cleared by the next accepted commit.
                if let owner = refusedDuplicateOwner {
                    Text("That folder is already \(owner). One folder gets one source.")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            "Location not changed. That folder is already \(owner).")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isEnabled)

            HStack(spacing: 8) {
                Button("Browse…") { selectDirectory() }
                // No Reset: a folder source has no discovered default to reset to. Remove takes
                // its place, which a cloud account can't offer.
                Button("Remove…", role: .destructive) {
                    Self.removeFolderSourceIfConfirmed(
                        id: provider.id, from: settings,
                        confirm: RemovalPrompt.removeFolderSource(named: provider.displayName).ask)
                }
                .help("Removes \(provider.displayName) from your sources. The folder and its files stay where they are. Asks first.")
                Button("Show in Finder") { openInFinder(provider.rootPath) }
                Spacer()
            }
            .controlSize(.small)
            // No `.disabled` here, on purpose: Remove stays live on a switched-off folder, the one
            // you're most likely removing, rather than making you switch it back on first. The
            // account rows gate their own strips (`accountRootRow`, `openAtRow`).
        }
    }

    /// Opens and shuts the row. The chevron points where the content will be: down to open, up to
    /// shut.
    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // A bare chevron is a ~7pt target. The frame is the hit area, not the drawing.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chromeHover()
        // "Folders", not "location": this discloses the source's root and the folder panes open at.
        .help(isExpanded ? "Hide \(provider.displayName)’s folders" : "Show \(provider.displayName)’s folders")
        .accessibilityLabel(isExpanded ? "Collapse \(provider.displayName)" : "Expand \(provider.displayName)")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled(provider.id) },
            set: { settings.setEnabled($0, for: provider.id) }
        )
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select root directory for \(provider.displayName)"

        if panel.runModal() == .OK {
            if let url = panel.url {
                pathDraft.value = url.path
                commitPath()
            }
        }
    }

    /// Picks the folder panes on this source open at. The panel starts inside the root, but macOS
    /// lets the user navigate anywhere, so containment is enforced on the answer.
    private func selectOpenAtDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder \(provider.displayName) opens at"
        panel.prompt = "Open at"
        // Through the manager, not `provider.landingPath`: the manager falls back to the root when
        // the landing folder is gone. Otherwise the panel opens wherever macOS last was, likely
        // outside the root, and the first pick is refused. `SetupSheet.seedWalkRoot` does the same.
        panel.directoryURL = URL(
            fileURLWithPath: (settings.landingPath(for: provider.id) as NSString).expandingTildeInPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The words live in ``OpenAtRefusal``, shared with setup's Locations screen, so one rule
        // has one wording.
        openAtRefusal = OpenAtRefusal.message(settings.setOpenAt(url.path, for: provider.id),
                                              provider: provider.displayName)
    }

    private func openInFinder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // Both fields commit on Return and on focus-loss, so a blur on an unchanged value must be a
    // no-op: both guard on `ProviderFieldEdit.shouldCommit` before writing.
    private func commitPath() {
        let normalized = ProviderFieldEdit.normalized(pathDraft.value)
        pathDraft.value = normalized
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.rootPath) else { return }
        switch settings.setPath(normalized, for: provider.id) {
        case .changed, .unchanged:
            refusedDuplicateOwner = nil
        case .refusedDuplicate(let existingId):
            // Put the field back to what the source points at. Nothing was written, so no
            // `onChange(of: provider.rootPath)` will do it.
            refusedDuplicateOwner = settings.availableProviders
                .first { $0.id == existingId }
                .map { "\($0.displayName)’s folder" } ?? "another source’s folder"
            pathDraft.adopt(provider.rootPath)
        case .refusedOutsideRoot, .refusedUnknownSource:
            // Neither reaches this field: `setPath` refuses a folder source only for a duplicate.
            // Named rather than defaulted, so a new refusal can't pass silently as accepted.
            refusedDuplicateOwner = nil
            pathDraft.adopt(provider.rootPath)
        }
    }

    private func commitName() {
        let normalized = ProviderFieldEdit.normalized(draftName)
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.displayName) else {
            draftName = normalized
            return
        }
        // Empty clears the override; the default name flows back through discovery
        // and the onChange(of: provider.displayName) refreshes the field.
        settings.setCustomName(normalized, for: provider.id)
        draftName = normalized.isEmpty ? provider.displayName : normalized
    }
}

/// Normalization applied to the provider text fields (path and name) before committing.
/// Pure and internal so tests can pin the trimming without instantiating the view.
enum ProviderFieldEdit {
    /// Pasted values often carry a trailing space or newline. A path stored with one fails
    /// validation and scans empty with only a red badge, so both fields trim them.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a commit should write: only when the normalized draft differs from the stored
    /// value, so an unchanged blur is a no-op.
    static func shouldCommit(draft: String, committed: String) -> Bool {
        normalized(draft) != committed
    }
}

/// The Location field's draft text, modeled as a value so its lifecycle — adopting an external
/// discovery change — is decided in one testable place instead of inline in SwiftUI closures.
///
/// **Never blank the draft and wait for `onChange(of: provider.rootPath)` to refill it.** That
/// fires only when the path changes, and resetting a source with no override changes nothing, so
/// the field would sit empty and the next blur would commit the empty string.
struct ProviderPathDraft: Equatable {
    /// The text currently in the field. A plain `var` because the `TextField` binds straight to it.
    var value: String = ""

    /// The row appeared: start on the provider's effective (default or overridden) path.
    mutating func adopt(_ path: String) {
        value = path
    }

    /// An external change to the published path landed (a discovery/refresh pass). Adopt it only
    /// when the user isn't actively editing this field — otherwise a concurrent
    /// `discoverProviders()` would silently discard their uncommitted draft.
    mutating func adoptExternalChange(to updated: String, isEditing: Bool) {
        guard !isEditing else { return }
        guard value != updated else { return }
        value = updated
    }
}

/// One row of a fixed-choice settings picker: the value it stores and the label it shows.
struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// Row lists for the numeric Settings pickers, and the rule that keeps them honest when the
/// persisted value isn't one of the offered rows.
///
/// A `Picker` whose selection matches none of its tags shows nothing selected while the value stays
/// in effect, and the first click replaces a setting the user never knowingly chose. Off-list
/// values come from an older build's options, a `defaults write` or a hand-edited plist.
///
/// So show the stored value, never coerce it: snapping to the nearest option destroys it silently.
/// Unlike model ids, two numbers have no equivalence to map between, so these pickers add one row
/// for the stored value, sorted into place so the list still reads as a scale.
///
/// Labels are derived from the formatters, not spelled per row, so the extra row and the fixed
/// rows share one vocabulary.
enum SettingsPickerOptions {

    // MARK: - The widening rule

    /// `options`, plus one extra row carrying `stored` when no option already holds that value.
    /// The extra row is inserted in value order so the list still reads as an ascending scale.
    static func including<Value: Hashable & Comparable>(
        stored: Value,
        in options: [SettingsPickerOption<Value>],
        label: (Value) -> String
    ) -> [SettingsPickerOption<Value>] {
        guard !options.contains(where: { $0.value == stored }) else { return options }
        let extra = SettingsPickerOption(value: stored, label: label(stored))
        guard let insertion = options.firstIndex(where: { $0.value > stored }) else {
            return options + [extra]
        }
        var widened = options
        widened.insert(extra, at: insertion)
        return widened
    }

    // MARK: - Labels

    /// A number without a ".0" tail. Guarded on finiteness and Int range because `defaults write`
    /// can store 1e300 or a NaN.
    static func trimmed(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        guard value == value.rounded(), abs(value) < 1e15 else { return "\(value)" }
        return String(Int(value))
    }

    static func dateToleranceLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Exact match" }
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(trimmed(seconds)) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(trimmed(minutes)) minutes"
    }

    static func fileSizeLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "No minimum" }
        if bytes >= 1_048_576 { return "\(trimmed(Double(bytes) / 1_048_576)) MB" }
        if bytes >= 1024 { return "\(trimmed(Double(bytes) / 1024)) KB" }
        return bytes == 1 ? "1 byte" : "\(bytes) bytes"
    }

    /// Rounded to two decimal places before trimming: 0.6 is not exactly representable, so a bare
    /// `fraction * 100` renders as "60.00000000000001%".
    static func percentLabel(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "\(fraction)" }
        return "\(trimmed(((fraction * 100) * 100).rounded() / 100))%"
    }

    // MARK: - The three numeric pickers

    static func dateTolerance(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 1, 2, 5, 60], dateToleranceLabel), label: dateToleranceLabel)
    }

    static func minFileSize(including stored: Int) -> [SettingsPickerOption<Int>] {
        including(stored: stored, in: rows([0, 4096, 102_400, 1_048_576], fileSizeLabel), label: fileSizeLabel)
    }

    static func overlapThreshold(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0.5, 0.6, 0.7, 0.8, 0.9], percentLabel), label: percentLabel)
    }

    private static func rows<Value: Hashable>(
        _ values: [Value], _ label: (Value) -> String
    ) -> [SettingsPickerOption<Value>] {
        values.map { SettingsPickerOption(value: $0, label: label($0)) }
    }
}

// MARK: - Browse

/// Browse's two pages (TE332): how every pane lists files, and the Browse window's View-menu
/// switches.
///
/// Panes' settings apply to every pane in every workspace, Compare's included, and the caption says
/// so; the tab is named for the workspace where people look for them (his call, JS). Window's keys
/// live in `BrowseWindowSettings` and `PaneViewMode` (Design), because the app that reads them is
/// above this module.
struct BrowseSettingsTab: View {
    let page: SettingsSubTab
    @EnvironmentObject var settings: SettingsManager
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(GeneralSettings.showHiddenByDefaultKey) private var showHiddenByDefault: Bool = false
    @AppStorage(PaneViewMode.browseDefaultsKey) private var browseViewModeRaw: String = PaneViewMode.default.rawValue
    @AppStorage(BrowseWindowSettings.sidebarVisibleKey) private var sidebarVisible: Bool = BrowseWindowSettings.sidebarVisibleDefault
    @AppStorage(BrowseWindowSettings.sidebarRecentsModeKey) private var recentsModeRaw: String = RecentsMode.recents.rawValue
    @AppStorage(BrowseWindowSettings.tabBarVisibleKey) private var tabBarVisible: Bool = BrowseWindowSettings.tabBarVisibleDefault
    @AppStorage(BrowseWindowSettings.statusBarVisibleKey) private var statusBarVisible: Bool = BrowseWindowSettings.statusBarVisibleDefault
    /// Whether a Columns divider sizes its own column or every column — see `ColumnResizeMode`.
    @AppStorage(ColumnResizeMode.defaultsKey) private var columnResizeModeRaw: String =
        ColumnResizeMode.default.rawValue
    /// The columns sized one at a time, which choosing "All columns" releases.
    @AppStorage(PaneViewMode.columnWidthOverridesDefaultsKey) private var columnWidthOverrides =
        ColumnWidthOverrides()
    /// Asks before "All columns" erases the widths of that many columns sized on their own.
    private let confirmReleasingColumnWidths: @MainActor (Int) -> Bool
    /// Bumped by a declined "All columns", to rebuild the picker. Otherwise the clicked segment
    /// stays lit: the setter wrote nothing, so SwiftUI has no change to redraw from.
    @State private var declinedResizeChoices = 0
    /// Whether keyboard focus is on the picker. The decline's rebuild drops focus with the old
    /// control, so a keyboard or VoiceOver user is put back where they were.
    @FocusState private var resizePickerFocused: Bool

    /// The app takes the standard alert; a test that drives the picker passes its own answer, since
    /// a modal alert in a test process blocks its main thread with nothing to dismiss it.
    init(page: SettingsSubTab, onCustomizePaneBar: (() -> Void)? = nil,
         confirmReleasingColumnWidths: @escaping @MainActor (Int) -> Bool = {
        RemovalPrompt.releaseColumnWidths(count: $0).ask()
    }) {
        self.page = page
        self.onCustomizePaneBar = onCustomizePaneBar
        self.confirmReleasingColumnWidths = confirmReleasingColumnWidths
    }

    /// Opens Dashboard's Customize Pane Bar sheet; nil hides the row (see `SettingsView`).
    private let onCustomizePaneBar: (() -> Void)?

    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue }

    /// The setting, written through one rule: choosing "All columns" puts every column back to the
    /// one shared width. Keeping the columns sized on their own would leave one wide column under
    /// "All columns", which looks broken.
    private var columnResizeMode: Binding<String> {
        Binding(
            get: { columnResizeModeRaw },
            set: { raw in
                let overrides = columnWidthOverrides
                guard let choice = Self.chooseResizeMode(
                    raw, overrides: overrides,
                    confirm: { confirmReleasingColumnWidths(overrides.widths.count) })
                else {
                    let hadFocus = resizePickerFocused
                    declinedResizeChoices += 1
                    // Next turn, once the rebuilt picker exists to take it.
                    if hadFocus { DispatchQueue.main.async { resizePickerFocused = true } }
                    return
                }
                // Written only after the answer, and only what changed: any write is a defaults
                // change other windows react to.
                let old = columnResizeModeRaw
                columnResizeModeRaw = choice.mode
                if choice.overrides != overrides { columnWidthOverrides = choice.overrides }
                SettingsWindowLog.log("readability.columnWidths", from: .string(old), to: .string(choice.mode))
            })
    }

    /// The setter's rule, reachable without mounting the tab. Asks first when "All columns" would
    /// release columns sized on their own: their widths are erased, and choosing "Each column"
    /// again doesn't bring them back. With none, it doesn't ask. The rule is `ColumnResizeChoice`'s,
    /// so a control outside the tab applies it too.
    /// - Returns: The mode and widths to store, or nil when declined — nothing is written then.
    static func chooseResizeMode(_ raw: String, overrides: ColumnWidthOverrides,
                                 confirm: () -> Bool) -> (mode: String, overrides: ColumnWidthOverrides)? {
        ColumnResizeChoice.choose(raw, overrides: overrides, confirm: confirm)
    }

    var body: some View {
        SettingsPage {
            if page == .window { window } else { panes }
        }
    }

    // Titleless sections: each page is one group, and the strip already names it.
    private var panes: some View {
        SettingsSection(caption: "For every pane in every workspace, Compare’s Differences included.") {
            Toggle("Show hidden files by default", isOn: $showHiddenByDefault.loggingSettingsChange("general.showHiddenByDefault"))
                .help("Starts each launch with hidden files shown in both panes. Showing or hiding them while you work lasts until you quit.")
            SettingsRow("Sort panes by") {
                Picker("Sort panes by", selection: $settings.defaultSortOption.loggingSettingsChange("general.sortPanesBy")) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Sorts the files in both panes. Changing the sort from a pane’s menu changes this too.")
            }
            Toggle(isOn: $settings.rescanWhenFilesChange.loggingSettingsChange("sync.rescanOnChange")) {
                Text("Rescan when files change")
            }
            .help("Rescans a pane by itself when something in its folder changes, so rows can move while you look at them. Off, the scan age says “changed since” and the list waits for Refresh.")
            // The segments are short because at the sheet's floor the content is about 340pt
            // wide; the note carries ⌥, which nothing else shows.
            LabeledContent("Column widths") {
                Picker("Column widths", selection: columnResizeMode) {
                    ForEach(ColumnResizeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
                .fixedSize()
                .focused($resizePickerFocused)
                .id(declinedResizeChoices)
                .help("What dragging a divider in Columns resizes: Each column resizes that column, All columns resizes every column. Hold ⌥ for the other; double-clicking a divider fits to the longest name the same way. All columns also puts every column back to one width, and asks first when a column was sized on its own.")
            }
            Text("Hold ⌥ while dragging a divider to do the other.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onCustomizePaneBar {
                SettingsRow("Pane bar") {
                    Button("Customize Pane Bar…", action: onCustomizePaneBar)
                }
                .help("Which buttons the bar above each pane shows, in what order, and at what size. The same sheet as right-clicking the pane bar.")
            }
        }
    }

    private var window: some View {
        SettingsSection(caption: "View as and the status bar are Browse’s. The sidebar shows in every workspace but Edit.") {
            SettingsRow("View as") {
                Picker("View as", selection: $browseViewModeRaw.loggingSettingsChange(label: "View as", words: { PaneViewMode(rawValue: $0)?.displayName ?? $0 })) {
                    ForEach([PaneViewMode.columns, .tree]) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
                .fixedSize()
                .help("How Browse shows its pane: Columns opens a column per folder, Tree expands folders in place.")
            }
            Toggle("Show sidebar", isOn: $sidebarVisible.loggingSettingsChange(label: "Show sidebar", words: \.onOff))
                .help("The folder sidebar beside the panes, in every workspace but Edit, which keeps its own. View ▸ Sidebar changes it too.")
            SettingsRow("Sidebar recents") {
                Picker("Sidebar recents", selection: $recentsModeRaw.loggingSettingsChange(label: "Sidebar recents", words: { $0 })) {
                    ForEach(RecentsMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("What the sidebar’s Recents heading lists: the folders you were last in, the ones you return to on different days, or the ones you stay in most. Its icon cycles through them too.")
            }
            Toggle("Show tab bar", isOn: $tabBarVisible.loggingSettingsChange(label: "Show tab bar", words: \.onOff))
                .help("The tab bar above each pane. It shows anyway while a pane has a second tab. View ▸ Tab Bar changes it too.")
            Toggle("Show status bar", isOn: $statusBarVisible.loggingSettingsChange(label: "Show status bar", words: \.onOff))
                .help("The line under Browse’s pane with its item count. View ▸ Status Bar changes it too.")
        }
    }
}

// MARK: - Compare

/// Compare (Sync until TE332, raw value still `sync`): what counts as a difference, what is
/// ignored, and One-Way Sync. The conflict policy and the confirmations moved to General, because
/// they govern every copy and move.
struct SyncSettingsTab: View {
    let page: SettingsSubTab
    @EnvironmentObject var settings: SettingsManager
    let syncManager: FileSyncManager?
    var oneWaySync: AnyView?
    @State private var patternDraft = ""
    /// The Differences table's own choice (FileExplorer), keyed in Design so this page reaches it.
    @AppStorage(DifferencesSettings.groupByFolderKey) private var groupByFolder: Bool = DifferencesSettings.groupByFolderDefault

    var body: some View {
        SettingsPage {
            switch page {
            case .ignored: ignored
            case .oneWaySync: oneWay
            default: differences
            }
        }
    }

    @ViewBuilder
    private var oneWay: some View {
        if let oneWaySync {
            SettingsSection(caption: "Anything replaced or removed in Dropbox goes to Dropbox ▸ SyncCloud Removed.") {
                oneWaySync
            }
        }
    }

    private var differences: some View {
        SettingsSection(caption: "Providers round dates on upload; a small tolerance hides those false differences.") {
            // Rows come from `SettingsPickerOptions`, which adds the stored value when it isn't
            // offered, so an off-list tolerance shows rather than leaving the picker blank.
            SettingsRow("Treat dates as equal within") {
                Picker("Treat dates as equal within", selection: $settings.dateToleranceSeconds.loggingSettingsChange("sync.dateTolerance")) {
                    ForEach(SettingsPickerOptions.dateTolerance(including: settings.dateToleranceSeconds)) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Counts two modification dates as the same when they are this close, so a provider rounding dates on upload doesn’t show up as a difference.")
            }
            Toggle(isOn: $settings.autoVerifySameSizeDuringScan.loggingSettingsChange("sync.verifySameSize")) {
                Text("Verify same-size files during scans")
            }
            .help("During each scan, checksums same-size files that differ only by date and hides the ones that are identical. Files over 100 MB are left for Verify All. Thorough, but slower on large folders.")
            Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly.loggingSettingsChange("sync.ignoreGoogleDriveNewer")) {
                Text("Ignore “newer on Google Drive” when same size")
            }
            .help("When Google Drive is in the right pane, hides differences where only its copy is newer and the sizes match — Drive often rewrites file dates.")
            Toggle("Group by folder", isOn: $groupByFolder.loggingSettingsChange("sync.groupByFolder"))
                .help("Breaks the Differences list into a section per top-level folder. Off, it is one flat list, so a sort by size runs across the whole comparison. The list’s filter menu changes it too.")
        }
    }

    @ViewBuilder
    private var ignored: some View {
        // No caption: "remove one" means nothing until there is one, so the list says it itself.
        SettingsSection("Ignored items") {
            Toggle(isOn: $settings.rememberIgnoredItems.loggingSettingsChange("sync.rememberIgnored")) {
                Text("Remember ignored items across rescans")
            }
            .help("Keeps an item you ignore from the Differences list hidden through rescans, folder changes, and relaunches, for each pair of sources. Off, an ignore lasts only until you move to another folder.")
            if let syncManager, let store = syncManager.ignoredItemsStore {
                IgnoredItemsList(
                    store: store,
                    onRemove: {
                        syncManager.unignoreRootRelative($0)
                        SettingsWindowLog.log("sync.ignoredItems", "an item no longer ignored")
                    },
                    onClear: {
                        let count = store.rootRelativePaths.count
                        syncManager.clearAllIgnoredItems()
                        SettingsWindowLog.log("sync.ignoredItems", "Clear All, \(count) no longer ignored")
                    }
                )
            }
        }

        SettingsSection(
            "Ignored name patterns",
            caption: "* matches any run of characters, ? matches one."
        ) {
            ForEach(settings.ignorePatterns, id: \.self) { pattern in
                HStack {
                    Text(pattern)
                        .scaledFont(.system(.callout, design: .monospaced))
                    Spacer()
                    Button {
                        settings.removeIgnorePattern(pattern)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Remove this pattern")
                    .accessibilityLabel("Remove this pattern")
                }
            }
            HStack(spacing: 8) {
                TextField("*.tmp, .DS_Store, node_modules", text: $patternDraft)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.system(.callout, design: .monospaced))
                    .onSubmit(addPattern)
                    .help("A name pattern to hide from every comparison, at any depth — * matches any run of characters, ? matches one. Press Return or click Add.")
                Button("Add", action: addPattern)
                    .disabled(IgnoreRules.normalized(patternDraft) == nil)
            }
        }
    }

    private func addPattern() {
        if settings.addIgnorePattern(patternDraft) {
            patternDraft = ""
        }
    }
}

/// The remembered-ignores rows on Compare ▸ Ignored: a monospaced root-relative path per
/// entry with a remove button, plus Clear All. Split out so it can observe the store
/// directly — un-ignoring from here must repaint the list immediately.
///
/// Internal rather than `private` so the tests can reach `clearAll(confirm:)`, the gate Clear All
/// goes through.
struct IgnoredItemsList: View {
    @ObservedObject var store: IgnoredItemsStore
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        if store.rootRelativePaths.isEmpty {
            Text("Nothing ignored. Right-click a difference and choose Ignore.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.sortedPaths, id: \.self) { path in
                HStack {
                    Text(path)
                        .scaledFont(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer()
                    Button {
                        onRemove(path)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Stop ignoring this item")
                    .accessibilityLabel("Stop ignoring this item")
                }
            }
            Text("Remove one to see its differences again.")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Clear All…", role: .destructive) {
                    clearAll(confirm: RemovalPrompt.clearIgnoredItems(
                        count: store.rootRelativePaths.count).ask)
                }
                .controlSize(.small)
                .help("Stops ignoring every item listed, so each comes back in Differences. Asks first.")
            }
        }
    }

    /// Clear All asks first: every ignore goes at once.
    ///
    /// **Never clear a pair the question didn't name.** The app keeps running while the alert is
    /// up, and a source removed meanwhile moves the store to another pair; then nothing is cleared.
    /// - Returns: Whether the list was cleared.
    @discardableResult
    func clearAll(confirm: () -> Bool) -> Bool {
        let askedAbout = store.activeKey
        guard confirm() else { return false }
        guard store.activeKey == askedAbout else {
            Logger.shared.info("Clear All for ignored items not applied: the folders being compared changed while it asked")
            return false
        }
        onClear()
        return true
    }
}

// MARK: - Duplicates

/// Organize ▸ Duplicates: how a duplicate scan decides what counts as a match. A page of Organize
/// since TE332, because Find Duplicates is a view of the Organize workspace. Changes apply on the
/// next scan.
struct DuplicatesSettingsTab: View {
    // The defaults keys keep their `tidy` prefixes ("tidyMinFileSize" and friends, owned by
    // `DuplicateFinderOptions.DefaultsKey`) because they are a persistence format. To trace a
    // stored value, follow the `DefaultsKey` constant, not the property name.
    @AppStorage(DuplicateFinderOptions.DefaultsKey.minFileSize) private var duplicateMinFileSize: Int = 4096
    @AppStorage(DuplicateFinderOptions.DefaultsKey.overlapThreshold) private var duplicateOverlapThreshold: Double = 0.7
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectVersions) private var duplicateDetectVersions: Bool = true
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectSameText) private var duplicateDetectSameText: Bool = true
    /// Where the groups kept separate are remembered. Optional because tests and previews build the
    /// page without an engine; the row then reads None.
    var syncManager: FileSyncManager? = nil
    /// Read on appear and after Show Again: the set is plain defaults, not published, and nothing
    /// else changes it while the sheet is up.
    @State private var keptSeparateCount = 0

    var body: some View {
        SettingsPage {
            // Titleless: the strip already says "Duplicates".
            SettingsSection(
                caption: "Identical files are always confirmed by checksum. Reading PDFs slows only the first scan."
            ) {
                // Both row lists come from `SettingsPickerOptions` so a stored value outside the
                // offered set still displays (and survives) instead of rendering as no selection.
                SettingsRow("Ignore files smaller than") {
                    Picker("Ignore files smaller than", selection: $duplicateMinFileSize.loggingSettingsChange("duplicates.minSize")) {
                        ForEach(SettingsPickerOptions.minFileSize(including: duplicateMinFileSize)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Leaves files below this size out of the results. They still count when whole folders are compared.")
                }
                SettingsRow("Folders overlap at") {
                    Picker("Folders overlap at", selection: $duplicateOverlapThreshold.loggingSettingsChange("duplicates.overlap")) {
                        ForEach(SettingsPickerOptions.overlapThreshold(including: duplicateOverlapThreshold)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How much of their content two same-named folders must share to be grouped as overlapping. Below it, they’re treated as unrelated.")
                }
                Toggle("Detect versions (Report, Report (1), Report-final)", isOn: $duplicateDetectVersions.loggingSettingsChange("duplicates.detectVersions"))
                    .help("Groups files whose names differ only by a marker like “(1)”, “copy”, “-v2”, or “final”, even though their contents differ.")
                Toggle("Read PDFs to find copies a byte hash misses", isOn: $duplicateDetectSameText.loggingSettingsChange("duplicates.readPDFs"))
                    .help("Reads the text of PDFs to find one document saved twice with different bytes. No OCR; the first scan of a large folder takes a few minutes longer.")
            }

            SettingsSection("Kept separate", caption: "Show Again forgets them, so the next scan flags them again.") {
                SettingsRow("Groups kept separate") {
                    HStack(spacing: 8) {
                        Text(keptSeparateCount == 0 ? "None" : keptSeparateCount.formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Show Again…") {
                            if let syncManager, Self.showAgainIfConfirmed(syncManager, confirm: {
                                RemovalPrompt.showKeptSeparateAgain(count: keptSeparateCount).ask()
                            }) != nil {
                                keptSeparateCount = syncManager.keptSeparateGroupCount
                            }
                        }
                        .disabled(keptSeparateCount == 0)
                    }
                }
                .help("Groups you chose Keep Separate for in Find Duplicates, in every folder. The Duplicates view’s Show Them Again does one folder at a time.")
            }
        }
        .onAppear { keptSeparateCount = syncManager?.keptSeparateGroupCount ?? 0 }
    }

    /// Show Again, as one step: ask, and only then forget every group kept separate.
    /// - Returns: How many were forgotten, or nil when declined.
    @discardableResult
    static func showAgainIfConfirmed(_ sync: FileSyncManager, confirm: () -> Bool) -> Int? {
        guard sync.keptSeparateGroupCount > 0, confirm() else { return nil }
        return sync.forgetAllKeptSeparateGroups()
    }
}

// MARK: - Organize ▸ To File

/// Organize ▸ To File: where Organize looks for loose files, the rules it was taught, and what it
/// knows about each source's folders. Suggestions, People and Duplicates are the tab's other pages
/// (`OrganizeSuggestionsPage`, `PeopleSettingsTab`, `DuplicatesSettingsTab`); the allowed names
/// went to Sources ▸ Name Checks, beside the rule that raises them.
struct FilingSettingsTab: View {
    /// Folder surveys reach the surveys through it. Optional because tests and previews build the
    /// page without an engine.
    let syncManager: FileSyncManager?
    /// Cloud sources by name and landing folder, for Folder surveys. Empty hides the section,
    /// which is how the layout tests build the page.
    var surveySources: [(name: String, root: String)] = []
    /// See `SettingsView.onOpenRules`. nil hides the button.
    var onOpenRules: (() -> Void)? = nil
    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"
    @AppStorage(FilingScorecard.shownDefaultsKey) private var showsScorecard = true
    /// The inbox when its field took focus: the field writes every keystroke, so the change is
    /// logged once, at Return or when focus leaves.
    @State private var inboxAtFocus: String?
    @FocusState private var inboxFocused: Bool

    var body: some View {
        SettingsPage {
            // "Inbox", not "Filing", a retired word (search keeps it as a keyword), and not
            // "Organize", which would repeat the rail row.
            SettingsSection("Inbox") {
                SettingsRow("Loose-files inbox") {
                    // The placeholder is "None", not the default "TODO", so an emptied field reads
                    // as off rather than untouched. The help text says what off does.
                    TextField("None", text: $filingInbox)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                        .focused($inboxFocused)
                        .onSubmit(commitInbox)
                        .onChange(of: inboxFocused) { _, focused in
                            if focused { inboxAtFocus = filingInbox } else { commitInbox() }
                        }
                        .onDisappear(perform: commitInbox)
                }
                .help("The folder (relative to the provider root) where loose files pile up — e.g. “TODO”. Organize offers it on its overview as a one-click way to narrow to that folder. It does not open there on its own; leave this blank and the offer disappears.")
                if let onOpenRules {
                    SettingsRow("Rules you taught by correcting") {
                        Button("Open Rules", action: onOpenRules)
                            .controlSize(.small)
                    }
                    .help("A rule you teach by correcting a suggestion is saved. Review, edit or delete it under Rules in the Organize workspace.")
                }
                Toggle("Filing scorecard", isOn: $showsScorecard.loggingSettingsChange("organize.filingScorecard"))
                    .help("Shows how often you kept To File’s first pick, above its cards. Counting continues while hidden.")
            }

            if let syncManager, !surveySources.isEmpty {
                FolderSurveysSection(syncManager: syncManager, sources: surveySources)
            }
        }
    }

    /// Logs the inbox's change since its field took focus, once.
    private func commitInbox() {
        guard let was = inboxAtFocus else { return }
        inboxAtFocus = inboxFocused ? filingInbox : nil
        SettingsWindowLog.log("organize.inbox", from: .string(was), to: .string(filingInbox))
    }
}

// MARK: - Edit

/// Edit (new in TE332): the Edit workspace's remembered choices, which were set only from the
/// Text and View menus, the format bar's menu and the reader's own controls. A page per kind of
/// document, Markdown inside Text.
///
/// The keys live in `EditorTextSettings` and `EditorPDFSettings` (Design), because the editor
/// that reads them is in FileExplorer, which this module can't see. Autosave stays per file, on
/// the file: the page says where.
struct EditSettingsTab: View {
    let page: SettingsSubTab
    @AppStorage(EditorTextSettings.wrapsKey) private var wraps = EditorTextSettings.wrapsDefault
    @AppStorage(EditorTextSettings.readableLineLengthKey) private var readableLineLength = EditorTextSettings.readableLineLengthDefault
    @AppStorage(EditorTextSettings.drawsPageKey) private var drawsPage = EditorTextSettings.drawsPageDefault
    @AppStorage(EditorTextSettings.typewriterScrollingKey) private var typewriterScrolling = EditorTextSettings.typewriterScrollingDefault
    @AppStorage(EditorTextSettings.checksSpellingKey) private var checksSpelling = EditorTextSettings.checksSpellingDefault
    @AppStorage(EditorTextSettings.showsFormatBarKey) private var showsFormatBar = EditorTextSettings.showsFormatBarDefault
    @AppStorage(EditorTextSettings.formatBarShowsLabelsKey) private var formatBarShowsLabels = EditorTextSettings.formatBarShowsLabelsDefault
    @AppStorage(EditorTextSettings.continuesListsKey) private var continuesLists = EditorTextSettings.continuesListsDefault
    @AppStorage(EditorTextSettings.editsInPreviewKey) private var editsInPreview = EditorTextSettings.editsInPreviewDefault
    @AppStorage(EditorPDFSettings.layoutKey) private var pdfLayoutRaw: String = EditorPDFSettings.layoutDefault.rawValue
    @AppStorage(EditorPDFSettings.coverSeparatelyKey) private var coverSeparately = EditorPDFSettings.coverSeparatelyDefault
    /// The saved signatures' list, drawn by FileExplorer (see `SettingsView.savedSignatures`).
    var savedSignatures: AnyView? = nil

    var body: some View {
        SettingsPage {
            if page == .pdf { pdf } else { text }
        }
    }

    @ViewBuilder
    private var text: some View {
        SettingsSection("Text", content: {
            Toggle("Wrap lines", isOn: $wraps.loggingSettingsChange(label: "Wrap lines", words: \.onOff))
                .help("Wraps lines at the column edge. Off, a long line runs on with a horizontal scroller, as a log or a CSV needs.")
            Toggle("Readable line length", isOn: $readableLineLength.loggingSettingsChange(label: "Readable line length", words: \.onOff))
                .disabled(!wraps)
                .help("Keeps wrapped text to a readable column in a wide window, rather than edge to edge. It means nothing while Wrap lines is off.")
            Toggle("Paper background", isOn: $drawsPage.loggingSettingsChange(label: "Paper background", words: \.onOff))
                .help("Sets Source’s text on a page — white in Light Mode, dark gray in Dark Mode — rather than on the window’s glass.")
            Toggle("Typewriter scrolling", isOn: $typewriterScrolling.loggingSettingsChange(label: "Typewriter scrolling", words: \.onOff))
                .help("Holds the caret’s line at mid-height as you type and move with the keyboard. A click, a drag and the trackpad leave the text where it is.")
            Toggle("Check spelling while typing", isOn: $checksSpelling.loggingSettingsChange(label: "Check spelling while typing", words: \.onOff))
                .help("Underlines misspelled words. It never changes your text: nothing in the editor corrects or replaces words for you.")
        }, caption: {
            // The rule, then its one exception.
            VStack(alignment: .leading, spacing: 2) {
                Text("The same switches as the Text menu, for every file.")
                Text("Autosave is set per file: Text ▸ Autosave This File.")
            }
        })

        SettingsSection("Markdown") {
            Toggle("Format bar", isOn: $showsFormatBar.loggingSettingsChange(label: "Format bar", words: \.onOff))
                .help("The bar of formatting buttons above a Markdown file’s text. View ▸ Format Bar changes it too.")
            Toggle("Labels on the format bar", isOn: $formatBarShowsLabels.loggingSettingsChange(label: "Labels on the format bar", words: \.onOff))
                .help("Puts a word beside each icon where there is room. Right-clicking the bar changes it too: Icon and Text, or Icon Only.")
            Toggle("Continue lists", isOn: $continuesLists.loggingSettingsChange(label: "Continue lists", words: \.onOff))
                .help("Return carries a list on, and Tab and ⇧Tab move an item in and out. ⌘Z takes a new marker back.")
            Toggle("Edit in Preview (experimental)", isOn: $editsInPreview.loggingSettingsChange(label: "Edit in Preview (experimental)", words: \.onOff))
                .help("Lets you type in Preview, for small changes. Experimental, and for Markdown files only.")
        }
    }

    @ViewBuilder
    private var pdf: some View {
        SettingsSection("Reading") {
            SettingsRow("Page layout") {
                Picker("Page layout", selection: $pdfLayoutRaw.loggingSettingsChange(label: "Page layout", words: { EditorPDFLayout(rawValue: $0)?.title ?? $0 })) {
                    ForEach(EditorPDFLayout.allCases, id: \.rawValue) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("How a PDF’s pages are laid out when it opens. The reader’s own layout menu changes it too.")
            }
            Toggle("Cover page separately", isOn: $coverSeparately.loggingSettingsChange(label: "Cover page separately", words: \.onOff))
                .disabled(!(EditorPDFLayout(rawValue: pdfLayoutRaw) ?? EditorPDFSettings.layoutDefault).isTwoUp)
                .help("In the two-page layouts, shows the first page on its own, so a book’s spreads pair as they do in print.")
        }

        if let savedSignatures {
            SettingsSection("Saved signatures", caption: "Kept on this Mac for Fill & Sign.") {
                savedSignatures
            }
        }
    }
}

// MARK: - Organize ▸ Suggestions

/// Organize ▸ Suggestions: how Organize suggests where files go — the free on-device pass, Refine,
/// and the cache that stops either being asked twice.
///
/// Refine has no switch or model of its own (TE335): a saved key turns it on, it runs on the chat's
/// model, and its limit, key and privacy are Ask Claude's, a jump away.
struct OrganizeSuggestionsPage: View {
    /// Reaches `filingVerdictCache*` for the saved-suggestion count. Optional because tests and
    /// previews build the page without an engine.
    let syncManager: FileSyncManager?
    /// See `SettingsView.onOpenHelp`. nil hides the pointer beside the on-device switch.
    var onOpenHelp: ((String) -> Void)? = nil
    /// Moves the sheet to another page, for the jump to the key. nil hides it.
    var onJump: ((SettingsPlace) -> Void)? = nil
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true
    @AppStorage(FileSyncManager.readContentsDefaultsKey) private var filingReadContents: Bool = true
    @AppStorage(FileSyncManager.reuseVerdictsDefaultsKey) private var filingReuseVerdicts: Bool = true

    /// How many saved suggestions there are. Read on appear and after a clear, not in `body`,
    /// because answering it touches the cache file.
    @State private var savedSuggestionCount = 0

    /// The Help pointer beside "Read file contents on this Mac", a privacy switch whose caption can
    /// say what is read but not what happens to it afterwards.
    ///
    /// Shaped like `RestructureLens.helpPointer`, glyph included: one affordance through the app's
    /// Help front door, never an overlay or sheet. `questionmark.circle`, not `info.circle`, so
    /// the app has one mark for "the book has a page on this".
    @ViewBuilder
    private var helpPointer: some View {
        if let onOpenHelp {
            Button { onOpenHelp(SettingsHelpTopics.onDeviceReading) } label: {
                Image(systemName: "questionmark.circle")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // A glyph-only control needs both: `.help` is the tooltip, not the name.
            .accessibilityLabel("About reading your documents")
            .help("What gets opened, how much is read, what is kept — and why none of it leaves this Mac.")
            .chromeHover()
        }
    }

    var body: some View {
        SettingsPage {
            SettingsSection(
                "On-device",
                caption: "Free, and runs on this Mac. Changes apply on the next scan."
            ) {
                Toggle("Suggest folders with Apple Intelligence", isOn: $filingUseAI.loggingSettingsChange("intelligence.onDeviceAI"))
                    .help("Lets Organize ask the on-device model where files belong. Off, or where it isn’t available, Organize suggests from names and metadata alone. Nothing here opens a network connection. Refine and saved suggestions need it on.")
                // `.firstTextBaseline`, so the glyph sits on the label's baseline rather than
                // centring on the switch, which at Large text leaves it high.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Toggle("Read file contents on this Mac", isOn: $filingReadContents.loggingSettingsChange("intelligence.readContents"))
                        .help("Lets Organize read the text inside your files, on this Mac, for better folder suggestions. Refine sends an excerpt of each file too, when you click it.")
                    helpPointer
                }
            }

            SettingsSection(
                "Refine",
                caption: "Refine asks Claude in an Ask Claude chat when you click it. A saved API key turns it on."
            ) {
                if let onJump {
                    HStack {
                        Text("Key, model and limit")
                        Spacer(minLength: 12)
                        Button("Ask Claude ▸ Key & Spending") { onJump(SettingsPlace(.keyAndSpending)) }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection(
                "Saved suggestions",
                caption: "With reuse on, an unchanged file keeps its suggestion, so Refine doesn’t pay for it twice."
            ) {
                Toggle("Reuse suggestions for files that haven’t changed", isOn: $filingReuseVerdicts.loggingSettingsChange("intelligence.reuseSuggestions"))
                    .disabled(!filingUseAI)
                    .help("Gives a file that hasn’t been edited, renamed, or moved the suggestion it got last time, instead of asking the model — or paying Claude — again.")
                SettingsRow("Saved suggestions") {
                    HStack(spacing: 8) {
                        Text(savedSuggestionCount == 1 ? "1 file" : "\(savedSuggestionCount) files")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // Asks first: the next Refine pays Claude again for every file.
                        Button("Clear…", role: .destructive) {
                            guard let syncManager else { return }
                            // Counted at the click, since a scan may have saved more and the
                            // question names what goes. The non-awaiting read is free: the button
                            // stays disabled until the awaited count has loaded the memo.
                            savedSuggestionCount = syncManager.filingVerdictCacheCountNow
                            // Cleared elsewhere meanwhile: nothing to ask, and the button disables.
                            guard savedSuggestionCount > 0 else { return }
                            if IntelligenceSettingsTab.clearSavedSuggestionsIfConfirmed(
                                confirm: RemovalPrompt.clearSavedSuggestions(count: savedSuggestionCount).ask,
                                clear: { syncManager.clearFilingVerdictCache() }) {
                                savedSuggestionCount = syncManager.filingVerdictCacheCountNow
                            }
                        }
                        .disabled(savedSuggestionCount == 0)
                        .help("Forgets every saved suggestion. The next scan asks the on-device model about each file again, and the next Refine asks — and pays — Claude again. Asks first.")
                    }
                }
            }
        }
        // **Never move this into `body`'s reads:** the count decodes a cache file of up to ~12 MB,
        // which must not run on the main actor.
        .task { savedSuggestionCount = await syncManager?.filingVerdictCacheCount() ?? 0 }
    }
}

// MARK: - Ask Claude

/// Ask Claude (Intelligence until TE332, raw value still `intelligence`): the chat's model and
/// answers, what Claude may see, and the key and what Claude costs.
///
/// Key & Spending holds the one monthly limit, which the chat, Refine, Try Another and Refine Names
/// share (TE335), and the notice that says Refine's own caps are gone.
struct IntelligenceSettingsTab: View {
    let page: SettingsSubTab
    @AppStorage(AskClaudeModels.defaultsKey) private var askClaudeModel: String = AskClaudeModels.defaultModel.id
    @AppStorage(AskClaudeSpend.limitDefaultsKey) private var askClaudeLimitUSD: Double = AskClaudeSpend.defaultLimitUSD
    @AppStorage(AskClaudeDetail.defaultsKey) private var askClaudeAnswers: String = AskClaudeDetail.brief.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @State private var askClaudeHidden: [String] = []
    @State private var askClaudeShared: [String] = []
    @State private var askClaudeSpentUSD = 0.0
    @State private var organizeSpentUSD = 0.0
    /// What Refine's old caps and history said, until it is read (``RefineSpendMigration``).
    @State private var refineNotice: RefineSpendMigration.Notice?

    @ViewBuilder private func refineNoticeBody(_ notice: RefineSpendMigration.Notice) -> some View {
        Text(notice.text)
            .scaledFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer(minLength: 0)
            Button("Got It") {
                RefineSpendMigration.dismissNotice()
                refineNotice = nil
            }
            .controlSize(.small)
        }
    }

    var body: some View {
        SettingsPage {
            switch page {
            case .privacy: privacy
            case .keyAndSpending: keyAndSpending
            default: general
            }
        }
    }

    private var general: some View {
        Group {
            modelAndAnswers
            NotesForClaudeSection()
            AskClaudeIntroSection()
            AskClaudeSuggestionsSection()
        }
    }

    private var modelAndAnswers: some View {
        SettingsSection(caption: "Model and answers apply from the next question, in an open chat too.") {
            SettingsRow("Model") {
                Picker("Model", selection: Binding(
                    get: { AskClaudeModels.option(for: askClaudeModel).id },
                    set: { askClaudeModel = $0 }).loggingSettingsChange("intelligence.askClaudeModel")) {
                    ForEach(AskClaudeModels.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Sonnet 5.5 answers a typical question for about a cent. A change carries on in the open chat from its next question; the menu under Ask Claude’s text box changes it too.")
            }
            SettingsRow("Answers") {
                Picker("Answers", selection: $askClaudeAnswers.loggingSettingsChange("intelligence.answers")) {
                    ForEach(AskClaudeDetail.allCases, id: \.rawValue) { detail in
                        Text(detail.label).tag(detail.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accentedSegments(LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
                .labelsHidden()
                .fixedSize()
                .help("Brief answers in a sentence or two. Detailed explains what it checked and names close alternatives, and costs a little more per answer. A change carries on in the open chat from its next question; the menu under Ask Claude’s text box changes it too.")
            }
        }
    }

    @ViewBuilder
    private var privacy: some View {
        SettingsSection(
            "What Claude may see",
            caption: "A folder asks each time unless it’s shared or hidden, and hidden wins. Refine leaves hidden ones out."
        ) {
            SettingsRow("Every folder") {
                Text("Ask Each Time").foregroundStyle(.secondary)
            }
            .help("Claude sees the names, sizes and dates on screen. Before anything from inside a file goes to it, the chat asks, unless the file’s folder is shared or hidden below.")
            SettingsRow("Hidden from Claude") {
                VStack(alignment: .leading, spacing: 4) {
                    if askClaudeHidden.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(askClaudeHidden, id: \.self) { folder in
                        HStack(spacing: 6) {
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle)
                            // Hidden by path: a folder renamed or moved since is no longer
                            // covered, so the list says so rather than looking protected.
                            if !FileManager.default.fileExists(atPath: folder) {
                                Text("Not found — renamed or moved?")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help("This is hidden by its path. If it was renamed or moved, add it again under its new name.")
                            }
                            Button("Remove") {
                                if Self.unhideIfConfirmed(folder, in: .standard, confirm: RemovalPrompt.showToClaude(
                                    named: (folder as NSString).lastPathComponent,
                                    isFolder: Self.isFolderOrMissing(folder)).ask) {
                                    SettingsWindowLog.log("intelligence.hidden", "removed")
                                }
                                askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Remove \((folder as NSString).lastPathComponent) from the hidden list")
                            .help("Shows it to Claude again. Asks first.")
                        }
                    }
                    // Files too, as a row's Hide from Claude allows.
                    Button("Add…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = true
                        panel.prompt = "Hide from Claude"
                        if panel.runModal() == .OK {
                            for url in panel.urls { AskClaudePrivacy.hide(url.path, in: .standard) }
                            SettingsWindowLog.log("intelligence.hidden", "added")
                            NotesForClaudeSection.offerToRemoveLines(naming: panel.urls.map(\.path))
                            askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Claude is never shown these folders and files, or what’s in them: not their names, not their contents. They appear to it only as a count. Right-click a row ▸ Hide from Claude adds one too.")
            }
            // Added here or from the shield menu in Ask Claude; taken off with no question, since
            // taking one off is the stricter way.
            SettingsRow("Shared without asking") {
                VStack(alignment: .leading, spacing: 4) {
                    if askClaudeShared.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(askClaudeShared, id: \.self) { folder in
                        HStack(spacing: 6) {
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Remove") {
                                AskClaudePrivacy.stopSharing(folder, in: .standard)
                                SettingsWindowLog.log("intelligence.shared", "removed")
                                askClaudeShared = AskClaudePrivacy.sharedFolders(in: .standard)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Stop sharing \((folder as NSString).lastPathComponent) without asking")
                            .help("Claude asks before anything from it goes again.")
                        }
                    }
                    // Folders only, as the shield shares a folder and everything in it.
                    Button("Add…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = true
                        panel.prompt = "Share Without Asking"
                        if panel.runModal() == .OK {
                            let shared = panel.urls.filter { url in
                                Self.shareIfConfirmed(url.path, in: .standard) { $0.ask() }
                            }
                            if !shared.isEmpty { SettingsWindowLog.log("intelligence.shared", "added") }
                            askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
                            askClaudeShared = AskClaudePrivacy.sharedFolders(in: .standard)
                        }
                    }
                    .controlSize(.small)
                }
                .help("From these folders, Apple Intelligence’s answers, page text, search names and lookups go to Claude without a card. Whole documents still ask. Anything hidden inside one stays hidden; adding a hidden folder takes it off Hidden from Claude, and asks first. The shield in Ask Claude adds one too.")
            }
        }
        .onAppear {
            askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
            askClaudeShared = AskClaudePrivacy.sharedFolders(in: .standard)
        }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)
            .receive(on: DispatchQueue.main)) { _ in
            askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
            askClaudeShared = AskClaudePrivacy.sharedFolders(in: .standard)
        }

        AskClaudePastChatsSettings()
    }

    @ViewBuilder
    private var keyAndSpending: some View {
        SettingsSection(
            "Claude API key",
            caption: "Stored in your Keychain. Pays for Ask Claude, Refine, Try Another and Refine Names."
        ) {
            CloudKeyRow()
        }

        if let notice = refineNotice {
            // Headed by what it mostly says: the old limits, or only Try Another's change.
            if notice.hadLimits == false {
                SettingsSection("Try Another asks Claude now") { refineNoticeBody(notice) }
            } else {
                SettingsSection("Refine’s own limits are gone") { refineNoticeBody(notice) }
            }
        }

        SettingsSection(
            "Monthly limit",
            caption: "Estimated from list prices. Ask Claude, Refine, Try Another and Refine Names share it, and stop at it until the month turns."
        ) {
            SettingsRow("Monthly limit") {
                Picker("Monthly limit", selection: $askClaudeLimitUSD.loggingSettingsChange("intelligence.monthlyLimit")) {
                    ForEach(AskClaudeSpend.limitChoices, id: \.self) { value in
                        Text(value == 0 ? "No limit" : AskClaudeSpend.format(value)).tag(value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Ask Claude warns at 80% of this and stops taking questions at it, until the month turns. Estimated from list prices; the Console has what was billed.")
            }
            SettingsRow("This month") {
                Text(AskClaudeSpend.format(askClaudeSpentUSD))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SettingsRow("Of that, Organize") {
                Text(AskClaudeSpend.format(organizeSpentUSD))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Refine, Try Another and Refine Names. It is part of this month’s total, not added to it.")
            }
        }
        .onAppear {
            askClaudeSpentUSD = AskClaudeSpend.spent(in: .standard)
            organizeSpentUSD = AskClaudeSpend.organizeSpent(in: .standard)
            refineNotice = RefineSpendMigration.pendingNotice()
        }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudeSpend.didChange)
            .receive(on: DispatchQueue.main)) { _ in
            askClaudeSpentUSD = AskClaudeSpend.spent(in: .standard)
            organizeSpentUSD = AskClaudeSpend.organizeSpent(in: .standard)
        }
    }

    /// Hidden from Claude's Remove, as one step: ask, and only then show the item to Claude again.
    /// - Returns: Whether it was taken off the list.
    @discardableResult
    static func unhideIfConfirmed(_ path: String, in defaults: UserDefaults, confirm: () -> Bool) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm) { AskClaudePrivacy.unhide(path, in: defaults) }
    }

    /// Shared without asking's Add…, for one folder. Hidden wins over shared, so a folder hidden
    /// now, by its own entry or a folder above it, is shared only on a yes to `confirm`, and those
    /// entries come off Hidden from Claude first, as the shield in Ask Claude takes them off.
    /// - Returns: Whether it was shared.
    @discardableResult
    static func shareIfConfirmed(_ path: String, in defaults: UserDefaults,
                                 confirm: (RemovalPrompt) -> Bool) -> Bool {
        let folder = (path as NSString).standardizingPath
        let covering = AskClaudePrivacy.hiddenEntries(covering: folder, in: defaults)
        if !covering.isEmpty {
            let above = covering.filter { ($0 as NSString).standardizingPath.lowercased() != folder.lowercased() }
                .map { ($0 as NSString).lastPathComponent }
            guard confirm(.shareHidden(named: (folder as NSString).lastPathComponent, above: above)) else { return false }
            covering.forEach { AskClaudePrivacy.unhide($0, in: defaults) }
        }
        AskClaudePrivacy.shareWithoutAsking(folder, in: defaults)
        return true
    }

    /// A path that is gone reads as a folder: the list holds folders far more often than files.
    static func isFolderOrMissing(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || isDirectory.boolValue
    }

    /// Saved suggestions' Clear, as one step: ask, and only then forget.
    /// - Returns: Whether the suggestions were cleared.
    @discardableResult
    static func clearSavedSuggestionsIfConfirmed(confirm: () -> Bool, clear: () -> Void) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm, act: clear)
    }

}

// MARK: - People

/// Organize ▸ People: who Organize files for.
///
/// A page of its own because it is a roster, not a preference: rows with their own facts and veto counts, an
/// overview of what the set governs, a name-suggestion queue, a tester and an editor sheet, like
/// `ProvidersSettingsTab`'s list of things the user maintains.
///
/// The page is ``PeopleList``'s, which lays out its own sections for its four subjects: the
/// roster, what was read off the tree, what the roster governs, and the tester. The tab only
/// decides whether there is an engine to draw them from.
struct PeopleSettingsTab: View {
    /// Reaches the people store, the folder profile, the filing memory and the veto log. Optional
    /// because tests and previews build the tab without an engine.
    let syncManager: FileSyncManager?
    /// See `SettingsView.onShowPerson`.
    var onShowPerson: ((Person) -> Void)? = nil

    var body: some View {
        SettingsPage {
            if let store = syncManager?.filingPeopleStore,
               let vetoLog = syncManager?.filingPersonVetoLog {
                PeopleList(store: store,
                           profile: syncManager?.filingFolderProfile,
                           memory: syncManager?.filingMemory,
                           vetoLog: vetoLog,
                           onShowPerson: onShowPerson)
            } else {
                // No engine attached (tests, previews): say so, and never offer an Add button
                // that would write nowhere.
                SettingsSection(caption: PeopleList.purposeCaption) {
                    PeopleList.noStoreNote
                }
            }
        }
    }
}

/// The kept-names rows inside the Organize tab: one name per entry with a remove button, plus
/// Clear All. A kept name draws no badge, so this is the only place the whole set of "I meant that
/// name" decisions is visible.
///
/// Split out so it can observe ``KeptNamesStore`` directly. `FileSyncManager` holds the store in a
/// plain `var`, not `@Published`, so a view watching only the manager wouldn't repaint when the
/// set changes; the manager's didSet sends `objectWillChange` by hand, but this view doesn't rely
/// on it.
///
/// Internal so the tests can call `remove(_:)` and `clearAll(confirm:)` against a real store on an
/// injected defaults suite. Nothing else constructs it.
struct KeptNamesList: View {
    @ObservedObject var store: KeptNamesStore

    var body: some View {
        if store.names.isEmpty {
            Self.nothingKeptNote
        } else {
            ForEach(store.sortedNames, id: \.self) { name in
                HStack {
                    KeptNameLabel(name: name)
                    Spacer()
                    Button {
                        remove(name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Report “\(name)” again — here, on its row, and in Organize")
                    .accessibilityLabel("Report \(name) again")
                }
            }
            HStack {
                Spacer()
                Button("Clear All…", role: .destructive) {
                    clearAll(confirm: RemovalPrompt.clearKeptNames(count: store.names.count).ask)
                }
                .controlSize(.small)
                .help("Stops keeping every name listed, so each is flagged again. Asks first.")
            }
        }
    }

    /// Withdraw one keep. Straight to the store, as the row menu's "Stop Allowing This Name" does:
    /// the store is the single mutation point, and `FileSyncManager` subscribes to it for the
    /// announcement and the `riskyNames` reconciliation.
    func remove(_ name: String) { store.stopKeeping(name) }

    /// Withdraw every keep, after asking. One store call rather than a loop over `remove(_:)`, so
    /// the manager re-filters its finding once. The confirmer has no default, so a test cannot
    /// reach the modal alert by leaving it out.
    /// - Returns: Whether the keeps were withdrawn.
    @discardableResult
    func clearAll(confirm: () -> Bool) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm) { store.stopKeepingAll() }
    }

    /// Shown by an empty store, and by a tab built without an engine attached.
    static var nothingKeptNote: some View {
        Text("No allowed names yet.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }
}

/// The question asked before a person leaves the roster — here and on setup's People screen.
///
/// One wording for one act: both places remove from the same `people.json`, taking the full names
/// and aliases curated here with the person.
public enum PersonRemoval {
    public static func title(_ name: String) -> String { "Remove \(name)?" }

    /// Says what removal does and what it doesn't, so nobody has to guess whether it touches their
    /// files.
    public static let message = "Their folders and files are left exactly as they are. Organize will stop "
        + "recognizing documents that name them, so it will no longer keep those documents "
        + "out of other people’s folders."
}

/// Who Organize files for — one row per person, each editable, each showing what the engine
/// actually knows about them.
///
/// "People", not "the household": the same roster could tell one colleague's contract from
/// another's in a work tree.
///
/// Each row shows what the record buys, because the rule can silently refuse a filing suggestion
/// when a document names the wrong person: the name forms matched, how many folders are theirs,
/// how many documents are filed there, and a warning when every word they answer to is shared
/// (the case where adding a full name helps). One line per person with the detail behind a
/// disclosure, like the Sources tab, so the page doesn't crowd; the rest is in titled sections.
///
/// `@ObservedObject` on the store because the roster is written from this view and must show its
/// own edits.
struct PeopleList: View {
    @ObservedObject var store: PeopleStore
    let profile: FolderProfile?
    let memory: FilingMemory?
    /// What the cross-person rule has refused. Optional: with no engine there is nothing to report,
    /// and an empty log is the ordinary state of a machine that has not filed anything yet.
    @ObservedObject var vetoLog: PersonVetoLog
    /// See `SettingsView.onShowPerson`. nil hides "Show Their Files" on every row.
    let onShowPerson: ((Person) -> Void)?

    /// Which person is open in the editor. `nil` closes it; a person with an empty id is the
    /// "add" case, the same sheet doing both jobs.
    @State private var editing: Person?
    @State private var confirmingRemoval: Person?
    /// Ids of the rows the user has opened; shut by default. State, not a persisted default, as in
    /// `ProvidersSettingsTab.expandedIds`.
    @State private var expandedIds: Set<String>
    /// Name forms found in the tree that nobody has recorded. Empty until asked for: reading a few
    /// hundred folders shouldn't happen just because a tab appeared.
    @State private var suggestions: [PersonNameSuggestion] = []
    @State private var isLooking = false
    @State private var hasLooked = false

    /// `initiallyExpanded` lets a test render an opened row: `@State` has no storage off the view
    /// tree, so a probe can't click one. The app passes nothing, like `PeopleTester.initialText`.
    init(store: PeopleStore, profile: FolderProfile?, memory: FilingMemory?,
         vetoLog: PersonVetoLog, onShowPerson: ((Person) -> Void)? = nil,
         initiallyExpanded: Set<String> = []) {
        self.store = store
        self.profile = profile
        self.memory = memory
        self.vetoLog = vetoLog
        self.onShowPerson = onShowPerson
        _expandedIds = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        // Before the list, because the list below is a seed and its edits won't be written; without
        // it the refusal in `PeopleStore.save()` would look like a change that worked.
        if store.rosterIsUnreadable {
            Self.unreadableRosterNote
        } else if !store.repeatedRosterIds.isEmpty {
            // Its own note: here the list is real but missing a record, and the note names the id
            // so they can find it in the file, the only place the dropped record still exists.
            Self.repeatedIdRosterNote(store.repeatedRosterIds)
        }
        peopleSection
        if !store.people.isEmpty {
            // The queue sits under the roster, and only once its button has been pressed.
            if hasLooked || !suggestions.isEmpty {
                namesFound
            }
            // Needs a survey: without one it could only say nobody has folders, which reads as a
            // fault.
            if profile != nil {
                acrossTheTree
            }
            tester
        }
    }

    // MARK: - The sections

    /// The roster: a header row carrying the two actions, the list, and the caption that says what
    /// the whole thing is for.
    private var peopleSection: some View {
        SettingsSection(caption: Self.purposeCaption + " " + sourceNote) {
            HStack(spacing: 10) {
                Text("People")
                    .scaledFont(.body.weight(.medium))
                    // On the heading, not the section: a section's tooltip shows over every row
                    // that has none of its own.
                    .help(Self.purposeHelp)
                Spacer()
                if profile != nil, !store.people.isEmpty {
                    Button(action: look) {
                        if isLooking {
                            Text("Reading…")
                        } else {
                            Label("Look for Names", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isLooking)
                    .help("Reads the file names already in each person’s folders and offers any name "
                          + "form they use that is not recorded yet. Nothing is changed without asking.")
                }
                Button {
                    editing = Person(id: "", displayName: "")
                } label: {
                    Label("Add Person…", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if store.people.isEmpty {
                Self.emptyRosterNote
            } else {
                roster
                if store.orderIsCustom {
                    // The visible way back to the default order, which nothing else restores.
                    // Under the list, not beside Add Person…: it's about the whole list, and a
                    // third button there doesn't fit at the largest text size.
                    HStack {
                        Spacer()
                        Button("Use Default Order") { store.useDefaultOrder() }
                            .controlSize(.small)
                            .help("Back to relationship order — you, spouse, children, parents, "
                                  + "siblings, then everyone else")
                    }
                }
            }
        }
        .sheet(item: $editing) { person in
            PersonEditor(person: person,
                         isNew: person.id.isEmpty,
                         roster: store.people,
                         onSave: { edited in
                             if person.id.isEmpty {
                                 store.add(displayName: edited.displayName,
                                           relationship: edited.relationship,
                                           fullNames: edited.fullNames,
                                           aliases: edited.aliases)
                             } else {
                                 store.update(edited)
                             }
                             editing = nil
                         },
                         onCancel: { editing = nil })
                .presentedNativeControlAccent()
        }
        .alert(PersonRemoval.title(confirmingRemoval?.displayName ?? ""),
               isPresented: Binding(get: { confirmingRemoval != nil },
                                    set: { if !$0 { confirmingRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let p = confirmingRemoval { store.remove(id: p.id) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text(PersonRemoval.message)
        }
    }

    /// The people, one line each, in a well. Separators are inset past the initials disc so they
    /// divide rows of one list rather than sections.
    private var roster: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.people.enumerated()), id: \.element.id) { index, person in
                if index > 0 {
                    Divider().padding(.leading, PersonRow.textInset)
                }
                PersonRow(facts: facts(for: person), person: person,
                          preventedCount: vetoLog.count(namedPerson: person.id),
                          lastPrevented: vetoLog.mostRecent(namedPerson: person.id),
                          isExpanded: expansionBinding(person.id),
                          folderRoot: profile.map(Self.lookRoot(for:)),
                          canMoveUp: store.canMove(id: person.id, up: true),
                          canMoveDown: store.canMove(id: person.id, up: false),
                          orderIsCustom: store.orderIsCustom,
                          onEdit: { editing = person },
                          onRemove: { confirmingRemoval = person },
                          onMove: { up in store.move(id: person.id, up: up) },
                          onUseDefaultOrder: { store.useDefaultOrder() },
                          onShowFiles: onShowPerson.map { show in { show(person) } })
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Radius.well, style: .continuous))
    }

    /// What "Look for Names" read off the tree, or the sentence that says it found nothing.
    private var namesFound: some View {
        SettingsSection("Names found in your documents",
                        caption: "From file names in each person’s folders. Nothing is added without asking.") {
            if suggestions.isEmpty {
                Label("No new names — every form your filed documents use is already recorded.",
                      systemImage: "checkmark.circle")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(suggestions) { suggestion in
                PersonSuggestionRow(suggestion: suggestion,
                                    personName: store.person(id: suggestion.personId)?.displayName
                                        ?? suggestion.personId,
                                    onAccept: {
                                        store.acceptSuggestion(suggestion)
                                        suggestions.removeAll { $0.id == suggestion.id }
                                    },
                                    onDismiss: {
                                        store.dismissSuggestion(suggestion)
                                        suggestions.removeAll { $0.id == suggestion.id }
                                    })
            }
        }
    }

    /// What the roster governs across the tree, and where it doesn't reach: facts about the set,
    /// not any one row.
    private var acrossTheTree: some View {
        SettingsSection("Across your tree") {
            PeopleOverviewRow(overview: overview, store: store)
        }
    }

    private var tester: some View {
        SettingsSection("Try a filename",
                        caption: "See who Organize would say a document belongs to, and what that decides.") {
            PeopleTester(registry: store.registry, factsById: allFacts)
        }
    }

    // MARK: - What the sections draw from

    /// One row's open/closed state. A binding over the shared set, not per-row `@State`, so a row
    /// rebuilt when the store republishes doesn't snap shut under the pointer.
    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedIds.insert(id)
                } else {
                    expandedIds.remove(id)
                }
            }
        )
    }

    /// Everything known about one person, computed in `Sync` so the claim this view makes is
    /// testable without a window.
    private func facts(for person: Person) -> PersonFilingFacts {
        PersonFilingFacts.make(for: person, registry: store.registry,
                               profile: profile, memory: memory)
    }

    /// Reads the person folders off the main actor and publishes what it learned. Detached because
    /// a few hundred directory listings is too much for the actor drawing the window.
    private func look() {
        guard let profile else { return }
        isLooking = true
        let registry = store.registry
        let dismissed = store.dismissedSuggestions
        let root = Self.lookRoot(for: profile)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                PeopleNameScanner.suggestions(registry: registry, profile: profile, root: root,
                                              dismissed: dismissed)
            }.value
            suggestions = found
            hasLooked = true
            isLooking = false
        }
    }

    /// Where "Look for Names" reads: the tree the profile itself describes, since its folder paths
    /// are relative to `profile.root`. **Never use a root that only a scan sets**: the button is
    /// offered whenever a profile is loaded, and with no scan yet it would silently do nothing.
    ///
    /// Resolved as every other reader of the profile does (`FileSyncManager+RestructureApply`,
    /// `duplicateScanCoversSurvey`): the recorded root with its tilde expanded.
    nonisolated static func lookRoot(for profile: FolderProfile) -> URL {
        URL(fileURLWithPath: (profile.root as NSString).expandingTildeInPath)
    }

    /// Keyed tolerantly: a strict dictionary init traps on a duplicate key, and `people.json` is
    /// hand-edited. ``PersonRegistry`` already collapses a repeated id on load, but **keep this**
    /// in case that collapse regresses. `theFactsMapStaysTolerantOfARepeatedKey` pins it, since
    /// no behavioural test can reach it.
    ///
    /// Last wins, which is the collapse's own rule and ``FolderSurveyBuilder``'s over the same file.
    private var allFacts: [String: PersonFilingFacts] {
        Dictionary(store.people.map { ($0.id, facts(for: $0)) }, uniquingKeysWith: { _, latest in latest })
    }

    private var overview: PeopleOverview {
        PeopleOverview.make(registry: store.registry, profile: profile, memory: memory)
    }

    private var sourceNote: String {
        store.source == .file
            ? "Saved in people.json, on this Mac."
            : "This list was suggested from your folder names — edit anyone to make it yours."
    }

    /// What the roster is for, in a line (TE332); the rest is `purposeHelp`, and the longer
    /// version with a worked example is in Help.
    static let purposeCaption = "Who Organize files documents for. Add each person’s names as their documents print them."

    /// What the caption gave up: what the roster decides, and the order rule, which the reader
    /// would otherwise have to guess.
    static let purposeHelp = "The people Organize files for. It keeps one person’s document out of another’s folder, and chooses between folders that differ only by person (School/Daughter beside School/Son). A full name is matched before any single word. The list is in relationship order — you, spouse, children, parents, siblings, then everyone else — until you move someone, after which your order is kept. Nothing here leaves your Mac, and only the names you add are stored."

    /// Shown when `people.json` is on disk but unreadable. It names the file and says plainly that
    /// edits won't save, or the roster would look ordinary while its edits went nowhere.
    static var unreadableRosterNote: some View {
        Label {
            Text("The people file couldn’t be read, so this list is guessed from folder names. Edits won’t be saved. Fix people.json and restart SyncCloud — ~/sync-cloud.log says what went wrong.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shown when `people.json` lists an id more than once: the list below is one person short of
    /// the file, and edits are held back so the write cannot make that permanent.
    ///
    /// Names the ids, because the dropped record exists only in the file and the app no longer
    /// shows it.
    static func repeatedIdRosterNote(_ ids: [String]) -> some View {
        Label {
            Text(ids.count == 1
                 ? "people.json lists “\(ids[0])” more than once, so only its last entry is in use here. Edits won’t be saved, because saving would delete the others. Give each person a unique id in people.json and restart SyncCloud."
                 : "people.json lists these ids more than once — \(ids.joined(separator: ", ")) — so only the last entry of each is in use here. Edits won’t be saved, because saving would delete the others. Give each person a unique id in people.json and restart SyncCloud.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shown when the roster is empty but editable — an invitation, not an error.
    static var emptyRosterNote: some View {
        Text("No people yet. Add the people whose documents you file — yourself, family — and Organize will stop mixing up whose document is whose.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }

    /// Shown when there is no engine behind the tab at all (tests, previews).
    static var noStoreNote: some View {
        Text("People are available once a filing profile is loaded.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }
}

/// One person: who they are on one line, and — once opened — what the engine matches them on,
/// what that is worth in this tree, and the buttons that change the record.
///
/// Shut, the row is the initials disc, the name, the relationship, and how many folders and
/// documents are theirs. A caution glyph joins it only for the state that can change an outcome
/// (see `caveatLine`), so a row that shows one is the row to open.
///
/// Open, it adds the evidence, then the caveat (the only tinted line), then the buttons.
private struct PersonRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let facts: PersonFilingFacts
    let person: Person
    let preventedCount: Int
    let lastPrevented: PersonVetoEvent?
    @Binding var isExpanded: Bool
    /// The tree the person's folders are relative to, for "Show Folder". nil without a survey.
    let folderRoot: URL?
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Whether the list is in the user's own order — which is when "Use Default Order" is offered.
    let orderIsCustom: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void
    /// `true` moves the row up.
    let onMove: (Bool) -> Void
    let onUseDefaultOrder: () -> Void
    /// Hands the person to the app's gather. nil hides the button — see `SettingsView.onShowPerson`.
    let onShowFiles: (() -> Void)?

    /// Where the text starts, past the disc. The row separators and the opened detail share it, so
    /// the detail reads as belonging to the name above.
    static let textInset: CGFloat = PersonInitials.diameter + 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(person.displayName)"
                                           : "Expand \(person.displayName)")
            if isExpanded {
                detail
                    .padding(.leading, Self.textInset)
                    .padding(.bottom, 8)
            }
        }
        // Every action is also a right-click away, for anyone who doesn't open the row first.
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove…", role: .destructive, action: onRemove)
            Divider()
            if let onShowFiles, facts.folderCount > 0 {
                Button("Show Their Files", action: onShowFiles)
            }
            Button("Move Up") { onMove(true) }.disabled(!canMoveUp)
            Button("Move Down") { onMove(false) }.disabled(!canMoveDown)
            if orderIsCustom {
                Button("Use Default Order", action: onUseDefaultOrder)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PersonInitials(person: person)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(person.displayName).scaledFont(.callout).fontWeight(.medium)
                if let relationship = person.relationship {
                    Text(relationship).scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if caveatLine != nil {
                // The glyph only; the sentence is in the detail.
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(.caption)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.caution))
                    .accessibilityLabel("Cannot be attributed yet")
            }
            if !isExpanded {
                // Hidden while open: the detail's second line says the same, with the areas.
                Text(countsLine)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // A bare chevron is a ~7pt target; the row is the target, and the frame keeps the
                // glyph from drifting as the counts beside it change width.
                .frame(width: 22, height: 22)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(matchedLine).scaledFont(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !knowledgeLine.isEmpty {
                Text(knowledgeLine).scaledFont(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if preventedCount > 0 {
                // A sentence, so the readable ink rather than raw green, like the caveat below.
                Text(preventedLine).scaledFont(.subheadline)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.success))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caveat = caveatLine {
                Text(caveat).scaledFont(.subheadline)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.caution))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Edit…", action: onEdit)
                Button("Remove…", action: onRemove)
                    .help("Remove \(person.displayName) from the list")
                if facts.folderCount > 0 {
                    // Two ways to go to what the numbers count: the app's gather of everything
                    // theirs, or Finder one folder at a time, grouped by area because a flat menu
                    // of hundreds of paths is unusable.
                    if let onShowFiles {
                        Button(action: onShowFiles) {
                            Label("Show Their Files", systemImage: "doc.text.magnifyingglass")
                        }
                        .help("Gather everything that is \(person.displayName)’s, across the whole source")
                    }
                    if folderRoot != nil {
                        folderMenu
                    }
                }
                Spacer(minLength: 0)
                Button {
                    onMove(true)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!canMoveUp)
                .help("Move \(person.displayName) up")
                .accessibilityLabel("Move \(person.displayName) up")
                Button {
                    onMove(false)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(!canMoveDown)
                .help("Move \(person.displayName) down")
                .accessibilityLabel("Move \(person.displayName) down")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    /// The person's folders, one submenu per area, each item revealing that folder in Finder.
    ///
    /// Capped per area, not overall, which would silently drop whole areas off the end.
    private var folderMenu: some View {
        Menu {
            ForEach(facts.areas, id: \.name) { area in
                let paths = folders(inArea: area.name)
                Menu("\(area.name) (\(paths.count))") {
                    ForEach(paths.prefix(Self.folderMenuCap), id: \.self) { path in
                        Button(path, action: { reveal(path) })
                    }
                    if paths.count > Self.folderMenuCap {
                        Text("…and \(paths.count - Self.folderMenuCap) more")
                    }
                }
            }
        } label: {
            Label("Show Folder", systemImage: "folder")
        }
        .help("Reveal one of \(person.displayName)’s folders in Finder")
    }

    static let folderMenuCap = 40

    /// The person's folders under one area, in the order `PersonFilingFacts` keeps them —
    /// shallowest first, then by name.
    private func folders(inArea area: String) -> [String] {
        facts.folders.filter { $0.split(separator: "/").first.map(String.init) == area }
    }

    private func reveal(_ relative: String) {
        guard let folderRoot else { return }
        let url = folderRoot.appendingPathComponent(relative)
        Logger.shared.info("People: revealing \(person.displayName)'s folder \(relative) in Finder")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The shared-word detail lives in the tooltip, not on a line: everyone on a family roster
    /// shares a word with somebody, so it isn't a problem.
    private var tooltip: String {
        var parts = [matchedLine]
        if !facts.uniqueWords.isEmpty {
            parts.append("Theirs alone: " + facts.uniqueWords.joined(separator: ", ") + ".")
        }
        if !facts.sharedWords.isEmpty {
            parts.append("Shared with others on this list: " + facts.sharedSummary + ".")
        }
        return parts.joined(separator: " ")
    }

    /// The forms a document is matched against, longest first — which is the order they are tried
    /// in, so the line doubles as an explanation of precedence.
    private var matchedLine: String {
        facts.matchedForms.isEmpty ? person.displayName
                                   : "Matches " + facts.matchedForms.joined(separator: " · ")
    }

    /// The only line that reports the rule doing something, rather than what is known. Absent at
    /// zero.
    private var preventedLine: String {
        let count = preventedCount == 1 ? "1 document" : "\(preventedCount) documents"
        guard let last = lastPrevented else { return "Kept \(count) out of other folders" }
        return "Kept \(count) out of other folders — last “\(last.fileName)”"
    }

    /// The shut row's trailing figure: how much of the tree is theirs. Grouped, like every count
    /// the app prints, and stated at zero ("No folders yet") so a blank can't hide which row.
    private var countsLine: String {
        guard facts.folderCount > 0 else { return "No folders yet" }
        var out = facts.folderCount == 1 ? "1 folder" : "\(facts.folderCount.formatted()) folders"
        if facts.filedDocuments > 0 {
            out += facts.filedDocuments == 1
                ? " · 1 document" : " · \(facts.filedDocuments.formatted()) documents"
        }
        return out
    }

    /// What the record is worth in this tree: how much, and where.
    ///
    /// One line: the totals say how much, up to three area names say about what. More names stop
    /// being a summary.
    ///
    /// Omitted when nothing has been surveyed, where "0 folders" would read as a fault.
    private var knowledgeLine: String {
        guard facts.folderCount > 0 else { return "" }
        guard !facts.areas.isEmpty else { return countsLine }
        let names = facts.areas.prefix(3).map(\.name)
        let rest = facts.areas.count - names.count
        return countsLine + " · " + names.joined(separator: ", ") + (rest > 0 ? " +\(rest) more" : "")
    }

    /// The one line that can change an outcome, shown only when there is one: every word this
    /// person answers to belongs to somebody else too, and they have no multi-word form for the
    /// matcher, so no document can be attributed to them. Merely sharing a word isn't enough.
    private var caveatLine: String? {
        guard !facts.isAttributable else { return nil }
        let shared = facts.sharedWords.isEmpty
            ? "Nothing names them yet"
            : "Nothing names them yet: " + facts.sharedSummary
        return shared + " — add a full name as documents print it"
    }
}

/// A name form the documents keep using that nobody has recorded — offered, never applied.
///
/// The evidence is the point: the count and a real filename let the user decide in a second,
/// including when the answer is no (a wedding folder naming a couple reads like a name).
struct PersonSuggestionRow: View {
    let suggestion: PersonNameSuggestion
    let personName: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(suggestion.form)” — another name for \(personName)?")
                    .scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(suggestion.occurrences) of their filed documents use it, "
                     + "including “\(suggestion.exampleFile)”")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add", action: onAccept).controlSize(.small)
                .help("Adds “\(suggestion.form)” to \(personName)’s full names on documents.")
            Button("Not a Name", action: onDismiss).controlSize(.small)
                .help("Dismisses “\(suggestion.form)” — it won’t be suggested again.")
        }
        .padding(.vertical, 2)
    }
}

/// A person's initials in a tinted disc. Identity at a glance, and the one thing on the row that
/// stays legible when the text is scaled up and everything else wraps.
private struct PersonInitials: View {
    let person: Person

    static let diameter: CGFloat = 22

    var body: some View {
        Text(initials)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(tint.gradient))
            .accessibilityHidden(true)
    }

    /// Two letters of the display name, not initials of the full name, which can repeat within one
    /// family. The display name heads the row and names the folders, so the disc tracks it.
    private var initials: String {
        let name = PersonRegistry.words(person.displayName).first ?? person.displayName
        return name.prefix(2).capitalized
    }

    /// Derived from the id, so a person keeps their colour across renames and relaunches.
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo]
        var hash = 5381
        for byte in person.id.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// A kept name with its invisible characters made visible — an affix space as "␣", a zero-width
/// scalar as "◌", both tinted.
///
/// Not a plain `Text`: many risky names differ only by invisible characters, so "report " and
/// "report" would look identical. The rule is ``InvisibleNameMarking``, shared with the Rename
/// lens's card so the two agree on how many trailing spaces a name has.
private struct KeptNameLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(InvisibleNameMarking.cells(for: name).enumerated()), id: \.offset) { _, cell in
                if cell.isMarker {
                    // Caution, matching the Rename lens's markers and the risky-names pill. The
                    // marker keeps the name's own ink; the caution is the wash behind it.
                    Text(cell.glyph)
                        .background(SemanticColor.caution.opacity(PillVariant.fillOpacity))
                } else {
                    Text(cell.glyph)
                }
            }
        }
        .scaledFont(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(name)
    }
}

// MARK: - Advanced

/// Logging, maintenance, saved scan data, both ways back into setup, and the settings reset:
/// engine machinery given a user-facing surface.
struct AdvancedSettingsTab: View {
    let syncManager: FileSyncManager?
    let onResetAllSettings: (() -> Void)?
    /// Opens the guided setup sheet with the current answers (General's until TE332, which put it
    /// beside Reset Setup). Defaulted for the reason on `onResetSetup`.
    var onRunSetup: (() -> Void)? = nil
    /// Clears the three setup flags and the draft, then opens the guided sheet at its first screen.
    ///
    /// **Keep it defaulted.** The tab uses the memberwise `init`, so a parameter without a default
    /// breaks every construction site, including `SettingsLayoutTests.mustFitTabs`.
    var onResetSetup: (() -> Void)? = nil
    /// What Reset All would raise for Claude from the values now, named in its confirmation as the
    /// card's question names it. Defaulted for the same reason as `onResetSetup`.
    var resetAllRaises: () -> [String] = { [] }

    @AppStorage(Logger.minimumLevelDefaultsKey) private var minimumLevelRaw: String = LogLevel.info.rawValue
    /// Whether the running log gate differs from the stored choice, which only a trace switch
    /// armed by hand does (it lowers this launch to Debug). Refreshed on appear and after a choice.
    @State private var runningLevelDiffers = false
    /// Human-readable size of the log file, refreshed on appear and after Clear Log.
    @State private var logFileSizeText: String?
    /// Human-readable sizes of the two saved-scan-data files, or nil where there is no file. nil is
    /// what disables each Clear, so "None" and a live button cannot disagree.
    @State private var hashIndexSizeText: String?
    @State private var storageLensSizeText: String?

    /// True when a trace switch lowered this launch below the level `raw` names. Not "the gate
    /// differs from the picker": under a test runner the gate is always Debug, and that is no
    /// trace switch.
    static func runningLevelDiffers(from raw: String) -> Bool {
        LogLevelSetting.traceLoweredThisLaunch
            && Logger.shared.minimumLevel != (LogLevel(rawValue: raw) ?? Logger.defaultMinimumLevel)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Logging",
                caption: "Rotates at 5 MB."
            ) {
                SettingsRow("Log level") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Log level", selection: $minimumLevelRaw) {
                            Text("Debug (everything)").tag(LogLevel.debug.rawValue)
                            Text("Info").tag(LogLevel.info.rawValue)
                            Text("Warnings").tag(LogLevel.warning.rawValue)
                            Text("Errors only").tag(LogLevel.error.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: minimumLevelRaw) { _, raw in
                            LogLevelSetting.applyRunning(raw: raw)
                            runningLevelDiffers = Self.runningLevelDiffers(from: raw)
                        }
                        .help("Which messages the log keeps: the chosen level and everything more severe; the rest are skipped entirely. Info, the default, keeps every operation and its outcome; Debug adds per-click detail.")
                        // A hand-armed trace switch runs this launch at Debug whatever the picker
                        // holds (`LaunchLogLevel` in the app); without this the picker would say Info
                        // over a log that is keeping everything.
                        if runningLevelDiffers {
                            Text("This launch logs at Debug: a trace switch is on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onAppear { runningLevelDiffers = Self.runningLevelDiffers(from: minimumLevelRaw) }
                }

                SettingsRow("Log file") {
                    HStack(spacing: 8) {
                        if let logFileSizeText {
                            Text(logFileSizeText)
                                .foregroundStyle(.secondary)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
                        }
                        Button(CopyLogForSharing.title) {
                            Task { await CopyLogForSharing.copy() }
                        }
                        .help(CopyLogForSharing.help)
                        // Asks first, like the Activity Log's trash button: one gesture, one name.
                        Button("\(Logger.clearLogName)…") {
                            guard Logger.shared.clearIfConfirmed() else { return }
                            Task { await refreshLogFileSize() }
                        }
                        .help("Empty the Activity Log and the log file on disk")
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                "Maintenance",
                caption: ".tmp_ files over an hour old go to the Trash on their own."
            ) {
                SettingsRow("Orphaned temporary files") {
                    Button("Sweep Now") {
                        syncManager?.sweepOrphanedTempArtifactsNow()
                    }
                    .controlSize(.small)
                    .disabled(syncManager == nil)
                    .help("Interrupted copies can leave .tmp_ working files behind. Moves the ones over an hour old, in the folders the panes have loaded, to the Trash now. Recovery backups (.rollback_) are never touched.")
                }
            }

            // Two scan caches the app writes to Application Support, beside the log file because
            // the question is "how much is this storing, and make it stop". Saved suggestions,
            // the third, lives with the toggles that decide what it keys on.
            //
            // Sizes, not entry counts: a `stat` each, where a count would parse the largest file
            // the app writes on the main actor as the tab appears.
            SettingsSection(
                "Saved scan data",
                caption: "Clearing only makes the next scan slower."
            ) {
                SettingsRow("File digests") {
                    HStack(spacing: 8) {
                        Text(hashIndexSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                // Logged before it happens: the effect shows up much later (a
                                // cold duplicate scan, "0 digest(s) reloaded" at launch), and
                                // `ContentHashIndexStore` logs only a failure to delete.
                                Logger.shared.info("User cleared the saved file digests")
                                await ContentHashCache.forgetAllPersistedIndexes()
                                // **Detached:** the barrier is a blocking `writeQueue.sync`, and
                                // on the main actor, behind a queued multi-megabyte index write,
                                // it would beachball.
                                await Task.detached(priority: .utility) {
                                    ContentHashIndexStore.waitForPendingWrites()
                                }.value
                                await refreshSavedScanData()
                            }
                        }
                        .disabled(hashIndexSizeText == nil)
                    }
                    .controlSize(.small)
                }
                .help("Checksums of files Duplicates and Verify have already read, so unchanged files aren’t read again. Clearing means the next scan re-reads them.")

                SettingsRow("Saved Storage reports") {
                    HStack(spacing: 8) {
                        Text(storageLensSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            // Logged for the digests' reason: an empty Storage panel later is the
                            // only other trace.
                            Logger.shared.info("User cleared the saved Storage reports")
                            syncManager?.forgetStoredStorageLens()
                            Task {
                                // Off the main actor: the barrier blocks on the store's write queue.
                                await Task.detached(priority: .utility) {
                                    StorageLensStore.waitForPendingWrites()
                                }.value
                                await refreshSavedScanData()
                            }
                        }
                        .disabled(storageLensSizeText == nil || syncManager == nil)
                    }
                    .controlSize(.small)
                }
                .help("The last Storage analysis for each folder, shown while a fresh one runs. Clearing means Storage starts from an empty panel again.")
            }

            // Both ways back into setup, together (TE332): one keeps your answers, one starts over.
            if onRunSetup != nil || onResetSetup != nil {
                SettingsSection("Setup", content: {
                    // Leading and full size, as Reset All Settings… is below: the three ways to
                    // start over read as one kind of control.
                    HStack(spacing: 8) {
                        if let onRunSetup {
                            Button("Run Setup Again…", action: onRunSetup)
                                .help("Reopens the guided setup sheet with your current answers filled in. Nothing is reset.")
                        }
                        if let onResetSetup {
                            Button("Reset Setup…", role: .destructive) {
                                confirmResetSetup(onResetSetup)
                            }
                            .help("Forgets that setup has run and which location it learns from, and opens it now, from the beginning. On a Mac with no folder profile yet this also discards the name and household answers setup was holding for one. Asks first.")
                        }
                    }
                }, caption: {
                    // About Reset Setup alone, so only where it is offered.
                    if onResetSetup != nil {
                        Text("Reset Setup starts over. Your folder profile and people stay; with no profile yet, its answers go.")
                    }
                })
            }

            if let onResetAllSettings {
                SettingsSection(
                    caption: "Restores defaults. Keeps what you made, the folders hidden from Claude, and Claude’s limits and record. Your files aren’t affected."
                ) {
                    Button("Reset All Settings…", role: .destructive) {
                        confirmReset(onResetAllSettings)
                    }
                    .help("Returns SyncCloud’s settings to their defaults and removes the folders you added as sources; keeps what you made — Rules, signatures, Favorites, pins and your choices while organizing — the folders hidden from Claude, and Claude’s spending limits and record. Asks first; your files aren’t touched.")
                }
            }
        }
        .task { await refreshLogFileSize() }
        .task { await refreshSavedScanData() }
    }

    /// Stats the saved-scan-data files. Digest sizes come from the cache actors, not the store,
    /// because only an actor knows whether persistence is enabled (the app injects a location;
    /// tests don't). "File digests" sums every persisted digest index, content hashes and document
    /// fingerprints alike, matching what Clear removes.
    private func refreshSavedScanData() async {
        let hashBytes = await ContentHashCache.totalPersistedSizeOnDisk()
        let storageBytes = syncManager?.storedStorageLensSizeOnDisk()
        // Zero bytes reads as "None": a cleared Storage store leaves an empty payload behind.
        hashIndexSizeText = Self.sizeText(hashBytes)
        storageLensSizeText = Self.sizeText(storageBytes)
    }

    private static func sizeText(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Asks before forgetting that setup has run.
    ///
    /// Its own alert, because without a folder profile the name and household answers live only in
    /// the draft, so clearing it loses them.
    private func confirmResetSetup(_ reset: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.resetSetupPrompt.messageText
        alert.informativeText = Self.resetSetupPrompt.informativeText
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if let resetButton = alert.buttons.first {
            resetButton.hasDestructiveAction = true
            resetButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        if NativeAlerts.runModalCancellingOnEscape(alert) == .alertFirstButtonReturn {
            reset()
        }
    }

    /// What Reset Setup asks, here so an Ask Claude card asks in the same words.
    static let resetSetupPrompt = (
        messageText: "Run setup again from the beginning?",
        informativeText: "SyncCloud forgets that setup has run and which location it learns from, and opens setup now, from the beginning. On a Mac that hasn’t learned a folder tree yet, the name and household answers setup was holding are discarded with it. Your folder profile, people and other settings stay.")

    /// What Reset All Settings takes and what it keeps, in the confirmation.
    static let resetAllExplanation = "Settings return to their defaults, apart from what is kept below. Folders you added as sources, ignored items, and source names and paths are removed, and SyncCloud forgets that setup has run.\n\nKept: your Rules, saved signatures, Favorites and pins, and the choices you made while organizing (corrections, groups kept separate, names kept); the folders you hid from Claude, and Notes for Claude; and your spending limits for Claude and the record of what it has cost. One-Way Sync stays set up as it is, with its choices for a Dropbox file deleted, renamed, moved or edited, and Launch at login stays as it is: macOS holds it. Your Claude API key, folder profile, Ask Claude chats and your files are not touched."

    /// The confirmation's words, with what the reset would raise for Claude from the values now
    /// (`SettingsActions.resetAllRaises`) — the same in Settings and on an Ask Claude card.
    static func resetAllQuestion(raising raised: [String]) -> String {
        resetAllExplanation + (raised.isEmpty ? "" : "\n\nThis also raises what Claude may do: " + raised.joined(separator: "; ") + ".")
    }

    /// Confirmation ahead of the defaults wipe; Cancel is the default button (Return must
    /// not reset, same convention as the permanent-delete alert).
    private func confirmReset(_ reset: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        // Names what goes and what stays, not only that files are unaffected: the folder sources
        // go with the defaults. What stays is `SettingsResetKeeps`.
        alert.informativeText = Self.resetAllQuestion(raising: resetAllRaises())
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if let resetButton = alert.buttons.first {
            resetButton.hasDestructiveAction = true
            resetButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        if NativeAlerts.runModalCancellingOnEscape(alert) == .alertFirstButtonReturn {
            reset()
        }
    }

    /// Stats the log file off the main actor (flushing buffered writes first so the number
    /// reflects everything logged).
    private func refreshLogFileSize() async {
        let url = Logger.shared.logFileURL
        let logger = Logger.shared
        let bytes = await Task.detached(priority: .utility) { () -> Int? in
            logger.flushToDisk()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.intValue
        }.value
        logFileSizeText = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}
