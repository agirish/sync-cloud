import SwiftUI
import Sync

/// A source-switcher dropdown. The trigger is a caller-supplied label (e.g. a pane header's
/// brand-tinted provider capsule, or a lens source bar), and the menu is an inline picker over the
/// enabled sources plus "Choose Folder…" and a "Manage sources…" escape hatch to Settings.
///
/// This replaces the old standalone Left/Right `ProviderSidebar`: source choice now rides on the
/// thing it applies to (each pane header, or the single lens source), so no window column is spent
/// on a picker — and a single-source workspace never shows a second source it doesn't use.
public struct ProviderMenu<LabelContent: View>: View {
    private let providers: [CloudProvider]
    private let currentId: String
    private let onSelect: (String) -> Void
    private let onManage: () -> Void
    private let onChooseFolder: (() -> Void)?
    private let onGoToRoot: (() -> Void)?
    private let label: LabelContent

    /// - Parameter onGoToRoot: moves the caller to the top of the source it is already on. nil omits
    ///   the item, which is right for every caller that is not a pane — the lens source bar has no
    ///   position to move.
    ///
    ///   It exists because the pane breadcrumb's first crumb has two jobs and only one target. The
    ///   first cut split them by region — the mark opened this menu, the name went to the root — and
    ///   it was tried and reported: clicking the chip's obvious affordance (the chevron a few points
    ///   to its right) opens the *quick-jump* menu, which belongs to the current folder, so the
    ///   source picker read as missing. A 15pt mark is not an affordance. So the whole chip opens
    ///   this menu, and going to the root becomes the thing it offers first.
    public init(
        providers: [CloudProvider],
        currentId: String,
        onSelect: @escaping (String) -> Void,
        onManage: @escaping () -> Void,
        onChooseFolder: (() -> Void)? = nil,
        onGoToRoot: (() -> Void)? = nil,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.providers = providers
        self.currentId = currentId
        self.onSelect = onSelect
        self.onManage = onManage
        self.onChooseFolder = onChooseFolder
        self.onGoToRoot = onGoToRoot
        self.label = label()
    }

    /// What the current source is called, for the "Go to…" item. Read off the list rather than
    /// taken as a parameter, so it cannot disagree with the row the Picker checks.
    private var currentName: String? {
        providers.first { $0.id == currentId }?.displayName
    }

    public var body: some View {
        Menu {
            // First, and above the divider: this is the one item about where you ARE rather than
            // which source you are on, and it is the commoner act of the two.
            if let onGoToRoot {
                Button {
                    onGoToRoot()
                } label: {
                    Label(currentName.map { "Go to \($0)" } ?? "Go to the top of this source",
                          systemImage: "arrow.turn.left.up")
                }
                Divider()
            }
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
