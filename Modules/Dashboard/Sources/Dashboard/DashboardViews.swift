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
    /// Whether the breadcrumb shows its "Link both panes" chain toggle. Compare shows it (two
    /// panes to lock-step); the single-source Tidy rail has no sibling pane, so it's hidden there.
    public let showsLinkToggle: Bool
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
    /// When the current comparison last scanned, driving the "Scanned N ago" freshness pill.
    /// nil hides it (no scan yet, or the comparison state was invalidated).
    public let lastScanDate: Date?
    /// Whether hidden files are shown. A per-pane control for the (global) setting, so it lives
    /// right next to each pane's navigation buttons.
    @Binding public var showHiddenFiles: Bool
    // No surface style here: the header's shape comes from its container, its material from the
    // glass level. This view only paints the tint.
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized. Read here
    /// only to frost this header's own controls at Clear — the header paints no surface itself.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    /// "Scanned N ago" pill: green while fresh, amber once the diff may be out of date. It ticks on
    /// its own so the age stays honest without a scan, and — when a refresh handler exists — tapping
    /// it re-scans (same action as the adjacent Scan button). Hidden until the first scan lands.
    @ViewBuilder
    private var freshnessPill: some View {
        if let lastScanDate {
            TimelineView(.periodic(from: Date(), by: 30)) { context in
                let freshness = ScanFreshness.describe(scanDate: lastScanDate, now: context.date)
                // Fresh reads in the app accent (the pill was a neutral gray before); stale still
                // goes amber as a semantic warning, and the status dot below stays green/amber.
                let tint = freshness.isStale ? Color.orange : glassHue.accentColor
                // The pill is a near-solid accent (or amber) glass tile now, so its text and dot are
                // the on-fill label color (white on the accent, dark on amber) — a green dot would
                // vanish on the green pill.
                let onTint = Color.onFillLabel(tint)
                let label = HStack(spacing: 5) {
                    Circle()
                        .fill(onTint)
                        .frame(width: 5, height: 5)
                    // One line always: in a narrow pane a wrapping pill would grow the whole
                    // header vertically.
                    Text(freshness.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if freshness.isStale {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(onTint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                // Near-solid accent (or amber) glass tile with white on-fill text.
                .accentGlassCapsule(tint, strength: 0.85)

                if let onRefresh {
                    // Same guard as the Scan button below: the pill triggers the same action,
                    // so it must not queue a second scan while one is running.
                    Button(action: onRefresh) { label }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing)
                        .help(freshness.isStale
                              ? "This comparison may be out of date — click to re-scan"
                              : "\(freshness.text) — click to re-scan")
                } else {
                    label.help(freshness.text)
                }
            }
        }
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
        showsLinkToggle: Bool = true,
        providers: [CloudProvider] = [],
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        sortOption: Binding<SortOption>,
        onCollapse: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        lastScanDate: Date? = nil,
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
        self.showsLinkToggle = showsLinkToggle
        self.providers = providers
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self._sortOption = sortOption
        self.onCollapse = onCollapse
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.lastScanDate = lastScanDate
        self._showHiddenFiles = showHiddenFiles
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let provider = provider {
                    // In a narrow pane the provider NAME is the identity anchor: with the whole
                    // capsule at the row's highest layoutPriority it is offered width before the
                    // freshness pill and before the nav cluster's full-size variant, so under
                    // constraint the pill yields first, then the name middle-truncates, and only
                    // then (below the logo variant's readable floor) the logo drops.
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

                if lastScanDate != nil {
                    // The pill YIELDS FIRST (round-5 intent): all-or-nothing instead of
                    // compressing to a bare dot. fixedSize makes the pill rigid so ViewThatFits
                    // is a real binary choice — a truncating pill would always "fit" and never
                    // hand its width back to the provider name. Priority 1 keeps it above the
                    // Spacer in layout order (otherwise the HStack splits leftover width between
                    // them and the pill hides even in a wide pane) but below the name's 2.
                    ViewThatFits(in: .horizontal) {
                        freshnessPill.fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(1)
                }

                navCluster
            }
            PaneBreadcrumb(
                rootPath: rootPath,
                providerName: provider?.displayName,
                relativePath: relativePath,
                showHidden: showHiddenFiles,
                showsLinkToggle: showsLinkToggle,
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
            navClusterContent.controlSize(.small)
            navClusterContent.controlSize(.mini)
        }
    }

    private var navClusterContent: some View {
        HStack(spacing: 6) {
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left")
                }
                .help("Collapse the source pane")
            }

            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)
            .help("Go back to this pane's previous folder")

            Button(action: onForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            .help("Go forward to this pane's next folder")

            if let onRefresh {
                // Scan/refresh moved off the titlebar to here, next to the nav controls; the
                // arrow spins while a scan runs (reduced-motion is honored automatically).
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
                }
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
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose how items are sorted")

            // Hidden-files toggle, icon-only, sitting beside the nav buttons. The eye
            // mirrors the state: open when hidden files are shown, slashed when filtered.
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash")
            }
            .help(showHiddenFiles
                  ? "Hidden files are visible — click to hide them"
                  : "Hidden files are hidden — click to show them")
        }
        .chromeButtonStyle(glassLevel)
    }
}
