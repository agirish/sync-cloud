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
    /// default read at window creation, so treat them as stable.
    public enum SettingsTab: String {
        case general
        case appearance
        case providers
        case sync
        case advanced
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
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Escape closes the overlay even when focus is elsewhere in the card.
                .keyboardShortcut(.cancelAction)
                .help("Close settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // A segmented picker rather than a TabView: a plain TabView (outside the native
            // Settings scene) hoists its tab bar into the window toolbar. This keeps the tabs
            // inside the overlay card.
            Picker("Settings section", selection: $selectedTab) {
                Text("General").tag(SettingsTab.general)
                Text("Appearance").tag(SettingsTab.appearance)
                Text("Providers").tag(SettingsTab.providers)
                Text("Sync").tag(SettingsTab.sync)
                Text("Advanced").tag(SettingsTab.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab()
                case .appearance:
                    AppearanceSettingsTab()
                case .providers:
                    ProvidersSettingsTab()
                case .sync:
                    SyncSettingsTab(syncManager: syncManager)
                case .advanced:
                    AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 560)
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
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
            } footer: {
                Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn't the active app. Requires notification permission.")
            }

            Section {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
            } footer: {
                Text("Shows a confirmation if you try to quit while a copy, move, or delete is still running.")
            }
        }
        .formStyle(.grouped)
        .task { readLoginItemState() }
        // Approving the login item happens in System Settings, so the footer's "Approval
        // needed" hint goes stale exactly while this tab is still open. Coming back to the
        // app re-activates it — re-read so the hint clears without reopening the tab.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItemState()
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

/// Accent hue and liquid glass intensity, both shared with MacApp through UserDefaults.
struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
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
        Form {
            Section("Accent color") {
                HStack(spacing: 8) {
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
                HStack(spacing: 12) {
                    Slider(value: $glassIntensity, in: 0.0...1.0) {
                        Text("Glass effect")
                    }
                    Text("\(Int(glassIntensity * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } footer: {
                Text("Controls the translucency of window backgrounds, bars, and cards.")
            }

            Section {
                HStack(spacing: 12) {
                    Slider(value: $surfaceTint, in: 0.0...1.0) {
                        Text("Tint")
                    }
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
                            .foregroundStyle(hue == .none ? Color.primary : .white)
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @FocusState private var nameFieldFocused: Bool

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
                if draftPath != updated {
                    draftPath = updated
                }
            }
            .onChange(of: provider.displayName) { _, updated in
                if draftName != updated {
                    draftName = updated
                }
            }

            LabeledContent("Location") {
                TextField("Synchronized path", text: $draftPath)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .labelsHidden()
                    .onSubmit { commitPath() }
            }
            .disabled(!isEnabled)

            HStack(spacing: 8) {
                Button("Browse…") { selectDirectory() }
                Button("Reset") { resetToDefault() }
                Button("Show in Finder") { openInFinder() }
                Spacer()
                Button("Save") { commitPath() }
                    .disabled(draftPath == provider.path)
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

    private func commitPath() {
        let normalized = ProviderFieldEdit.normalized(draftPath)
        draftPath = normalized
        guard normalized != provider.path else { return }
        settings.setPath(normalized, for: provider.id)
    }

    private func commitName() {
        let normalized = ProviderFieldEdit.normalized(draftName)
        if normalized == provider.displayName {
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
                Text("Copies and moves first show what will be transferred and where. Deleted items go to the Trash either way and can be restored with Undo.")
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
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                Text("Interrupted copies can leave .tmp_ working files behind; they're removed automatically once they're an hour old. Recovery backups (.rollback_) are never touched.")
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

            Section {
            } footer: {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("SyncCloud \(version)")
                        .frame(maxWidth: .infinity, alignment: .center)
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
