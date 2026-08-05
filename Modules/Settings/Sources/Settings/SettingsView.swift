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

    /// Bool (default true). When false, panes always open at their provider roots instead of
    /// the folders they were focused on when the app last quit.
    public static let restoreLastFocusKey = "restoreLastFocusOnLaunch"
    /// String. The left pane's root-relative focus path, continuously persisted by
    /// ContentView ("" = provider root). App state rather than a user preference, but the
    /// keys live here beside the toggle that governs them.
    public static let lastLeftFocusKey = "lastLeftFocusPath"
    /// Right-pane counterpart of `lastLeftFocusKey`.
    public static let lastRightFocusKey = "lastRightFocusPath"

    /// Bool (default false). Posts a system notification when an operation banner lands
    /// while SyncCloud is not the active app. Read by `OperationNotifier`.
    public static let notifyOnBackgroundCompletionKey = "notifyOnBackgroundCompletion"

    /// String (default "TODO"). The provider-root-relative folder Organize scans for loose files by
    /// default — the "inbox" where loose files pile up. Read by ContentView's Filing action; an empty
    /// value (or navigating the rail into a subfolder) falls back to the focused folder.
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
    /// Identifies a settings tab; raw values are the format of the `settingsSelectedTab`
    /// default read at window creation, so treat them as stable. `CaseIterable` backs both the
    /// segmented picker and the search index's "every entry points at a real tab" invariant.
    public enum SettingsTab: String, CaseIterable, Sendable {
        case general
        case appearance
        case providers
        case sync
        /// Shown as "Organize". The case is named for `Workspace.filing`, not for the label, for
        /// the reason that workspace keeps its own name: the label moved and the identity didn't,
        /// and a tab whose case matches its workspace's is one grep away from the code it governs.
        case filing
        case duplicates
        case advanced

        /// The human-readable tab name shown in the rail and as the dim subtitle on a search
        /// result. Kept here so the labels have a single source of truth.
        public var displayName: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            // "Sources", not "Providers": the tab lists plain folders alongside the cloud accounts
            // now, and a folder is not a provider — "Discovered providers" over a row saying
            // ~/Projects was the tell. The case keeps its name so the stable `settingsSelectedTab`
            // raw value, and every `selectedTab = .providers` deep link, are untouched.
            case .providers: return "Sources"
            case .sync: return "Sync"
            case .filing: return "Organize"
            case .duplicates: return "Duplicates"
            case .advanced: return "Advanced"
            }
        }

        /// The rail row's SF Symbol. Monochrome and outline-weight throughout: a rail of mixed
        /// filled and outline glyphs reads as though the filled ones meant something.
        ///
        /// Organize and Duplicates take the glyphs their workspaces wear in the bar
        /// (`Workspace.symbol`) rather than picking settings-only ones — the rail row and the bar
        /// button are two ways into the same feature, and a second glyph for it would say they
        /// weren't.
        public var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .providers: return "cloud"
            case .sync: return "arrow.left.arrow.right"
            case .filing: return "folder.badge.gearshape"
            case .duplicates: return "doc.on.doc"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
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

    /// Runs the full settings reset (defaults wipe plus the host's re-seeding of live state).
    /// Provided by the host; the Reset control hides when nil.
    private let onResetAllSettings: (() -> Void)?

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

    /// The app's text-size setting. The sheet is sized in points but its contents are sized in
    /// scaled type, so the sheet has to grow with the type or the taller tabs start scrolling
    /// again at Large — the exact failure this layout exists to fix.
    @AppStorage(FontSize.defaultsKey) private var fontSizeRaw: String = FontSize.medium.rawValue
    private var fontSize: FontSize { FontSize(rawValue: fontSizeRaw) ?? .medium }

    /// The space the host has to place the sheet in, or `nil` when the host doesn't say. The
    /// window's own minimum is 600pt wide, narrower than the sheet wants at any text size, so
    /// without this the sheet would hang off the edge of a small window.
    private let availableSize: CGSize?

    public init(
        selection: Binding<SettingsTab>,
        onClose: @escaping () -> Void,
        syncManager: FileSyncManager? = nil,
        onResetAllSettings: (() -> Void)? = nil,
        availableSize: CGSize? = nil
    ) {
        _selectedTab = selection
        self.onClose = onClose
        self.syncManager = syncManager
        self.onResetAllSettings = onResetAllSettings
        self.availableSize = availableSize
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
            }
            .padding(.horizontal, 16)
            // Fixed rather than padding-derived: the content opening below is computed as
            // `height − headerHeight − 1`, and a header that sized itself would make that
            // arithmetic — and every layout assertion resting on it — a guess.
            .frame(height: SettingsSheetMetrics.headerHeight * fontSize.scale)

            Divider()

            HStack(spacing: 0) {
                // Search and the tabs stand down the left — the macOS Settings convention, and
                // the reason the content column gets its height back. Both used to be rows
                // stacked above the content, costing 124pt before the first control.
                SettingsRail(selection: $selectedTab, query: $searchQuery, hue: selectedHue)
                    .background(Color.primary.opacity(0.035))

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
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
                GeneralSettingsTab()
            case .appearance:
                AppearanceSettingsTab()
            case .providers:
                ProvidersSettingsTab()
            case .sync:
                SyncSettingsTab(syncManager: syncManager)
            case .filing:
                FilingSettingsTab(syncManager: syncManager)
            case .duplicates:
                DuplicatesSettingsTab()
            case .advanced:
                AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings)
            }
        }
    }
}

// MARK: - Settings search

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
/// something, across every tab. Two kinds of on-screen label deliberately get no entry of their
/// own, because neither is a setting — the `SettingsSection` headers that only group other
/// controls ("Conflicts", "Logging"), and the read-only readouts in Organize's Cloud spend
/// section ("Total spent", "Tokens"). Both are reached through the control they belong to.
///
/// Titles mirror the on-screen label, or extend it where the label alone would be ambiguous in a
/// results list that shows nothing but the title and its tab ("Surface tint" for the section
/// headed "Tint"). Keywords add the words people are likely to type instead — synonyms, the value
/// names, the feature they're after.
///
/// This is the single place to keep in sync when a control is added or renamed, and
/// `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed` holds that: it scans the tab
/// sources for control labels and fails on one that reaches nothing here. A control whose label
/// the scan cannot see (a title built at runtime, a control vehicle it does not model) is still
/// only as indexed as whoever adds it makes it.
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
        // "theme" lives here, not on Accent color: since the Theme control exists, that word
        // means light/dark to users, and matching it on the accent row steered them wrong.
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
        // "solid" belongs to Glass effect now, not here: this control is shape only.
        .init(tab: .appearance, title: "Content surface style",
              keywords: ["surface", "unified", "cards", "pane background", "content surface"]),
        .init(tab: .appearance, title: "Text size",
              keywords: ["text size", "font", "font size", "type size", "bigger text", "larger text",
                         "smaller text", "readability", "zoom", "scale"]),
        .init(tab: .appearance, title: "List density",
              keywords: ["density", "compact", "comfortable", "row height", "spacing", "tighter rows", "row size"]),

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
        .init(tab: .providers, title: "Enable or disable a source",
              keywords: ["enable", "disable", "show", "hide", "sidebar", "toggle provider",
                         "toggle source"]),

        // Sync
        .init(tab: .sync, title: "When a file already exists",
              keywords: ["conflict", "conflict policy", "overwrite", "replace", "keep both", "duplicate handling"]),
        .init(tab: .sync, title: "Treat dates as equal within",
              keywords: ["date tolerance", "date", "timestamp", "tolerance", "modified date", "rounding"]),
        .init(tab: .sync, title: "Verify same-size files during scans",
              keywords: ["verify", "checksum", "same size", "scan verification", "hash"]),
        .init(tab: .sync, title: "Ignore \"newer on Google Drive\" when same size",
              keywords: ["google drive", "newer", "ignore date", "gdrive"]),
        .init(tab: .sync, title: "Confirm before copying or moving",
              keywords: ["confirm copy", "confirm move", "transfer confirmation", "what goes where", "confirm before copy"]),
        .init(tab: .sync, title: "Confirm before deleting",
              keywords: ["confirm delete", "delete confirmation", "trash", "remove"]),
        .init(tab: .sync, title: "Remember ignored items across rescans",
              keywords: ["ignored items", "remember ignores", "hidden differences", "ignore"]),
        .init(tab: .sync, title: "Ignored name patterns",
              keywords: ["ignore patterns", "glob", "exclude", "wildcard", "ds_store", "node_modules", "patterns"]),

        // Organize — the Suggestions and Cloud spend sections, in tab order.
        // "tidy" is kept as a keyword on the two entries a Tidy-era user is most likely to hunt
        // for by that name: the word left the product with this split, so someone who remembers
        // it has nothing to type otherwise.
        .init(tab: .filing, title: "Suggest folders with on-device AI",
              keywords: ["filing", "apple intelligence", "on-device ai", "suggestions", "suggest folders",
                         "sort files", "organize", "tidy"]),
        .init(tab: .filing, title: "Use Claude (cloud) for the best suggestions",
              keywords: ["claude", "cloud", "anthropic", "cloud filing", "ai"]),
        .init(tab: .filing, title: "Anthropic API key",
              keywords: ["api key", "key", "keychain", "sk-ant", "anthropic key", "token"]),
        .init(tab: .filing, title: "Cloud model",
              keywords: ["model", "haiku", "sonnet", "opus", "claude model"]),
        .init(tab: .filing, title: "Read file contents on-device for better signals",
              keywords: ["read contents", "content signals", "ocr", "text", "pdf", "vision"]),
        // "cache" is the word an engineer reaches for and the UI deliberately never says, so it
        // has to live here or the row is unfindable by the people most likely to look for it.
        .init(tab: .filing, title: "Reuse suggestions for files that haven’t changed",
              keywords: ["reuse", "cache", "cached suggestions", "rescan", "re-ask", "cost", "save money"]),
        .init(tab: .filing, title: "Saved suggestions",
              keywords: ["saved suggestions", "clear cache", "cache", "forget suggestions", "reset suggestions"]),
        // "loose files" and "todo" are the two a user actually types: the title spells the first
        // hyphenated ("Loose-files"), so the spaced form matches nothing without the keyword, and
        // the second is the default value rather than anything in the label.
        .init(tab: .filing, title: "Loose-files inbox",
              keywords: ["inbox", "loose files", "todo", "default folder", "scan folder", "organize"]),
        .init(tab: .filing, title: "Remembered rules",
              keywords: ["filing rules", "rules", "remembered rules", "manage rules", "automation", "automations"]),
        .init(tab: .filing, title: "Cloud spend",
              keywords: ["spend", "cost", "tokens", "billing", "usage", "money", "price"]),
        .init(tab: .filing, title: "Monthly budget cap",
              keywords: ["budget", "cap", "limit", "monthly", "spend limit", "cost cap", "guardrail", "pause cloud", "money"]),
        .init(tab: .filing, title: "Total budget cap",
              keywords: ["budget", "cap", "limit", "total", "lifetime", "spend limit", "cost cap", "guardrail", "pause cloud", "money", "backstop"]),
        // Nearly every query for this one misses the label. The section is titled "Kept names",
        // but the decision is made from a menu item worded "Always Allow This Name" and withdrawn
        // from one worded "Stop Allowing This Name" — so "allow" is the word the user has actually
        // read — and what they are looking for is more likely described by the problem ("risky
        // name", "trailing space", "badge") than by the state they put it in.
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
    /// Mirrors `SMAppService.mainApp.status`. Deliberately not seeded in the initializer:
    /// the status getter is a synchronous XPC call, which must not run on the main thread —
    /// `.task` kicks off a detached read once the view is up (and app activation re-reads,
    /// since approval happens over in System Settings).
    @State private var launchAtLogin = false
    /// The login item is registered but awaits the user's consent in System Settings →
    /// Login Items; shown distinctly so a pending approval doesn't read as a broken toggle.
    @State private var loginItemNeedsApproval = false
    /// Tells a user's flip apart from the echo of a programmatic set, keeps the register /
    /// unregister calls serialised to one at a time, and decides what a finished round-trip
    /// owes the user — see `LoginItemEchoGuard`, where the whole state machine lives so it can
    /// be tested without an SMAppService round-trip.
    @State private var loginItemEcho = LoginItemEchoGuard()
    @AppStorage(GeneralSettings.showHiddenByDefaultKey) private var showHiddenByDefault: Bool = false
    @AppStorage(GeneralSettings.warnBeforeQuitKey) private var warnBeforeQuit: Bool = true
    @AppStorage(GeneralSettings.restoreLastFocusKey) private var restoreLastFocus: Bool = true
    @AppStorage(GeneralSettings.notifyOnBackgroundCompletionKey) private var notifyInBackground: Bool = false
    /// Whether the system has DENIED notification permission while the toggle is on — the one
    /// state where the feature looks enabled here but can never fire. Surfaced in the footer
    /// (mirroring the login-item "Approval needed" hint) and re-checked on toggle and app
    /// re-activation, since the user flips the real switch over in System Settings.
    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage {
            SettingsSection {
                Toggle("Launch SyncCloud at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard loginItemEcho.shouldStartRoundTrip(for: enabled, at: .now) else {
                            // Echo of a programmatic set, or a gesture the in-flight call will
                            // carry in its `settle`. Logged because the second case is the one
                            // shape of this guard the user can FEEL — the switch moves and
                            // nothing happens — and with no line here a guard stuck shut was
                            // invisible in the log by construction.
                            Logger.shared.debug("Launch-at-login: no round-trip started for \(enabled) (echo, or one already in flight)")
                            return
                        }
                        updateLoginItem(enabled)
                    }
            } caption: {
                if loginItemNeedsApproval {
                    HStack(spacing: 4) {
                        Text("Approval needed — allow SyncCloud in Login Items settings.")
                        Button("Open Login Items Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                } else {
                    Text("Automatically start SyncCloud when you log in to your Mac.")
                }
            }

            SettingsSection(
                "Startup",
                caption: "Panes reopen at the folders they showed when you last quit (falling back to the root if a folder is gone). Sort changes made from the pane menus are remembered here too."
            ) {
                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
                Toggle("Reopen panes where I left off", isOn: $restoreLastFocus)
                SettingsRow("Sort panes by") {
                    Picker("Sort panes by", selection: $settings.defaultSortOption) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection {
                Toggle("Notify when operations finish in the background", isOn: $notifyInBackground)
                    .onChange(of: notifyInBackground) { _, enabled in
                        if enabled {
                            // Capture the result: a denied request used to vanish, leaving the
                            // toggle on and the user waiting for notifications that never come.
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                Task { @MainActor in notificationsDenied = !granted }
                            }
                        } else {
                            // The hint only matters while the feature is on.
                            notificationsDenied = false
                        }
                    }
            } caption: {
                if notifyInBackground && notificationsDenied {
                    Text("Notifications are disabled in System Settings — allow SyncCloud under Notifications to see these alerts.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn't the active app. Requires notification permission.")
                }
            }

            SettingsSection(caption: "Shows a confirmation if you try to quit while a copy, move, or delete is still running.") {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
            }
        }
        .task {
            readLoginItemState()
            readNotificationAuthorization()
        }
        // Approving the login item (and notification permission) happens in System Settings,
        // so these footers' hints go stale exactly while this tab is still open. Coming back
        // to the app re-activates it — re-read so the hints clear without reopening the tab.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItemState()
            readNotificationAuthorization()
        }
    }

    /// Reflects the real notification authorization into the footer hint. Only `denied` shows
    /// the warning: `notDetermined` means the request prompt is still ahead, and provisional/
    /// authorized both deliver.
    private func readNotificationAuthorization() {
        guard notifyInBackground else { return }
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            let denied = notificationSettings.authorizationStatus == .denied
            Task { @MainActor in notificationsDenied = denied }
        }
    }

    /// Reflects the real service state into the toggle and approval hint. A pending
    /// approval counts as "on": the item *is* registered, just not yet consented to.
    ///
    /// Dated against the echo guard: this runs on `.task` and on EVERY app re-activation, so
    /// without the epoch check a cmd-tab away and back mid-gesture published a service state
    /// that predated the user's flip, moving the toggle out from under the running round-trip.
    /// That call then settled against the "moved" toggle and drove the service back, losing a
    /// registration that had succeeded.
    private func readLoginItemState() {
        Task {
            let epoch = loginItemEcho.epoch
            let status = await Self.readStatusOffMain()
            guard loginItemEcho.mayPublishStatus(readAt: epoch, at: .now) else { return }
            applyLoginItemState(status)
        }
    }

    /// Publishes just the approval hint, leaving the toggle where the user put it. Used when a
    /// failing round-trip's status re-read is the freshest thing we know but the toggle has
    /// already moved on — `applyLoginItemState` would overwrite that move.
    private func applyApprovalHint(_ status: SMAppService.Status) {
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// Publishes a freshly read service status to the view state. Marking the value applied in
    /// the same main-actor turn as the toggle keeps `onChange` from treating the programmatic
    /// set as a user gesture (initial read, failure revert).
    ///
    /// `adoptedStatus` rather than `markApplied`: this write TAKES the toggle, so any round-trip
    /// whose claim had already expired must stop speaking for it — see `adoptedStatus`.
    private func applyLoginItemState(_ status: SMAppService.Status) {
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        loginItemEcho.adoptedStatus(launchAtLogin)
    }

    /// Registers/unregisters the login item, reverting the toggle to the real service state on
    /// failure so the UI never claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        // Synchronously, before the `Task` is even scheduled: two `onChange` turns must not
        // both pass `shouldStartRoundTrip` and start a call apiece.
        let token = loginItemEcho.beginRoundTrip(at: .now)
        Task {
            do {
                let needsApproval = try await Self.applyLoginItemOffMain(enabled)
                // A superseded settle (nil) owns nothing, so it publishes nothing: this hint was
                // sampled off-main and lands an actor hop later, and whatever superseded the call
                // — a fresher status read, a later gesture — knows better than it does.
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: true) else { return }
                loginItemNeedsApproval = needsApproval
                if needsApproval {
                    Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
                }
                perform(followUp, status: nil)
            } catch {
                // Logged before the ownership test: the call really did fail, and that is worth
                // a line whether or not this round-trip still speaks for the toggle.
                Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
                let status = await Self.readStatusOffMain()
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: false) else { return }
                perform(followUp, status: status)
            }
        }
    }

    /// Carries out what `LoginItemEchoGuard.settle` decided. `status` is the freshly re-read
    /// service status, available only on the failure path.
    private func perform(_ followUp: LoginItemFollowUp, status: SMAppService.Status?) {
        switch followUp {
        case .settled:
            break
        case .adoptServiceState:
            if let status { applyLoginItemState(status) }
        case .reapply(let value, let refreshApprovalHint):
            if refreshApprovalHint, let status { applyApprovalHint(status) }
            updateLoginItem(value)
        }
    }

    /// Reads `SMAppService.mainApp.status` detached: the getter is a synchronous XPC call
    /// that must not run on the main thread (the same hazard that defers the initial read
    /// out of view init).
    private static func readStatusOffMain() async -> SMAppService.Status {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value
    }

    /// Runs the status check plus register/unregister round-trip detached — all three are
    /// synchronous XPC calls. Returns whether the item now awaits approval in Login Items.
    private static func applyLoginItemOffMain(_ enabled: Bool) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering a pending-approval item withdraws it from Login Items.
                try SMAppService.mainApp.unregister()
            }
            return SMAppService.mainApp.status == .requiresApproval
        }.value
    }
}

// MARK: - Appearance

/// Theme, accent hue, glass material and surface shape, all shared with MacApp through
/// UserDefaults.
///
/// Theme (light/dark), Glass effect (material) and Content surface (shape) are deliberately
/// separate controls: any combination is valid. The latter two were entangled before — "Solid"
/// appeared in the shape picker and silently overrode the material one.
///
/// Theme leads the tab because it is the broadest of the four: the others all decide how a
/// surface reads *within* an appearance, so choosing light vs dark first is what makes them
/// meaningful. Unlike the others it renders nothing here — `ContentView` pushes it to NSApp.
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
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(FontSize.defaultsKey) private var fontSizeRaw: String = FontSize.medium.rawValue

    /// The resolved text size; `.medium` (the standard size) if unrecognized.
    private var fontSize: FontSize { FontSize(rawValue: fontSizeRaw) ?? .medium }

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
            }

            SettingsSection(
                "Tint",
                caption: selectedHue == .none
                    ? "Choose an accent color above to tint the panes and Differences area."
                    : "Washes the panes and Differences area with the accent color chosen above."
            ) {
                HStack(spacing: 12) {
                    // The slider's own label is hidden, not dropped: the section title above
                    // already says "Tint", and two of them would read as two controls. It stays
                    // in the accessibility tree.
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
            }

            // Text size leads List density: the two are the pair that decides how much fits on
            // screen, and how big the type is has to be settled before how tightly it packs.
            SettingsSection("Text size", caption: fontSize.detail) {
                Picker("Text size", selection: $fontSizeRaw) {
                    ForEach(FontSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
            }

            SettingsSection(
                "List density",
                caption: "Comfortable keeps the standard spacing. Compact tightens rows in lists across SyncCloud — the file panes, the Compare table, every lens workspace, and the Activity Log and Sync History windows — so more fits on screen."
            ) {
                Picker("List density", selection: $listDensityRaw) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.displayName).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
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
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2)
                        )
                        .shadow(color: swatchShadowColor, radius: isSelected ? 5 : 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .scaledFont(.system(size: 13, weight: .semibold))
                            // The checkmark sits on the swatch's own fill, so it pairs with that
                            // fill's luminance — hardcoded white was ~2.1:1 on amber. "None" has no
                            // fill of its own (a neutral disc deferring to the system accent), so it
                            // tracks the appearance via `.primary` like the disc does.
                            .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .scaledFont(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Twelve hues share one row; the longest name ("Graphite") shrinks to stay on a
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

    /// The colored disc for a hue, or a neutral slashed disc for "None".
    @ViewBuilder
    private var swatch: some View {
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

    private var swatchShadowColor: Color {
        hue == .none ? Color.black.opacity(0.2) : hue.accentColor.opacity(0.4)
    }
}

// MARK: - Sources

/// The sources panes can be pointed at: the cloud accounts discovered on this Mac, and the plain
/// folders the user added. Two sub-sections, because they are two different kinds of thing — one is
/// found, the other is chosen — and the controls differ accordingly: a cloud account can be
/// refreshed but never removed, a folder can be removed but never discovered.
struct ProvidersSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var isRefreshingProviders = false
    /// Ids of the rows the user has opened. Collapsed is the default and the point: this tab grows
    /// with every account the Mac has plus every folder added, and at four expanded rows the list
    /// already scrolls past the sheet. State, not a persisted default — which row you last opened
    /// is not a preference, and restoring it would reopen the scroll problem on the next launch.
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
                caption: "Cloud accounts are discovered from ~/Library/CloudStorage. Disabled sources stay configured but are hidden from the pane sidebar. At least one source must remain enabled."
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
                }
            }

            // This tab is the one that legitimately keeps scrolling: it grows with every
            // provider the Mac has, so no sheet height can promise to hold it. Collapsed rows are
            // what keep that growth linear in sources rather than in sources × four fields.
            ForEach(cloudProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
            }

            Divider()

            SettingsSection(
                caption: "Any folder on this Mac can be a source — Compare and Tidy work the same over it. Folders you add appear in every workspace. Removing one leaves the folder itself untouched."
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
                        "A folder accepts any name, so \"risky name\" has no meaning until you say where the files are headed. Organize and the pane badges check names under a folder source against this."
                    )
                }
            }

            ForEach(folderProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
            }
        }
    }

    /// One row's open/closed state. A binding over the shared set rather than per-row `@State`, so
    /// a row that is rebuilt when discovery republishes `availableProviders` — which happens on
    /// every path edit, every rename, every Refresh — doesn't silently snap shut mid-edit.
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

    /// Picks a folder and adds it as a source — opening the new row, so the thing that just
    /// appeared is the thing you can see. Adding a folder that is already a source opens *that*
    /// row instead of adding a second (see `SettingsManager.addFolderSource`).
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
/// Only the two that HAVE rules, plus off. iCloud and Google Drive accept anything the local
/// filesystem does, so offering them would be offering two more spellings of "don't check" —
/// three ways to say one thing, two of which look like they mean something.
struct FolderNameRuleOption: Identifiable {
    static let all: [FolderNameRuleOption] = [
        .init(value: .oneDrive, label: "OneDrive (strictest)"),
        .init(value: .dropBox, label: "Dropbox"),
        .init(value: .localFolder, label: "Don't check"),
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
    let provider: CloudProvider
    /// Whether the path configuration is showing. The header line is always there.
    @Binding var isExpanded: Bool
    @EnvironmentObject var settings: SettingsManager
    // The path draft is a value type rather than a bare String: Reset, focus-blur commit, and the
    // discovery refresh all move it, and getting Reset wrong left the field blank. See
    // `ProviderPathDraft`.
    @State private var pathDraft = ProviderPathDraft()
    @State private var draftName: String = ""
    // Both editable fields share one commit model: Return or focus-loss commits,
    // so each needs its own focus state to observe its own blur.
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var pathFieldFocused: Bool

    /// The display name of the source that already owns a folder this row's Location edit was
    /// refused for, or nil when the last commit was accepted. Drives the line under the field —
    /// the refusal has to say *which* source holds the folder, because "that didn't work" leaves
    /// the user re-typing the same path.
    @State private var refusedDuplicateOwner: String?

    private var isEnabled: Bool {
        settings.isEnabled(provider.id)
    }

    var body: some View {
        SettingsSection {
            HStack(spacing: 12) {
                ProviderLogo(provider.imageName, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    // The name itself is the rename affordance: click to edit in place.
                    // Enter or clicking away commits; emptying it restores the default.
                    // labelsHidden keeps the grouped Form from rendering a leading
                    // "Provider name" label and right-aligning the value; the name
                    // must sit in place of the title, next to the icon.
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
                    // What identifies this source at a glance while the row is shut. A cloud
                    // account is identified by its id (`OneDrive-Personal`) — that IS the
                    // account, and its path is a consequence of it. A folder source's id is a
                    // UUID that says nothing to anyone; the folder IS the path, so that shows.
                    Text(provider.isLocalFolder ? provider.path : provider.id)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(provider.isLocalFolder ? provider.path : provider.id)
                }

                Spacer()

                // SettingsManager owns validity (re-checked on discovery/refresh and
                // path edits), so re-renders here never stat the disk.
                StatusBadge(isValid: settings.isPathValid(for: provider.id))

                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(isEnabled && !settings.canDisable(provider.id))
                    .help(
                        isEnabled && !settings.canDisable(provider.id)
                            ? "At least one source must remain enabled."
                            : "Show \(provider.displayName) in the pane sidebar."
                    )

                disclosureButton
            }
            .padding(.vertical, 2)
            .onAppear {
                pathDraft.adopt(provider.path)
                draftName = provider.displayName
                // A refusal is about one edit, not about the row. Re-mounting starts clean.
                refusedDuplicateOwner = nil
            }
            .onChange(of: provider.path) { _, updated in
                pathDraft.adoptExternalChange(to: updated, isEditing: pathFieldFocused)
            }
            .onChange(of: provider.displayName) { _, updated in
                if !nameFieldFocused && draftName != updated {
                    draftName = updated
                }
            }

            if isExpanded {
                // The path gets its own full-width line rather than sharing one with its label.
                // Beside the label it had ~300pt, and every provider under
                // ~/Library/CloudStorage runs past that — the paths were clipped at the pane edge
                // with no ellipsis, so the tail that distinguishes them
                // (…/OneDrive-Personal/Documents from …/Desktop) was the part you couldn't see.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")
                    // Mirrors the name field above: Enter or clicking away commits.
                    // No Save button — focus-loss covers the same ground, so the two
                    // fields commit through one identical set of triggers.
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
                        // A TextField scrolls rather than ellipsizing, so a path longer than even the
                        // full width still hides its tail. The tooltip is the backstop — the same
                        // answer the ignored-items list already uses for long root-relative paths.
                        .help(pathDraft.value)

                    // Only ever set for a folder source, and cleared by the next accepted commit.
                    if let owner = refusedDuplicateOwner {
                        Text("That folder is already \(owner). One folder gets one source.")
                            .scaledFont(.caption)
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
                    // A folder source has no discovered default to reset TO — the user chose
                    // the path, and that choice is the whole record. Remove takes its place: the
                    // one thing a folder source can do that a cloud account cannot.
                    if provider.isLocalFolder {
                        Button("Remove", role: .destructive) { settings.removeFolderSource(id: provider.id) }
                    } else {
                        Button("Reset") { resetToDefault() }
                    }
                    Button("Show in Finder") { openInFinder() }
                    Spacer()
                }
                .controlSize(.small)
                // Remove stays live on a disabled source: a folder switched off is exactly the
                // one you are most likely to be removing, and leaving the only way to get rid of
                // it behind a toggle you have to switch back on first is a trap.
                .disabled(!isEnabled && !provider.isLocalFolder)
            }
        }
    }

    /// Opens and shuts the row. Down-chevron to open, up-chevron to shut — the arrow points at
    /// where the content will be, not at where it is.
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
        .help(isExpanded ? "Hide \(provider.displayName)'s location" : "Show \(provider.displayName)'s location")
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

    private func resetToDefault() {
        settings.resetPath(for: provider.id)
        // Repopulate rather than blank. Rediscovery is async, so `provider.path` is still the old
        // effective value here: with no override that value already IS the default and no
        // `onChange(of: provider.path)` is coming to fill the field in, and with an override it is
        // corrected by that onChange as soon as discovery lands — including while this field still
        // holds focus, which clicking this button does not take away. The draft remembers the reset
        // so that correction is adopted instead of being declined as mid-edit; without that, the
        // blur after Reset commits the stale override straight back. See `ProviderPathDraft.reset`.
        pathDraft.reset(toEffective: provider.path)
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: (provider.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // Both fields commit on Return AND on focus-loss (one shared model), so a blur that
    // lands on an unchanged value must be a harmless no-op — hence both guard on
    // ProviderFieldEdit.shouldCommit before writing.
    private func commitPath() {
        let normalized = ProviderFieldEdit.normalized(pathDraft.value)
        pathDraft.value = normalized
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.path) else { return }
        switch settings.setPath(normalized, for: provider.id) {
        case .changed, .unchanged:
            refusedDuplicateOwner = nil
        case .refusedDuplicate(let existingId):
            // Put the field back to what the source actually points at. Nothing was written, so no
            // `onChange(of: provider.path)` is coming to do it — and leaving the refused text in
            // place would show a Location this source does not have.
            refusedDuplicateOwner = settings.availableProviders
                .first { $0.id == existingId }
                .map { "\($0.displayName)'s folder" } ?? "another source's folder"
            pathDraft.adopt(provider.path)
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
    /// Pasted values often arrive with a trailing space or newline (terminal copies, drag-outs).
    /// A path stored verbatim with trailing whitespace fails validation and scans empty with no
    /// visual hint — the badge just goes red — so both fields trim whitespace and newlines alike.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a commit should actually write. Both fields now commit on Return *and* on
    /// focus-loss (one shared model), so an unchanged blur must be a no-op: committing is
    /// gated on the normalized draft differing from the currently stored value.
    static func shouldCommit(draft: String, committed: String) -> Bool {
        normalized(draft) != committed
    }
}

/// The Location field's draft text, modeled as a value so its lifecycle — adopting an external
/// discovery change, and repopulating after "Reset" — is decided in one testable place instead of
/// inline in three SwiftUI closures.
///
/// It exists because "Reset" got that lifecycle wrong in a way no view-level reasoning caught. It
/// used to blank the draft and lean on `onChange(of: provider.path)` to refill it. That refresh
/// only fires when the published path actually CHANGES — and resetting a provider that has NO
/// override removes a defaults key that was never there, so nothing changed, nothing refreshed,
/// and the Location field simply sat empty. A later focus-blur then committed that empty string,
/// which `SettingsManager.setPath` records as "User cleared custom path mapping" for a provider
/// that never had one: a misleading log line and a pointless rediscovery pass.
struct ProviderPathDraft: Equatable {
    /// The text currently in the field. A plain `var` because the `TextField` binds straight to it.
    var value: String = ""

    /// What "Reset" put in the field, held until the rediscovery it kicked off lands — or `nil`
    /// when no reset is outstanding. Stored as the TEXT rather than a bool so it self-clears: the
    /// `TextField` binds straight to `value`, so typing is invisible to this type, and the only
    /// way to tell "still showing what Reset left" from "the user has since typed over it" is to
    /// compare. See `reset(toEffective:)` for why the distinction decides who wins.
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
    /// The one exception is the rediscovery the user's own "Reset" started. That refresh is not a
    /// background pass racing their typing, it is the ANSWER to the button they just pressed —
    /// and clicking a macOS button does not blur the text field, so it arrives with
    /// `isEditing: true` and the ordinary guard would decline it. Declining it is what re-committed
    /// the cleared override on the next blur (see `reset(toEffective:)`). The exception is narrow:
    /// it applies only while the field still shows exactly what Reset left there, so a user who
    /// started typing a replacement path keeps their draft, as always.
    mutating func adoptExternalChange(to updated: String, isEditing: Bool) {
        let isResetLanding = textAwaitingReset == value
        guard !isEditing || isResetLanding else { return }
        textAwaitingReset = nil
        guard value != updated else { return }
        value = updated
    }

    /// "Reset" was pressed. Echo the provider's effective path rather than blanking the field:
    /// with no override in play that value already IS the default and no refresh is coming, and
    /// with one in play it is replaced by `adoptExternalChange` the moment the async rediscovery
    /// lands. Either way the field never shows an empty path the user didn't type.
    ///
    /// Remembering that echoed text is what makes Reset actually stick when an override WAS in
    /// play. `SettingsManager.resetPath` rediscovers asynchronously, so the effective path echoed
    /// here is still the old override; if the correction that follows is declined for being
    /// mid-edit, the field keeps showing the override and the blur commits it straight back —
    /// `shouldCommit(draft: oldOverride, committed: default)` is true, so `setPath` restores the
    /// very override the user just cleared. (The pre-refactor code escaped that only because its
    /// draft was `""`, i.e. by way of the blank-field bug this type exists to fix.)
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
/// A `Picker` whose selection matches none of its `.tag` values renders with NOTHING selected while
/// that value stays fully in effect behind it: the scan really is using a 3-second tolerance, the
/// picker just refuses to say so. Worse, the control is then one click from destroying it — the
/// user's first interaction with a blank-looking picker replaces a setting they never knowingly
/// chose. Off-list values are not hypothetical: an older build's option set, a `defaults write`, or
/// a hand-edited plist all produce them.
///
/// The answer is to SHOW the stored value, not to coerce it. Snapping to the nearest offered option
/// is the same destruction one click earlier, just silent. The adjacent Cloud-model picker can map
/// a superseded model id onto its family's current one because that equivalence genuinely exists;
/// no such equivalence exists between two numbers, so these pickers take the other honest route —
/// one extra row carrying the stored value, labeled by the same formatter as its neighbours and
/// sorted into place so the list still reads as a scale.
///
/// Labels are *derived* from those formatters rather than spelled per row, for the same reason
/// `CloudFilingProtocol.selectableModelOptions` is one list and not two: the extra row and the
/// fixed rows cannot then drift into two different vocabularies for the same quantity.
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

    /// A number without a pointless ".0" tail. Guarded on finiteness and Int range because the
    /// value can arrive from `defaults write`, which will happily store 1e300 or a NaN.
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
    @AppStorage(GeneralSettings.confirmBeforeDeleteKey) private var confirmBeforeDelete: Bool = true
    @AppStorage(GeneralSettings.confirmBeforeTransferKey) private var confirmBeforeTransfer: Bool = true
    @State private var patternDraft = ""

    var body: some View {
        SettingsPage {
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
                }
            }

            SettingsSection(
                "Comparison",
                caption: "Cloud providers round file dates on upload; a small tolerance hides those false differences. Verification checksums same-size pairs that only differ by date and hides identical ones — thorough, but slower on large folders."
            ) {
                // Rows come from `SettingsPickerOptions`, which widens the list with the stored
                // value when it isn't one of them — a tolerance left by an older build or a
                // `defaults write` shows itself rather than leaving the picker blank while
                // silently governing every scan. Same treatment as the four other numeric
                // pickers; see that type for why showing beats coercing.
                SettingsRow("Treat dates as equal within") {
                    Picker("Treat dates as equal within", selection: $settings.dateToleranceSeconds) {
                        ForEach(SettingsPickerOptions.dateTolerance(including: settings.dateToleranceSeconds)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(isOn: $settings.autoVerifySameSizeDuringScan) {
                    Text("Verify same-size files during scans")
                }
                Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                    Text("Ignore \"newer on Google Drive\" when same size")
                }
            }

            SettingsSection(
                "Confirmations",
                caption: "Copies and moves first show what will be transferred and where; turning this off starts them immediately, including moves, with no confirmation. Deleted items go to the Trash either way and can be restored with Undo."
            ) {
                Toggle("Confirm before copying or moving", isOn: $confirmBeforeTransfer)
                Toggle("Confirm before deleting", isOn: $confirmBeforeDelete)
            }

            SettingsSection(
                "Ignored items",
                caption: "Items you ignore from the Differences list are kept here per provider pair. Remove one to see its differences again."
            ) {
                Toggle(isOn: $settings.rememberIgnoredItems) {
                    Text("Remember ignored items across rescans")
                }
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
                    }
                }
                HStack(spacing: 8) {
                    TextField("*.tmp, .DS_Store, node_modules", text: $patternDraft)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.system(.callout, design: .monospaced))
                        .onSubmit(addPattern)
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
private struct IgnoredItemsList: View {
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
                }
            }
            HStack {
                Spacer()
                Button("Clear All", role: .destructive, action: onClear)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Duplicates

/// How a duplicate scan decides what counts as a match. Three preferences and nothing else —
/// thin, and honestly so: this is the first place anyone hunting for the overlap threshold looks.
///
/// Split out of the old Tidy tab along with `FilingSettingsTab`. Tidy was one tab holding the
/// preferences of two workspaces that stopped sharing a home when the workspace bar went flat
/// (Compare · Organize · Duplicates · Automations · Storage), under a word the rest of the
/// product had already retired. The rule the split follows is *settings go where the work is*,
/// not one tab per workspace — Automations, Storage and Compare get no tab because they have no
/// preferences to put in one.
struct DuplicatesSettingsTab: View {
    // The `tidy` prefixes are the DEFAULTS KEYS' ("tidyMinFileSize" and friends, owned by
    // `DuplicateFinderOptions.DefaultsKey`), mirrored deliberately. The keys are a persistence
    // format and did not move with the tab; a local name that stopped matching its key would be
    // the first thing to mislead someone chasing a stored value.
    @AppStorage(DuplicateFinderOptions.DefaultsKey.minFileSize) private var tidyMinFileSize: Int = 4096
    @AppStorage(DuplicateFinderOptions.DefaultsKey.overlapThreshold) private var tidyOverlapThreshold: Double = 0.7
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectVersions) private var tidyDetectVersions: Bool = true

    var body: some View {
        SettingsPage {
            // Titleless, keeping the caption: the rail row above already says "Duplicates", and a
            // lone section header repeating it would read as a subdivision of a tab that has none
            // — the same redundancy that cost the Filing header its name over on Organize. The
            // caption carried the actual explanation and is unchanged.
            SettingsSection(
                caption: "How Find Duplicates groups results. Identical detection is always checksum-verified; the overlap threshold decides when same-named folders read as overlapping vs unrelated. Changes apply on the next scan."
            ) {
                // Both row lists come from `SettingsPickerOptions` so a stored value outside the
                // offered set still displays (and survives) instead of rendering as no selection.
                SettingsRow("Ignore files smaller than") {
                    Picker("Ignore files smaller than", selection: $tidyMinFileSize) {
                        ForEach(SettingsPickerOptions.minFileSize(including: tidyMinFileSize)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Folders overlap at") {
                    Picker("Folders overlap at", selection: $tidyOverlapThreshold) {
                        ForEach(SettingsPickerOptions.overlapThreshold(including: tidyOverlapThreshold)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Detect versions (Report, Report (1), Report-final)", isOn: $tidyDetectVersions)
            }
        }
    }
}

// MARK: - Organize

/// Everything that changes what Organize suggests — on-device AI, the opt-in Claude cloud path
/// with its key and model, the loose-files inbox — plus the spend that cloud option can run up,
/// and the inventory of names the user has told Organize to stop offering to rename.
///
/// Cloud spend rides here rather than getting a Billing tab of its own: the caps exist because
/// Organize can call Claude, so they are *Organize's* money, and a second tab for one feature's
/// opt-in API key would be a third place to look for one workflow.
struct FilingSettingsTab: View {
    /// Only the kept-names list needs it, and only to reach `keptNamesStore`. Optional for the
    /// same reason every other tab's is: tests and previews build the tab without an engine.
    let syncManager: FileSyncManager?
    @AppStorage(FileSyncManager.readContentsDefaultsKey) private var filingReadContents: Bool = true
    @AppStorage(FileSyncManager.reuseVerdictsDefaultsKey) private var filingReuseVerdicts: Bool = true
    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true
    @AppStorage(FileSyncManager.usesCloudDefaultsKey) private var filingUseCloud: Bool = false
    // Default from the protocol, not a repeated literal: the classifier and the spend preflight both
    // fall back to `CloudFilingProtocol.defaultModel`, and a copy here would silently disagree with
    // them the next time the default model moves.
    @AppStorage(FileSyncManager.cloudModelDefaultsKey) private var filingCloudModel: String = CloudFilingProtocol.defaultModel
    @AppStorage(FileSyncManager.monthlyBudgetCapKey) private var monthlyBudgetUSD: Double = 0
    @AppStorage(FileSyncManager.totalBudgetCapKey) private var totalBudgetUSD: Double = FileSyncManager.defaultTotalBudgetCapUSD

    /// How many saved suggestions there are. Read on appear and after a clear rather than computed
    /// in `body`: answering it touches the cache file, and `body` runs far more often than the
    /// number changes.
    @State private var savedSuggestionCount = 0

    // Cloud spend, refreshed on appear and when the history sheet closes.
    @State private var spendTotals = FilingSpendTotals()
    @State private var spendLast: FilingSpendEntry?
    @State private var showSpendHistory = false

    var body: some View {
        SettingsPage {
            // "Filing" as a header no longer earns its keep — the tab above it is called
            // Organize, and this is the group that decides what Organize suggests. "Suggestions"
            // names the thing the rows change, and leaves "Cloud spend" below it reading as the
            // other half of the tab rather than as a subsection of filing.
            SettingsSection("Suggestions", content: {
                Toggle("Suggest folders with on-device AI (Apple Intelligence)", isOn: $filingUseAI)
                Toggle("Use Claude (cloud) for the best suggestions", isOn: $filingUseCloud)
                    .disabled(!filingUseAI)
                // Cloud filing rides on top of on-device AI (its toggle is disabled when AI is
                // off). Gate the key/model sub-panel on both flags so turning AI off doesn't
                // strand a live-looking cloud panel whose own toggle can no longer dismiss it.
                if filingUseCloud && filingUseAI {
                    CloudKeyRow()
                    // Read through `currentModel(for:)` so a value stored before a model refresh
                    // (e.g. "claude-opus-4-8") still lights up its family's row instead of leaving
                    // the picker blank — the scan resolves it the same way.
                    // "Cloud model" matches this row's entry in the search index above; the index
                    // documents that its titles mirror the on-screen labels, and "Model" alone did
                    // not. Rows come from `selectableModelOptions` rather than being spelled here,
                    // so ids and labels cannot drift out of step across a model refresh.
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
                    .help("Saved suggestions are per model — switching means the next scan asks, and pays for, every file again.")
                }
                Toggle("Read file contents on-device for better signals", isOn: $filingReadContents)
                Toggle("Reuse suggestions for files that haven’t changed", isOn: $filingReuseVerdicts)
                    .disabled(!filingUseAI)
                    .help("A file that hasn’t been edited, renamed, or moved gets the same suggestion it got last time, so scanning the same folder again doesn’t ask the model — or, with Claude, pay — a second time. Turning this off asks afresh every scan.")
                SettingsRow("Saved suggestions") {
                    HStack(spacing: 8) {
                        Text(savedSuggestionCount == 1 ? "1 file" : "\(savedSuggestionCount) files")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Clear") {
                            syncManager?.clearFilingVerdictCache()
                            // The non-awaiting read: `clearFilingVerdictCache` has just written the
                            // memo, so this cannot be the first load and cannot decode anything.
                            savedSuggestionCount = syncManager?.filingVerdictCacheCountNow ?? 0
                        }
                        .disabled(savedSuggestionCount == 0)
                    }
                }
                .help("Forget every saved suggestion. The next scan asks the model about each file again — with Claude, that means paying for them again.")
                SettingsRow("Loose-files inbox") {
                    TextField("TODO", text: $filingInbox)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                }
                .help("The folder (relative to the provider root) Organize scans for loose files by default — e.g. “TODO”. Navigate the source rail into another folder to scan that instead.")
                SettingsRow("Remembered rules") {
                    Text("Now live in the Automations workspace")
                        .foregroundStyle(.secondary)
                }
                .help("A rule you teach by correcting a suggestion is saved as an automation — review, edit, or delete it in the Automations workspace.")
            }, caption: {
                Text("Organize suggests where loose files belong. The on-device model (Apple Intelligence, macOS 26) runs free and private; where it isn’t available, Organize falls back to name/metadata matching. Claude (cloud) is the most accurate option but is opt-in and off by default and billed to your API key. To keep cost low it sends your folder names plus file names — and a short text excerpt only for files whose name says nothing — for up to 150 files per scan. Pick Haiku for the cheapest runs (roughly a penny a scan). The key is stored in the macOS Keychain. The corrections you ask Organize to remember are saved as automations (the Automations workspace). Changes apply on the next scan.")
            })

            SettingsSection(
                "Cloud spend",
                caption: "Before each cloud (Claude) scan you’ll see a cost estimate to confirm. Two caps pause cloud classification when a scan would push you past them: a monthly cap (Off by default) and a total lifetime cap (defaults to $5 as a safety backstop). Either one being reached falls back to the free on-device suggestions until you raise or turn it off. Costs are estimated from list prices for the cloud suggestions only (the Anthropic Console is authoritative); on-device and keyword suggestions are free."
            ) {
                // A cap is the one setting where a blank picker is actively dangerous: the stored
                // value keeps pausing (or not pausing) cloud scans regardless of what the control
                // shows, so an unrecognized cap has to be visible. Rows via `SettingsPickerOptions`.
                SettingsRow("Monthly budget cap") {
                    Picker("Monthly budget cap", selection: $monthlyBudgetUSD) {
                        ForEach(SettingsPickerOptions.monthlyBudget(including: monthlyBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Total budget cap") {
                    Picker("Total budget cap", selection: $totalBudgetUSD) {
                        ForEach(SettingsPickerOptions.totalBudget(including: totalBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Total spent") { Text(FilingSpendFormat.cost(spendTotals.costUSD)) }
                SettingsRow("Tokens") { Text(FilingSpendFormat.tokens(spendTotals.tokens)) }
                SettingsRow("Cloud scans") { Text("\(spendTotals.scans)") }
                if let last = spendLast {
                    SettingsRow("Last scan") {
                        Text("\(FilingSpendFormat.model(last.model)) · \(last.fileCount) files · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                    }
                }
                HStack {
                    Button("View history…") { showSpendHistory = true }
                        .disabled(spendTotals.scans == 0)
                    Button("Clear", role: .destructive) { FilingSpendStore.clear(); refreshSpend() }
                        .disabled(spendTotals.scans == 0)
                }
                .controlSize(.small)
            }

            // Last, below Cloud spend, rather than between it and Suggestions: those two are one
            // subject (what Organize suggests, and what the cloud option costs to suggest it), and
            // the header comment above turns on them reading as the two halves of this tab. Kept
            // names is the other lens — the rename finding — so it goes after both rather than
            // splitting them. Being at the bottom of a long tab is what the search index answers.
            SettingsSection(
                "Kept names",
                caption: "Names you kept with “Always Allow This Name” after SyncCloud flagged them as ones a cloud provider may mishandle — a trailing space, a forbidden character, and so on. A kept name draws no badge anywhere it is listed, and Organize never offers to rename it. Kept names are matched exactly, so the decision covers every file with that name and follows it when it moves. Remove one to have it reported again; the files themselves are never touched either way."
            ) {
                if let store = syncManager?.keptNamesStore {
                    KeptNamesList(store: store)
                } else {
                    // No engine attached (tests, previews). The list would say the same thing an
                    // empty store does, so say it rather than leaving the caption over a void.
                    KeptNamesList.nothingKeptNote
                }
            }
        }
        .onAppear(perform: refreshSpend)
        // The store's change signal — the Organize lens's history sheet (main window) can Clear
        // History while this tab is open in the Settings window, and a scan can record spend
        // mid-view. Mirrors TidyView's observer; `receive(on:)` because `record` posts from off
        // the main actor.
        .onReceive(NotificationCenter.default.publisher(for: FilingSpendStore.didChange)
            .receive(on: DispatchQueue.main)) { _ in refreshSpend() }
        // The saved-suggestion count is asked SEPARATELY from the spend figures, and awaited.
        // Folding it into `refreshSpend` — which is what this did — put a decode of a file that
        // reaches ~12 MB at the entry cap on the main actor the moment this tab appeared. The two
        // spend reads are small `UserDefaults` blobs and stay where they are.
        .task { savedSuggestionCount = await syncManager?.filingVerdictCacheCount() ?? 0 }
        .sheet(isPresented: $showSpendHistory, onDismiss: refreshSpend) {
            FilingSpendHistorySheet()
        }
    }

    private func refreshSpend() {
        spendTotals = FilingSpendStore.totals()
        spendLast = FilingSpendStore.last()
    }

}

/// The kept-names rows inside the Organize tab: one name per entry with a remove button, plus
/// Clear All — the inventory of "I meant that name" decisions, which until now could only be read
/// back by walking your files. A kept name draws no badge, so there was nothing on screen leading
/// anywhere; this is the only place the whole set is visible at once.
///
/// Split out so it can observe ``KeptNamesStore`` directly. `FileSyncManager` holds the store
/// behind a plain `var`, not a `@Published` one, so a view watching only the manager does not
/// repaint when the set changes — the manager's `keptNamesStore` didSet sends `objectWillChange`
/// by hand for exactly that reason, and this view does not rely on it.
///
/// Internal rather than `private`, unlike its `IgnoredItemsList` neighbour, so the tests can call
/// `remove(_:)` and `clearAll()` — the two methods the buttons call — against a real store on an
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
                }
            }
            HStack {
                Spacer()
                Button("Clear All", role: .destructive, action: clearAll)
                    .controlSize(.small)
            }
        }
    }

    /// Withdraw one keep. Straight to the store, exactly as the row menu's "Stop Allowing This
    /// Name" does: the store is the single mutation point, and `FileSyncManager` subscribes to it
    /// for the announcement and the `riskyNames` reconciliation. Routing this through a manager
    /// method instead would be a second door onto the same latch.
    func remove(_ name: String) { store.stopKeeping(name) }

    /// Withdraw every keep. One store call rather than a loop over `remove(_:)`, so the manager
    /// re-filters its finding once.
    func clearAll() { store.stopKeepingAll() }

    /// Shown by an empty store, and by a tab built without an engine attached.
    static var nothingKeptNote: some View {
        Text("No kept names. Right-click a file with a flagged name and choose Always Allow This Name to keep it.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }
}

/// A kept name with its invisible characters made visible — an affix space as "␣", a zero-width
/// scalar as "◌", both tinted.
///
/// Not a plain `Text`: every name in this list is here *because* something about it is risky, and a
/// whole class of those offences is invisible in a proportional face. "report " and "report" would
/// render identically, in the one view whose entire job is telling the user what they kept. The
/// rule is ``InvisibleNameMarking``, shared with the Rename lens's card so the two cannot disagree
/// about how many trailing spaces a name has.
private struct KeptNameLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(InvisibleNameMarking.cells(for: name).enumerated()), id: \.offset) { _, cell in
                if cell.isMarker {
                    // Caution, matching the Rename lens's markers and the risky-names pill — the
                    // whole risky-name vocabulary sits in one tier.
                    Text(cell.glyph)
                        .foregroundStyle(SemanticColor.caution)
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
                Text("Cloud Filing Spend").scaledFont(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).shortcutKeycap("⏎")
            }
            .padding()
            Divider()
            HStack(spacing: 24) {
                stat(FilingSpendFormat.cost(totals.costUSD), "total")
                stat(FilingSpendFormat.tokens(totals.tokens), "tokens")
                stat("\(totals.scans)", "cloud scans")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            Divider()
            if entries.isEmpty {
                EmptyStateView(
                    icon: "cloud",
                    title: "No cloud scans yet",
                    layout: .compact
                )
            } else {
                List(entries.reversed()) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).scaledFont(.system(size: 12))
                            Text("\(FilingSpendFormat.model(entry.model)) · \(entry.fileCount) files · placed \(entry.placedCount)")
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

/// Logging, maintenance, and the settings reset — the machinery that already existed in the
/// engine but had no user-facing surface.
struct AdvancedSettingsTab: View {
    let syncManager: FileSyncManager?
    let onResetAllSettings: (() -> Void)?

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
                        Logger.shared.minimumLevel = LogLevel(rawValue: raw) ?? .debug
                    }
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
                        Button("Clear Log") {
                            Logger.shared.clearLogs()
                            Task { await refreshLogFileSize() }
                        }
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                "Maintenance",
                caption: "Interrupted copies can leave .tmp_ working files behind; they're moved to the Trash automatically once they're an hour old. Recovery backups (.rollback_) are never touched."
            ) {
                SettingsRow("Orphaned temporary files") {
                    Button("Sweep Now") {
                        syncManager?.sweepOrphanedTempArtifactsNow()
                    }
                    .controlSize(.small)
                    .disabled(syncManager == nil)
                }
            }

            // The two scan caches the app writes to Application Support that had no readout and no
            // way to clear them. Saved suggestions is the third and stays in Organize, where the
            // toggles that decide what it keys on live; these two belong beside the log file,
            // because what a user wants from them is "how much is this storing, and make it stop".
            //
            // Sizes rather than entry counts: a `stat` each, where a count would mean parsing the
            // largest file this app writes — on the main actor, on a tab appearing.
            SettingsSection(
                "Saved scan data",
                caption: "Kept so a rescan doesn't repeat work it already did. Clearing costs time on the next scan and nothing else — your files aren't affected, and neither are your saved suggestions (Organize)."
            ) {
                SettingsRow("File digests") {
                    HStack(spacing: 8) {
                        Text(hashIndexSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                await ContentHashCache.shared.forgetPersistedIndex()
                                // The barrier is a blocking `writeQueue.sync`, and this Task runs
                                // on the main actor — parked behind a queued multi-megabyte index
                                // write (a Verify save that just fired, say) it is a beachball.
                                // Detached, the wait happens where blocking is free.
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
                .help("Checksums of files Duplicates and Verify have already read, so unchanged files aren't read again. Clearing means the next scan re-reads them.")

                SettingsRow("Saved Storage reports") {
                    HStack(spacing: 8) {
                        Text(storageLensSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            syncManager?.forgetStoredStorageLens()
                            Task {
                                // Off the main actor for the same reason as the digests' Clear
                                // above — the barrier blocks on the store's write queue.
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

            if let onResetAllSettings {
                SettingsSection(
                    caption: "Restores defaults for appearance, sync behavior, and source names and paths, and clears the folders you added as sources. Your files aren't affected."
                ) {
                    Button("Reset All Settings…", role: .destructive) {
                        confirmReset(onResetAllSettings)
                    }
                }
            }
        }
        .task { await refreshLogFileSize() }
        .task { await refreshSavedScanData() }
    }

    /// Stats the two saved-scan-data files. The hash index's size is asked of the cache actor
    /// rather than of the store, because only the actor knows whether persistence was enabled at
    /// all — a location the app injects and tests never do.
    private func refreshSavedScanData() async {
        let hashBytes = await ContentHashCache.shared.persistedSizeOnDisk()
        let storageBytes = syncManager?.storedStorageLensSizeOnDisk()
        // Zero-byte files read as "None": a store that has been cleared leaves an empty payload
        // behind in the Storage case, and offering Clear for 0 bytes is offering nothing.
        hashIndexSizeText = Self.sizeText(hashBytes)
        storageLensSizeText = Self.sizeText(storageBytes)
    }

    private static func sizeText(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Confirmation ahead of the defaults wipe; Cancel is the default button (Return must
    /// not reset, same convention as the permanent-delete alert).
    private func confirmReset(_ reset: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        // Names the folder list explicitly. "Files on disk are not affected" is true and used to be
        // the whole of the reassurance, which read as "nothing you care about is lost" while the
        // curated list of folder sources went with the defaults domain.
        alert.informativeText = "Appearance, sync behavior, ignored items, and source names and paths return to their defaults, and any folders you added as sources are removed from the list. Files on disk are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if let resetButton = alert.buttons.first {
            resetButton.hasDestructiveAction = true
            resetButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn {
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
