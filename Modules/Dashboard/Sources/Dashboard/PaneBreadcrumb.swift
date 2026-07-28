import SwiftUI
import AppKit
import Design

/// The "Link both panes" preference. The toggle that writes it is the seam capsule's lower half
/// (`SeamPaneControls`, in the app target); the readers are spread wider — every breadcrumb crumb
/// click, and drilling into a folder from the file list (`FileActionHandler.focusFolder`), which
/// never touches a view at all. Centralizing the key here keeps all of them in sync instead of
/// duplicating the string literal.
///
/// `public` is load-bearing: the toggle now lives in the app target, across a module boundary.
public enum PaneLinkPreference {
    public static let defaultsKey = "breadcrumbLinkBothPanes"
    /// Whether the user has the panes linked. Reads the same UserDefaults key `@AppStorage` writes,
    /// so it stays true to the toggle without threading the state through every call site.
    public static var isLinked: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Clickable breadcrumb inside each `PaneHeader`: the provider root (named after the root
/// folder, full path in the tooltip) followed by the pane's relative-path segments. Clicking
/// a crumb re-focuses that pane on the ancestor; ⌥-clicking any crumb (including the current
/// folder) focuses *both* panes on the same relative path. The seam capsule's link half makes
/// that both-panes behavior sticky, so a plain click keeps the two panes in lock-step while
/// drilling down — this view only *reads* that preference now. Deep trails collapse their middle
/// into an ellipsis menu, same as the old toolbar bar did.
struct PaneBreadcrumb: View {
    let rootPath: String
    /// The pane's provider display name.
    ///
    /// It tints the root crumb with the provider's brand hue (UX H2) **on a light appearance only**.
    /// Dark drops the tint for contrast: on the surface a hue wash actually produces there —
    /// `#4d7f68`, sampled from the running app at the green hue — the brand tints measure 2.16:1
    /// (iCloud) and 1.53:1 (OneDrive) against the 4.5 text needs, and this crumb is `.caption`, the
    /// smallest text in the header. Light's surfaces are the ones those tints were drawn for and
    /// read fine, so light keeps H2 intact. See `PaneHeader.providerCapsule` for the full
    /// measurement; the name above it splits the same way.
    let providerName: String?
    let relativePath: String
    /// The pane's live show-hidden-files state, forwarded to the quick-jump menu so its sibling
    /// list matches what the pane shows.
    let showHidden: Bool
    let onNavigate: (String) -> Void
    let onNavigateBoth: (String) -> Void

    /// When on, a plain crumb click drives *both* panes — the sticky form of ⌥-click. Read-only
    /// here: the seam capsule owns the writing, and both breadcrumbs observe the same key.
    @AppStorage(PaneLinkPreference.defaultsKey) private var linkBothPanes = false
    /// Only dark drops the root crumb's brand tint — see `providerName` and `ChromeInk`.
    @Environment(\.colorScheme) private var colorScheme
    // Crumb hover washes in the user-selected glass hue, like the rest of the main window (C7).
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
                tint: ChromeInk.tint(colorScheme,
                                     light: providerName.map { ProviderHue.classify($0).tint })
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
                            .foregroundStyle(.secondary)
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
        }
        .scaledFont(.caption)
    }

    /// `tint` carries the provider hue for the root crumb, and only on a light appearance — dark
    /// passes nil (see `providerName`) and falls back to the standard hierarchy, the current folder
    /// at `.primary` and its ancestors at `.secondary`. A tinted ancestor crumb fades slightly so
    /// the current-folder emphasis still reads.
    @ViewBuilder
    private func crumbButton(name: String, relativePath: String, isCurrent: Bool, helpPath: String,
                             tint: Color? = nil) -> some View {
        Button {
            navigate(to: relativePath, isCurrent: isCurrent)
        } label: {
            Text(name)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
            .buttonStyle(.hoverAffordance(.segment, tint: hueAccent))
            .padding(.horizontal, -4)
            .padding(.vertical, -1)
            .fontWeight(isCurrent ? .medium : .regular)
            .foregroundStyle(tint.map { isCurrent ? $0 : $0.opacity(0.75) } ?? (isCurrent ? .primary : .secondary))
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
