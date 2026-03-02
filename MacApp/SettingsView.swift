import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    
    var body: some View {
        Form {
            Section(header: Text("Cloud Provider Paths").font(.headline)) {
                ForEach(settings.availableProviders) { provider in
                    HStack {
                        Image(provider.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text(provider.displayName)
                            .frame(width: 200, alignment: .leading)
                        
                        TextField("Path", text: Binding(
                            get: { settings.path(for: provider.id) },
                            set: { settings.setPath($0, for: provider.id) }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button("Browse...") {
                            selectDirectory(for: provider.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .frame(width: 700, height: 350)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
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
