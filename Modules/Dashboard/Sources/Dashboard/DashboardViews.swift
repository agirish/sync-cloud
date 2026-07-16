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
    /// When the current comparison last scanned, driving the "Scanned N ago" freshness pill.
    /// nil hides it (no scan yet, or the comparison state was invalidated).
    public let lastScanDate: Date?
    /// Whether hidden files are shown. A per-pane control for the (global) setting, so it lives
    /// right next to each pane's navigation buttons.
    @Binding public var showHiddenFiles: Bool
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }
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
                let tint = freshness.isStale ? Color.orange : Color.secondary
                let label = HStack(spacing: 5) {
                    Circle()
                        .fill(freshness.isStale ? Color.orange : Color.green)
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
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint.opacity(freshness.isStale ? 0.14 : 0.1), in: Capsule())

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
                    // UX H2: the provider's brand hue tints its name and washes softly behind
                    // the logo, so the two panes are distinguishable at a glance (and visibly
                    // *matching* when both panes show the same provider). Buttons and
                    // selection states keep the user's accent color.
                    let hue = ProviderHue.classify(provider.displayName)
                    // The provider name is now a dropdown (the Left/Right sidebar is gone). The logo
                    // stays a plain image OUTSIDE the menu — a resizable image inside a Menu label
                    // balloons to its native size under the menu's fixedSize — and only the tinted
                    // name + chevron is the menu trigger.
                    HStack(spacing: 10) {
                        Image(provider.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
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
                                // header taller in a narrow pane.
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentShape(Rectangle())
                        }
                        .help("Switch this pane's cloud provider")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(hue.soft, in: Capsule())
                    // In a narrow pane the provider NAME is the identity anchor — the freshness
                    // pill (relative time, repeated on both panes) must yield width first, not
                    // squeeze the name to an ellipsis.
                    .layoutPriority(1)
                } else {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                freshnessPill

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
                .buttonStyle(.bordered)
                .controlSize(.small)
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
        .contentSurface(surfaceStyle, hue: glassHue, tint: surfaceTint)
    }
}
