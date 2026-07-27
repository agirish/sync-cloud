import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Header above each file tree pane: provider logo and name on the left, this pane's
/// back/forward buttons on the right, and a clickable breadcrumb (provider root +
/// relative-path segments) below. Clicking a crumb navigates this pane; ⌥-clicking
/// navigates both panes to the same relative path.
public struct PaneHeader: View {
    /// The app's text size, for the labels that have to stay a `Text` (see `providerCapsule`).
    @Environment(\.appFontScale) private var appFontScale
    public let title: String
    public let provider: CloudProvider?
    public let rootPath: String
    public let relativePath: String
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let onBack: () -> Void
    public let onForward: () -> Void
    public let onNavigate: (String) -> Void
    public let onNavigateBoth: (String) -> Void
    /// The enabled providers this pane can switch between — the provider name is now a dropdown
    /// (replacing the old Left/Right sidebar). Empty hides the dropdown affordance.
    public let providers: [CloudProvider]
    /// Switches this pane to the chosen provider id.
    public let onSelectProvider: (String) -> Void
    /// Opens Settings ▸ Providers (the "Manage providers…" menu item).
    public let onManageProviders: () -> Void
    /// The (global) sort order, surfaced per-pane now that the titlebar's file actions have moved
    /// onto the panes.
    @Binding public var sortOption: SortOption
    /// When set, shows a collapse button in the nav cluster — used by the single-source Tidy rail to
    /// collapse itself back to the spine directly (not only via the titlebar pane toggle). nil on the
    /// comparison panes, which don't collapse individually.
    public let onCollapse: (() -> Void)?
    /// Triggers a scan/refresh — moved off the titlebar into each pane's nav cluster. nil hides it.
    public let onRefresh: (() -> Void)?
    /// Spins the refresh glyph while a scan is running.
    public let isRefreshing: Bool
    /// Whether hidden files are shown. A per-pane control for the (global) setting, so it lives
    /// right next to each pane's navigation buttons.
    @Binding public var showHiddenFiles: Bool
    /// This pane's presentation. `nil` hides the switch entirely — the Tidy rail has no Columns
    /// mode, so it gets no control for one.
    public var viewMode: Binding<PaneViewMode>?
    /// Creates a folder in the pane's current folder — in Columns that is the deepest open column,
    /// which is the one genuinely unambiguous answer the tree view could never give. `nil` hides it.
    public let onNewFolder: (() -> Void)?
    // No surface style here: the header's shape comes from its container, its material from the
    // glass level. This view only paints the tint. It does read the level back, though — the nav
    // cluster stopped needing it when it was drawn in-house (6bb7bdf), but the provider capsule
    // needs it again: at Clear the header is see-through to the desktop, and the capsule has to
    // floor itself to frosted so the logo and name keep a ground (`chromePillSurface`).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }
    private var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? .frosted
    }

    public init(
        title: String,
        provider: CloudProvider?,
        rootPath: String,
        relativePath: String,
        canGoBack: Bool,
        canGoForward: Bool,
        onBack: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onNavigate: @escaping (String) -> Void,
        onNavigateBoth: @escaping (String) -> Void,
        providers: [CloudProvider] = [],
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        sortOption: Binding<SortOption>,
        onCollapse: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        showHiddenFiles: Binding<Bool>,
        viewMode: Binding<PaneViewMode>? = nil,
        onNewFolder: (() -> Void)? = nil
    ) {
        self.title = title
        self.provider = provider
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onBack = onBack
        self.onForward = onForward
        self.onNavigate = onNavigate
        self.onNavigateBoth = onNavigateBoth
        self.providers = providers
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self._sortOption = sortOption
        self.onCollapse = onCollapse
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self._showHiddenFiles = showHiddenFiles
        self.viewMode = viewMode
        self.onNewFolder = onNewFolder
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let provider = provider {
                    // In a narrow pane the provider NAME is the identity anchor: with the whole
                    // capsule at the row's highest layoutPriority it is offered width before the
                    // nav cluster's full-size variant, so under constraint the cluster steps down
                    // to `.mini` first, then the name middle-truncates, and only then (below the
                    // logo variant's readable floor) the logo drops.
                    ViewThatFits(in: .horizontal) {
                        providerCapsule(provider, showsLogo: true)
                        providerCapsule(provider, showsLogo: false)
                    }
                    .layoutPriority(2)
                } else {
                    Image(systemName: "folder")
                        .scaledFont(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .scaledFont(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                navCluster
            }
            PaneBreadcrumb(
                rootPath: rootPath,
                providerName: provider?.displayName,
                relativePath: relativePath,
                showHidden: showHiddenFiles,
                onNavigate: onNavigate,
                onNavigateBoth: onNavigateBoth
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Pinned, not intrinsic — this header and Tidy's `LensHeaderCard` both read
        // `headerHeight`, so the pane's header↔list boundary and the card's bottom edge land on
        // the same rule (83.5 = cardInset + headerHeight) instead of merely happening to agree.
        //
        // They did NOT agree before this: measured, the intrinsic height was 80 at a comfortable
        // width, 68 once the nav cluster stepped down to `.mini` in a ~250pt pane, and 66 with no
        // provider — so the line the two surfaces were supposed to share drifted by up to 15pt,
        // worst exactly when panes are narrow. The extra point (80 → 81) is slack absorbed by the
        // symmetric vertical padding; the narrow cases gain real air and stop breaking the line.
        .frame(height: LiquidGlass.headerHeight)
        .contentSurface(hue: glassHue, tint: surfaceTint)
    }

    /// The provider capsule. UX H2's hue still washes behind it (`hue.soft`) so the two panes are
    /// distinguishable — and visibly matching — at a glance, but the NAME is the standard label
    /// colour, not the brand tint.
    ///
    /// H2 tinted the name, and `ProviderHue`'s dark variants were lifted to clear AA "on the app's
    /// dark surfaces". Measured against the surface a hue wash actually produces, they do not:
    /// sampled from the running app at the green hue, the pane reads `#4d7f68` — a mid-tone, not a
    /// dark one — and on it iCloud's `#6FB6FF` is 2.16:1 and OneDrive's `#3E9BE0` is 1.53:1, against
    /// 4.5 for text. Plain white is 4.61:1, which is why the folder names in the list below read
    /// perfectly on the same pixels while the provider name above them did not. The wash was tuned
    /// as a background and then had text put on it.
    ///
    /// So identity moves to the logo and the wash, and the name buys legibility with lightness
    /// instead of chroma. `ProviderHue.tint` is still right for a hairline or a fill — this is only
    /// about text on a washed surface, which is also true of `PaneBreadcrumb`'s root crumb.
    ///
    /// The name + chevron is the menu trigger;
    /// the logo stays a plain image OUTSIDE the menu label (a resizable image inside one balloons
    /// to its native size). ViewThatFits compares each variant's IDEAL width against the offer,
    /// so the logo variant wins only while the full name fits alongside it; once the name would
    /// have to give up characters, the logo yields first and the logo-less variant truncates the
    /// name as far as an ellipsis — the name is the identity anchor, the logo is decoration.
    private func providerCapsule(_ provider: CloudProvider, showsLogo: Bool) -> some View {
        let hue = ProviderHue.classify(provider.displayName)
        return HStack(spacing: 10) {
            if showsLogo {
                ProviderLogo(provider.imageName, size: 28)
            }
            ProviderMenu(
                providers: providers,
                currentId: provider.id,
                onSelect: onSelectProvider,
                onManage: onManageProviders
            ) {
                Text(provider.displayName)
                    // `Text.scaledFont(_:scale:)`, not the View modifier: this is a `Menu`
                    // label, and AppKit renders it itself — a wrapped Text loses both the
                    // weight and the colour below.
                    .scaledFont(.headline.weight(.semibold), scale: appFontScale)
                    .foregroundStyle(.primary)
                    // A long custom provider name must truncate, not wrap the
                    // header taller in a narrow pane. Middle truncation is the intent, but the
                    // menu style's AppKit-backed label ignores the preference and elides the
                    // tail (verified in the 250/400 pt snapshots; setting the environment value
                    // on the Menu itself changes nothing either) — the load-bearing part is
                    // that the name truncates at all instead of ballooning the row.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .help("Switch this pane's cloud provider")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .chromePillSurface(glassLevel, wash: hue.soft)
    }

    /// This pane's navigation/action buttons. Rendered through ViewThatFits so that at the
    /// narrowest pane widths (the split clamps panes at 250 pt, where small-size controls plus
    /// the provider capsule physically exceed the row) the cluster steps down to `.mini`
    /// controls instead of overflowing the pane's trailing edge — every control stays present
    /// and clickable, nothing is pushed out of view.
    private var navCluster: some View {
        ViewThatFits(in: .horizontal) {
            navClusterContent(.small, fold: .none)
            navClusterContent(.mini, fold: .none)
            navClusterContent(.mini, fold: .viewOptions)
            navClusterContent(.mini, fold: .all)
        }
    }

    /// How much of the cluster has collapsed into the ⋯ menu at this rung.
    ///
    /// The cluster was already at the edge of what a 250pt pane can hold — 159pt of controls in a
    /// 222pt content box, leaving 51pt for a provider name that is already an ellipsis. Adding a
    /// view switch and New Folder inline costs 255pt, which overruns the box by 33pt before the
    /// capsule gets a point. So the extra controls arrive by folding the *rarely-pressed* ones
    /// away as the pane narrows — sort and hidden-files first, which is where Finder keeps them
    /// anyway — and at the floor the cluster is back to five pills, exactly today's geometry.
    ///
    /// Refresh never folds: it is the pane's scan control, not a view preference.
    private enum ClusterFold {
        case none
        /// Sort and hidden-files move into ⋯.
        case viewOptions
        /// The view switch becomes a single menu and New Folder joins ⋯ as well.
        case all
    }

    private func navClusterContent(_ controlSize: ControlSize, fold: ClusterFold) -> some View {
        HStack(spacing: 6) {
            if let viewMode {
                if fold == .all {
                    // One pill showing the current mode; the alternatives live in its menu.
                    Menu {
                        Picker("View", selection: viewMode) {
                            ForEach(PaneViewMode.allCases) { mode in
                                Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Image(systemName: viewMode.wrappedValue.symbol)
                            .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .buttonStyle(navButtonStyle)
                    .fixedSize()
                    .help("Choose how this pane shows its files")
                } else {
                    viewModeSwitch(viewMode, controlSize: controlSize)
                }
            }

            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .help("Collapse the source pane")
            }

            Button(action: onBack) {
                Image(systemName: "chevron.left").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .buttonStyle(navButtonStyle)
            .disabled(!canGoBack)
            .help("Go back to this pane's previous folder")

            Button(action: onForward) {
                Image(systemName: "chevron.right").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .buttonStyle(navButtonStyle)
            .disabled(!canGoForward)
            .help("Go forward to this pane's next folder")

            // Scan/refresh used to live INSIDE the pane's freshness badge, pairing the action
            // with the state it acted on, and this standalone button existed only for the
            // pre-scan window where that badge had no date to show. Freshness has since moved to
            // the differences count pill — a toggle, so it cannot also be the scan button — which
            // makes this the pane's one scan control at every point in the lifecycle. Ungated
            // accordingly: a gate here now means a pane that can never be scanned.
            if let onRefresh {
                // The arrow spins while a scan runs (reduced-motion is honored automatically).
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .disabled(isRefreshing)
                .help("Scan for changes")
            }

            // New Folder. In Columns its target is unambiguous — the deepest open column — which
            // is why it graduates from the right-click menu to the chrome here.
            if let onNewFolder, fold != .all {
                Button(action: onNewFolder) {
                    Image(systemName: "folder.badge.plus")
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .help("New folder in this pane's current folder")
            }

            // Sort moved out of the titlebar (its file-action neighbors are now the pane's
            // contextual action bar); it lives per-pane, driving the shared sort order.
            if fold == .none {
            Menu {
                Picker("Sort By", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .menuIndicator(.hidden)
            // The one combination that leaves the label alone. `.button` makes the menu render as
            // a button; `.plain` inside `navButtonStyle` stops that button drawing chrome of its
            // own over the capsule the label already carries. Measured at 21x20 painted —
            // pixel-identical to a plain Button, which nothing else here managed.
            //
            // A `Menu` also does NOT inherit a `buttonStyle` from an ancestor, so this has to be
            // restated on the menu itself rather than left to the cluster.
            .menuStyle(.button)
            .buttonStyle(navButtonStyle)
            .fixedSize()
            .help("Choose how items are sorted")

            // Hidden-files toggle, icon-only, sitting beside the nav buttons. The eye
            // mirrors the state: open when hidden files are shown, slashed when filtered.
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .buttonStyle(navButtonStyle)
            .help(showHiddenFiles
                  ? "Hidden files are visible — click to hide them"
                  : "Hidden files are hidden — click to show them")
            }

            if fold != .none {
                viewOptionsMenu(controlSize: controlSize, fold: fold)
            }
        }
        .controlSize(controlSize)
    }

    /// Tree | Columns as a two-segment control, built from the same plain buttons as the window's
    /// tab picker: a `Picker(.segmented)` renders neutral inside macOS 26 glass chrome and ignores
    /// `.tint`, so the selected segment could never carry the app accent.
    private func viewModeSwitch(_ mode: Binding<PaneViewMode>, controlSize: ControlSize) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return HStack(spacing: 3) {
            ForEach(PaneViewMode.allCases) { candidate in
                let isSelected = mode.wrappedValue == candidate
                Button {
                    mode.wrappedValue = candidate
                } label: {
                    Image(systemName: candidate.symbol)
                        .scaledFont(PaneNavMetrics.glyphFont(controlSize))
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(glassHue.onAccentLabelColor)
                                         : AnyShapeStyle(Color.primary.opacity(0.75)))
                        .frame(width: pill.width - 4, height: pill.height)
                        .background(isSelected ? AnyShapeStyle(glassHue.accentFillColor) : AnyShapeStyle(Color.clear),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: glassHue.accentFillColor))
                // These stand in for a Picker, so they restate the selected-state semantics it
                // would have given VoiceOver for free.
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .help(candidate.help)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane view")
    }

    /// The ⋯ overflow. Holds whatever the current rung folded away, so nothing is ever merely
    /// dropped — a narrow pane loses the pill, not the ability.
    private func viewOptionsMenu(controlSize: ControlSize, fold: ClusterFold) -> some View {
        Menu {
            if fold == .all, let viewMode {
                Picker("View", selection: viewMode) {
                    ForEach(PaneViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }
            if fold == .all, let onNewFolder {
                Button(action: onNewFolder) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Divider()
            }
            Picker("Sort By", selection: $sortOption) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(isOn: $showHiddenFiles) {
                Label("Show Hidden Files", systemImage: showHiddenFiles ? "eye" : "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(navButtonStyle)
        .fixedSize()
        .help("View options")
    }

    /// Shared by every nav control. `.filled` contributes the press scale and the hover phase
    /// `PaneNavChrome` reads, and paints no wash of its own — the capsule's fill is the wash.
    private var navButtonStyle: HoverAffordanceStyle {
        .hoverAffordance(.filled, tint: glassHue.accentColor, shape: .capsule)
    }
}

/// Sizing for the pane header's nav cluster.
///
/// Liquid Glass takes a button's size straight from its label, so six different SF Symbols gave
/// six different pill heights — 17.5 for the chevrons, 20 for `eye.slash`, 18.5 for the sort
/// arrows — and the sort menu came in at 14, visibly the runt of the row. Pinning one height on
/// every glyph levels all six at 20 (16 at `.mini`) without moving a single width; the menu needs
/// its height set outright, because `ButtonMenuStyle` pins its own and no label padding moves it.
///
/// All figures measured with `NSHostingView.fittingSize` and pinned by `PaneNavMetricsTests`.
enum PaneNavMetrics {
    /// The pill every nav control draws, per control size.
    ///
    /// Fixed, because nothing else worked. Liquid Glass sizes a button from its label, so six SF
    /// Symbols gave six pill heights and `ButtonMenuStyle` pinned the sort menu at 14 regardless.
    /// An outer `.frame(height:)` does NOT stretch a system-drawn pill — it only gives it a taller
    /// box to sit inside, which is why an earlier fix measured 20 and still rendered 14. Drawing
    /// the capsule ourselves is the only way the size is actually ours.
    static func pill(_ controlSize: ControlSize) -> CGSize {
        controlSize == .mini ? CGSize(width: 27, height: 17) : CGSize(width: 33, height: 20)
    }

    /// An explicit symbol size, so the glyphs stop each having their own intrinsic metrics.
    static func glyphFont(_ controlSize: ControlSize) -> ScaledFont {
        .system(size: controlSize == .mini ? 10 : 12, weight: .medium)
    }

    /// Laid-out width of the whole cluster, for the narrow-pane ladder. Six controls plus the
    /// HStack's five 6pt gaps.
    ///
    /// Deliberately matched to what the system chrome used to take — 226.5pt at `.small`, 188.5
    /// at `.mini` — rather than made as small as possible. Uniform pills cannot land on both
    /// numbers exactly (the old widths ranged 22.5–30.5 within a single rung), and `.mini` comes
    /// out 3.5pt over, which costs the provider name one character in a 250pt pane.
    ///
    /// Do not try to tune that back by shrinking the pill: the header's own degradation ladder is
    /// not monotonic in this width. 25pt collapsed the provider capsule to "..." — worse than the
    /// 27pt this settles on — and 33 vs 36 at `.small` changed nothing at all, because a 250pt
    /// pane is already on the `.mini` rung.
    static func clusterWidth(_ controlSize: ControlSize) -> CGFloat {
        pill(controlSize).width * 6 + 6 * 5
    }
}

/// The chrome for one pane-header nav control: a fixed capsule the app draws itself.
///
/// These used to wear `chromeButtonStyle`, i.e. the system `.glass` style, and three rounds of
/// hover fixes failed against it — an outer `.foregroundStyle` loses to the style's own label
/// colour, an outer `.frame` doesn't resize the pill, and any filter or offscreen pass over glass
/// renders nothing at all. The freshness badge that used to sit beside these gave up on glass for
/// the same family of reason (an accent tint over an accent wash has nothing to shift against).
/// This follows it: the app owns the fill, so the app can guarantee both the size and the hover.
struct PaneNavChrome: ViewModifier {
    let accent: Color
    let controlSize: ControlSize

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return content
            .scaledFont(PaneNavMetrics.glyphFont(controlSize))
            .foregroundStyle(glyph)
            .frame(width: pill.width, height: pill.height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }

    /// Disabled reads as a flatter, quieter pill and never responds — `canGoBack` is false at the
    /// top of a tree, and a Back arrow that lights up there would promise a click that does nothing.
    private var fill: Color {
        guard isEnabled else { return .primary.opacity(0.035) }
        switch phase {
        case .rest: return .primary.opacity(0.075)
        case .hover: return accent.opacity(0.22)
        case .pressed: return accent.opacity(0.34)
        }
    }

    /// Disabled stays quiet in both appearances — `canGoBack` is false at the top of a tree, and a
    /// Back arrow that reads live there promises a click that does nothing.
    ///
    /// Enabled, dark is full-strength white via `ChromeInk`: on the hue-washed surface this app
    /// actually renders, the 0.75 rest ink measures ~3.4:1 and the engaged accent glyph sits on an
    /// accent wash with nothing to shift against. The pill's `fill` still carries the hover in both
    /// appearances, so dropping the glyph's tint costs the affordance nothing.
    private var glyph: Color {
        guard isEnabled else { return .primary.opacity(0.25) }
        return ChromeInk.label(colorScheme, light: phase.isEngaged ? accent : .primary.opacity(0.75))
    }
}

extension View {
    /// See `PaneNavChrome`. Pair with `.buttonStyle(.hoverAffordance(.filled, …))`, which supplies
    /// the phase this reads plus the press scale, and deliberately no wash of its own — the fill
    /// here is the wash.
    func paneNavChrome(accent: Color, controlSize: ControlSize) -> some View {
        modifier(PaneNavChrome(accent: accent, controlSize: controlSize))
    }
}

