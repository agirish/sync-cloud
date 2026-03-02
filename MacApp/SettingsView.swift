import Foundation
import SwiftUI

/// An overlay window allowing users to customize CloudProvider synchronization paths.
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    
    var body: some View {
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
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            
            Text("Configure your cloud storage root directories for synchronization.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            
            Divider()
        }
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
        .padding(24)
    }
}

/// An interactive UI card displaying the configurations and health status of a specific `CloudProvider`.
struct ProviderCard: View {
    let provider: CloudProvider
    @EnvironmentObject var settings: SettingsManager
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                // Icon and Name
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.1))
                        .frame(width: 48, height: 48)
                    
                    Image(provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.displayName)
                            .font(.headline)
                        
                        StatusBadge(isValid: isPathValid)
                    }
                    
                    Text(provider.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: { resetToDefault() }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(6)
                    .background(.white.opacity(0.05))
                    .cornerRadius(6)
                    
                    Button(action: { openInFinder() }) {
                        Label("Show in Finder", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(6)
                    .background(.white.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            
            // Path Input Area
            HStack(spacing: 12) {
                TextField("Synchronized Path", text: Binding(
                    get: { provider.path },
                    set: { settings.setPath($0, for: provider.id) }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .background(.black.opacity(0.2))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                
                Button(action: { selectDirectory() }) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Browse...")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.07), lineWidth: 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
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
                settings.setPath(url.path, for: provider.id)
            }
        }
    }
    
    private func resetToDefault() {
        settings.resetPath(for: provider.id)
    }
    
    private func openInFinder() {
        let url = URL(fileURLWithPath: (provider.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

/// A tiny visual indicator showing whether a given String path actually exists as a directory on disk.
struct StatusBadge: View {
    let isValid: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isValid ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            
            Text(isValid ? "Valid Path" : "Invalid Path")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isValid ? .green : .red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isValid ? Color.green : Color.red).opacity(0.1))
        .cornerRadius(20)
    }
}

// Utility view for blur effects
/// A SwiftUI bridge to `NSVisualEffectView` allowing native macOS vibrancy and background blurring.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

