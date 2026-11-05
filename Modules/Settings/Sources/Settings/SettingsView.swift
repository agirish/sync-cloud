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
    /// Never rename a case: a label can change (`providers` shows as "Sources"), but the raw value
    /// is what a stored `settingsSelectedTab` holds. A tab split out of another gets a new case,
    /// so the old one keeps meaning what the user last looked at.
    ///
    /// The stored value is resolved through `resolvingStored(_:)`, which falls back to Appearance
    /// rather than trapping on a value this build doesn't know (`StoredTabResolutionTests`).
    public enum SettingsTab: String, CaseIterable, Sendable {
        case general
        case appearance
        /// Text size and row spacing — how large the type is and how tightly the rows pack. Its
        /// own tab because its controls and preview come to ~875pt, and Appearance's opening on a
        /// 1280×800 display is 647pt. See `ReadabilitySettingsTab`.
        case readability
        case providers
        /// The people the filing rules attribute documents to.
        case people
        case sync
        /// Shown as "Organize". Named for `Workspace.filing`, not the label, so the tab is one
        /// grep away from the code it governs.
        case filing
        case duplicates
        /// The suggestion engine — on-device AI, the opt-in Claude path, and what that path costs.
        case intelligence
        case advanced

        /// The human-readable tab name shown in the rail and as the dim subtitle on a search
        /// result. Kept here so the labels have a single source of truth.
        public var displayName: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            // "Readability", not "Text size": row spacing is half the tab and isn't type. Not
            // "Display" either, which in a Mac app promises monitors and resolution.
            case .readability: return "Readability"
            // "Sources", not "Providers": the tab lists plain folders beside the cloud accounts,
            // and a folder is not a provider. The case keeps its name for the stored raw value.
            case .providers: return "Sources"
            case .people: return "People"
            case .sync: return "Sync"
            case .filing: return "Organize"
            case .duplicates: return "Duplicates"
            // Not "Claude": the tab holds the free on-device pass too. Not "AI & Cloud": "Cloud"
            // collides with Sources' cloud providers. `SettingsSearchIndex` carries "API key" and
            // "Anthropic" here.
            case .intelligence: return "Intelligence"
            case .advanced: return "Advanced"
            }
        }

        /// The rail row's SF Symbol. Outline weight throughout: mixed filled and outline glyphs
        /// read as though the filled ones meant something. Organize and Duplicates use their
        /// workspaces' glyphs (`Workspace.symbol`), since the row and the bar button reach the
        /// same feature.
        public var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            // The system's own text-size glyph, the one macOS puts on this exact control.
            case .readability: return "textformat.size"
            case .providers: return "cloud"
            case .people: return "person.2"
            case .sync: return "arrow.left.arrow.right"
            case .filing: return "folder.badge.gearshape"
            case .duplicates: return "doc.on.doc"
            case .intelligence: return "sparkles"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        /// Where the "set up cloud refine" offer on Organize's results deep-links to: the tab that
        /// holds the Claude toggle, the key and the model.
        ///
        /// Named here, not written at the call site, because that site is in `MacApp/`, which no
        /// package test can reach. A wrong tab there would still compile and open Settings; this
        /// constant lets `theCloudRefineOfferLandsOnTheTabThatHoldsTheKey` check it.
        public static let cloudRefineSetup: SettingsTab = .intelligence

        /// The tabs the layout fit-guard (`SettingsLayoutTests`) does not hold to fitting the
        /// sheet's opening without scrolling. `everyTabIsEitherFitTestedOrExplicitlyExempt`
        /// measures `allCases` minus this set, so a new case either fits or earns a line here:
        /// - `providers` grows with the Mac's provider and folder-source lists.
        /// - `people` grows with the roster (`PeopleList` draws one row per person).
        /// - `filing` grows with the kept-names list (`KeptNamesList`, one row per name), passing
        ///   a 1280×800 display's opening at about the 17th name.
        /// - `intelligence` is long by nature and expected to scroll.
        ///
        /// **A fit-guard fixture built with a nil dependency measures only the empty state**, so a
        /// tab with an unbounded list belongs here however well its `else` branch fits. Tests hold
        /// two exemptions to their claim: `intelligenceLaysOutWithoutReachingForTheKeychain` and
        /// `theOrganizeTabOutgrowsItsOpeningOnceNamesAreKept`. Organize's empty state is still
        /// fit-tested, by `theOrganizeTabFitsItsOpeningWithNothingKept`. `providers` and `people`
        /// have no such test yet. Revisit an exemption when a tab's shape changes.
        public static let exemptFromFitGuard: Set<SettingsTab> = [.providers, .people, .filing, .intelligence]

        /// The rail's rows in groups, separated by a hairline.
        ///
        /// Flat rows read as a pile, but the rail is fixed-height and doesn't scroll, so each
        /// separator costs space; `theRailFitsItsOpening` measures the rail with them. Groups are by
        /// question asked: the app itself, the user's world, what a scan does, the engine room.
        /// Spelled out, not derived, so a new case must name its group (`railGroupsCoverEveryTab`).
        public static let railGroups: [[SettingsTab]] = [
            // Readability sits next to Appearance: how it looks, then how it reads.
            [.general, .appearance, .readability],
            [.providers, .people],
            [.sync, .filing, .duplicates],
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
        availableSize: CGSize? = nil,
        oneWaySync: AnyView? = nil
    ) {
        _selectedTab = selection
        self.onClose = onClose
        self.syncManager = syncManager
        self.onResetAllSettings = onResetAllSettings
        self.onRunSetup = onRunSetup
        self.onResetSetup = onResetSetup
        self.onShowPerson = onShowPerson
        self.onOpenHelp = onOpenHelp
        self.availableSize = availableSize
        self.oneWaySync = oneWaySync
    }

    /// Sync ▸ One-Way Sync, supplied by the app because its state lives above Settings.
    private let oneWaySync: AnyView?

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

    /// The right-hand column: the selected tab, or the search results standing in for it.
    @ViewBuilder
    private var content: some View {
        if isSearching {
            SettingsSearchResults(results: searchResults) { tab in
                // The jump: land on the matching tab and drop back to normal content.
                selectedTab = tab
                searchQuery = ""
            }
        } else {
            switch selectedTab {
            case .general:
                GeneralSettingsTab(onRunSetup: onRunSetup)
            case .appearance:
                AppearanceSettingsTab()
            case .readability:
                ReadabilitySettingsTab()
            case .providers:
                ProvidersSettingsTab()
            case .people:
                PeopleSettingsTab(syncManager: syncManager, onShowPerson: onShowPerson)
            case .sync:
                SyncSettingsTab(syncManager: syncManager, oneWaySync: oneWaySync)
            case .filing:
                FilingSettingsTab(syncManager: syncManager,
                                  surveySources: settings.enabledProviders.filter { !$0.isLocalFolder }
                                      .map { ($0.displayName, settings.landingPath(for: $0.id)) })
            case .duplicates:
                DuplicatesSettingsTab()
            case .intelligence:
                IntelligenceSettingsTab(syncManager: syncManager, onOpenHelp: onOpenHelp)
            case .advanced:
                AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings,
                                    onResetSetup: onResetSetup, resetAllRaises: { [settings, syncManager] in
                    SettingsActions(settings: settings, sync: syncManager,
                                    lookup: SettingsLookup(defaults: .standard, settings: settings, keyIsSaved: { false },
                                                           hiddenCount: { 0 }, isHidden: { _ in false },
                                                           loginItemIsOn: { false })).resetAllRaises()
                })
            }
        }
    }
}

// MARK: - Settings search

public extension SettingsView.SettingsTab {
    /// The tab that holds a setting or section named in words (“Ask Claude”, “monthly limit”,
    /// “API key”), by the same index Settings' own search reads: an exact title first, then a title
    /// containing it, then a keyword. Nil when nothing matches.
    static func holding(_ words: String) -> SettingsView.SettingsTab? {
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
                ?? entries.first { $0.matches(needle) })?.tab
    }
}

/// One searchable settings control: the tab it lives on, its display title, and a few
/// synonyms/keywords so a search for "blur" finds "Glass effect" and "trash" finds the
/// delete confirmation. Pure data with a pure match — no SwiftUI — so the filter is unit-testable.
struct SettingsSearchEntry: Identifiable, Sendable {
    let tab: SettingsView.SettingsTab
    let title: String
    let keywords: [String]

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
/// something, across every tab. One kind of on-screen label deliberately gets no entry of its own,
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
        .init(tab: .general, title: "Launch SyncCloud at login",
              keywords: ["launch", "login", "startup", "start", "open at login", "boot", "auto start"]),
        .init(tab: .general, title: "Show hidden files by default",
              keywords: ["hidden", "dotfiles", "invisible", "show hidden"]),
        .init(tab: .general, title: "Reopen panes where I left off",
              keywords: ["restore", "reopen", "last focus", "remember folders", "panes", "resume"]),
        .init(tab: .general, title: "Sort panes by",
              keywords: ["sort", "order", "sorting", "name", "size", "date", "default sort"]),
        .init(tab: .general, title: "Notify when operations finish in the background",
              keywords: ["notification", "notify", "background", "alert", "banner", "system notification"]),
        .init(tab: .general, title: "Warn before quitting during file operations",
              keywords: ["quit", "warn", "confirm quit", "close", "exit"]),

        // Appearance
        // "theme" lives here, not on Accent color: to users it means light/dark.
        .init(tab: .appearance, title: "Theme",
              keywords: ["theme", "light", "dark", "dark mode", "light mode", "appearance",
                         "system", "night", "follow macos"]),
        .init(tab: .appearance, title: "Accent color",
              keywords: ["accent", "color", "colour", "hue", "highlight"]),
        .init(tab: .appearance, title: "Glass effect",
              keywords: ["glass", "translucency", "transparency", "frosted", "clear", "solid",
                         "blur", "liquid glass", "material", "opaque", "see-through"]),
        .init(tab: .appearance, title: "Surface tint",
              keywords: ["tint", "wash", "color overlay", "vivid", "subtle"]),
        // "solid" belongs to Glass effect, not here: this control is shape only.
        .init(tab: .appearance, title: "Content surface style",
              keywords: ["surface", "unified", "cards", "pane background", "content surface"]),
        // Three entries for one section: the heading a search for "spacing" should land on, and
        // the two controls inside it, which people look for by name. "list density" stays a
        // keyword of Row spacing because users learned the control by that name.
        .init(tab: .readability, title: "Size & spacing",
              keywords: ["size", "spacing", "size and spacing", "preset", "presets", "scale",
                         "zoom", "how much fits", "bigger", "smaller", "readability", "legibility",
                         // Anyone who knows these controls as part of Appearance types that.
                         "appearance"]),
        .init(tab: .readability, title: "Text size",
              keywords: ["text size", "font", "font size", "type size", "bigger text", "larger text",
                         "smaller text", "readability", "zoom", "scale", "percent", "percentage"]),
        .init(tab: .readability, title: "Row spacing",
              keywords: ["density", "list density", "compact", "comfortable", "row height",
                         "spacing", "row spacing", "tighter rows", "row size"]),
        .init(tab: .readability, title: "Column widths",
              keywords: ["column width", "column widths", "columns", "resize columns", "width",
                         "each column", "all columns", "divider", "wider", "narrower", "fit"]),

        // Sources
        .init(tab: .providers, title: "Cloud providers",
              keywords: ["providers", "cloud", "discover", "refresh", "cloudstorage", "sources",
                         "icloud", "dropbox", "onedrive", "google drive"]),
        .init(tab: .providers, title: "Local folders",
              keywords: ["folder", "local", "add folder", "choose folder", "mac", "home folder",
                         "volume", "disk", "external drive", "source", "remove folder"]),
        .init(tab: .providers, title: "Check folder names against",
              keywords: ["names", "risky names", "rename", "name rules", "onedrive rules",
                         "reserved", "check names", "folder names"]),
        .init(tab: .providers, title: "Source name",
              keywords: ["rename", "name", "provider name", "custom name", "label"]),
        .init(tab: .providers, title: "Synchronized path",
              keywords: ["path", "location", "root", "folder", "directory", "sync path", "browse"]),
        // Display name and Open at are the two per-location rows the setup sheet also offers,
        // under More options on its Locations screen; indexed under their own row labels.
        .init(tab: .general, title: "Run Setup Again",
              keywords: ["setup", "guided setup", "first run", "onboarding", "welcome",
                         "run setup", "set up syncCloud"]),
        .init(tab: .advanced, title: "Reset Setup",
              keywords: ["reset setup", "setup", "first run", "onboarding", "forget setup",
                         "run setup again", "start over"]),
        .init(tab: .providers, title: "Display name",
              keywords: ["rename", "display name", "name", "provider name", "custom name",
                         "label", "setup"]),
        .init(tab: .providers, title: "Open at",
              keywords: ["open at", "landing", "starting folder", "opens at", "default folder",
                         "where panes open", "setup"]),
        .init(tab: .providers, title: "Enable or disable a source",
              keywords: ["enable", "disable", "show", "hide", "toggle provider",
                         "toggle source"]),

        // People. Indexed by what it's about as much as by its label: people type a relationship
        // or the problem ("wrong person"). "organize" and "filing" stay for anyone who knows the
        // roster as part of Organize.
        .init(tab: .people, title: "People",
              keywords: ["people", "person", "family", "household", "names", "full name",
                         "wife", "husband", "son", "daughter", "mother", "father", "kids",
                         "wrong person", "whose document", "who", "aliases", "privacy",
                         "what is stored", "data", "organize", "filing"]),
        // The Add button is its own entry: "add person" is what someone types when the roster is
        // missing somebody, and the section title doesn't contain it.
        .init(tab: .people, title: "Add Person…",
              keywords: ["add person", "new person", "add family member", "add someone",
                         "remove person", "delete person", "edit person", "rename person",
                         "relationship", "brother", "sister", "roster",
                         // The row's other buttons, by the words someone reaches for.
                         "look for names", "find names", "suggest names", "name suggestions",
                         "reorder", "move up", "move down", "order", "show files", "their files"]),
        // The tester, indexed by what someone wants from it: who a document would be filed for.
        .init(tab: .people, title: "Try a filename",
              keywords: ["try a filename", "test a filename", "test", "who does this belong to",
                         "which person", "match", "attribute", "explain"]),

        // Sync
        .init(tab: .sync, title: "One-Way Sync",
              keywords: ["one-way", "one way", "mirror", "sync now", "icloud to dropbox", "dropbox", "pause", "synccloud removed",
                         "stopped syncing", "first run", "turn off"]),
        .init(tab: .sync, title: "When a file already exists",
              keywords: ["conflict", "conflict policy", "overwrite", "replace", "keep both", "duplicate handling"]),
        .init(tab: .sync, title: "Treat dates as equal within",
              keywords: ["date tolerance", "date", "timestamp", "tolerance", "modified date", "rounding"]),
        .init(tab: .sync, title: "Verify same-size files during scans",
              keywords: ["verify", "checksum", "same size", "scan verification", "hash"]),
        .init(tab: .sync, title: "Rescan when files change",
              keywords: ["rescan", "auto rescan", "watch", "folder watching", "file changes", "changed on disk",
                         "refresh automatically", "live", "fsevents"]),
        .init(tab: .sync, title: "Ignore “newer on Google Drive” when same size",
              keywords: ["google drive", "newer", "ignore date", "gdrive"]),
        .init(tab: .sync, title: "Confirm before copying or moving",
              keywords: ["confirm copy", "confirm move", "transfer confirmation", "what goes where", "confirm before copy"]),
        .init(tab: .sync, title: "Confirm before deleting",
              keywords: ["confirm delete", "delete confirmation", "trash", "remove"]),
        .init(tab: .sync, title: "Remember ignored items across rescans",
              keywords: ["ignored items", "remember ignores", "hidden differences", "ignore"]),
        .init(tab: .sync, title: "Ignored name patterns",
              keywords: ["ignore patterns", "glob", "exclude", "wildcard", "ds_store", "node_modules", "patterns"]),

        // Organize: the settings that describe the job rather than the machinery. "tidy" and
        // "filing" are old names for this feature that users still type.
        //
        // "loose files" is needed because the title hyphenates it, and "todo" is the default value,
        // not in the label.
        .init(tab: .filing, title: "Loose-files inbox",
              keywords: ["inbox", "loose files", "todo", "default folder", "scan folder",
                         "organize", "tidy", "filing"]),
        .init(tab: .filing, title: "Remembered rules",
              keywords: ["filing rules", "rules", "remembered rules", "manage rules", "automation", "automations"]),
        .init(tab: .filing, title: "Folder surveys",
              keywords: ["survey", "folder survey", "learn folders", "learn its folders", "profile",
                         "google drive", "dropbox", "onedrive", "icloud", "layout", "forget survey"]),
        // Most queries miss the label: the menu items say "Always Allow This Name" and "Stop
        // Allowing This Name", so "allow" is the word users have read, and they describe the
        // problem ("risky name", "trailing space", "badge") more than the state.
        .init(tab: .filing, title: "Kept names",
              keywords: ["kept name", "keep name", "allow name", "always allow", "stop allowing",
                         "allowed names", "risky name", "risky names", "badge", "name badge",
                         "trailing space", "forbidden character", "rename", "exceptions"]),

        // Duplicates
        .init(tab: .duplicates, title: "Ignore files smaller than",
              keywords: ["minimum size", "min file size", "small files", "duplicates", "threshold size", "tidy"]),
        .init(tab: .duplicates, title: "Folders overlap at",
              keywords: ["overlap", "threshold", "folder overlap", "percent", "duplicates"]),
        .init(tab: .duplicates, title: "Detect versions",
              keywords: ["versions", "final", "copy", "report (1)", "variants", "duplicates"]),
        // Nobody types this label; they type what they noticed: the same bill downloaded twice,
        // or a slow first scan.
        .init(tab: .duplicates, title: "Read PDFs to find copies a byte hash misses",
              keywords: ["pdf", "text", "same text", "content", "fingerprint", "re-downloaded",
                         "downloaded twice", "re-stamped", "slow scan", "duplicates"]),

        // Intelligence: the engine and its cost, in tab order. Keywords matter most here, since
        // nobody looking for where their API key goes types "Intelligence". "organize" and
        // "filing" stay for the People block's reason.
        .init(tab: .intelligence, title: "Suggest folders with on-device AI",
              keywords: ["filing", "apple intelligence", "on-device ai", "suggestions", "suggest folders",
                         "sort files", "organize", "tidy", "intelligence"]),
        .init(tab: .intelligence, title: "Read file contents on-device for better signals",
              keywords: ["read contents", "content signals", "ocr", "text", "pdf", "vision"]),
        // "refine" is the word on the button this row enables; "best suggestions" is an older
        // name for the row.
        .init(tab: .intelligence, title: "Use Claude (cloud) to refine suggestions",
              keywords: ["claude", "cloud", "anthropic", "cloud filing", "ai", "refine",
                         "best suggestions", "organize"]),
        // "claude" belongs on the key too, not only the toggle: someone pasting an `sk-ant-…`
        // types whichever name they last read, often "claude api key".
        .init(tab: .intelligence, title: "Claude API key",
              keywords: ["api key", "key", "keychain", "sk-ant", "anthropic key", "anthropic api key", "token",
                         "api", "credentials", "secret", "claude", "claude key"]),
        // Ask Claude: the chat panel's own model and limit, separate from Filing's.
        .init(tab: .intelligence, title: "Ask Claude",
              keywords: ["chat", "assistant", "ask", "claude chat", "panel", "⌘J", "copilot", "help me"]),
        .init(tab: .intelligence, title: "Answers",
              keywords: ["brief", "detailed", "verbose", "answer length", "concise", "ask claude answers"]),
        .init(tab: .intelligence, title: "Let Claude read files",
              keywords: ["read files", "file contents", "passage", "privacy", "send text", "ask claude reading"]),
        .init(tab: .intelligence, title: "Hidden from Claude",
              keywords: ["never show claude", "hide folder", "privacy", "exclude", "private folders"]),
        .init(tab: .intelligence, title: "Shared without asking",
              keywords: ["share without asking", "trusted folders", "don’t ask", "privacy", "ask each time"]),
        .init(tab: .intelligence, title: "Monthly limit",
              keywords: ["ask claude limit", "chat limit", "spend limit", "budget", "cap", "money"]),
        .init(tab: .intelligence, title: "This month",
              keywords: ["ask claude spend", "chat cost", "spent", "usage", "cost"]),
        .init(tab: .intelligence, title: "Cloud model",
              keywords: ["model", "haiku", "sonnet", "opus", "claude model"]),
        // "cloud spend" stays a keyword because the history sheet says it.
        .init(tab: .intelligence, title: "Cost and limits",
              keywords: ["spend", "cloud spend", "cost", "tokens", "billing", "usage", "money", "price"]),
        .init(tab: .intelligence, title: "Monthly budget cap",
              keywords: ["budget", "cap", "limit", "monthly", "spend limit", "cost cap", "guardrail", "pause cloud", "money"]),
        .init(tab: .intelligence, title: "Total budget cap",
              keywords: ["budget", "cap", "limit", "total", "lifetime", "spend limit", "cost cap", "guardrail", "pause cloud", "money", "backstop"]),
        // "cache" is the word the UI never says but an engineer types, so it lives here.
        .init(tab: .intelligence, title: "Reuse suggestions for files that haven’t changed",
              keywords: ["reuse", "cache", "cached suggestions", "rescan", "re-ask", "cost", "save money"]),
        .init(tab: .intelligence, title: "Saved suggestions",
              keywords: ["saved suggestions", "clear cache", "cache", "forget suggestions", "reset suggestions"]),

        // Advanced
        .init(tab: .advanced, title: "Log level",
              keywords: ["log", "logging", "debug", "verbosity", "log level", "info", "warnings", "errors"]),
        .init(tab: .advanced, title: "Log file",
              keywords: ["log file", "logs", "clear log", "show log"]),
        .init(tab: .advanced, title: "Sweep orphaned temporary files",
              keywords: ["orphan", "temp files", "tmp", "sweep", "maintenance", "cleanup", "clean up"]),
        .init(tab: .advanced, title: "File digests",
              keywords: ["digests", "checksums", "hashes", "content hash", "cache", "disk space",
                         "storage", "saved scan data", "duplicates", "verify"]),
        .init(tab: .advanced, title: "Saved Storage reports",
              keywords: ["storage lens", "saved reports", "snapshots", "cache", "disk space",
                         "saved scan data"]),
        .init(tab: .advanced, title: "Reset all settings",
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
/// list of matching settings, each showing its title and — dimmed — the tab it lives on. A tap
/// hands the tab back to `SettingsView` for the jump. An empty result set shows a gentle miss.
private struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let onSelect: (SettingsView.SettingsTab) -> Void

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
                            onSelect(entry.tab)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .foregroundStyle(.primary)
                                    Text(entry.tab.displayName)
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

/// App-level preferences: login item, startup state (hidden files, last folders, sort),
/// background notifications, and the quit safety guard.
struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    /// Opens the guided setup sheet. Defaulted: this tab is memberwise-only and is built bare in
    /// `SettingsLayoutTests.mustFitTabs`.
    var onRunSetup: (() -> Void)? = nil
    @AppStorage(GeneralSettings.showHiddenByDefaultKey) private var showHiddenByDefault: Bool = false
    @AppStorage(GeneralSettings.warnBeforeQuitKey) private var warnBeforeQuit: Bool = true
    @AppStorage(GeneralSettings.restoreLastFocusKey) private var restoreLastFocus: Bool = true

    var body: some View {
        SettingsPage {
            LaunchAtLoginRow()

            SettingsSection(
                "Startup",
                caption: "Panes reopen at the folders they showed when you last quit (falling back to the root if a folder is gone). Sort changes made from the pane menus are remembered here too."
            ) {
                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
                    .help("Starts each launch with hidden files shown in both panes. Showing or hiding them while you work lasts until you quit.")
                Toggle("Reopen panes where I left off", isOn: $restoreLastFocus)
                    .help("Reopens each pane with the tabs and folders it had when you last quit. Off, every pane starts with one tab at its source’s opening folder.")
                if let onRunSetup {
                    SettingsRow("Setup") {
                        Button("Run Setup Again…", action: onRunSetup)
                            .controlSize(.small)
                    }
                    .help("Reopens the guided setup sheet with your current answers filled in. Nothing is reset.")
                }
                SettingsRow("Sort panes by") {
                    Picker("Sort panes by", selection: $settings.defaultSortOption) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Sorts the files in both panes. Changing the sort from a pane’s menu changes this too.")
                }
            }

            NotifyInBackgroundRow()

            SettingsSection(caption: "Shows a confirmation if you try to quit while a copy, move, or delete is still running.") {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
                    .help("Asks before quitting while a copy, move, or delete is still running. Off, SyncCloud quits at once.")
            }
        }
    }

}

// MARK: - Appearance

/// Theme, accent hue, glass material and surface shape, all shared with MacApp through
/// UserDefaults.
///
/// Theme (light/dark), Glass effect (material) and Content surface (shape) are separate controls:
/// any combination is valid, and none overrides another.
///
/// Theme leads because the others decide how a surface reads within an appearance. Unlike them it
/// renders nothing here: `ContentView` pushes it to NSApp.
struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    /// The resolved theme; `.system` (follow macOS) if unrecognized.
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
    }

    private var selectedSurfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Theme", caption: appearanceMode.detail) {
                Picker("Theme", selection: $appearanceModeRaw) {
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
                               onSelect: { selectedHueRaw = $0.rawValue })

            SettingsSection("Glass effect", caption: glassLevel.detail) {
                Picker("Glass effect", selection: $glassLevelRaw) {
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
                    : "How strongly the accent color colors the window. Subtle keeps a faint tint rather than removing it — for none at all, choose the None accent above."
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

            SettingsSection("Content surface", caption: selectedSurfaceStyle.detail) {
                Picker("Content surface", selection: $surfaceStyleRaw) {
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
/// the row of these, and the snapshot tests render it.
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

// MARK: - Readability

/// Text size and row spacing, with a preset row over them and a live preview under them.
///
/// Both controls answer one question, how much you want on screen, so they sit together. With the
/// presets, detent labels and preview the group comes to ~875pt, more than Appearance's 647pt
/// opening on a 1280×800 display, hence its own tab. `readabilityFitsItsOpeningWithoutScrolling`
/// holds it to the same fit bar as the others.
///
/// Nothing here is stored by this view: `FontSize.defaultsKey` and `ListDensity.defaultsKey` stay
/// the two sources of truth, and the preset row reads them to decide which tile is lit.
struct ReadabilitySettingsTab: View {
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent: Int = FontSize.medium.percent
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
    init(confirmReleasingColumnWidths: @escaping @MainActor (Int) -> Bool = {
        RemovalPrompt.releaseColumnWidths(count: $0).ask()
    }) {
        self.confirmReleasingColumnWidths = confirmReleasingColumnWidths
    }

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
                columnResizeModeRaw = choice.mode
                if choice.overrides != overrides { columnWidthOverrides = choice.overrides }
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

    /// The resolved text size. `FontSize.init(percent:)` clamps, so an out-of-range stored value
    /// is honoured rather than discarded.
    private var fontSize: FontSize { FontSize(percent: fontSizePercent) }

    /// The resolved row spacing; `.comfortable` (the standard rows) if unrecognized.
    private var listDensity: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue }

    private var sizeBinding: Binding<FontSize> {
        Binding(get: { fontSize }, set: { fontSizePercent = $0.percent })
    }

    private var densityBinding: Binding<ListDensity> {
        Binding(get: { listDensity }, set: { listDensityRaw = $0.rawValue })
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
            SettingsSection("Size & spacing") {
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
                            )
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

                Text(fontSize.detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // "Row spacing", not "List density": spacing is what the person changes, and it
                // pairs with "Text size" above. The stored key is still `listDensity`.
                LabeledContent("Row spacing") {
                    Picker("Row spacing", selection: $listDensityRaw) {
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

                Text(listDensity.detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SizeSpacingPreview(fontSize: fontSize, density: listDensity)
                    .padding(.top, 4)

                // Here because it's about how the columns read. The segments are short because at
                // the sheet's floor the content is about 340pt wide; the caption carries the rest,
                // including ⌥ and the double-click, which nothing else shows.
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
                    .help("What dragging a divider in Columns resizes: Each column resizes that column, All columns resizes every column. Hold ⌥ for the other. All columns asks first when a column was sized on its own.")
                }
                .padding(.top, 10)

                Text("Dragging a divider in Columns resizes that column, or every column at once; hold ⌥ to do the other. Double-clicking a divider fits to the longest name the same way. All columns also puts every column back to one width.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } caption: {
                // The prose lives inline under what it explains, so the caption slot is empty.
                EmptyView()
            }
        }
    }
}

// MARK: - Sources

/// The sources panes can be pointed at: the cloud accounts discovered on this Mac, and the plain
/// folders the user added. Two sub-sections, because one is found and the other chosen: a cloud
/// account can be refreshed but never removed, a folder removed but never discovered.
struct ProvidersSettingsTab: View {
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
            SettingsSection(
                caption: "Cloud accounts are discovered from ~/Library/CloudStorage. Disabled sources stay configured but are not offered anywhere a source is picked. At least one source must remain enabled."
            ) {
                HStack {
                    Text("Cloud providers")
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
                    .help("Reads ~/Library/CloudStorage again, picking up cloud accounts added or removed since it last looked.")
                }
            }

            // This tab legitimately scrolls: it grows with every provider the Mac has. Collapsed
            // rows keep the growth to one row per source rather than four fields each.
            ForEach(cloudProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
            }

            Divider()

            SettingsSection(
                caption: "Any folder on this Mac can be a source — Compare and Organize work the same over it. Folders you add appear in every workspace. Removing one leaves the folder itself untouched."
            ) {
                HStack {
                    Text("Local folders")
                        .scaledFont(.body.weight(.medium))
                    Spacer()
                    Button(action: addFolder) {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                if folderProviders.isEmpty {
                    Text("No folders added.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsRow("Check folder names against") {
                    Picker("Check folder names against", selection: $settings.folderNameRule) {
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

            ForEach(folderProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
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
    // A value type, not a bare String: Reset, focus-blur commit and the discovery refresh all move
    // it, and a wrong Reset would leave the field blank. See `ProviderPathDraft`.
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
/// discovery change, and repopulating after "Reset" — is decided in one testable place instead of
/// inline in three SwiftUI closures.
///
/// **Never blank the draft and wait for `onChange(of: provider.rootPath)` to refill it.** That
/// fires only when the path changes, and resetting a source with no override changes nothing, so
/// the field would sit empty and the next blur would commit the empty string.
struct ProviderPathDraft: Equatable {
    /// The text currently in the field. A plain `var` because the `TextField` binds straight to it.
    var value: String = ""

    /// What "Reset" put in the field, held until the rediscovery it started lands, or nil. Stored
    /// as the text, not a bool: typing is invisible to this type, so comparing is the only way to
    /// tell "still what Reset left" from "typed over since". See `reset(toEffective:)`.
    private var textAwaitingReset: String?

    /// The row appeared: start on the provider's effective (default or overridden) path.
    mutating func adopt(_ path: String) {
        value = path
        textAwaitingReset = nil
    }

    /// An external change to the published path landed (a discovery/refresh pass). Adopt it only
    /// when the user isn't actively editing this field — otherwise a concurrent
    /// `discoverProviders()` would silently discard their uncommitted draft.
    ///
    /// The exception is the rediscovery the user's own "Reset" started. Clicking a macOS button
    /// doesn't blur the field, so it arrives with `isEditing: true`; declining it would let the
    /// next blur re-commit the cleared override (see `reset(toEffective:)`). It applies only while
    /// the field still shows exactly what Reset left, so a user typing a new path keeps it.
    mutating func adoptExternalChange(to updated: String, isEditing: Bool) {
        let isResetLanding = textAwaitingReset == value
        guard !isEditing || isResetLanding else { return }
        textAwaitingReset = nil
        guard value != updated else { return }
        value = updated
    }

    /// "Reset" was pressed. Echo the provider's effective path rather than blanking the field:
    /// with no override it already is the default and no refresh is coming; with one,
    /// `adoptExternalChange` replaces it when the async rediscovery lands.
    ///
    /// Remembering the echoed text is what makes Reset stick. `SettingsManager.resetPath`
    /// rediscovers asynchronously, so the echo is still the old override; if the correction were
    /// declined as mid-edit, the next blur would commit the override straight back.
    mutating func reset(toEffective path: String) {
        value = path
        textAwaitingReset = path
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

    static func budgetLabel(_ usd: Double) -> String {
        usd > 0 ? "$\(trimmed(usd))" : "Off (no limit)"
    }

    // MARK: - The five numeric pickers

    static func dateTolerance(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 1, 2, 5, 60], dateToleranceLabel), label: dateToleranceLabel)
    }

    static func minFileSize(including stored: Int) -> [SettingsPickerOption<Int>] {
        including(stored: stored, in: rows([0, 4096, 102_400, 1_048_576], fileSizeLabel), label: fileSizeLabel)
    }

    static func overlapThreshold(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0.5, 0.6, 0.7, 0.8, 0.9], percentLabel), label: percentLabel)
    }

    static func monthlyBudget(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 1, 5, 10, 25, 50], budgetLabel), label: budgetLabel)
    }

    static func totalBudget(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 5, 10, 25, 50, 100], budgetLabel), label: budgetLabel)
    }

    private static func rows<Value: Hashable>(
        _ values: [Value], _ label: (Value) -> String
    ) -> [SettingsPickerOption<Value>] {
        values.map { SettingsPickerOption(value: $0, label: label($0)) }
    }
}

// MARK: - Sync

/// Behavior of difference scanning and comparison: date tolerance, checksum verification,
/// the delete confirmation, and the two ignore mechanisms (remembered items and name patterns).
struct SyncSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    let syncManager: FileSyncManager?
    var oneWaySync: AnyView?
    @AppStorage(GeneralSettings.confirmBeforeDeleteKey) private var confirmBeforeDelete: Bool = true
    @AppStorage(GeneralSettings.confirmBeforeTransferKey) private var confirmBeforeTransfer: Bool = true
    @State private var patternDraft = ""

    var body: some View {
        SettingsPage {
            if let oneWaySync {
                SettingsSection(
                    "One-Way Sync",
                    caption: "iCloud to Dropbox, one way: change files in iCloud and Sync Now copies the change. Whatever SyncCloud removes or replaces in Dropbox goes to Dropbox ▸ SyncCloud Removed."
                ) {
                    oneWaySync
                }
            }
            SettingsSection(
                "Conflicts",
                caption: "Applies to copies, moves, and syncs. Keep both renames the incoming file; Replace moves the existing file to the Trash first. Folder conflicts always ask."
            ) {
                SettingsRow("When a file already exists") {
                    Picker("When a file already exists", selection: $settings.conflictPolicy) {
                        ForEach(ConflictPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("What a copy, move, or sync does when a file of the same name is already there: ask, keep both, replace it (the old one goes to the Trash), or skip it. Folder conflicts always ask.")
                }
            }

            SettingsSection(
                "Comparison",
                caption: "Cloud providers round file dates on upload; a small tolerance hides those false differences. Verification checksums same-size pairs that only differ by date and hides identical ones — thorough, but slower on large folders."
            ) {
                // Rows come from `SettingsPickerOptions`, which adds the stored value when it isn't
                // offered, so an off-list tolerance shows rather than leaving the picker blank.
                SettingsRow("Treat dates as equal within") {
                    Picker("Treat dates as equal within", selection: $settings.dateToleranceSeconds) {
                        ForEach(SettingsPickerOptions.dateTolerance(including: settings.dateToleranceSeconds)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Counts two modification dates as the same when they are this close, so a provider rounding dates on upload doesn’t show up as a difference.")
                }
                Toggle(isOn: $settings.autoVerifySameSizeDuringScan) {
                    Text("Verify same-size files during scans")
                }
                .help("During each scan, checksums same-size files that differ only by date and hides the ones that are identical. Files over 100 MB are left for Verify All. Slower on large folders.")
                Toggle(isOn: $settings.rescanWhenFilesChange) {
                    Text("Rescan when files change")
                }
                .help("Rescans a pane by itself when something in its folder changes, so rows can move while you look at them. Off, the scan age says “changed since” and the list waits for Refresh.")
                Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                    Text("Ignore “newer on Google Drive” when same size")
                }
                .help("When Google Drive is in the right pane, hides differences where only its copy is newer and the sizes match — Drive often rewrites file dates.")
            }

            SettingsSection(
                "Confirmations",
                caption: "Copies and moves first show what will be transferred and where; turning this off starts them immediately, including moves, with no confirmation. Deleted items go to the Trash either way and can be restored with Undo."
            ) {
                Toggle("Confirm before copying or moving", isOn: $confirmBeforeTransfer)
                    .help("Shows what will be copied or moved, and where, before it starts. Off, copies and moves start at once.")
                Toggle("Confirm before deleting", isOn: $confirmBeforeDelete)
                    .help("Asks before moving items to the Trash. They go to the Trash either way, and Undo brings them back.")
            }

            SettingsSection(
                "Ignored items",
                caption: "Items you ignore from the Differences list are kept here per provider pair. Remove one to see its differences again."
            ) {
                Toggle(isOn: $settings.rememberIgnoredItems) {
                    Text("Remember ignored items across rescans")
                }
                .help("Keeps an item you ignore hidden through rescans, folder changes, and relaunches. Off, an ignore lasts only until you move to another folder.")
                if let syncManager, let store = syncManager.ignoredItemsStore {
                    IgnoredItemsList(
                        store: store,
                        onRemove: { syncManager.unignoreRootRelative($0) },
                        onClear: { syncManager.clearAllIgnoredItems() }
                    )
                }
            }

            SettingsSection(
                "Ignored name patterns",
                caption: "Hides any item whose name matches a pattern, at any depth, in every comparison. * matches any run of characters and ? matches one."
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
                        .help("A name pattern to hide from every comparison — * matches any run of characters, ? matches one. Press Return or click Add.")
                    Button("Add", action: addPattern)
                        .disabled(IgnoreRules.normalized(patternDraft) == nil)
                }
            }
        }
    }

    private func addPattern() {
        if settings.addIgnorePattern(patternDraft) {
            patternDraft = ""
        }
    }
}

/// The remembered-ignores rows inside the Sync tab: a monospaced root-relative path per
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
            Text("Nothing ignored right now. Right-click a difference and choose Ignore to hide it.")
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

/// How a duplicate scan decides what counts as a match. A thin tab, but it's where anyone hunting
/// for the overlap threshold looks first. Settings go where the work is, not one tab per
/// workspace: Storage and Compare have no preferences, so no tab.
struct DuplicatesSettingsTab: View {
    // The defaults keys keep their `tidy` prefixes ("tidyMinFileSize" and friends, owned by
    // `DuplicateFinderOptions.DefaultsKey`) because they are a persistence format. To trace a
    // stored value, follow the `DefaultsKey` constant, not the property name.
    @AppStorage(DuplicateFinderOptions.DefaultsKey.minFileSize) private var duplicateMinFileSize: Int = 4096
    @AppStorage(DuplicateFinderOptions.DefaultsKey.overlapThreshold) private var duplicateOverlapThreshold: Double = 0.7
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectVersions) private var duplicateDetectVersions: Bool = true
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectSameText) private var duplicateDetectSameText: Bool = true

    var body: some View {
        SettingsPage {
            // Titleless: the rail row already says "Duplicates", and a lone header repeating it
            // would read as a subdivision of a tab that has none.
            SettingsSection(
                caption: "How Find Duplicates groups results. Identical detection is always checksum-verified; the overlap threshold decides when same-named folders read as overlapping vs unrelated. Reading PDFs finds a further kind — the same document downloaded twice, which providers re-stamp so its bytes differ — and is the one setting here that costs time rather than shaping results: it extracts text (never OCR, and a scan with no text layer is simply skipped), so the first pass over a large tree takes a few extra minutes and later scans reuse what it read. Changes apply on the next scan."
            ) {
                // Both row lists come from `SettingsPickerOptions` so a stored value outside the
                // offered set still displays (and survives) instead of rendering as no selection.
                SettingsRow("Ignore files smaller than") {
                    Picker("Ignore files smaller than", selection: $duplicateMinFileSize) {
                        ForEach(SettingsPickerOptions.minFileSize(including: duplicateMinFileSize)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Leaves files below this size out of the results. They still count when whole folders are compared.")
                }
                SettingsRow("Folders overlap at") {
                    Picker("Folders overlap at", selection: $duplicateOverlapThreshold) {
                        ForEach(SettingsPickerOptions.overlapThreshold(including: duplicateOverlapThreshold)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How much of their content two same-named folders must share to be grouped as overlapping. Below it, they’re treated as unrelated.")
                }
                Toggle("Detect versions (Report, Report (1), Report-final)", isOn: $duplicateDetectVersions)
                    .help("Groups files whose names differ only by a marker like “(1)”, “copy”, “-v2”, or “final”, even though their contents differ.")
                Toggle("Read PDFs to find copies a byte hash misses", isOn: $duplicateDetectSameText)
                    .help("Reads the text of PDFs to find one document saved twice with different bytes. No OCR; the first scan of a large folder takes a few minutes longer.")
            }
        }
    }
}

// MARK: - Organize

/// The Organize job: where it looks for loose files, and the names it has been told to stop
/// offering to rename. The engine and its cost live in `IntelligenceSettingsTab` and the roster in
/// `PeopleSettingsTab`; what stays here describes the job, not the machinery.
///
/// Cloud spend lives with the key on Intelligence, not here: "what does the cloud path cost me?"
/// is one question, and splitting it would add a place to look.
struct FilingSettingsTab: View {
    /// The kept-names list reaches `keptNamesStore` through it, and Folder surveys the surveys.
    /// Optional because tests and previews build the tab without an engine.
    let syncManager: FileSyncManager?
    /// Cloud sources by name and landing folder, for Folder surveys. Empty hides the section,
    /// which is how the layout tests build the tab.
    var surveySources: [(name: String, root: String)] = []
    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"

    var body: some View {
        SettingsPage {
            // "Inbox and rules" names what the group holds. Not "Filing", a retired word (search
            // keeps it as a keyword), and not "Organize", which would repeat the rail row.
            SettingsSection("Inbox and rules", content: {
                SettingsRow("Loose-files inbox") {
                    // The placeholder is "None", not the default "TODO", so an emptied field reads
                    // as off rather than untouched. The help text says what off does.
                    TextField("None", text: $filingInbox)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                }
                .help("The folder (relative to the provider root) where loose files pile up — e.g. “TODO”. Organize offers it on its overview as a one-click way to narrow to that folder. It does not open there on its own; leave this blank and the offer disappears.")
                SettingsRow("Remembered rules") {
                    Text("Now live in Organize ▸ Rules")
                        .foregroundStyle(.secondary)
                }
                .help("A rule you teach by correcting a suggestion is saved — review, edit, or delete it under Rules in the Organize workspace.")
            }, caption: {
                // Names the two tabs this one hands off to, so "where is the API key?" has an
                // answer here.
                Text("Organize suggests where loose files belong, starting from the inbox folder above. What it suggests, and what the cloud pass costs, now live under **Intelligence**; the household it files for lives under **People**. Corrections you ask it to remember are saved as rules, listed under Rules in the Organize workspace.")
            })

            if let syncManager, !surveySources.isEmpty {
                FolderSurveysSection(syncManager: syncManager, sources: surveySources)
            }

            SettingsSection(
                "Kept names",
                caption: "Names you kept with “Always Allow This Name” after SyncCloud flagged them as ones a cloud provider may mishandle — a trailing space, a forbidden character, and so on. A kept name draws no badge anywhere it is listed, and Organize never offers to rename it. Kept names are matched exactly, so the decision covers every file with that name and follows it when it moves. Remove one to have it reported again; the files themselves are never touched either way."
            ) {
                if let store = syncManager?.keptNamesStore {
                    KeptNamesList(store: store)
                } else {
                    // No engine attached (tests, previews): say what an empty store would.
                    //
                    // This branch is not the tab. It is one fixed line; the real list grows a
                    // row per name, which is why this tab is in `SettingsTab.exemptFromFitGuard`.
                    // A layout test built with `syncManager: nil` measures only this line.
                    KeptNamesList.nothingKeptNote
                }
            }
        }
    }
}

// MARK: - Intelligence

/// The suggestion engine and what it costs: the free on-device pass, the opt-in Claude pass with
/// its key and model, the spend those calls run up, and the cache that stops them being repeated.
///
/// Named "Intelligence" for the reasons on `SettingsTab.displayName`; `SettingsSearchIndex` carries
/// "API key" and "Anthropic" here.
///
/// The sections escalate top to bottom: what runs for free, what runs for money, what that money
/// has come to, and what stops it being spent twice.
struct IntelligenceSettingsTab: View {
    /// Reaches `filingVerdictCache*` for the saved-suggestion count. Optional because tests and
    /// previews build the tab without an engine.
    let syncManager: FileSyncManager?
    /// See `SettingsView.onOpenHelp`. nil hides the pointer beside the on-device caption.
    /// Defaulted, so the layout tests can build the tab without one.
    var onOpenHelp: ((String) -> Void)?
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true
    @AppStorage(FileSyncManager.readContentsDefaultsKey) private var filingReadContents: Bool = true
    @AppStorage(FileSyncManager.usesCloudDefaultsKey) private var filingUseCloud: Bool = false
    // Default from the protocol, not a literal: the classifier and the spend preflight fall back
    // to `CloudFilingProtocol.defaultModel`, and a copy would drift when the default moves.
    @AppStorage(FileSyncManager.cloudModelDefaultsKey) private var filingCloudModel: String = CloudFilingProtocol.defaultModel
    @AppStorage(FileSyncManager.reuseVerdictsDefaultsKey) private var filingReuseVerdicts: Bool = true
    @AppStorage(FileSyncManager.monthlyBudgetCapKey) private var monthlyBudgetUSD: Double = 0
    @AppStorage(FileSyncManager.totalBudgetCapKey) private var totalBudgetUSD: Double = FileSyncManager.defaultTotalBudgetCapUSD
    @AppStorage(AskClaudeModels.defaultsKey) private var askClaudeModel: String = AskClaudeModels.defaultModel.id
    @AppStorage(AskClaudeSpend.limitDefaultsKey) private var askClaudeLimitUSD: Double = AskClaudeSpend.defaultLimitUSD
    @AppStorage(AskClaudeDetail.defaultsKey) private var askClaudeAnswers: String = AskClaudeDetail.brief.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(AskClaudePrivacy.readsFilesKey) private var askClaudeReadsFiles = false
    @State private var askClaudeHidden: [String] = []
    @State private var askClaudeShared: [String] = []
    @State private var askClaudeSpentUSD = 0.0

    /// How many saved suggestions there are. Read on appear and after a clear, not in `body`,
    /// because answering it touches the cache file.
    @State private var savedSuggestionCount = 0

    // Cloud spend, refreshed on appear and when the history sheet closes.
    @State private var spendTotals = FilingSpendTotals()
    @State private var spendLast: FilingSpendEntry?
    @State private var showSpendHistory = false

    /// Whether the key and model rows can be operated. The cloud path rides on top of on-device
    /// AI, so turning either flag off takes them with it. Static so the rule can be tested: a
    /// SwiftUI control's disabled state isn't observable from a unit test.
    static func cloudControlsEnabled(useAI: Bool, useCloud: Bool) -> Bool { useAI && useCloud }

    /// Whether the cloud toggle itself can be operated: gated on on-device AI and nothing else.
    ///
    /// Not `cloudControlsEnabled`: `filingUseCloud` defaults to false, so gating the toggle on it
    /// would leave cloud refining impossible to turn on, and no unit test can see a disabled
    /// control. **A control that turns something on must never be gated on that thing being on.**
    static func cloudToggleEnabled(useAI: Bool) -> Bool { useAI }

    /// The Help pointer beside "Read file contents on-device", a privacy switch whose caption can
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
                caption: "Free, private, and always the first pass: the on-device model (Apple Intelligence, macOS 26) runs at no cost, and where it isn’t available Organize falls back to matching on names and metadata. Reading contents gives it more to go on for files whose name says nothing. Nothing here opens a network connection — the reading happens on this Mac and is never sent anywhere. Changes apply on the next scan."
            ) {
                Toggle("Suggest folders with on-device AI (Apple Intelligence)", isOn: $filingUseAI)
                    .help("Lets Organize ask the on-device model where files belong. Off, or where it isn’t available, Organize suggests from names and metadata alone. Claude refining and saved suggestions need it on.")
                // `.firstTextBaseline`, so the glyph sits on the label's baseline rather than
                // centring on the switch, which at Large text leaves it high.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Toggle("Read file contents on-device for better signals", isOn: $filingReadContents)
                        .help("Lets Organize read the text inside your files, on this Mac, for better folder suggestions.")
                    helpPointer
                }
            }

            SettingsSection(
                "Claude API key",
                caption: "Used by Organize’s Refine and by Ask Claude, and billed to that key. A Max or Ultra plan’s monthly API credit pays for both once its Console organization is linked. The key is stored in the macOS Keychain."
            ) {
                CloudKeyRow()
            }

            SettingsSection(
                "Ask Claude",
                caption: "The chat button in the toolbar, ⌘J. Claude sees a description of the screen you’re on — the names, kinds, sizes, dates and tags of what’s shown — and can look things up, move your view and open your places. When it needs what’s inside a file, this Mac reads it, and a card shows Apple Intelligence’s answer; nothing from the file goes to Claude until you share it there, unless Let Claude read files is on. When you ask, it changes how SyncCloud looks, or lowers its own spending or access, with Undo on its card; any other change, files included, waits for your click on a card. Every answer says what it sent and what it cost."
            ) {
                SettingsRow("Model") {
                    Picker("Model", selection: Binding(
                        get: { AskClaudeModels.option(for: askClaudeModel).id },
                        set: { askClaudeModel = $0 })) {
                        ForEach(AskClaudeModels.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Sonnet 5.5 answers a typical question for about a cent. A change carries on in the open chat from its next question; the menu under Ask Claude’s text box changes it too.")
                }
                SettingsRow("Answers") {
                    Picker("Answers", selection: $askClaudeAnswers) {
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
                SettingsRow("Monthly limit") {
                    Picker("Monthly limit", selection: $askClaudeLimitUSD) {
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
                Toggle("Let Claude read files", isOn: $askClaudeReadsFiles)
                    .help("Off: Apple Intelligence reads a file on this Mac, and its answer and text go to Claude only when you share them on the card. On: the answer and the passage it came from go without asking, and so do lookups; all of a document still waits for your click.")
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
                                    Self.unhideIfConfirmed(folder, in: .standard, confirm: RemovalPrompt.showToClaude(
                                        named: (folder as NSString).lastPathComponent,
                                        isFolder: Self.isFolderOrMissing(folder)).ask)
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
                                askClaudeHidden = AskClaudePrivacy.hiddenFolders(in: .standard)
                            }
                        }
                        .controlSize(.small)
                    }
                    .help("Claude is never shown these folders and files, or what’s in them: not their names, not their contents. They appear to it only as a count. Right-click a row ▸ Hide from Claude adds one too.")
                }
                // Set from the shield menu in Ask Claude; taken off here with no question, since
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
                                    askClaudeShared = AskClaudePrivacy.sharedFolders(in: .standard)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Stop sharing \((folder as NSString).lastPathComponent) without asking")
                                .help("Claude asks before anything from it goes again.")
                            }
                        }
                    }
                    .help("From these folders, Apple Intelligence’s answers, page text, search names and lookups go to Claude without a card. Whole documents still ask. Set one from the shield in Ask Claude.")
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
            .onAppear { askClaudeSpentUSD = AskClaudeSpend.spent(in: .standard) }
            .onReceive(NotificationCenter.default.publisher(for: AskClaudeSpend.didChange)
                .receive(on: DispatchQueue.main)) { _ in askClaudeSpentUSD = AskClaudeSpend.spent(in: .standard) }

            SettingsSection(
                "Claude (cloud)",
                caption: "Refining is the opt-in second pass — once a scan has results, a Refine button re-asks Claude about them, billed to your API key. With Ask Claude above, it is what spends money here; it never runs on its own, and you see a cost estimate before each one. To keep cost low it sends your folder names plus file names — and a short text excerpt only for files whose name says nothing — for up to 150 files per pass. Pick Haiku for the cheapest runs (roughly a penny a pass). The key is stored in the macOS Keychain."
            ) {
                Toggle("Use Claude (cloud) to refine suggestions", isOn: $filingUseCloud)
                    .disabled(!Self.cloudToggleEnabled(useAI: filingUseAI))
                    .help("Lets Organize’s Refine button send to Claude — with the key above; without one it offers to bring you back here instead. Scans stay free and on-device either way; Organize reaches Claude only when you click Refine.")
                // Shown always, disabled rather than absent when the toggles are off. Grouped so
                // the `.disabled` covers the model row without the toggle above it; see
                // `cloudToggleEnabled`. (The key row has its own section above.)
                Group {
                    // Read through `currentModel(for:)` so a superseded model id still lights its
                    // family's row, as the scan resolves it. "Cloud model" matches the search
                    // index title. Rows come from `selectableModelOptions`, so ids and labels
                    // can't drift apart.
                    SettingsRow("Cloud model") {
                        Picker("Cloud model", selection: Binding(
                            get: { CloudFilingProtocol.currentModel(for: filingCloudModel) },
                            set: { filingCloudModel = $0 })) {
                            ForEach(CloudFilingProtocol.selectableModelOptions, id: \.id) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("Saved suggestions are per model — switching means the next Refine asks, and pays for, every file again.")
                }
                // The group only, never the toggle above.
                .disabled(!Self.cloudControlsEnabled(useAI: filingUseAI, useCloud: filingUseCloud))
            }

            SettingsSection(
                "Cost and limits",
                caption: "Before each Refine you’ll see a cost estimate to confirm. Two caps pause cloud classification when a refine would push you past them: a monthly cap (Off by default) and a total lifetime cap (defaults to $5 as a safety backstop). Either one being reached leaves the free on-device suggestions in place until you raise or turn it off. Costs are estimated from list prices for the cloud suggestions only (the Anthropic Console is authoritative); scanning is free."
            ) {
                // What has been spent, above the caps that bound it, so you can see how close the
                // $5 backstop is. A readout strip, not label/value rows: these report, not set.
                FilingSpendReadout(totals: spendTotals, last: spendLast)
                // A blank cap picker is dangerous: the stored value keeps governing cloud scans
                // whatever the control shows. Rows via `SettingsPickerOptions`.
                SettingsRow("Monthly budget cap") {
                    Picker("Monthly budget cap", selection: $monthlyBudgetUSD) {
                        ForEach(SettingsPickerOptions.monthlyBudget(including: monthlyBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Stops a Refine that would take this calendar month’s estimated Claude spend past this amount.")
                }
                SettingsRow("Total budget cap") {
                    Picker("Total budget cap", selection: $totalBudgetUSD) {
                        ForEach(SettingsPickerOptions.totalBudget(including: totalBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Stops a Refine that would take the estimated Claude spend recorded here, across all time, past this amount.")
                }
                HStack {
                    Button("View History…") { showSpendHistory = true }
                        .disabled(spendTotals.scans == 0)
                    // Asks first: this resets what both caps count against, the $5 backstop included.
                    Button("Clear", role: .destructive) {
                        if FilingSpendStore.clearIfConfirmed(confirm: Self.confirmClearSpend) {
                            refreshSpend()
                        }
                    }
                    .disabled(spendTotals.scans == 0)
                    .help("Deletes the recorded spend history and totals, so both caps count from zero again. What Anthropic has billed is unchanged. Asks first.")
                }
                .controlSize(.small)
            }

            SettingsSection(
                "Saved suggestions",
                caption: "A file that hasn’t been edited, renamed, or moved gets the same suggestion it got last time, so scanning — or refining — the same folder again doesn’t ask the model, or pay Claude, a second time. Clearing forgets every saved suggestion: the next scan asks the on-device model about each file again, and the next Refine asks — and pays — Claude again."
            ) {
                Toggle("Reuse suggestions for files that haven’t changed", isOn: $filingReuseVerdicts)
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
                            if Self.clearSavedSuggestionsIfConfirmed(
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
        .onAppear(perform: refreshSpend)
        // The store's change signal: the Organize lens's history sheet can clear history while
        // this tab is open, and a scan can record spend mid-view. `receive(on:)` because `record`
        // posts off the main actor.
        .onReceive(NotificationCenter.default.publisher(for: FilingSpendStore.didChange)
            .receive(on: DispatchQueue.main)) { _ in refreshSpend() }
        // **Never fold this into `refreshSpend`:** the count decodes a cache file of up to ~12 MB,
        // which must not run on the main actor. The spend reads are small defaults blobs.
        .task { savedSuggestionCount = await syncManager?.filingVerdictCacheCount() ?? 0 }
        .sheet(isPresented: $showSpendHistory, onDismiss: refreshSpend) {
            FilingSpendHistorySheet().presentedNativeControlAccent()
        }
    }

    /// Hidden from Claude's Remove, as one step: ask, and only then show the item to Claude again.
    /// - Returns: Whether it was taken off the list.
    @discardableResult
    static func unhideIfConfirmed(_ path: String, in defaults: UserDefaults, confirm: () -> Bool) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm) { AskClaudePrivacy.unhide(path, in: defaults) }
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

    /// The question both spend Clear buttons ask — see `FilingSpendStore.clearIfConfirmed`.
    static func confirmClearSpend() -> Bool {
        let prompt = FilingSpendStore.clearPrompt
        return NativeAlerts.confirmIrreversible(messageText: prompt.messageText,
                                                informativeText: prompt.informativeText,
                                                confirmTitle: prompt.confirmTitle)
    }

    private func refreshSpend() {
        spendTotals = FilingSpendStore.totals()
        spendLast = FilingSpendStore.last()
    }
}

/// What the cloud pass has cost so far — total, tokens, scan count, and the most recent scan.
///
/// A strip, not `SettingsRow`s: these set nothing, and as one readout they cost one row's height.
/// With no scans it says so in words, since four zeroes read as a broken control.
struct FilingSpendReadout: View {
    let totals: FilingSpendTotals
    let last: FilingSpendEntry?

    var body: some View {
        if totals.scans == 0 {
            Text("No cloud refines yet — nothing has been spent.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 18) {
                figure("Total spent", FilingSpendFormat.cost(totals.costUSD))
                figure("Tokens", FilingSpendFormat.tokens(totals.tokens))
                figure("Cloud refines", "\(totals.scans)")
                if let last {
                    figure("Last refine",
                           "\(FilingSpendFormat.model(last.model)) · \(FilingSpendFormat.counted(last)) · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A label over its value, monospaced so the figures don't shift their neighbours as the strip
    /// refreshes live during a refine.
    @ViewBuilder
    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            // No `.fixedSize(horizontal: false, vertical: true)`, unlike `SettingsSection`'s
            // caption: the `HStack` proposes this column a real width, so it already wraps.
            Text(value)
                .scaledFont(.callout)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - People

/// Who Organize files for.
///
/// A tab because it is a roster, not a preference: rows with their own facts and veto counts, an
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
        Text("No kept names. Right-click a file with a flagged name and choose Always Allow This Name to keep it.")
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
                        caption: "Read from the file names already in each person’s folders. Nothing is added without asking, and “Not a Name” is remembered.") {
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
            ? "Saved in people.json."
            : "This list was suggested from your folder names — edit anyone to make it yours."
    }

    /// What the roster is for, briefly; the longer version with a worked example is in Help. The
    /// order sentence is here because the reader would otherwise have to guess the rule.
    static let purposeCaption = "Who your documents belong to — the people Organize files for. It keeps one person’s document out of another’s folder, and chooses between folders that differ only by person (School/Daughter beside School/Son). A full name is matched before any single word, so add each person’s names as documents print them. The list is in relationship order — you, spouse, children, parents, siblings, then everyone else — until you move someone, after which your order is kept. Nothing here leaves your Mac, and only the names you add are stored."

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

/// The full cloud-Filing spend history as a sheet (Settings' copy — FileExplorer has its own in
/// the Organize workspace; both read the shared FilingSpendStore).
struct FilingSpendHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FilingSpendEntry] = []
    @State private var totals = FilingSpendTotals()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // "Cloud AI", not "Cloud Filing": the workspace is Organize and the lens To File.
                // `FileExplorer`'s `FilingSpendHistoryView` has a twin header that must match.
                Text("Cloud AI Spend").scaledFont(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).shortcutKeycap("↩").accentedProminent()
            }
            .padding()
            Divider()
            HStack(spacing: 24) {
                stat(FilingSpendFormat.cost(totals.costUSD), "total")
                stat(FilingSpendFormat.tokens(totals.tokens), "tokens")
                stat("\(totals.scans)", "cloud refines")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            Divider()
            if entries.isEmpty {
                EmptyStateView(
                    icon: "cloud",
                    title: "No cloud refines yet",
                    layout: .compact
                )
            } else {
                List(entries.reversed()) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).scaledFont(.system(size: 12))
                            Text("\(FilingSpendFormat.model(entry.model)) · \(FilingSpendFormat.counted(entry)) · \(FilingSpendFormat.outcome(entry))")
                                .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FilingSpendFormat.cost(entry.estimatedCostUSD)).scaledFont(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Text(FilingSpendFormat.tokens(entry.totalTokens)).scaledFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 540, height: 440)
        .onAppear {
            entries = FilingSpendStore.entries()
            totals = FilingSpendStore.totals()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).scaledFont(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Advanced

/// Logging, maintenance, saved scan data, and the setup and settings resets: engine machinery
/// given a user-facing surface.
struct AdvancedSettingsTab: View {
    let syncManager: FileSyncManager?
    let onResetAllSettings: (() -> Void)?
    /// Clears the three setup flags and the draft, then opens the guided sheet at its first screen.
    ///
    /// **Keep it defaulted.** The tab uses the memberwise `init`, so a parameter without a default
    /// breaks every construction site, including `SettingsLayoutTests.mustFitTabs`.
    var onResetSetup: (() -> Void)? = nil
    /// What Reset All would raise for Claude from the values now, named in its confirmation as the
    /// card's question names it. Defaulted for the same reason as `onResetSetup`.
    var resetAllRaises: () -> [String] = { [] }

    @AppStorage(Logger.minimumLevelDefaultsKey) private var minimumLevelRaw: String = LogLevel.debug.rawValue
    /// Human-readable size of the log file, refreshed on appear and after Clear Log.
    @State private var logFileSizeText: String?
    /// Human-readable sizes of the two saved-scan-data files, or nil where there is no file. nil is
    /// what disables each Clear, so "None" and a live button cannot disagree.
    @State private var hashIndexSizeText: String?
    @State private var storageLensSizeText: String?

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Logging",
                caption: "The log rotates at 5 MB. Levels below the chosen one are skipped entirely."
            ) {
                SettingsRow("Log level") {
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
                    }
                    .help("Which messages the log keeps: the chosen level and everything more severe. Debug keeps everything.")
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
                caption: "Interrupted copies can leave .tmp_ working files behind; they’re moved to the Trash automatically once they’re an hour old. Recovery backups (.rollback_) are never touched."
            ) {
                SettingsRow("Orphaned temporary files") {
                    Button("Sweep Now") {
                        syncManager?.sweepOrphanedTempArtifactsNow()
                    }
                    .controlSize(.small)
                    .disabled(syncManager == nil)
                    .help("Moves .tmp_ working files over an hour old, in the folders the panes have loaded, to the Trash now. .rollback_ backups are left alone.")
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
                caption: "Kept so a rescan doesn’t repeat work it already did. Clearing costs time on the next scan and nothing else — your files aren’t affected, and neither are your saved suggestions (Organize)."
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

            if let onResetSetup {
                SettingsSection(
                    caption: "Forgets that setup has run and which location it learns from, and opens it now, from the beginning. On a Mac with no folder profile yet this also discards the name and household answers setup was holding for one. Your folder profile, people and other settings stay."
                ) {
                    Button("Reset Setup…", role: .destructive) {
                        confirmResetSetup(onResetSetup)
                    }
                    .help("Forgets that setup has run and which location it learns from, and opens it now, from the beginning. Asks first.")
                }
            }

            if let onResetAllSettings {
                SettingsSection(
                    caption: "Restores defaults for appearance, sync behavior, and source names and paths, and clears the folders you added as sources. Keeps what you made — Rules, signatures, Favorites, pins and your choices while organizing — the folders hidden from Claude, and Claude’s spending limits and record. Your files aren’t affected."
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
    static let resetAllExplanation = "Settings return to their defaults, apart from what is kept below. Folders you added as sources, ignored items, and source names and paths are removed, and SyncCloud forgets that setup has run.\n\nKept: your Rules, saved signatures, Favorites and pins, and the choices you made while organizing (corrections, groups kept separate, names kept); the folders you hid from Claude; and your spending limits for Claude and the record of what it has cost. One-Way Sync stays set up as it is, with its choices for a Dropbox file deleted, renamed, moved or edited, and Launch at login stays as it is: macOS holds it. Your Claude API key, folder profile, Ask Claude chats and your files are not touched."

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

extension SettingsView.SettingsTab {

    /// Where a stored `settingsSelectedTab` resolves to, including when it resolves to nothing.
    ///
    /// Here, not in `MacApp/ContentView.swift` where the launch read happens, so a test can reach
    /// it. The stored value comes from past builds and from `defaults`, outside the app's control:
    /// **never trap on it**, or a retired tab crashes the launch.
    ///
    /// Falls back to Appearance, the tab that depends on nothing (no engine, provider list or
    /// roster), so it's safe whatever state the app is in.
    public static func resolvingStored(_ raw: String?) -> Self {
        guard let raw, let tab = Self(rawValue: raw) else { return .appearance }
        return tab
    }
}
