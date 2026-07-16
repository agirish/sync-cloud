import SwiftUI
import Sync

/// A provider-switcher dropdown. The trigger is a caller-supplied label (e.g. a pane header's
/// brand-tinted provider capsule, or a Tidy source bar), and the menu is an inline picker over the
/// enabled providers plus a "Manage providers…" escape hatch to Settings.
///
/// This replaces the old standalone Left/Right `ProviderSidebar`: provider choice now rides on the
/// source it applies to (each pane header, or the single Tidy source), so no window column is spent
/// on a picker — and single-source Tidy never shows a second provider it doesn't use.
public struct ProviderMenu<LabelContent: View>: View {
    private let providers: [CloudProvider]
    private let currentId: String
    private let onSelect: (String) -> Void
    private let onManage: () -> Void
    private let label: LabelContent

    public init(
        providers: [CloudProvider],
        currentId: String,
        onSelect: @escaping (String) -> Void,
        onManage: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.providers = providers
        self.currentId = currentId
        self.onSelect = onSelect
        self.onManage = onManage
        self.label = label()
    }

    public var body: some View {
        Menu {
            // Inline Picker gives the native menu check column for the current provider.
            Picker("Provider", selection: Binding(get: { currentId }, set: { onSelect($0) })) {
                ForEach(providers, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button {
                onManage()
            } label: {
                Label("Manage providers…", systemImage: "gearshape")
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        // Keep the native trailing menu indicator — it places the chevron correctly for the
        // borderless style (a custom one plus `.menuIndicator(.hidden)` mis-rendered under it).
        //
        // fixedSize is VERTICAL-ONLY: a fully fixedSize menu ignores the width proposal, so a
        // long custom provider name ballooned the label past the pane edge and pushed the pane
        // header's nav cluster out of view (the label's truncating Text was never offered a
        // constrained width to truncate against). Left flexible, the menu hugs its label at its
        // ideal width and only compresses — truncating the label — when the pane is narrower
        // than the header's content.
        .fixedSize(horizontal: false, vertical: true)
    }
}
