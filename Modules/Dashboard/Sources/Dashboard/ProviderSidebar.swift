import Settings
import FileExplorer
import Events
import SwiftUI
import Sync

/// Sidebar for choosing which cloud provider (and path) is used for the left and right comparison panes.
public struct ProviderSidebar: View {
    @ObservedObject public var settings: SettingsManager
    @Binding public var leftProviderId: String
    @Binding public var rightProviderId: String
    
    public init(settings: SettingsManager, leftProviderId: Binding<String>, rightProviderId: Binding<String>) {
        self.settings = settings
        self._leftProviderId = leftProviderId
        self._rightProviderId = rightProviderId
    }
    
    public var body: some View {
        List {
            Section("Left") {
                ForEach(settings.availableProviders) { provider in
                    Button(action: { leftProviderId = provider.id }) {
                        HStack {
                            Image(provider.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20)
                            Text(provider.displayName)
                            Spacer()
                            if leftProviderId == provider.id {
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
            
            Section("Right") {
                ForEach(settings.availableProviders) { provider in
                    Button(action: { rightProviderId = provider.id }) {
                        HStack {
                            Image(provider.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20)
                            Text(provider.displayName)
                            Spacer()
                            if rightProviderId == provider.id {
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
