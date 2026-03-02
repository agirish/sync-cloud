import SwiftUI

/// The left-most navigation pane in the application split view.
/// Allows users to independently select the driving CloudProvider mapping for both the Source and Destination synchronization trees.
struct ProviderSidebarView: View {
    let settings: SettingsManager
    @Binding var sourceProviderId: String
    @Binding var destinationProviderId: String
    
    var body: some View {
        List {
            Section("Source Provider") {
                ForEach(settings.availableProviders) { provider in
                    Button(action: { sourceProviderId = provider.id }) {
                        HStack {
                            Image(provider.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20)
                            Text(provider.displayName)
                            Spacer()
                            if sourceProviderId == provider.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            
            Section("Destination Provider") {
                ForEach(settings.availableProviders) { provider in
                    Button(action: { destinationProviderId = provider.id }) {
                        HStack {
                            Image(provider.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20)
                            Text(provider.displayName)
                            Spacer()
                            if destinationProviderId == provider.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Providers")
        .frame(minWidth: 200)
    }
}
