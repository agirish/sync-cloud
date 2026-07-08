import SwiftUI
import AppKit

/// Clickable breadcrumb inside each `PaneHeader`: the provider root (named after the root
/// folder, full path in the tooltip) followed by the pane's relative-path segments. Clicking
/// a crumb re-focuses that pane on the ancestor; ⌥-clicking any crumb (including the current
/// folder) focuses *both* panes on the same relative path. Deep trails collapse their middle
/// into an ellipsis menu, same as the old toolbar bar did.
struct PaneBreadcrumb: View {
    let rootPath: String
    let relativePath: String
    let onNavigate: (String) -> Void
    let onNavigateBoth: (String) -> Void

    var body: some View {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: relativePath)
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        HStack(spacing: 3) {
            crumbButton(
                name: BreadcrumbTrail.rootDisplayName(forRootPath: rootPath),
                relativePath: "",
                isCurrent: crumbs.isEmpty,
                helpPath: rootPath
            )

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                switch item {
                case .crumb(let crumb):
                    crumbButton(
                        name: crumb.name,
                        relativePath: crumb.relativePath,
                        isCurrent: crumb == crumbs.last,
                        helpPath: crumb.relativePath
                    )
                case .collapsed(let hidden):
                    Menu {
                        ForEach(hidden) { crumb in
                            Button(crumb.name) { navigate(to: crumb.relativePath, isCurrent: false) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Collapsed folders")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func crumbButton(name: String, relativePath: String, isCurrent: Bool, helpPath: String) -> some View {
        Button(name) { navigate(to: relativePath, isCurrent: isCurrent) }
            .buttonStyle(.plain)
            .fontWeight(isCurrent ? .medium : .regular)
            .foregroundColor(isCurrent ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(isCurrent
                ? "\(helpPath) — ⌥-click to bring both panes here"
                : "Go to \(helpPath) — ⌥-click to bring both panes here")
    }

    /// ⌥-click moves both panes to the crumb's path; a plain click moves only this pane.
    /// The current folder's crumb only responds to ⌥ (a plain click would be a no-op that
    /// still pollutes the back/forward history).
    private func navigate(to relativePath: String, isCurrent: Bool) {
        if NSEvent.modifierFlags.contains(.option) {
            onNavigateBoth(relativePath)
        } else if !isCurrent {
            onNavigate(relativePath)
        }
    }
}
