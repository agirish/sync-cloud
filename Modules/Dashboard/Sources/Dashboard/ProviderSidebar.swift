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
    /// Invoked by the ⇄ button to flip the left and right panes (providers, focused folders,
    /// selections, and history). The actual swap lives in ContentView, which owns both the
    /// provider ids and the sync manager.
    private let onSwap: () -> Void

    public init(
        settings: SettingsManager,
        leftProviderId: Binding<String>,
        rightProviderId: Binding<String>,
        onSwap: @escaping () -> Void
    ) {
        self.settings = settings
        self._leftProviderId = leftProviderId
        self._rightProviderId = rightProviderId
        self.onSwap = onSwap
    }
    
    public var body: some View {
        // Only user-enabled providers are offered as pane roots; disabled ones remain
        // visible (and re-enableable) in Settings.
        let providers = settings.enabledProviders
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
                swapButton
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

    /// Flips the two panes. Sits between the Left and Right sections so the ⇄ visually reads
    /// as "swap these two"; disabled only when there are no enabled providers, where both panes
    /// are placeholders and there is nothing to swap.
    @ViewBuilder
    private var swapButton: some View {
        HStack {
            Spacer()
            Button(action: onSwap) {
                Label("Swap panes", systemImage: "arrow.left.arrow.right.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(settings.enabledProviders.isEmpty)
            .accessibilityLabel("Swap left and right panes")
            .help("Swap the left and right panes")
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
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
