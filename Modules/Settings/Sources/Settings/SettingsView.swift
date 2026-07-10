import Events
import Foundation
import ServiceManagement
import SwiftUI
import Sync
import Design

/// UserDefaults keys for General settings that are read outside the Settings module — the app
/// delegate's quit guard and ContentView's launch-time seeding both reference the same literals,
/// so they live here as the single source of truth.
public enum GeneralSettings {
    /// Bool (default true). When false, the app quits immediately even with file operations in flight.
    public static let warnBeforeQuitKey = "warnBeforeQuitDuringOperations"
    /// Bool (default false). Seeds `FileSyncManager.showHiddenFiles` at launch.
    public static let showHiddenByDefaultKey = "showHiddenFilesByDefault"
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

    public init(selection: Binding<SettingsTab>, onClose: @escaping () -> Void) {
        _selectedTab = selection
        self.onClose = onClose
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
                    SyncSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

/// App-level preferences: login item, hidden-file default, and the quit safety guard.
struct GeneralSettingsTab: View {
    /// Mirrors `SMAppService.mainApp.status`. Deliberately not seeded in the initializer:
    /// the status getter is a synchronous XPC call, which must not run on the main thread
    /// during view init — `.task` reads it once the view is up.
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
            } footer: {
                Text("New launches start with hidden files shown. You can still toggle Hidden in the action bar at any time.")
            }

            Section {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
            } footer: {
                Text("Shows a confirmation if you try to quit while a copy, move, or delete is still running.")
            }
        }
        .formStyle(.grouped)
        .task { readLoginItemState() }
    }

    /// Reflects the real service state into the toggle and approval hint. A pending
    /// approval counts as "on": the item *is* registered, just not yet consented to.
    private func readLoginItemState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        lastAppliedLaunchAtLogin = launchAtLogin
    }

    /// Registers/unregisters the login item, reverting the toggle to the real service state on
    /// failure so the UI never claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering a pending-approval item withdraws it from Login Items.
                try SMAppService.mainApp.unregister()
            }
            lastAppliedLaunchAtLogin = enabled
            loginItemNeedsApproval = (SMAppService.mainApp.status == .requiresApproval)
            if loginItemNeedsApproval {
                Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
            }
        } catch {
            Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
            readLoginItemState()
        }
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
                    Text("\(Int(surfaceTint * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } footer: {
                Text("Washes the panes and Differences area with the accent color chosen above.")
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

            Section {
            } footer: {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("SyncCloud \(version)")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
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
                    .textFieldStyle(.roundedBorder)
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
        let normalized = draftPath.trimmingCharacters(in: .newlines)
        draftPath = normalized
        guard normalized != provider.path else { return }
        settings.setPath(normalized, for: provider.id)
    }

    private func commitName() {
        let normalized = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Sync

/// Behavior of difference scanning and comparison.
struct SyncSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                    Text("Ignore \"newer on Google Drive\" when same size")
                }
            } header: {
                Text("Differences")
            } footer: {
                Text("Hides differences where only the date changed (right side newer, same size). Reduces noise when Google Drive overwrites file dates.")
            }
        }
        .formStyle(.grouped)
    }
}
