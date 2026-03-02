import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Preferences")
                .font(.title2)
                .fontWeight(.bold)
                .padding()
                
            Divider()
            
            Form {
                Section(header: Text("Cloud Provider Paths").font(.headline).padding(.bottom, 4)) {
                    ForEach(settings.availableProviders) { provider in
                        HStack(spacing: 12) {
                            Image(provider.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                
                            Text(provider.displayName)
                                .fontWeight(.medium)
                                .frame(width: 150, alignment: .leading)
                            
                            TextField("Path", text: Binding(
                                get: { settings.path(for: provider.id) },
                                set: { settings.setPath($0, for: provider.id) }
                            ))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.body, design: .monospaced))
                            
                            Button(action: { selectDirectory(for: provider.id) }) {
                                Image(systemName: "folder.badge.magnifyingglass")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
            
            Divider()
            
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 700, height: 400)
        .background(.ultraThinMaterial)
    }
    
    private func selectDirectory(for providerId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                settings.setPath(url.path, for: providerId)
            }
        }
    }
}
