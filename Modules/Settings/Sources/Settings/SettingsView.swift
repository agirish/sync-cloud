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
        case tidy
        case advanced

        /// The human-readable tab name shown in the picker and as the dim subtitle on a search
        /// result. Kept here so the labels have a single source of truth.
        public var displayName: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .providers: return "Providers"
            case .sync: return "Sync"
            case .tidy: return "Tidy"
            case .advanced: return "Advanced"
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

    public init(
        selection: Binding<SettingsTab>,
        onClose: @escaping () -> Void,
        syncManager: FileSyncManager? = nil,
        onResetAllSettings: (() -> Void)? = nil
    ) {
        _selectedTab = selection
        self.onClose = onClose
        self.syncManager = syncManager
        self.onResetAllSettings = onResetAllSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                CloseButton(action: onClose)
                    // Escape closes the overlay even when focus is elsewhere in the card.
                    .keyboardShortcut(.cancelAction)
                    .help("Close settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search across every tab by name — the System Settings pattern. Typing here
            // replaces the tab content with matching settings; picking one jumps to its tab.
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // A segmented picker rather than a TabView: a plain TabView (outside the native
            // Settings scene) hoists its tab bar into the window toolbar. This keeps the tabs
            // inside the overlay card.
            Picker("Settings section", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            // While searching, the results are the content; leave the picker visible so the
            // current tab stays in view, but it isn't the thing being browsed.
            .disabled(isSearching)

            Divider()

            Group {
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
                    case .tidy:
                        TidySettingsTab(syncManager: syncManager)
                    case .advanced:
                        AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 560)
    }

    /// The header search box: a magnifier, a plain text field, and a clear button that shows
    /// once there's text. Styled as a rounded field so it reads as "search" without the native
    /// `.searchable` machinery, which is meant for navigation stacks rather than an overlay card.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search settings", text: $searchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .searchFieldSurface()
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

/// The catalog of settings the header search can jump to, one entry per user-facing control
/// across all six tabs. Titles mirror the on-screen labels; keywords add the words people are
/// likely to type instead (synonyms, the value names, the feature they're after). This is the
/// single place to keep in sync when a control is added or renamed.
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
        .init(tab: .appearance, title: "List density",
              keywords: ["density", "compact", "comfortable", "row height", "spacing", "tighter rows", "row size"]),

        // Providers
        .init(tab: .providers, title: "Discovered providers",
              keywords: ["providers", "cloud", "discover", "refresh", "cloudstorage"]),
        .init(tab: .providers, title: "Provider name",
              keywords: ["rename", "name", "provider name", "custom name", "label"]),
        .init(tab: .providers, title: "Synchronized path",
              keywords: ["path", "location", "root", "folder", "directory", "sync path", "browse"]),
        .init(tab: .providers, title: "Enable or disable a provider",
              keywords: ["enable", "disable", "show", "hide", "sidebar", "toggle provider"]),

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

        // Tidy
        .init(tab: .tidy, title: "Ignore files smaller than",
              keywords: ["minimum size", "min file size", "small files", "duplicates", "threshold size"]),
        .init(tab: .tidy, title: "Folders overlap at",
              keywords: ["overlap", "threshold", "folder overlap", "percent", "duplicates"]),
        .init(tab: .tidy, title: "Detect versions",
              keywords: ["versions", "final", "copy", "report (1)", "variants", "duplicates"]),
        .init(tab: .tidy, title: "Suggest folders with on-device AI",
              keywords: ["filing", "apple intelligence", "on-device ai", "suggestions", "suggest folders", "sort files"]),
        .init(tab: .tidy, title: "Use Claude (cloud) for the best suggestions",
              keywords: ["claude", "cloud", "anthropic", "cloud filing", "ai"]),
        .init(tab: .tidy, title: "Anthropic API key",
              keywords: ["api key", "key", "keychain", "sk-ant", "anthropic key", "token"]),
        .init(tab: .tidy, title: "Cloud model",
              keywords: ["model", "haiku", "sonnet", "opus", "claude model"]),
        .init(tab: .tidy, title: "Read file contents on-device for better signals",
              keywords: ["read contents", "content signals", "ocr", "text", "pdf", "vision"]),
        .init(tab: .tidy, title: "Remembered rules",
              keywords: ["filing rules", "rules", "remembered rules", "manage rules", "automation", "automations"]),
        .init(tab: .tidy, title: "Cloud spend",
              keywords: ["spend", "cost", "tokens", "billing", "usage", "money", "price"]),
        .init(tab: .tidy, title: "Monthly budget cap",
              keywords: ["budget", "cap", "limit", "monthly", "spend limit", "cost cap", "guardrail", "pause cloud", "money"]),
        .init(tab: .tidy, title: "Total budget cap",
              keywords: ["budget", "cap", "limit", "total", "lifetime", "spend limit", "cost cap", "guardrail", "pause cloud", "money", "backstop"]),

        // Advanced
        .init(tab: .advanced, title: "Log level",
              keywords: ["log", "logging", "debug", "verbosity", "log level", "info", "warnings", "errors"]),
        .init(tab: .advanced, title: "Log file",
              keywords: ["log file", "logs", "clear log", "show log"]),
        .init(tab: .advanced, title: "Sweep orphaned temporary files",
              keywords: ["orphan", "temp files", "tmp", "sweep", "maintenance", "cleanup", "clean up"]),
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
                                        .font(.caption)
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
    /// The last toggle value known to match the actual service state. `onChange` skips
    /// values equal to it, so programmatic sets (the initial `.task` read, a failure
    /// revert) don't trigger another register/unregister round-trip.
    @State private var lastAppliedLaunchAtLogin: Bool?
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
        Form {
            Section {
                Toggle("Launch SyncCloud at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != lastAppliedLaunchAtLogin else { return }
                        updateLoginItem(enabled)
                    }
            } footer: {
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

            Section {
                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
                Toggle("Reopen panes where I left off", isOn: $restoreLastFocus)
                Picker("Sort panes by", selection: $settings.defaultSortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Panes reopen at the folders they showed when you last quit (falling back to the root if a folder is gone). Sort changes made from the pane menus are remembered here too.")
            }

            Section {
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
            } footer: {
                if notifyInBackground && notificationsDenied {
                    Text("Notifications are disabled in System Settings — allow SyncCloud under Notifications to see these alerts.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn't the active app. Requires notification permission.")
                }
            }

            Section {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
            } footer: {
                Text("Shows a confirmation if you try to quit while a copy, move, or delete is still running.")
            }
        }
        .formStyle(.grouped)
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
    private func readLoginItemState() {
        Task {
            applyLoginItemState(await Self.readStatusOffMain())
        }
    }

    /// Publishes a freshly read service status to the view state. Setting
    /// `lastAppliedLaunchAtLogin` in the same main-actor turn as the toggle keeps `onChange`
    /// from treating the programmatic set as a user gesture (initial read, failure revert).
    private func applyLoginItemState(_ status: SMAppService.Status) {
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        lastAppliedLaunchAtLogin = launchAtLogin
    }

    /// Registers/unregisters the login item, reverting the toggle to the real service state on
    /// failure so the UI never claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        Task {
            do {
                let needsApproval = try await Self.applyLoginItemOffMain(enabled)
                lastAppliedLaunchAtLogin = enabled
                loginItemNeedsApproval = needsApproval
                if needsApproval {
                    Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
                }
                // The toggle can move again while the round-trip is in flight; that flip's
                // onChange compared against the OLD lastApplied value and was suppressed, so
                // apply the latest position now that the echo marker is up to date.
                if launchAtLogin != enabled {
                    updateLoginItem(launchAtLogin)
                }
            } catch {
                Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
                applyLoginItemState(await Self.readStatusOffMain())
            }
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

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
    }

    private var selectedSurfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Theme")
            } footer: {
                Text(appearanceMode.detail)
            }

            Section("Accent color") {
                // Twelve hues share this row; the tighter spacing gives each swatch more room.
                HStack(spacing: 5) {
                    ForEach(LiquidGlassHue.allCases) { hue in
                        HueOptionView(
                            hue: hue,
                            isSelected: selectedHue == hue,
                            action: { selectedHueRaw = hue.rawValue }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                Picker("Glass effect", selection: $glassLevelRaw) {
                    ForEach(GlassLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Glass effect")
            } footer: {
                Text(glassLevel.detail)
            }

            Section {
                HStack(spacing: 12) {
                    Slider(value: $surfaceTint, in: 0.0...1.0) {
                        Text("Tint")
                    } minimumValueLabel: {
                        Text("Subtle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    } maximumValueLabel: {
                        Text("Vivid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .accessibilityValue("\(Int(surfaceTint * 100)) percent")
                    .disabled(selectedHue == .none)
                    Text("\(Int(surfaceTint * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } footer: {
                Text(selectedHue == .none
                     ? "Choose an accent color above to tint the panes and Differences area."
                     : "Washes the panes and Differences area with the accent color chosen above.")
            }

            Section {
                Picker("Content surface", selection: $surfaceStyleRaw) {
                    ForEach(SurfaceStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Content surface")
            } footer: {
                Text(selectedSurfaceStyle.detail)
            }

            Section {
                Picker("List density", selection: $listDensityRaw) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.displayName).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("List density")
            } footer: {
                Text("Comfortable keeps the standard spacing. Compact tightens rows in lists throughout SyncCloud — the file panes, the Compare table, every Tidy lens, and the Activity Log and Sync History windows — so more fits on screen.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A selectable hue option for the liquid glass accent color.
private struct HueOptionView: View {
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
                            .font(.system(size: 13, weight: .semibold))
                            // The checkmark sits on the swatch's own fill, so it pairs with that
                            // fill's luminance — hardcoded white was ~2.1:1 on amber. "None" has no
                            // fill of its own (a neutral disc deferring to the system accent), so it
                            // tracks the appearance via `.primary` like the disc does.
                            .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
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

// MARK: - Providers

/// Discovered cloud providers: enable/disable each, and configure its synchronized root path.
struct ProvidersSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var isRefreshingProviders = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Discovered providers")
                        .font(.body.weight(.medium))
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
            } footer: {
                Text("Providers are discovered from ~/Library/CloudStorage. Disabled providers stay configured but are hidden from the pane sidebar. At least one provider must remain enabled.")
            }

            ForEach(settings.availableProviders) { provider in
                ProviderSettingsSection(provider: provider)
            }
        }
        .formStyle(.grouped)
    }

    private func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        Task {
            await settings.discoverProviders()
            await MainActor.run { isRefreshingProviders = false }
        }
    }
}

/// One provider's rows: identity + enable switch, then its root-path configuration.
struct ProviderSettingsSection: View {
    let provider: CloudProvider
    @EnvironmentObject var settings: SettingsManager
    @State private var draftPath: String = ""
    @State private var draftName: String = ""
    // Both editable fields share one commit model: Return or focus-loss commits,
    // so each needs its own focus state to observe its own blur.
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var pathFieldFocused: Bool

    private var isEnabled: Bool {
        settings.isEnabled(provider.id)
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(provider.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    // The name itself is the rename affordance: click to edit in place.
                    // Enter or clicking away commits; emptying it restores the default.
                    // labelsHidden keeps the grouped Form from rendering a leading
                    // "Provider name" label and right-aligning the value; the name
                    // must sit in place of the title, next to the icon.
                    TextField("Provider name", text: $draftName)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.body.weight(.medium))
                        .focused($nameFieldFocused)
                        .onSubmit { commitName() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commitName() }
                        }
                        .help("Click to rename. Clear the name to restore the default.")
                    Text(provider.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            ? "At least one provider must remain enabled."
                            : "Show \(provider.displayName) in the pane sidebar."
                    )
            }
            .padding(.vertical, 2)
            .onAppear {
                draftPath = provider.path
                draftName = provider.displayName
            }
            .onChange(of: provider.path) { _, updated in
                // Adopt an external (discovery) change to the published value only when the user
                // isn't actively editing this field — otherwise a concurrent discoverProviders()
                // pass would silently discard their uncommitted draft.
                if !pathFieldFocused && draftPath != updated {
                    draftPath = updated
                }
            }
            .onChange(of: provider.displayName) { _, updated in
                if !nameFieldFocused && draftName != updated {
                    draftName = updated
                }
            }

            LabeledContent("Location") {
                // Mirrors the name field above: Enter or clicking away commits.
                // No Save button — focus-loss covers the same ground, so the two
                // fields commit through one identical set of triggers.
                TextField("Synchronized path", text: $draftPath)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .labelsHidden()
                    .focused($pathFieldFocused)
                    .onSubmit { commitPath() }
                    .onChange(of: pathFieldFocused) { _, focused in
                        if !focused { commitPath() }
                    }
            }
            .disabled(!isEnabled)

            HStack(spacing: 8) {
                Button("Browse…") { selectDirectory() }
                Button("Reset") { resetToDefault() }
                Button("Show in Finder") { openInFinder() }
                Spacer()
            }
            .controlSize(.small)
            .disabled(!isEnabled)
        }
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
                draftPath = url.path
                commitPath()
            }
        }
    }

    private func resetToDefault() {
        draftPath = ""
        settings.resetPath(for: provider.id)
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: (provider.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // Both fields commit on Return AND on focus-loss (one shared model), so a blur that
    // lands on an unchanged value must be a harmless no-op — hence both guard on
    // ProviderFieldEdit.shouldCommit before writing.
    private func commitPath() {
        let normalized = ProviderFieldEdit.normalized(draftPath)
        draftPath = normalized
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.path) else { return }
        settings.setPath(normalized, for: provider.id)
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
        Form {
            Section {
                Picker("When a file already exists", selection: $settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            } header: {
                Text("Conflicts")
            } footer: {
                Text("Applies to copies, moves, and syncs. Keep both renames the incoming file; Replace moves the existing file to the Trash first. Folder conflicts always ask.")
            }

            Section {
                Picker("Treat dates as equal within", selection: $settings.dateToleranceSeconds) {
                    Text("Exact match").tag(0.0)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("1 minute").tag(60.0)
                }
                Toggle(isOn: $settings.autoVerifySameSizeDuringScan) {
                    Text("Verify same-size files during scans")
                }
                Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                    Text("Ignore \"newer on Google Drive\" when same size")
                }
            } header: {
                Text("Comparison")
            } footer: {
                Text("Cloud providers round file dates on upload; a small tolerance hides those false differences. Verification checksums same-size pairs that only differ by date and hides identical ones — thorough, but slower on large folders.")
            }

            Section {
                Toggle("Confirm before copying or moving", isOn: $confirmBeforeTransfer)
                Toggle("Confirm before deleting", isOn: $confirmBeforeDelete)
            } header: {
                Text("Confirmations")
            } footer: {
                Text("Copies and moves first show what will be transferred and where; turning this off starts them immediately, including moves, with no confirmation. Deleted items go to the Trash either way and can be restored with Undo.")
            }

            Section {
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
            } header: {
                Text("Ignored items")
            } footer: {
                Text("Items you ignore from the Differences list are kept here per provider pair. Remove one to see its differences again.")
            }

            Section {
                ForEach(settings.ignorePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .font(.system(.callout, design: .monospaced))
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
                        .font(.system(.callout, design: .monospaced))
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern)
                        .disabled(IgnoreRules.normalized(patternDraft) == nil)
                }
            } header: {
                Text("Ignored name patterns")
            } footer: {
                Text("Hides any item whose name matches a pattern, at any depth, in every comparison. * matches any run of characters and ? matches one.")
            }
        }
        .formStyle(.grouped)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.sortedPaths, id: \.self) { path in
                HStack {
                    Text(path)
                        .font(.system(.callout, design: .monospaced))
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

// MARK: - Tidy

/// Everything for the Tidy workspace: how Find Duplicates groups, how Filing suggests homes
/// (on-device AI + opt-in Claude cloud with its key/model), remembered rules, and cloud spend.
struct TidySettingsTab: View {
    let syncManager: FileSyncManager?

    @AppStorage(DuplicateFinderOptions.DefaultsKey.minFileSize) private var tidyMinFileSize: Int = 4096
    @AppStorage(DuplicateFinderOptions.DefaultsKey.overlapThreshold) private var tidyOverlapThreshold: Double = 0.7
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectVersions) private var tidyDetectVersions: Bool = true
    @AppStorage(FileSyncManager.readContentsDefaultsKey) private var filingReadContents: Bool = true
    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true
    @AppStorage(FileSyncManager.usesCloudDefaultsKey) private var filingUseCloud: Bool = false
    // Default from the protocol, not a repeated literal: the classifier and the spend preflight both
    // fall back to `CloudFilingProtocol.defaultModel`, and a copy here would silently disagree with
    // them the next time the default model moves.
    @AppStorage(FileSyncManager.cloudModelDefaultsKey) private var filingCloudModel: String = CloudFilingProtocol.defaultModel
    @AppStorage(FileSyncManager.monthlyBudgetCapKey) private var monthlyBudgetUSD: Double = 0
    @AppStorage(FileSyncManager.totalBudgetCapKey) private var totalBudgetUSD: Double = FileSyncManager.defaultTotalBudgetCapUSD

    @State private var apiKeyField: String = ""
    @State private var hasStoredKey = false
    @State private var testingKey = false
    @State private var keyTestResult: AnthropicKeyCheck.Result?
    // Cloud spend, refreshed on appear and when the history sheet closes.
    @State private var spendTotals = FilingSpendTotals()
    @State private var spendLast: FilingSpendEntry?
    @State private var showSpendHistory = false

    var body: some View {
        Form {
            Section {
                Picker("Ignore files smaller than", selection: $tidyMinFileSize) {
                    Text("No minimum").tag(0)
                    Text("4 KB").tag(4096)
                    Text("100 KB").tag(102_400)
                    Text("1 MB").tag(1_048_576)
                }
                Picker("Folders overlap at", selection: $tidyOverlapThreshold) {
                    Text("50%").tag(0.5)
                    Text("60%").tag(0.6)
                    Text("70%").tag(0.7)
                    Text("80%").tag(0.8)
                    Text("90%").tag(0.9)
                }
                Toggle("Detect versions (Report, Report (1), Report-final)", isOn: $tidyDetectVersions)
            } header: {
                Text("Duplicates")
            } footer: {
                Text("How Find Duplicates groups results. Identical detection is always checksum-verified; the overlap threshold decides when same-named folders read as overlapping vs unrelated. Changes apply on the next scan.")
            }

            Section {
                Toggle("Suggest folders with on-device AI (Apple Intelligence)", isOn: $filingUseAI)
                Toggle("Use Claude (cloud) for the best suggestions", isOn: $filingUseCloud)
                    .disabled(!filingUseAI)
                // Cloud filing rides on top of on-device AI (its toggle is disabled when AI is
                // off). Gate the key/model sub-panel on both flags so turning AI off doesn't
                // strand a live-looking cloud panel whose own toggle can no longer dismiss it.
                if filingUseCloud && filingUseAI {
                    cloudKeyControls
                    // Read through `currentModel(for:)` so a value stored before a model refresh
                    // (e.g. "claude-opus-4-8") still lights up its family's row instead of leaving
                    // the picker blank — the scan resolves it the same way.
                    Picker("Model", selection: Binding(
                        get: { CloudFilingProtocol.currentModel(for: filingCloudModel) },
                        set: { filingCloudModel = $0 })) {
                        // Name the generation, not just the family — it's the only place the app
                        // says which Claude a scan will actually run on, and the families outlive
                        // their versions. Keep these in step with `selectableModels`' tags.
                        Text("Haiku 4.5 — cheapest (default)").tag("claude-haiku-4-5")
                        Text("Sonnet 5 — balanced").tag("claude-sonnet-5")
                        Text("Opus 5 — best quality").tag("claude-opus-5")
                    }
                }
                Toggle("Read file contents on-device for better signals", isOn: $filingReadContents)
                LabeledContent("Loose-files inbox") {
                    TextField("TODO", text: $filingInbox)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                }
                .help("The folder (relative to the provider root) Organize scans for loose files by default — e.g. “TODO”. Navigate the source rail into another folder to scan that instead.")
                LabeledContent("Remembered rules") {
                    Text("Now live in Tidy ▸ Automations")
                        .foregroundStyle(.secondary)
                }
                .help("A rule you teach by correcting a suggestion is saved as an automation — review, edit, or delete it in the Tidy tab's Automations lens.")
            } header: {
                Text("Filing")
            } footer: {
                Text("Filing suggests where loose files belong. The on-device model (Apple Intelligence, macOS 26) runs free and private; where it isn’t available, Filing falls back to name/metadata matching. Claude (cloud) is the most accurate option but is opt-in and off by default and billed to your API key. To keep cost low it sends your folder names plus file names — and a short text excerpt only for files whose name says nothing — for up to 150 files per scan. Pick Haiku for the cheapest runs (roughly a penny a scan). The key is stored in the macOS Keychain. The corrections you ask Filing to remember are saved as automations (Tidy ▸ Automations). Changes apply on the next scan.")
            }

            Section {
                Picker("Monthly budget cap", selection: $monthlyBudgetUSD) {
                    Text("Off (no limit)").tag(0.0)
                    Text("$1").tag(1.0)
                    Text("$5").tag(5.0)
                    Text("$10").tag(10.0)
                    Text("$25").tag(25.0)
                    Text("$50").tag(50.0)
                }
                Picker("Total budget cap", selection: $totalBudgetUSD) {
                    Text("Off (no limit)").tag(0.0)
                    Text("$5").tag(5.0)
                    Text("$10").tag(10.0)
                    Text("$25").tag(25.0)
                    Text("$50").tag(50.0)
                    Text("$100").tag(100.0)
                }
                LabeledContent("Total spent", value: FilingSpendFormat.cost(spendTotals.costUSD))
                LabeledContent("Tokens", value: FilingSpendFormat.tokens(spendTotals.tokens))
                LabeledContent("Cloud scans", value: "\(spendTotals.scans)")
                if let last = spendLast {
                    LabeledContent("Last scan",
                                   value: "\(FilingSpendFormat.model(last.model)) · \(last.fileCount) files · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                }
                HStack {
                    Button("View history…") { showSpendHistory = true }
                        .disabled(spendTotals.scans == 0)
                    Button("Clear", role: .destructive) { FilingSpendStore.clear(); refreshSpend() }
                        .disabled(spendTotals.scans == 0)
                }
                .controlSize(.small)
            } header: {
                Text("Cloud spend")
            } footer: {
                Text("Before each cloud (Claude) scan you’ll see a cost estimate to confirm. Two caps pause cloud classification when a scan would push you past them: a monthly cap (Off by default) and a total lifetime cap (defaults to $5 as a safety backstop). Either one being reached falls back to the free on-device suggestions until you raise or turn it off. Costs are estimated from list prices for the cloud suggestions only (the Anthropic Console is authoritative); on-device and keyword suggestions are free.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredKey = AnthropicKeychain.hasKey
            refreshSpend()
        }
        .sheet(isPresented: $showSpendHistory, onDismiss: refreshSpend) {
            TidySpendHistorySheet()
        }
    }

    private func refreshSpend() {
        spendTotals = FilingSpendStore.totals()
        spendLast = FilingSpendStore.last()
    }

    /// The Anthropic key field, Save/Test/Clear, a status line, and a link to the Console.
    @ViewBuilder private var cloudKeyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(hasStoredKey ? "•••• key saved" : "Paste sk-ant-… key", text: $apiKeyField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    AnthropicKeychain.store(apiKeyField)
                    apiKeyField = ""
                    hasStoredKey = AnthropicKeychain.hasKey
                    keyTestResult = nil
                }
                .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { Task { await testKey() } } label: {
                    if testingKey { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .disabled(testingKey || (!hasStoredKey && apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty))
                if hasStoredKey {
                    Button("Clear") {
                        AnthropicKeychain.delete()
                        apiKeyField = ""
                        hasStoredKey = false
                        keyTestResult = nil
                    }
                }
            }
            .controlSize(.small)

            keyStatusLine

            Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                Text("Get a key from the Anthropic Console ↗").font(.caption)
            }
        }
    }

    @ViewBuilder private var keyStatusLine: some View {
        if testingKey {
            Label("Testing…", systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary)
        } else if let keyTestResult {
            switch keyTestResult {
            case .valid:
                Label("Key works — you’re set.", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            case .failed(let message):
                Label("Couldn’t reach Anthropic: \(message)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        } else if hasStoredKey {
            Label("Key saved to Keychain.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("No key yet — cloud suggestions fall back to the on-device model until you add one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Validates the key in the field (or, if empty, the stored key) with a free Console call.
    private func testKey() async {
        let typed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (AnthropicKeychain.read() ?? "") : typed
        testingKey = true
        keyTestResult = nil
        let result = await AnthropicKeyCheck.validate(key)
        testingKey = false
        keyTestResult = result
    }
}

/// The full cloud-Filing spend history as a sheet (Settings' copy — FileExplorer has its own for
/// the Tidy lens; both read the shared FilingSpendStore).
struct TidySpendHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FilingSpendEntry] = []
    @State private var totals = FilingSpendTotals()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cloud Filing Spend").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
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
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12))
                            Text("\(FilingSpendFormat.model(entry.model)) · \(entry.fileCount) files · placed \(entry.placedCount)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FilingSpendFormat.cost(entry.estimatedCostUSD)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Text(FilingSpendFormat.tokens(entry.totalTokens)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Form {
            Section {
                Picker("Log level", selection: $minimumLevelRaw) {
                    Text("Debug (everything)").tag(LogLevel.debug.rawValue)
                    Text("Info").tag(LogLevel.info.rawValue)
                    Text("Warnings").tag(LogLevel.warning.rawValue)
                    Text("Errors only").tag(LogLevel.error.rawValue)
                }
                .onChange(of: minimumLevelRaw) { _, raw in
                    Logger.shared.minimumLevel = LogLevel(rawValue: raw) ?? .debug
                }

                LabeledContent("Log file") {
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
            } header: {
                Text("Logging")
            } footer: {
                Text("The log rotates at 5 MB. Levels below the chosen one are skipped entirely.")
            }

            Section {
                LabeledContent("Orphaned temporary files") {
                    Button("Sweep Now") {
                        syncManager?.sweepOrphanedTempArtifactsNow()
                    }
                    .controlSize(.small)
                    .disabled(syncManager == nil)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Interrupted copies can leave .tmp_ working files behind; they're moved to the Trash automatically once they're an hour old. Recovery backups (.rollback_) are never touched.")
            }

            if let onResetAllSettings {
                Section {
                    Button("Reset All Settings…", role: .destructive) {
                        confirmReset(onResetAllSettings)
                    }
                } footer: {
                    Text("Restores defaults for appearance, sync behavior, and provider names and paths. Your files aren't affected.")
                }
            }

            // The bottom version line. Rendered as a background-less row rather than an empty
            // Section's footer, which drew a stray empty grouped card above it.
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Section {
                    Text("SyncCloud \(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshLogFileSize() }
    }

    /// Confirmation ahead of the defaults wipe; Cancel is the default button (Return must
    /// not reset, same convention as the permanent-delete alert).
    private func confirmReset(_ reset: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Appearance, sync behavior, ignored items, and provider names and paths return to their defaults. Files on disk are not affected."
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
