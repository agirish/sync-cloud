import SwiftUI
import AppKit
import Design

/// The "Link both panes" preference behind the breadcrumb chain toggle. The toggle itself is a
/// `@AppStorage` inside `PaneBreadcrumb`, but the same lock-step intent has to be honored from
/// code paths that never touch the breadcrumb view — chiefly drilling into a folder from the file
/// list (`FileActionHandler.focusFolder`). Centralizing the key here keeps those readers in sync
/// with the toggle instead of duplicating the string literal.
enum PaneLinkPreference {
    static let defaultsKey = "breadcrumbLinkBothPanes"
    /// Whether the user has the panes linked. Reads the same UserDefaults key `@AppStorage` writes,
    /// so it stays true to the toggle without threading the state through every call site.
    static var isLinked: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Clickable breadcrumb inside each `PaneHeader`: the provider root (named after the root
/// folder, full path in the tooltip) followed by the pane's relative-path segments. Clicking
/// a crumb re-focuses that pane on the ancestor; ⌥-clicking any crumb (including the current
/// folder) focuses *both* panes on the same relative path. A trailing "Link both" toggle makes
/// that both-panes behavior sticky, so a plain click keeps the two panes in lock-step while
/// drilling down. Deep trails collapse their middle into an ellipsis menu, same as the old
/// toolbar bar did.
struct PaneBreadcrumb: View {
    let rootPath: String
    /// The pane's provider display name, used only to tint the root crumb with the provider's
    /// brand hue (UX H2) — the root crumb *is* the provider-identity element of the trail.
    /// `nil` (no provider) keeps the plain primary/secondary crumb styling.
    let providerName: String?
    let relativePath: String
    /// The pane's live show-hidden-files state, forwarded to the quick-jump menu so its sibling
    /// list matches what the pane shows.
    let showHidden: Bool
    let onNavigate: (String) -> Void
    let onNavigateBoth: (String) -> Void

    /// When on, a plain crumb click drives *both* panes — the sticky form of ⌥-click. Shared
    /// across both panes' breadcrumbs by design: one setting, mirrored in each toggle.
    @AppStorage(PaneLinkPreference.defaultsKey) private var linkBothPanes = false
    // The link toggle's "on" tint reads the user-selected glass hue, like the rest of the
    // main window (C7).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    var body: some View {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: relativePath)
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        HStack(spacing: 3) {
            crumbButton(
                name: BreadcrumbTrail.rootDisplayName(forRootPath: rootPath),
                relativePath: "",
                isCurrent: crumbs.isEmpty,
                helpPath: rootPath,
                tint: providerName.map { ProviderHue.classify($0).tint }
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
            // The quick-jump affordance on the current folder: sibling folders (the lateral hop the
            // breadcrumb and back/forward can't make), plus recent and pinned folders.
            FolderJumpMenu(
                rootPath: rootPath,
                relativePath: relativePath,
                currentName: crumbs.last?.name ?? BreadcrumbTrail.rootDisplayName(forRootPath: rootPath),
                showHidden: showHidden,
                // Route through the same link-aware path as crumbs so a lateral jump also moves
                // both panes when linked (or ⌥ is held); unlinked, it's the plain single-pane hop.
                onNavigate: { navigate(to: $0, isCurrent: false) }
            )
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
            Image(systemName: PaneGlyph.linkBothPanes)
                .foregroundColor(linkBothPanes ? hueAccent : .secondary)
        }
        .buttonStyle(.plain)
        .help(linkBothPanes
            ? "Linked: clicking a folder moves both panes. Click to unlink."
            : "Link panes: clicking a folder will move both. Tip: hold ⌥ to do it once.")
        .accessibilityLabel("Link both panes")
        .accessibilityValue(linkBothPanes ? "On" : "Off")
        .accessibilityAddTraits(linkBothPanes ? .isSelected : [])
    }

    /// `tint` carries the provider hue for the root crumb only (UX H2); path crumbs pass nil
    /// and keep the primary/secondary treatment. A tinted ancestor crumb fades slightly so the
    /// current-folder emphasis still reads.
    @ViewBuilder
    private func crumbButton(name: String, relativePath: String, isCurrent: Bool, helpPath: String, tint: Color? = nil) -> some View {
        Button(name) { navigate(to: relativePath, isCurrent: isCurrent) }
            .buttonStyle(.plain)
            .fontWeight(isCurrent ? .medium : .regular)
            .foregroundColor(tint.map { isCurrent ? $0 : $0.opacity(0.75) } ?? (isCurrent ? .primary : .secondary))
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
