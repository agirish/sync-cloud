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
    /// Drives the freshness badge's light/dark palette. Read from the environment rather than
    /// from the Theme setting, so it follows System just as well as an explicit Light/Dark.
    @Environment(\.colorScheme) private var colorScheme
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    /// "Scanned N ago" badge — the pane's freshness readout AND its scan control in one capsule:
    /// status dot, age, hairline, re-scan glyph. Green while fresh, amber once the diff may be out
    /// of date, neutral "Scanning…" while a scan runs. Hidden until the first scan lands, which is
    /// why `navClusterContent` keeps a standalone Scan button for exactly that pre-scan window.
    ///
    /// The timeline is anchored to `lastScanDate`, NOT to `Date()`. Anchored to view creation the
    /// 30s ticks sat on an arbitrary phase relative to the scan, so a "30s ago" label could appear
    /// anywhere within 30s of the truth — and, because 600 is a multiple of 30, anchoring also
    /// lands the fresh→stale flip exactly on the ten-minute threshold instead of up to 30s late.
    @ViewBuilder
    private var freshnessPill: some View {
        if let lastScanDate {
            TimelineView(.periodic(from: lastScanDate, by: 30)) { context in
                let freshness = ScanFreshness.describe(scanDate: lastScanDate, now: context.date)
                let state: FreshnessState = isRefreshing
                    ? .scanning
                    : (freshness.isStale ? .stale : .fresh)
                let style = FreshnessStyle.of(state, colorScheme)
                let text = state == .scanning ? "Scanning…" : freshness.text

                // Three rungs, widest first. Unlike the pill this replaces, the badge must NOT
                // vanish under constraint — it now carries the pane's only scan control, and a
                // narrow pane that cannot be re-scanned is a worse outcome than a shortened
                // provider name. So it sheds parts instead: the age text goes first, then the dot.
                //
                // The `.minimal` rung exists because measurement said so. With `.compact` as the
                // floor, the 250 pt snapshot showed the provider name collapse from "Ma..." to a
                // bare "..." — the badge was eating the ~12 pt those characters needed. Glyph-only
                // is the width of the standalone Scan button it absorbed, so the row is genuinely
                // no wider than before at any size, and the fill colour still carries fresh/stale
                // even once the dot is gone.
                ViewThatFits(in: .horizontal) {
                    badge(style: style, text: text, density: .full)
                    badge(style: style, text: text, density: .compact)
                    badge(style: style, text: text, density: .minimal)
                }
                .help(helpText(lastScanDate: lastScanDate, state: state))
            }
        }
    }

    /// How much of the badge is drawn. The rungs shed information in the order it can be spared:
    /// the age text is recoverable from the tooltip, the dot is redundant with the fill colour,
    /// and the glyph — the only thing that is also an action — is never dropped.
    private enum BadgeDensity {
        /// Dot, age, divider, glyph.
        case full
        /// Dot and glyph.
        case compact
        /// Glyph alone, on the semantic fill.
        case minimal
    }

    /// One rendering of the freshness badge at a given density.
    @ViewBuilder
    private func badge(style: FreshnessStyle, text: String, density: BadgeDensity) -> some View {
        let label = HStack(spacing: density == .full ? 7 : 5) {
            if density != .minimal {
                Circle()
                    .fill(style.dot)
                    .frame(width: 7, height: 7)
            }
            if density == .full {
                // One line always: in a narrow pane a wrapping badge would grow the whole
                // header vertically.
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Rectangle()
                    .fill(style.content.opacity(0.22))
                    .frame(width: 1, height: 12)
            }
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(style.content)
        // Symmetric once the label is gone, so the lone glyph sits centred rather than shoved
        // against the leading edge by padding sized for a text run.
        .padding(.leading, density == .minimal ? 6 : 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        // A FLAT semantic fill — deliberately NOT `accentGlassCapsule`, and deliberately not the
        // accent hue at all. Measured on the live window, an accent-tinted glass capsule over the
        // accent-washed header rendered at rgb(244,246,249) — LIGHTER than the rgb(186,204,238)
        // backdrop behind it — because a tint composited over its own hue has nothing to shift
        // against. That is what left the label at 1.35:1. A flat fill with same-family text holds
        // its contrast under every one of the twelve hues and every glass level.
        .background(style.fill, in: Capsule())
        .contentShape(Capsule())
        // fixedSize so the enclosing ViewThatFits makes a real binary choice: a badge free to
        // truncate would always "fit" and the compact floor would never be reached.
        .fixedSize()

        if let onRefresh {
            Button(action: onRefresh) { label }
                .buttonStyle(.hoverAffordance(.filled, tint: style.dot))
                // Must not queue a second scan while one is already running.
                .disabled(isRefreshing)
        } else {
            label
        }
    }

    /// Coarse in the badge, exact on hover — the age buckets deliberately cannot answer "when
    /// precisely?", so the tooltip does. Same-day scans drop the date as noise.
    private func helpText(lastScanDate: Date, state: FreshnessState) -> String {
        if state == .scanning { return "Scanning for changes…" }
        let stamp = Calendar.current.isDateInToday(lastScanDate)
            ? lastScanDate.formatted(date: .omitted, time: .standard)
            : lastScanDate.formatted(date: .abbreviated, time: .standard)
        let lead = state == .stale
            ? "This comparison may be out of date — last scanned \(stamp)"
            : "Last scanned \(stamp)"
        return onRefresh == nil ? lead : "\(lead) — click to re-scan"
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
                    // The pill used to YIELD ENTIRELY here (round-5 intent: all-or-nothing rather
                    // than compressing to a bare dot), handing its width back to the provider
                    // name. It can't any more — it carries the pane's only scan control, and a
                    // narrow pane that cannot be re-scanned is a worse outcome than a truncated
                    // provider name. It now degrades to the compact dot+glyph floor instead,
                    // chosen inside `freshnessPill`, at roughly the width of the standalone Scan
                    // button it absorbed — so the row is no wider than before at every size.
                    //
                    // Priority 1 still keeps it above the Spacer in layout order (otherwise the
                    // HStack splits leftover width between them and the badge collapses even in a
                    // wide pane) and below the provider name's 2.
                    freshnessPill
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
                .chromeHover(tint: glassHue.accentColor)
                .help("Collapse the source pane")
            }

            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .chromeHover(tint: glassHue.accentColor)
            .disabled(!canGoBack)
            .help("Go back to this pane's previous folder")

            Button(action: onForward) {
                Image(systemName: "chevron.right")
            }
            .chromeHover(tint: glassHue.accentColor)
            .disabled(!canGoForward)
            .help("Go forward to this pane's next folder")

            // Scan/refresh normally lives INSIDE the freshness badge, which pairs the action with
            // the state it acts on — the arrows used to sit between them. This standalone button
            // survives only for the window where that badge does not exist: before the first scan
            // there is no `lastScanDate`, so without it a fresh comparison could never be scanned.
            if let onRefresh, lastScanDate == nil {
                // The arrow spins while a scan runs (reduced-motion is honored automatically).
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
                }
                .chromeHover(tint: glassHue.accentColor)
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
            // `.menuStyle(.button)` alone was not enough: it makes the menu render AS a button,
            // but it does not make it inherit the button style from an ancestor — so the sort
            // control still drew its own chrome while the HStack's `chromeButtonStyle` went to
            // its Button siblings only. Restating the style directly on the menu is what
            // actually matches it to them.
            .menuStyle(.button)
            .chromeButtonStyle(glassLevel)
            .fixedSize()
            .chromeHover(tint: glassHue.accentColor)
            .help("Choose how items are sorted")

            // Hidden-files toggle, icon-only, sitting beside the nav buttons. The eye
            // mirrors the state: open when hidden files are shown, slashed when filtered.
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash")
            }
            .chromeHover(tint: glassHue.accentColor)
            .help(showHiddenFiles
                  ? "Hidden files are visible — click to hide them"
                  : "Hidden files are hidden — click to show them")
        }
        .chromeButtonStyle(glassLevel)
    }
}
