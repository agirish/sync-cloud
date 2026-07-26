import SwiftUI
import AppKit
import Sync
import Design

// MARK: - StorageLensView

/// Storage Lens — the read-only "where does my space go?" surface. A treemap of the top areas over
/// three ranked lists (largest files, long-untouched files, and reclaim candidates). The only
/// action it offers is a Finder reveal: it never moves, deletes, or evicts a file. Rendered as the
/// Tidy workspace's read-only Storage lens.
struct StorageLensView: View {
    @ObservedObject var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    /// Which of the three lists are expanded (all open by default). Kept view-side; the report is
    /// the source of truth for the rows.
    @State private var collapsed: Set<StorageSection> = []

    private let providerName: String?
    /// The header card's live query. Filters the three ranked lists — NOT the treemap, which is a
    /// part-of-whole picture whose proportions a subset would misstate (see `StorageSearch`).
    private let query: StorageSearch.Query
    private let onBuild: () -> Void
    /// Reveals a path in Finder (NSWorkspace). The honest extent of "offload" in this landing.
    private let onReveal: (String) -> Void
    /// Presents a Quick Look preview for a file path. nil hides the per-row Preview button.
    private let onQuickLook: ((String) -> Void)?

    init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        query: StorageSearch.Query = StorageSearch.parse(""),
        onBuild: @escaping () -> Void,
        onReveal: @escaping (String) -> Void,
        onQuickLook: ((String) -> Void)? = nil
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.query = query
        self.onBuild = onBuild
        self.onReveal = onReveal
        self.onQuickLook = onQuickLook
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    private var report: StorageLensReport? { syncManager.storageLensReport }
    private var hasReport: Bool { report != nil }

    var body: some View {
        // The toolbar card that used to head this view is gone: Tidy's shared LensHeaderCard now
        // carries Storage's Re-analyze control, its total/largest/reclaim pills and its search, so
        // this view renders the content card alone. That's what makes Storage's header the same
        // 81pt as the other four lenses — it used to have no header at all until a report landed.
        contentCard
    }

    // MARK: Content card

    @ViewBuilder
    private var contentCard: some View {
        VStack(spacing: 0) {
            if syncManager.isBuildingStorageLens {
                buildingState
            } else if let report {
                reportBody(report)
            } else {
                introState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    // MARK: Intro / building states

    private var introState: some View {
        EmptyStateView(
            icon: "chart.pie.fill",
            tint: glassHue.accentColor,
            title: "See where your space goes in \(providerName ?? "this provider")",
            message: "Analyze this folder to map its biggest areas, list the largest and longest-untouched files, and flag large files worth making online-only.",
            caption: "Read-only: Storage Lens never moves, deletes, or evicts anything — the “Offload” button just reveals a file in Finder.",
            primary: .init("Analyze storage", systemImage: "chart.pie.fill", handler: onBuild)
        )
    }

    private var buildingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.storageLensStatus.isEmpty ? "Analyzing…" : syncManager.storageLensStatus)
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelBuildStorageLens() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Report body

    @ViewBuilder
    private func reportBody(_ report: StorageLensReport) -> some View {
        if report.totalBytes == 0 {
            EmptyStateView(
                icon: "externaldrive.badge.checkmark",
                tint: SemanticColor.success,
                title: "Nothing measurable here",
                message: "No files with size were found in \(scannedName). Analyze again after adding files.",
                secondary: .init("Analyze again", systemImage: "arrow.clockwise", handler: onBuild)
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The treemap takes the report's own nodes, unfiltered and deliberately so:
                    // it answers "where does my space go?" for the whole scanned tree, and drawing
                    // it from a query's subset would silently change what every proportion in it
                    // means. The ranked lists below are what the query narrows.
                    treemapSection(report)
                    listSection(.largest, entries: report.largest.filter { query.matches($0) })
                    listSection(.stale, entries: report.stale.filter { query.matches($0) })
                    listSection(.reclaim, entries: report.reclaimCandidates.filter { query.matches($0) })
                }
                .padding(densityMetrics.cardListPadding)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var scannedName: String {
        guard let root = syncManager.storageLensRoot?.path else { return "this folder" }
        return (root as NSString).lastPathComponent
    }

    // MARK: Treemap section

    @ViewBuilder
    private func treemapSection(_ report: StorageLensReport) -> some View {
        if !report.treemap.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeaderLabel(icon: "square.grid.2x2.fill", tint: glassHue.accentColor,
                                   title: "Where space concentrates",
                                   subtitle: "Top areas by total size")
                TreemapView(nodes: report.treemap)
            }
        }
    }

    // MARK: List sections

    private func listSection(_ section: StorageSection, entries: [StorageEntry]) -> some View {
        let isCollapsed = collapsed.contains(section)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isCollapsed { collapsed.remove(section) } else { collapsed.insert(section) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.icon)
                        .scaledFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(section.tint)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title)
                            .scaledFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(section.subtitle)
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(entries.count.formatted())
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .hoverInk()
                }
            }
            .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor))

            if !isCollapsed {
                if entries.isEmpty {
                    // Under a live query the section's own empty text would lie — "Nothing here"
                    // claims the scan found none, when the query is what hid them.
                    Text(query.isEmpty ? section.emptyText : "No files here match your search.")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: densityMetrics.cardListSpacing) {
                        ForEach(entries) { entry in
                            StorageEntryRow(
                                entry: entry,
                                relativeFolder: displayFolder(entry.path),
                                showAge: section == .stale,
                                offloadStyle: section == .reclaim,
                                densityMetrics: densityMetrics,
                                onReveal: { onReveal(entry.path) },
                                onPreview: onQuickLook.map { ql in { ql(entry.path) } }
                            )
                        }
                    }
                }
            }
        }
    }

    private func sectionHeaderLabel(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(.system(size: 13, weight: .semibold))
                Text(subtitle).scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Path helpers

    /// The file's containing folder, shown relative to the scanned root when possible (so rows read
    /// "Photos/2023" not the whole absolute path), else tilde-abbreviated.
    private func displayFolder(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if let root = syncManager.storageLensRoot?.path, !root.isEmpty {
            let standardizedRoot = (root as NSString).standardizingPath
            let standardizedParent = (parent as NSString).standardizingPath
            if standardizedParent == standardizedRoot { return scannedName }
            if standardizedParent.hasPrefix(standardizedRoot + "/") {
                let rel = String(standardizedParent.dropFirst(standardizedRoot.count + 1))
                return "\(scannedName)/\(rel)"
            }
        }
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Sections

/// The three ranked lists under the treemap, each with its own glyph, tint, and copy.
private enum StorageSection: Hashable {
    case largest, stale, reclaim

    var icon: String {
        switch self {
        case .largest: return "arrow.up.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .reclaim: return "internaldrive"
        }
    }
    var tint: Color {
        switch self {
        case .largest: return SemanticColor.info
        case .stale: return SemanticColor.warning
        case .reclaim: return SemanticColor.success
        }
    }
    var title: String {
        switch self {
        case .largest: return "Largest files"
        case .stale: return "Untouched for a long time"
        case .reclaim: return "Reclaim candidates"
        }
    }
    var subtitle: String {
        switch self {
        case .largest: return "The biggest individual files"
        case .stale: return "Not opened or changed in a long while — oldest first"
        case .reclaim: return "Large and long-idle — worth keeping online-only"
        }
    }
    var emptyText: String {
        switch self {
        case .largest: return "No files with measurable size."
        case .stale: return "Nothing has been sitting untouched."
        case .reclaim: return "No large, long-idle files to offload."
        }
    }
}

// MARK: - Row

/// One file row in a Storage Lens list. Read-only by construction: the trailing controls only
/// reveal the file in Finder (the honest extent of "offload") or open a Quick Look preview.
private struct StorageEntryRow: View {
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// Tint for this row's two hover-affordance glyphs, matching the lens chrome around them.
    private var rowAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }
    let entry: StorageEntry
    let relativeFolder: String
    /// When true, show the file's age (used by the stale list).
    let showAge: Bool
    /// When true, the reveal control renders as a prominent "Offload…" button with the
    /// Finder-handoff explainer; otherwise it's a quiet reveal glyph.
    let offloadStyle: Bool
    /// Row measurements per the appearance density setting (D4). Comfortable must render this row
    /// pixel-identical to the pre-density look.
    let densityMetrics: ListDensityMetrics
    let onReveal: () -> Void
    let onPreview: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .scaledFont(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The folder + age line is the secondary detail compact hides (D4); the name and
                // size still identify the file and its weight.
                if densityMetrics.showsSecondaryDetail {
                    HStack(spacing: 6) {
                        Text(relativeFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if showAge, let age = ageText {
                            Text("· \(age)")
                                .lineLimit(1)
                        }
                    }
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(FileSyncManager.formatBytes(entry.bytes))
                .scaledFont(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye").padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: rowAccent))
                .padding(-4)
                .controlSize(.small)
                .help("Preview with Quick Look")
            }
            if offloadStyle {
                Button(action: onReveal) {
                    Label("Offload…", systemImage: "icloud.and.arrow.up")
                }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover(tint: rowAccent)
                .help("Reveals the file in Finder — use Finder to keep it online-only and free local space")
            } else {
                Button(action: onReveal) {
                    Image(systemName: RevealGlyph.inFinder).padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: rowAccent))
                .padding(-4)
                .controlSize(.small)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 12)
        // This row's comfortable padding (8) is smaller than the shared card-row metric (11), so
        // clamp rather than substitute: comfortable stays exactly 8; compact tightens to the
        // metric's 6.
        .padding(.vertical, min(8, densityMetrics.cardRowVerticalPadding))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    /// A coarse "N years/months/days ago" for the stale list, from the file's mtime.
    private var ageText: String? {
        guard let modified = entry.modified else { return nil }
        let seconds = Date().timeIntervalSince(modified)
        guard seconds > 0 else { return nil }
        let days = Int(seconds / 86_400)
        if days >= 730 { return "\(days / 365) years ago" }
        if days >= 365 { return "1 year ago" }
        if days >= 60 { return "\(days / 30) months ago" }
        if days >= 30 { return "1 month ago" }
        return "\(days) days ago"
    }
}
