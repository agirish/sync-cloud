import SwiftUI
import Sync

/// A source-switcher dropdown. The trigger is a caller-supplied label (e.g. a pane header's
/// brand-tinted provider capsule, or a Tidy source bar), and the menu is an inline picker over the
/// enabled sources plus "Choose Folder…" and a "Manage sources…" escape hatch to Settings.
///
/// This replaces the old standalone Left/Right `ProviderSidebar`: source choice now rides on the
/// thing it applies to (each pane header, or the single Tidy source), so no window column is spent
/// on a picker — and single-source Tidy never shows a second source it doesn't use.
public struct ProviderMenu<LabelContent: View>: View {
    private let providers: [CloudProvider]
    private let currentId: String
    private let onSelect: (String) -> Void
    private let onManage: () -> Void
    private let onChooseFolder: (() -> Void)?
    private let label: LabelContent

    public init(
        providers: [CloudProvider],
        currentId: String,
        onSelect: @escaping (String) -> Void,
        onManage: @escaping () -> Void,
        onChooseFolder: (() -> Void)? = nil,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.providers = providers
        self.currentId = currentId
        self.onSelect = onSelect
        self.onManage = onManage
        self.onChooseFolder = onChooseFolder
        self.label = label()
    }

    public var body: some View {
        Menu {
            // Inline Picker gives the native menu check column for the current provider.
            //
            // ONE picker over the whole list, not one per kind with a divider between: the check
            // column is the reason this is a Picker at all, and a second Picker over the same
            // binding shows a check in whichever group holds the selection and a blank column in
            // the other — the list would visibly re-space as you switched between a cloud account
            // and a folder. `mapProviders` already sorts folder sources last as a block, so the
            // grouping the divider would have drawn is there in the order.
            Picker("Source", selection: Binding(get: { currentId }, set: { onSelect($0) })) {
                ForEach(providers, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // The one-gesture door: pick a folder and this pane is looking at it. The deliberate
            // door is Settings ▸ Sources ▸ Add Folder…; both go through `addFolderSource`, so
            // choosing a folder that is already a source selects it instead of adding a second.
            if let onChooseFolder {
                Button {
                    onChooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
            }
            Button {
                onManage()
            } label: {
                Label("Manage sources…", systemImage: "gearshape")
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
