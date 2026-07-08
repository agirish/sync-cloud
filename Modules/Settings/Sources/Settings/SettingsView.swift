import Events
import Foundation
import SwiftUI
import Sync
import Design

/// The app's settings window, hosted in the SwiftUI `Settings` scene. Follows the standard
/// macOS preferences layout: toolbar tabs (Appearance / Providers / Sync) over grouped forms.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            AppearanceSettingsTab()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            ProvidersSettingsTab()
                .tabItem {
                    Label("Providers", systemImage: "externaldrive.badge.icloud")
                }

            SyncSettingsTab()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - Appearance

/// Accent hue and liquid glass intensity, both shared with MacApp through UserDefaults.
struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
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
                    Circle()
                        .fill(hue.accentColor)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2)
                        )
                        .shadow(color: hue.accentColor.opacity(0.4), radius: isSelected ? 5 : 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
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
                    Text(provider.displayName)
                        .font(.body.weight(.medium))
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
            }
            .onChange(of: provider.path) { _, updated in
                if draftPath != updated {
                    draftPath = updated
                }
            }

            LabeledContent("Location") {
                TextField("Synchronized path", text: $draftPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
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
