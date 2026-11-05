import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync

/// The "Link both panes" preference. The seam capsule's lower half (`SeamPaneControls`, in the app
/// target) writes it; every crumb click and `FileActionHandler.focusFolder`, which touches no view,
/// read it. One key here keeps them in sync. Public because the toggle is in another module.
public enum PaneLinkPreference {
    public static let defaultsKey = "breadcrumbLinkBothPanes"
    /// Whether the user has the panes linked. Reads the same UserDefaults key `@AppStorage` writes,
    /// so it stays true to the toggle without threading the state through every call site.
    public static var isLinked: Bool { isLinked(in: .standard) }
    /// The same read against a given store, so `FileActionHandler`'s tests can hand it a scratch
    /// suite instead of the machine-wide standard domain.
    public static func isLinked(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// The breadcrumb's source chip, as numbers.
///
/// Out of the view so `PaneSourceChipTests` can hold the chip's size against the bar's without
/// restating literals. Nothing else draws this chip, so it describes one control, not a
/// design-system vocabulary (see `GeometryScale`).
public enum SourceChip {
    /// Between the brand mark and the name.
    public static let gap: CGFloat = 6
    /// The brand mark's box. Larger than a crumb's text because a mark reads smaller than type at
    /// the same nominal size (`ProviderLogo` insets a symbol to 0.82 for the same reason).
    public static let markSize: CGFloat = 18
    /// One step above the trail's `.callout`.
    public static let font: ScaledFont = .body
    /// Asymmetric on purpose: the mark carries its own optical padding on the leading side, and the
    /// trailing side has to clear the menu's disclosure indicator.
    public static let leading: CGFloat = 6
    public static let trailing: CGFloat = 7
    /// Enough for the capsule to contain the name rather than hug it, so the chip doesn't read
    /// small beside a 20pt bar control.
    public static let vertical: CGFloat = 3

    /// The brand wash behind the name.
    ///
    /// Above `ProviderHue.soft` and `PillVariant.fillOpacity` on purpose: a status pill is one of
    /// many on a row, while this is the one thing that says which account the pane shows. In dark the
    /// name's brand tint is dropped for contrast, so this and the hairline are the whole signal.
    public static let washOpacity: Double = 0.18
    /// The hairline that makes the wash read as a bounded control, not a highlight. It also
    /// separates this chip's disclosure mark from the quick-jump menu's just outside it (see
    /// `PaneBreadcrumb.rootCrumb`).
    public static let strokeOpacity: Double = 0.30
    public static let strokeWidth: CGFloat = 0.75
}

/// Clickable breadcrumb inside each `PaneHeader`: the source itself (named after the source,
/// "iCloud" or "OneDrive (EMP)", with the root's full path in the tooltip), then the pane's
/// relative-path segments from the root down. A source's root is the account folder, so levels
/// like Google Drive's `My Drive` are ordinary crumbs, and the first crumb goes to the top of the
/// account. Clicking a crumb re-focuses that pane on the ancestor; ⌥-click (current folder
/// included) focuses both panes on the same relative path. The seam capsule's link half makes that
/// sticky, and this view only reads the preference. Deep trails collapse their middle into an
/// ellipsis menu.
struct PaneBreadcrumb: View {

    /// The source-switching half of the first crumb.
    ///
    /// A value rather than loose parameters, so a caller either supplies the whole picker or none:
    /// no half-configured state where the mark is drawn but the menu does nothing.
    struct SourcePicker {
    /// Brand asset or SF Symbol for the mark, the same string `ProviderLogo` takes elsewhere.
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
    /// Tints the root crumb with the provider's brand hue on a light appearance only. On the dark
    /// surface a hue wash produces, the brand tints measure about 2.2:1 (iCloud) and 1.5:1 (OneDrive)
    /// against the 4.5:1 text needs, which fails at any size. Light's surfaces are the ones the
    /// tints were drawn for.
    let providerName: String?
    /// Whether that source is a plain folder rather than a cloud account: a folder wears
    /// `ProviderHue.folder` (graphite), which no display name can classify into. Defaults to false
    /// for callers with no source in hand.
    var providerIsLocalFolder: Bool = false
    /// What the first crumb needs to be the source picker as well as the top of the path, or nil
    /// for a caller with no source to switch (the tests, any trail-only surface). Nil draws a plain
    /// crumb: tinted text, no mark, no menu. Folding the picker into the crumb gives the pane bar
    /// the whole header track instead of a second picker restating the trail's first crumb.
    var sourcePicker: SourcePicker?
    let relativePath: String
    /// The pane's live show-hidden-files state, forwarded to the quick-jump menu so its sibling
    /// list matches what the pane shows.
    let showHidden: Bool
    let onNavigate: (String) -> Void
    /// Nil when there is no second pane (every workspace but Compare). The crumbs then move this
    /// pane only, ⌥ and the link preference included, and their tooltips don't mention both panes.
    let onNavigateBoth: ((String) -> Void)?
    /// Falls back to the compact trail (`BreadcrumbTrail.compactItems`) when the whole one doesn't
    /// fit. On only for Edit's pane, which is one column wide by default, where every crumb would
    /// truncate to a letter and a half.
    var compactsWhenNarrow: Bool = false

    /// When on, a plain crumb click drives both panes, the sticky form of ⌥-click. Read-only here:
    /// the seam capsule writes it, and both breadcrumbs observe the same key.
    @AppStorage(PaneLinkPreference.defaultsKey) private var linkBothPanes = false
    /// Only dark drops the root crumb's brand tint (see `providerName` and `ChromeInk`).
    @Environment(\.colorScheme) private var colorScheme
    /// The app's text size. Needed explicitly because the first crumb's name is a `Menu` label that
    /// AppKit draws, and the enclosing `.scaledFont(.callout)` does not reach it.
    @Environment(\.appFontScale) private var appFontScale
    // Crumb hover washes in the user-selected glass hue, like the rest of the main window.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    var body: some View {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: relativePath)
        if compactsWhenNarrow {
            // The whole trail at its ideal width if the row holds it; otherwise the compact one.
            // `ViewThatFits` measures each at its ideal width, before any name truncates, so a
            // trail that would only fit by cutting names to "C…6" does not count as fitting.
            ViewThatFits(in: .horizontal) {
                trail(crumbs: crumbs, items: BreadcrumbTrail.displayItems(for: crumbs))
                trail(crumbs: crumbs, items: BreadcrumbTrail.compactItems(for: crumbs))
            }
        } else {
            trail(crumbs: crumbs, items: BreadcrumbTrail.displayItems(for: crumbs))
        }
    }

    private func trail(crumbs: [BreadcrumbTrail.Crumb], items: [BreadcrumbTrail.Item]) -> some View {
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
                    // The current folder keeps its name before the source chip gives up its own.
                    .layoutPriority(crumb == crumbs.last ? 1 : 0)
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
                    // Hidden here, unlike the source chip's: the ellipsis IS this menu's mark, and a
                    // system arrow beside it would draw two disclosure marks on one control.
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
        // `.callout`, not `.caption`: the header is pinned to `LiquidGlass.headerHeight`, and the
        // row has room to spare below the crumbs even at the narrow and titled rungs and the
        // largest text scale. `PaneHeaderHeightTests` fails if the two rows stop fitting.
        .scaledFont(.callout)
    }

    /// The first crumb: the source itself, and the source picker.
    ///
    /// One chip, one menu: a click anywhere on it opens the source menu, whose first item goes to
    /// the top of the source and whose rest switch source. Splitting mark and name into two targets
    /// fails, because a 15pt brand mark is no affordance and the nearest thing that looks like one
    /// is the current folder's quick-jump chevron, which opens a different menu.
    ///
    /// The chip shows a disclosure mark. At a source root it is the only crumb, so without one the
    /// row's only chevron would be the quick-jump menu's. The bounded, washed, hairlined capsule keeps
    /// the two marks reading as one inside the chip and one outside it.
    ///
    /// The mark must be the `Menu`'s own indicator: in this AppKit-drawn label,
    /// `Text(Image(systemName:))` and `Image(nsImage:)` silently draw nothing. Only
    /// `.menuIndicator(.visible)` puts one there.
    ///
    /// The chip is heavier than a crumb on purpose (6/7/3 padding against 4/1, an 18pt mark, `.body`
    /// against `.callout`): with a hairline and a disclosure mark it is a control, and a control may
    /// outweigh the crumbs after it. Its wash (`SourceChip.washOpacity`) is the fastest "which
    /// account am I in" signal on the pane, and in dark, where the name's tint is dropped, the wash
    /// and hairline carry it alone.
    ///
    /// **Keep `inAppKitLabel` on the mark.** `ProviderMenu` is `borderlessButton`, so AppKit draws
    /// this label, and a `.resizable()` image there ignores its frame and draws at the asset's native
    /// 512pt, spreading across the pane and pushing the bar off the row. `MenuLabelMarkTests` checks
    /// it in the app target, since package tests can't see the brand assets.
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
                // Through `navigate`, not straight to `onNavigate`, so going to the top of the
                // source obeys the link preference like any other crumb.
                onGoToRoot: { navigate(to: "", isCurrent: isCurrent) }
            ) {
                HStack(spacing: SourceChip.gap) {
                    ProviderLogo(sourcePicker.imageName, size: SourceChip.markSize, inAppKitLabel: true)
                    Text(name)
                        // `Text.scaledFont(_:scale:)`, not the View modifier or the enclosing
                        // `.scaledFont(.callout)`: AppKit renders this `Menu` label itself, so a
                        // wrapped `Text` would arrive without the weight or colour set here. One
                        // step above the trail's `.callout` (see this method's doc).
                        .scaledFont(SourceChip.font.weight(isCurrent ? .medium : .regular), scale: appFontScale)
                        .foregroundStyle(tint ?? (isCurrent ? .primary : .secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            // The chip says it opens something. It must be the menu's own indicator, not a glyph in
            // the label (see the doc above).
            .menuIndicator(.visible)
            // The wash goes outside the menu, not on its label: AppKit draws the label and doesn't
            // paint a `.background` inside it, which would lose the "which account is this" signal.
            .padding(.leading, SourceChip.leading)
            .padding(.trailing, SourceChip.trailing)
            .padding(.vertical, SourceChip.vertical)
            .background {
                // Both read the same optional, so a crumb with no source at all (`providerName`
                // nil: the tests and trail-only surfaces) gets neither wash nor hairline. A
                // `.neutral` source has a hue whose `tint` follows the app accent, and wears both.
                Capsule(style: .continuous)
                    .fill(hue?.tint.opacity(SourceChip.washOpacity) ?? .clear)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(hue?.tint.opacity(SourceChip.strokeOpacity) ?? .clear,
                                          lineWidth: SourceChip.strokeWidth)
                    }
            }
            // Frosted and Clear: glass under the wash, like every bar button (`ChromeGlass`). The
            // brand wash stays painted on top rather than becoming the glass's tint, which follows
            // the Tint slider and accent and would vanish at None. Gated on the same optional as the
            // wash. The brand hairline is the pill's edge, so Clear adds no rim under it.
            .chromeGlassGround(.capsule, rim: false, when: hue != nil)
            .help("Go to \(rootPath), or switch this pane’s source")
            .accessibilityLabel("Source, \(name)")
        } else {
            crumbButton(name: name, relativePath: "", isCurrent: isCurrent,
                        helpPath: rootPath, tint: tint)
        }
    }

    /// `tint` carries the provider hue for the root crumb, on a light appearance only. Dark passes
    /// nil (see `providerName`) and falls back to the standard hierarchy: the current folder at
    /// `.primary`, ancestors at `.secondary`. A tinted ancestor fades slightly so the current
    /// folder still stands out.
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
            .help(Self.crumbHelp(isCurrent: isCurrent, helpPath: helpPath,
                                 linked: linkBothPanes, hasSecondPane: onNavigateBoth != nil))
    }

    /// A tooltip that stays honest whether the panes are linked or not: linked, a plain click
    /// already drives both, so it says so instead of the ⌥ instruction. With no second pane it
    /// names the destination and stops; the link preference is shared with Compare and stays set.
    static func crumbHelp(isCurrent: Bool, helpPath: String, linked: Bool, hasSecondPane: Bool) -> String {
        let destination = isCurrent ? helpPath : "Go to \(helpPath)"
        guard hasSecondPane else { return destination }
        return linked
            ? "\(destination) — panes are linked, so both move here"
            : "\(destination) — ⌥-click to bring both panes here"
    }

    /// Moves both panes to the crumb's path when linked or ⌥ is held and there is a second pane;
    /// otherwise moves only this pane. A plain click on the current folder's crumb does nothing,
    /// so it doesn't pollute the back/forward history.
    private func navigate(to relativePath: String, isCurrent: Bool) {
        let wantsBoth = linkBothPanes || NSEvent.modifierFlags.contains(.option)
        if wantsBoth, let onNavigateBoth {
            onNavigateBoth(relativePath)
        } else if !isCurrent {
            onNavigate(relativePath)
        }
    }
}
