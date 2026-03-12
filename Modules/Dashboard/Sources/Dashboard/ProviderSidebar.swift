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
        let providers = settings.availableProviders
        return List {
            Group {
                Section("Left") {
                    ForEach(providers, id: \.id) { provider in
                        Button(action: { leftProviderId = provider.id }) {
                            providerCell(provider: provider, isSelected: leftProviderId == provider.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Right") {
                    ForEach(providers, id: \.id) { provider in
                        Button(action: { rightProviderId = provider.id }) {
                            providerCell(provider: provider, isSelected: rightProviderId == provider.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Providers")
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private func providerCell(provider: CloudProvider, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(provider.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            Text(provider.displayName)
                .font(.body.weight(.medium))
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}
