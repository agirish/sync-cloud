import SwiftUI

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
