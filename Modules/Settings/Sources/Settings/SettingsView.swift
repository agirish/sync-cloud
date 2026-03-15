import Events
import Foundation
import SwiftUI
import Sync
import Design

/// An overlay window allowing users to customize CloudProvider synchronization paths and app preferences.
public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    @State private var isRefreshingProviders = false
    // Stored in UserDefaults; MacApp reads the same keys for Liquid Glass appearance.
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    appearanceSection
                    differencesSection
                    cloudStorageSection
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            footer
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
    
    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Settings")
                    .font(.system(size: 26, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            
            Text("Configure appearance and cloud storage roots for synchronization.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
            
            Divider()
                .opacity(0.6)
        }
        .glassBarStyle(intensity: glassIntensity)
    }
    
    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Appearance")

            // Color / hue selector
            VStack(alignment: .leading, spacing: 10) {
                Text("Accent color")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(LiquidGlassHue.allCases) { hue in
                        HueOptionView(
                            hue: hue,
                            isSelected: selectedHue == hue,
                            action: { selectedHueRaw = hue.rawValue }
                        )
                    }
                }
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )

            // Glass intensity slider
            VStack(alignment: .leading, spacing: 10) {
                Text("Glass effect")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Slider(value: $glassIntensity, in: 0.0...1.0)
                        .controlSize(.regular)
                    Text("\(Int(glassIntensity * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    private var differencesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Differences")

            Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ignore \"newer on Google Drive\" when same size")
                        .font(.subheadline.weight(.medium))
                    Text("Hides differences where only the date changed (right side newer, same size). Reduces noise when Google Drive overwrites file dates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
        }
    }
    
    private var cloudStorageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Cloud storage")
                Spacer()
                Button(action: refreshProviders) {
                    Label(
                        isRefreshingProviders ? "Refreshing…" : "Refresh providers",
                        systemImage: "arrow.clockwise"
                    )
                    .disabled(isRefreshingProviders)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            Text("Set the root folder for each provider. Defaults are discovered from ~/Library/CloudStorage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 12) {
                ForEach(settings.availableProviders) { provider in
                    ProviderCard(provider: provider)
                }
            }
        }
    }
    
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
    
    private func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        Task {
            await settings.discoverProviders()
            await MainActor.run { isRefreshingProviders = false }
        }
    }
    
    private var footer: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tip: Use Browse or Reset to change paths. Default roots come from ~/Library/CloudStorage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("SyncCloud \(version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .glassBarStyle(intensity: glassIntensity)
    }
}

/// A selectable hue option for the liquid glass accent color.
private struct HueOptionView: View {
    let hue: LiquidGlassHue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(hue.accentColor)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2.5)
                        )
                        .shadow(color: hue.accentColor.opacity(0.4), radius: isSelected ? 6 : 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(width: 64)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An interactive UI card displaying the configurations and health status of a specific `CloudProvider`.
struct ProviderCard: View {
    let provider: CloudProvider
    @EnvironmentObject var settings: SettingsManager
    @State private var draftPath: String = ""
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                // Icon and Name
                ZStack {
                    RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                        .frame(width: 52, height: 52)
                    
                    Image(provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.displayName)
                            .font(.headline.weight(.semibold))
                        
                        StatusBadge(isValid: isPathValid)
                    }
                    
                    Text(provider.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    Button(action: { resetToDefault() }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: { openInFinder() }) {
                        Label("Show in Finder", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            // Path Input Area
            HStack(spacing: 12) {
                TextField("Synchronized Path", text: $draftPath)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                    .onSubmit { commitPath() }
                
                Button(action: { commitPath() }) {
                    Text("Save")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftPath == provider.path)
                
                Button(action: { selectDirectory() }) {
                    Label("Browse...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
        .onAppear {
            draftPath = provider.path
        }
        .onChange(of: provider.path) { _, updated in
            if draftPath != updated {
                draftPath = updated
            }
        }
    }
    
    private var isPathValid: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (provider.path as NSString).expandingTildeInPath, isDirectory: &isDir) && isDir.boolValue
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


