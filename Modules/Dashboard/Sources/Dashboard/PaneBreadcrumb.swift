import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync

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

/// Clickable breadcrumb inside each `PaneHeader`: the source itself (named after the *source* —
/// "iCloud", "OneDrive (HPE)" — with the root's full path in the tooltip) followed by the pane's
/// relative-path segments, spelled out from the root down. Since a source's root is the account
/// folder rather than the `Documents` inside it, the levels between — Google Drive's `My Drive`,
/// OneDrive's `Documents` — are ordinary crumbs here, and the first crumb goes to the top of the
/// account rather than to the folder panes happen to open at. Clicking
/// a crumb re-focuses that pane on the ancestor; ⌥-clicking any crumb (including the current
/// folder) focuses *both* panes on the same relative path. The seam capsule's link half makes
/// that both-panes behavior sticky, so a plain click keeps the two panes in lock-step while
/// drilling down — this view only *reads* that preference now. Deep trails collapse their middle
/// into an ellipsis menu, same as the old toolbar bar did.
struct PaneBreadcrumb: View {

    /// The source-switching half of the first crumb.
    ///
    /// A value rather than five loose parameters, so that "this crumb picks sources" is one thing a
    /// caller either supplies or does not — there is no half-configured state where the mark is
    /// drawn but the menu does nothing.
    struct SourcePicker {
        /// Brand asset or SF Symbol for the mark — the same string `ProviderLogo` takes elsewhere.
        let imageName: String
        let currentId: String
        let providers: [CloudProvider]
        let onSelect: (String) -> Void
        let onManage: () -> Void
        let onChooseFolder: (() -> Void)?
    }

    let rootPath: String
    /// The pane's provider display name.
    ///
    /// It tints the root crumb with the provider's brand hue (UX H2) **on a light appearance only**.
    /// Dark drops the tint for contrast: on the surface a hue wash actually produces there —
    /// `#4d7f68`, sampled from the running app at the green hue — the brand tints measure 2.16:1
    /// (iCloud) and 1.53:1 (OneDrive) against the 4.5 text needs. Light's surfaces are the ones
    /// those tints were drawn for and read fine, so light keeps H2 intact.
    ///
    /// The measurement stands, but one of its reasons has expired and is worth retiring with it:
    /// this used to add "and this crumb is `.caption`, the smallest text in the header", which was
    /// the aggravating factor. The trail is `.callout` now — the header's only other text was the
    /// retired provider capsule's name, and the trail grew into the room that left. **A ratio of
    /// 1.53:1 fails at any size**, so the split is unchanged; there is simply no longer a smallness
    /// argument propping it up.
    let providerName: String?
    /// Whether that source is a plain folder rather than a cloud account — a folder wears
    /// `ProviderHue.folder` (graphite), which no display name can classify into. Defaulted so the
    /// crumb keeps its old behaviour for every caller that has no source in hand.
    var providerIsLocalFolder: Bool = false
    /// What the first crumb needs to be the **source picker** as well as the top of the path, or
    /// nil for a caller with no source to switch (the tests, and any surface that only shows a
    /// trail). Nil renders exactly the crumb this view drew before: tinted text, no mark, no menu.
    ///
    /// This arrived when the pane header's provider capsule was retired. That capsule was a second
    /// source picker — logo, name, dropdown — sitting directly above a breadcrumb whose first crumb
    /// had just become able to name the source and navigate to it, so the header spent its widest
    /// element (about 300pt at a comfortable width) restating its own second row. Folding it in
    /// here is what let the bar have the whole track.
    var sourcePicker: SourcePicker?
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
    /// The app's text size. Needed explicitly because the first crumb's name is a `Menu` label that
    /// AppKit draws, and the enclosing `.scaledFont(.callout)` does not reach it.
    @Environment(\.appFontScale) private var appFontScale
    // Crumb hover washes in the user-selected glass hue, like the rest of the main window (C7).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    var body: some View {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: relativePath)
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        HStack(spacing: 3) {
            rootCrumb(isCurrent: crumbs.isEmpty)

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
                    .accessibilityLabel("Collapsed folders")
                }
            }
            // The quick-jump affordance on the current folder: sibling folders (the lateral hop the
            // breadcrumb and back/forward can't make), plus recent and pinned folders.
            FolderJumpMenu(
                rootPath: rootPath,
                relativePath: relativePath,
                currentName: crumbs.last?.name ?? BreadcrumbTrail.rootDisplayName(forRootPath: rootPath, providerName: providerName),
                showHidden: showHidden,
                // Route through the same link-aware path as crumbs so a lateral jump also moves
                // both panes when linked (or ⌥ is held); unlinked, it's the plain single-pane hop.
                onNavigate: { navigate(to: $0, isCurrent: false) }
            )
            Spacer(minLength: 0)
        }
        // **`.callout`, not `.caption`.** The header is pinned to `LiquidGlass.headerHeight` so its
        // bottom edge lands on the same rule as the lens header card, and the trail was sized as if
        // that budget were tight. It is not: measured through the drawn rings, the row leaves 19–20.5pt
        // unused below the crumbs at EVERY case that matters — the narrow rung, the titled rung, and
        // the 1.35 text scale — so the smallest text in the app was sitting in a card with a fifth of
        // its height spare. Two steps up spends some of that and stays well inside the budget; the
        // guard is `PaneHeaderHeightTests`, which fails if the two rows stop fitting their card.
        .scaledFont(.callout)
    }

    /// The first crumb: the source itself, and the source picker.
    ///
    /// **One chip, one menu.** Clicking anywhere on it — mark or name — opens the source menu, whose
    /// first item goes to the top of the current source and whose rest switches source.
    ///
    /// **It was built the other way first, and that was tried and reported.** The mark opened the
    /// menu and the name went to the root: two targets in one chip, split so that the larger target
    /// served the commoner act. What that missed is that a 15pt brand mark is not an affordance, and
    /// the only thing beside this chip that *looks* like one is the quick-jump chevron a few points
    /// to its right — which belongs to the current folder, not to the source. The first click landed
    /// there, got Recent/Pin, and the reasonable conclusion was that the picker had been dropped.
    ///
    /// So the two acts share one target and the menu separates them, which also settles what the
    /// split was avoiding: there is still no disclosure mark here, because at the root the trail is
    /// one crumb and a chevron would render `Google Drive (HPE) ⌄ ⌄`, two adjacent marks opening
    /// unrelated menus. The washed chip is the affordance instead.
    ///
    /// The wash is the retired capsule's, at the capsule's own opacity: with four sources across
    /// three brands, the soft brand tint behind the name is the fastest "which account am I in"
    /// signal on the pane, and losing it was the one thing retiring the capsule would have cost.
    ///
    /// **`inAppKitLabel` is the load-bearing word on the mark**, and it is not a style choice.
    /// `ProviderMenu` is `borderlessButton`, so AppKit draws this label, and a `.resizable()` image
    /// in one of those ignores its frame and draws at the asset's native 512pt. That shipped once:
    /// the header came up with the source's mark spread across the whole pane and the bar pushed
    /// off the row. `MenuLabelMarkTests` measures it now, in the app target, because the brand
    /// assets are invisible from a package test and every snapshot here measures an SF Symbol
    /// standing in for the thing that broke.
    @ViewBuilder
    private func rootCrumb(isCurrent: Bool) -> some View {
        let name = BreadcrumbTrail.rootDisplayName(forRootPath: rootPath, providerName: providerName)
        let hue = providerName.map { ProviderHue.classify($0, isLocalFolder: providerIsLocalFolder) }
        let tint = ChromeInk.tint(colorScheme, light: hue?.tint)
        if let sourcePicker {
            ProviderMenu(
                providers: sourcePicker.providers,
                currentId: sourcePicker.currentId,
                onSelect: sourcePicker.onSelect,
                onManage: sourcePicker.onManage,
                onChooseFolder: sourcePicker.onChooseFolder,
                // Routed through `navigate`, not straight to `onNavigate`, so going to the top of
                // the source obeys the link preference exactly as clicking any other crumb does.
                onGoToRoot: { navigate(to: "", isCurrent: isCurrent) }
            ) {
                HStack(spacing: 5) {
                    ProviderLogo(sourcePicker.imageName, size: 15, inAppKitLabel: true)
                    Text(name)
                        // `Text.scaledFont(_:scale:)`, not the View modifier, and not the enclosing
                        // `.scaledFont(.callout)` either: this is a `Menu` label and AppKit renders
                        // it itself, so a wrapped `Text` arrives with neither the weight nor the
                        // colour set here. The retired provider capsule carried the same note.
                        //
                        // **The same style the trail would have given it**, which is the whole
                        // point of restating it — this sat at `.body` while the trail was
                        // `.callout`, so the source name drew one step larger than the crumbs
                        // beside it (a 16pt chip against the quick-jump menu's 14) and read as a
                        // heading over the trail rather than as its first crumb. Rendered both
                        // ways before choosing: the emphasis the row wants is already carried by
                        // the current crumb's medium weight.
                        .scaledFont(.callout.weight(isCurrent ? .medium : .regular), scale: appFontScale)
                        .foregroundStyle(tint ?? (isCurrent ? .primary : .secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            // No disclosure mark: the quick-jump menu owns one a few points to the right, and two
            // adjacent chevrons onto unrelated menus is exactly the confusion this chip caused in
            // the other direction. The washed chip is the affordance.
            .menuIndicator(.hidden)
            // **The wash goes OUTSIDE the menu, not on its label**, for the same reason the name's
            // font and colour are set on the `Text` rather than inherited: AppKit draws this label
            // and a `.background` inside one is simply not painted. It was inside for one recording
            // and the references came back with the crumb's brand wash missing entirely — which is
            // the whole "which account is this" signal, and the one thing retiring the capsule was
            // not supposed to cost. The retired capsule put its own surface here too.
            .padding(.leading, 3)
            .padding(.trailing, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(hue?.soft ?? .clear))
            .help("Go to \(rootPath), or switch this pane's source")
            .accessibilityLabel("Source, \(name)")
        } else {
            crumbButton(name: name, relativePath: "", isCurrent: isCurrent,
                        helpPath: rootPath, tint: tint)
        }
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
