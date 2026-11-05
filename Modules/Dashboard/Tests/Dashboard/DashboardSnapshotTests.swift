import AppKit
import SwiftUI
import Testing
import Sync
import Design
import Events
import FileExplorer
@testable import Dashboard

/// Visual snapshot net over Dashboard's composite surfaces: PaneHeader (including the 250 pt
/// narrow-pane truncation), LogViewer's severity rows, the bar's customize sheet and Activity's
/// Now. Fixed sizes, frozen or bucket-safe dates, light + dark; workflow and caveats in
/// Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct DashboardSnapshotTests {

    // MARK: PaneHeader

    /// A comfortable-width header: the bar packed against the leading edge, and the breadcrumb below
    /// it opening with the source chip. Scan freshness is absent on purpose: it lives on the
    /// differences count pill, and the header must not draw a second copy.
    ///
    /// No provider mark appears in these references: the brand asset lives in the app's catalog,
    /// which an SPM test target can't see, so the chip's mark slot renders empty. These pin the
    /// header's geometry only. A `.resizable()` image in a `Menu`'s AppKit-drawn label ignores its
    /// frame and draws at the asset's native 512pt, which nothing here can see;
    /// `SyncCloudTests.MenuLabelMarkTests` checks the mark.
    @Test func paneHeaderComfortable() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive"),
            size: CGSize(width: 560, height: 92),
            named: "comfortable")
    }

    /// A long custom provider name at the split clamp's 250 pt pane minimum. The name
    /// middle-truncates inside the source chip on the breadcrumb row, while the bar above takes the
    /// rung that fits (7 controls, per `PaneBarLadderTests`' golden). Every control stays visible
    /// and nothing passes the pane's trailing edge. The chip has its own row, so it keeps the mark.
    @Test func paneHeaderNarrow250LongProviderName() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive"),
            size: CGSize(width: 250, height: 92),
            named: "narrow-250")
    }

    /// The ladder's middle rung, 400 pt with the long name: the name keeps its readable floor and
    /// middle-truncates inside the source chip, while the bar sits a rung above the 250pt case.
    /// The name is the identity anchor, so it is the last thing to give.
    @Test func paneHeaderMid400LongProviderName() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive"),
            size: CGSize(width: 400, height: 92),
            named: "mid-400")
    }

    // MARK: LogViewer rows

    /// The zone the log rows' time column is rendered in, pinned so the machine's zone can't leak
    /// into the references. A zone change shifts the stamp and, in compact, the whole message line,
    /// which reads as a rendering regression on a frozen fixture. UTC, so the stamp matches the
    /// fixture comments below.
    private static let pinnedZone = TimeZone(identifier: "UTC")!

    /// One row per severity, pinning the icon/color/capsule pairing, plus the dimmed
    /// `Location:` developer-breadcrumb tail on the error row. Timestamps are frozen, and
    /// rendered in `pinnedZone` rather than the machine's — see its note.
    @Test func logRowsAllSeverities() {
        let at = Date(timeIntervalSince1970: 1_780_315_200) // 2026-06-01 12:00:00 UTC
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 0) {
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .debug,
                    message: "Scan enumerated 1,204 items under ~/iCloud Drive"), timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .info,
                    message: "Copied Invoice-2026-06.pdf to OneDrive/Documents"), timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .warning,
                    message: "Skipped cloud-only file (not downloaded): Budget.xlsx"), timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .error,
                    message: "Move failed: destination folder is read-only | Location: FileSyncManager.swift:412 / moveItem(_:to:)"), timeZone: Self.pinnedZone)
            }
            .padding(12),
            size: CGSize(width: 560, height: 260),
            named: "severities")
    }

    /// The compact twin of `logRowsAllSeverities`: the same four entries on one baseline row each
    /// (a message too long for the width wraps, see `LogRowWrapTests`), and no `Location:` tail on
    /// the error row; compact drops it, and it survives in the log file and in Copy.
    @Test func logRowsAllSeveritiesCompact() {
        let at = Date(timeIntervalSince1970: 1_780_315_200) // 2026-06-01 12:00:00 UTC
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 0) {
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .debug,
                    message: "Scan enumerated 1,204 items under ~/iCloud Drive"), density: .compact, timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .info,
                    message: "Copied Invoice-2026-06.pdf to OneDrive/Documents"), density: .compact, timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .warning,
                    message: "Skipped cloud-only file (not downloaded): Budget.xlsx"), density: .compact, timeZone: Self.pinnedZone)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .error,
                    message: "Move failed: destination folder is read-only | Location: FileSyncManager.swift:412 / moveItem(_:to:)"), density: .compact, timeZone: Self.pinnedZone)
            }
            .padding(12),
            size: CGSize(width: 560, height: 150),
            named: "severities-compact")
    }

    // MARK: Fixtures

    /// The header plus the two controls Columns adds (the Tree|Columns switch and New Folder), at
    /// the 250 pt split clamp with a long provider name. Inline they would need 255 pt of a 222 pt
    /// content box; the fold ladder buys the room back. Pins that every control stays reachable and
    /// the name still reads at the floor.
    @Test func paneHeaderNarrow250WithColumnsControls() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive",
                            viewMode: .constant(PaneViewMode.columns), onNewFolder: {}),
            size: CGSize(width: 250, height: 92),
            named: "narrow-250-columns")
    }

    /// The roomy rung: everything inline, including the two-segment switch with Columns selected.
    @Test func paneHeaderWideWithColumnsControls() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive",
                            viewMode: .constant(PaneViewMode.columns), onNewFolder: {}),
            size: CGSize(width: 660, height: 92),
            named: "wide-660-columns")
    }

    // MARK: Customize sheet

    /// The customize sheet, whole. Dimmed tiles, sections running together and a squeezed track
    /// are all invisible to geometry assertions, so only an image catches them. `availableHere`
    /// omits Collapse Pane so the "doesn't apply to this pane" treatment is in frame too.
    ///
    /// The whole default arrangement fits the 600pt track: its head is a blank drop zone over the
    /// track's padding (`leadingEdgeZone`), so the first pill sits at the edge. The track is a
    /// horizontal `ScrollView` (up to `maxItems`, 16), so a longer bar scrolls rather than losing
    /// items.
    ///
    /// These two pin `precision: 0.999`, because at the suite's 0.99 a 24pt shift of the whole row
    /// passes. A shifted row differs on about 0.7–1.9% of the canvas and a re-render on about
    /// 0.001%, so 0.999 separates them. Machine-pinned like the rest of the suite.
    @Test func paneBarCustomizeSheet() {
        let defaults = ScratchDefaults("DashboardSnapshotTests-customize")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        assertViewSnapshot(
            of: PaneBarCustomizeSheet(
                availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles])
                .defaultAppStorage(defaults),
            size: CGSize(width: 600, height: 545),
            named: "customize-sheet",
            precision: 0.999, perceptualPrecision: 0.98)
    }

    /// The same sheet with a bar item held over the palette: the remove target, lit. The state lasts
    /// only as long as a drag, so nothing else reaches it, and only an image shows whether the tiles
    /// beneath read through the words "Remove from bar".
    @Test func paneBarCustomizeSheetRemoving() {
        let defaults = ScratchDefaults("DashboardSnapshotTests-customize-removing")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        assertViewSnapshot(
            of: PaneBarCustomizeSheet(
                availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles],
                showingRemoveTarget: true)
                .defaultAppStorage(defaults),
            size: CGSize(width: 600, height: 545),
            named: "customize-sheet-removing",
            precision: 0.999, perceptualPrecision: 0.98)
    }

    /// The injected defaults domain pins the glass hue, tint and level the header reads.
    private static func header(providerName: String,
                               viewMode: Binding<PaneViewMode>? = nil,
                               onNewFolder: (() -> Void)? = nil) -> some View {
        let defaults = ScratchDefaults("DashboardSnapshotTests-header")
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(
                id: "icloud",
                displayName: providerName,
                imageName: "icloud-logo",
                rootPath: "/Users/test/iCloud",
                type: .iCloud),
            rootPath: "/Users/test/iCloud",
            relativePath: "Documents/Reports",
            canGoBack: true,
            canGoForward: false,
            onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in },
            sortOption: .constant(.name),
            onRefresh: {},
            isRefreshing: false,
            showHiddenFiles: .constant(false),
            viewMode: viewMode,
            onNewFolder: onNewFolder)
        .defaultAppStorage(defaults)
    }

    /// The Activity window's Now, at Solid: the tabs in the title bar's row, then Running and Recent
    /// drawn straight on the window like History's rows, a hairline between them, from the top. A
    /// stack centred with no ground of its own would float the tabs mid-window and let Clear show
    /// through.
    @Test func activityWindowNow() {
        let defaults = UserDefaults(suiteName: "DashboardSnapshotTests.activity-\(UUID())")!
        defaults.set(GlassLevel.solid.rawValue, forKey: LiquidGlass.levelKey)
        let center = ActivityCenter()
        center.record(ActivityMessage(message: "Merged “Photos” — folded 7,363 files into Photos.",
                                      severity: .success, runId: UUID()), seen: true)
        center.record(ActivityMessage(message: "Saved 5 of 6 as PDF.", detail: "Budget.numbers — it isn’t downloaded",
                                      severity: .warning), seen: true)
        assertViewSnapshot(
            of: ActivityWindow(center: center, activeProgress: nil, activeProgressStartedAt: nil,
                               runWriteLock: nil) { EmptyView() }
                .defaultAppStorage(defaults),
            size: CGSize(width: 640, height: 420),
            named: "now-solid")
    }
}
