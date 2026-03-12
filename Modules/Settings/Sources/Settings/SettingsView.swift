import Events
import Foundation
import SwiftUI
import Sync
import Design

/// An overlay window allowing users to customize CloudProvider synchronization paths.
public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    // Stored in UserDefaults; MacApp reads the same key to drive Liquid Glass intensity.
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(settings.availableProviders) { provider in
                        ProviderCard(provider: provider)
                    }
                }
                .padding()
            }
            
            Divider()
            
            footer
        }
        .frame(width: 800, height: 500)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
    
    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Settings")
                    .font(.system(size: 26, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            
            Text("Configure your cloud storage root directories for synchronization.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
            
            HStack(spacing: 12) {
                Text("Glass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                Slider(value: $glassIntensity, in: 0.0...1.0)
                    .controlSize(.small)
                
                Text("\(Int(glassIntensity * 100))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
            
            Divider()
                .opacity(0.6)
        }
        .glassBarStyle(intensity: glassIntensity)
    }
    
    private var footer: some View {
        HStack {
            Text("Tip: Default roots are automatically discovered in ~/Library/CloudStorage")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .glassBarStyle(intensity: glassIntensity)
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


