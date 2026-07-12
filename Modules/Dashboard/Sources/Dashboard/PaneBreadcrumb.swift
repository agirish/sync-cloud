import SwiftUI
import AppKit

/// Clickable breadcrumb inside each `PaneHeader`: the provider root (named after the root
/// folder, full path in the tooltip) followed by the pane's relative-path segments. Clicking
/// a crumb re-focuses that pane on the ancestor; ⌥-clicking any crumb (including the current
/// folder) focuses *both* panes on the same relative path. A trailing "Link both" toggle makes
/// that both-panes behavior sticky, so a plain click keeps the two panes in lock-step while
/// drilling down. Deep trails collapse their middle into an ellipsis menu, same as the old
/// toolbar bar did.
struct PaneBreadcrumb: View {
    let rootPath: String
    let relativePath: String
    let onNavigate: (String) -> Void
    let onNavigateBoth: (String) -> Void

    /// When on, a plain crumb click drives *both* panes — the sticky form of ⌥-click. Shared
    /// across both panes' breadcrumbs by design: one setting, mirrored in each toggle.
    @AppStorage("breadcrumbLinkBothPanes") private var linkBothPanes = false

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
            linkBothToggle
        }
        .font(.caption)
    }

    /// A subtle, caption-scaled toggle that makes the ⌥-click "navigate both panes" trick a
    /// visible, first-class mode. Tinted with the accent color when on, muted when off.
    private var linkBothToggle: some View {
        Button {
            linkBothPanes.toggle()
        } label: {
            // A chain, not ⇄ — the ⇄ arrows are reserved for swap-panes (UX 1.2).
            Image(systemName: "link")
                .foregroundColor(linkBothPanes ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(linkBothPanes
            ? "Linked: clicking a folder moves both panes. Click to unlink."
            : "Link panes: clicking a folder will move both. Tip: hold ⌥ to do it once.")
        .accessibilityLabel("Link both panes")
        .accessibilityValue(linkBothPanes ? "On" : "Off")
        .accessibilityAddTraits(linkBothPanes ? .isSelected : [])
    }

    @ViewBuilder
    private func crumbButton(name: String, relativePath: String, isCurrent: Bool, helpPath: String) -> some View {
        Button(name) { navigate(to: relativePath, isCurrent: isCurrent) }
            .buttonStyle(.plain)
            .fontWeight(isCurrent ? .medium : .regular)
            .foregroundColor(isCurrent ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(crumbHelp(isCurrent: isCurrent, helpPath: helpPath))
    }

    /// Tooltip that stays honest whether panes are linked or not: when linked, a plain click
    /// already drives both panes, so we drop the ⌥ instruction and say so.
    private func crumbHelp(isCurrent: Bool, helpPath: String) -> String {
        let destination = isCurrent ? helpPath : "Go to \(helpPath)"
        return linkBothPanes
            ? "\(destination) — panes are linked, so both move here"
            : "\(destination) — ⌥-click to bring both panes here"
    }

    /// Moves both panes to the crumb's path when linked or ⌥ is held; otherwise a plain click
    /// moves only this pane. When neither applies, the current folder's crumb is a no-op (a
    /// plain click on it would only pollute the back/forward history).
    private func navigate(to relativePath: String, isCurrent: Bool) {
        let both = linkBothPanes || NSEvent.modifierFlags.contains(.option)
        if both {
            onNavigateBoth(relativePath)
        } else if !isCurrent {
            onNavigate(relativePath)
        }
    }
}
