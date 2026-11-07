import SwiftUI
import Sync

/// A source-switcher dropdown. The trigger is a caller-supplied label (e.g. a pane header's
/// brand-tinted provider capsule, or a lens source bar), and the menu is an inline picker over the
/// enabled sources plus "Choose Folder…" and a "Manage Sources…" escape hatch to Settings.
///
/// Source choice rides on the thing it applies to (each pane header, or the single lens source),
/// so no window column is spent on a picker and a single-source workspace never shows a second.
public struct ProviderMenu<LabelContent: View>: View {
    private let providers: [CloudProvider]
    private let currentId: String
    private let onSelect: (String) -> Void
    private let onManage: () -> Void
    private let onChooseFolder: (() -> Void)?
    private let onGoToRoot: (() -> Void)?
    private let label: LabelContent
    @ObservedObject private var cloudApps: CloudAppMonitor

    /// - Parameter onGoToRoot: moves the caller to the top of the source it is already on. nil omits
    ///   the item, right for every caller that is not a pane (the lens source bar has no position).
    ///   The pane breadcrumb's whole first crumb opens this menu, so going to the root is offered
    ///   here, first.
    public init(
        providers: [CloudProvider],
        currentId: String,
        onSelect: @escaping (String) -> Void,
        onManage: @escaping () -> Void,
        onChooseFolder: (() -> Void)? = nil,
        onGoToRoot: (() -> Void)? = nil,
        cloudApps: CloudAppMonitor = .shared,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.cloudApps = cloudApps
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
            // First, above the divider: the one item about where you are rather than which source,
            // and the commoner act.
            if let onGoToRoot {
                Button {
                    onGoToRoot()
                } label: {
                    Label(currentName.map { "Go to \($0)" } ?? "Go to the Top of This Source",
                          systemImage: "arrow.turn.left.up")
                }
                Divider()
            }
            // An inline Picker gives the native check column. One picker over the whole list: a
            // second over the same binding leaves a blank check column in the other group, and the
            // list re-spaces as the selection crosses groups. `mapProviders` already sorts folder
            // sources last as a block. A pick is the user asking about that source, so its app is
            // checked at once.
            Picker("Source", selection: Binding(get: { currentId }, set: { id in
                cloudApps.checkNow([id])
                onSelect(id)
            })) {
                ForEach(providers, id: \.id) { provider in
                    // A cloud app not syncing: an amber dot and what is wrong. Nothing otherwise,
                    // no green.
                    if let problem = cloudApps.problems[provider.id] {
                        Label {
                            Text("\(provider.displayName) — \(problem.shortLabel)")
                        } icon: {
                            Image(nsImage: CloudAppStatusDot.menuImage)
                        }
                        .tag(provider.id)
                    } else {
                        Text(provider.displayName).tag(provider.id)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // Pick a folder and this pane is looking at it. Like Settings ▸ Sources ▸ Add
            // Folder…, it goes through `addFolderSource`, so a folder already a source is
            // selected, not added.
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
                Label("Manage Sources…", systemImage: "gearshape")
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        // Reaching for the chip checks every source it lists, so the menu opens on current dots:
        // the check takes milliseconds, and the click comes after the pointer arrives.
        .onHover { inside in
            if inside { cloudApps.checkNow(providers.map(\.id)) }
        }
        // Keep the native trailing menu indicator: a custom one with `.menuIndicator(.hidden)`
        // mis-renders under the borderless style.
        //
        // fixedSize is vertical-only: a fully fixed menu ignores the width proposal, so a long
        // provider name would balloon the label past the pane edge and push the header's nav
        // cluster out of view. Flexible, the menu hugs its label and truncates only when the pane
        // is narrower than the header's content.
        .fixedSize(horizontal: false, vertical: true)
    }
}
