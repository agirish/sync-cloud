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
    // No surface style here: the header's shape comes from its container, its material from the
    // glass level. This view only paints the tint. It reads no glass level of its own either: the
    // nav cluster it used to frost at Clear is drawn in-house now (6bb7bdf), which took the last
    // reader with it.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
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
        showHiddenFiles: Binding<Bool>
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
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
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

    /// The brand-tinted provider capsule (UX H2: the hue tints the name and washes softly behind
    /// the logo so the two panes are distinguishable — and visibly matching — at a glance; buttons
    /// and selection states keep the user's accent color). The name + chevron is the menu trigger;
    /// the logo stays a plain image OUTSIDE the menu label (a resizable image inside one balloons
    /// to its native size). ViewThatFits compares each variant's IDEAL width against the offer,
    /// so the logo variant wins only while the full name fits alongside it; once the name would
    /// have to give up characters, the logo yields first and the logo-less variant truncates the
    /// name as far as an ellipsis — the name is the identity anchor, the logo is decoration.
    private func providerCapsule(_ provider: CloudProvider, showsLogo: Bool) -> some View {
        let hue = ProviderHue.classify(provider.displayName)
        return HStack(spacing: 10) {
            if showsLogo {
                Image(provider.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            ProviderMenu(
                providers: providers,
                currentId: provider.id,
                onSelect: onSelectProvider,
                onManage: onManageProviders
            ) {
                Text(provider.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(hue.tint)
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
        .background(hue.soft, in: Capsule())
    }

    /// This pane's navigation/action buttons. Rendered through ViewThatFits so that at the
    /// narrowest pane widths (the split clamps panes at 250 pt, where small-size controls plus
    /// the provider capsule physically exceed the row) the cluster steps down to `.mini`
    /// controls instead of overflowing the pane's trailing edge — every control stays present
    /// and clickable, nothing is pushed out of view.
    private var navCluster: some View {
        ViewThatFits(in: .horizontal) {
            navClusterContent(.small)
            navClusterContent(.mini)
        }
    }

    private func navClusterContent(_ controlSize: ControlSize) -> some View {
        HStack(spacing: 6) {
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

            // Sort moved out of the titlebar (its file-action neighbors are now the pane's
            // contextual action bar); it lives per-pane, driving the shared sort order.
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
        .controlSize(controlSize)
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
    static func glyphFont(_ controlSize: ControlSize) -> Font {
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

    func body(content: Content) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return content
            .font(PaneNavMetrics.glyphFont(controlSize))
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

    private var glyph: Color {
        guard isEnabled else { return .primary.opacity(0.25) }
        return phase.isEngaged ? accent : .primary.opacity(0.75)
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

