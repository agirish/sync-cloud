import AppKit
import SwiftUI
import Testing
import Sync
import Design
import Events
@testable import Dashboard

/// Visual snapshot net over Dashboard's composite surfaces: PaneHeader (with the freshness
/// pill in its fresh and stale states, and the 250 pt narrow-pane truncation that burned us),
/// and LogViewer's severity rows. Fixed sizes, frozen or bucket-safe dates, light + dark;
/// workflow and caveats in Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct DashboardSnapshotTests {

    // MARK: PaneHeader

    /// A comfortable-width header: provider capsule, nav cluster, breadcrumb. Scan freshness is
    /// deliberately absent — it moved to the differences count pill, so this pins that the pane
    /// header no longer draws a second copy of it.
    ///
    /// Note when reading these references: no provider mark appears in any of them. The brand asset
    /// lives in the app's catalog, which an SPM test target cannot see, so `Image("icloud-logo")`
    /// resolves to nothing and the capsule's logo slot renders empty. What is pinned here is the
    /// header's geometry — the capsule spans x 28-327 — not the mark, which is only ever verifiable
    /// in the running app.
    @Test func paneHeaderComfortable() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive"),
            size: CGSize(width: 560, height: 92),
            named: "comfortable")
    }

    /// The burned edge case: a long custom provider name at the split clamp's 250 pt pane
    /// minimum. Pins the full degradation ladder: the logo drops, the name middle-truncates
    /// inside its capsule, and the nav cluster steps down to .mini controls — every control
    /// fully visible, nothing pushed past the pane's trailing edge (the pre-fix Menu fixedSize
    /// ballooned the name and shoved the nav cluster out of view).
    @Test func paneHeaderNarrow250LongProviderName() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive"),
            size: CGSize(width: 250, height: 92),
            named: "narrow-250")
    }

    /// The ladder's middle rung, 400 pt with the long name: the logo variant still fits (the
    /// name keeps its readable floor and middle-truncates) and the nav cluster is on its .mini
    /// fallback — the name is the identity anchor, so it outranks full-size controls.
    @Test func paneHeaderMid400LongProviderName() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive"),
            size: CGSize(width: 400, height: 92),
            named: "mid-400")
    }

    // MARK: LogViewer rows

    /// One row per severity, pinning the icon/color/capsule pairing, plus the dimmed
    /// `Location:` developer-breadcrumb tail on the error row. Timestamps are frozen
    /// (rendered in the machine's local timezone — see SNAPSHOTS.md).
    @Test func logRowsAllSeverities() {
        let at = Date(timeIntervalSince1970: 1_780_315_200) // 2026-06-01 12:00:00 UTC
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 0) {
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .debug,
                    message: "Scan enumerated 1,204 items under ~/iCloud Drive"))
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .info,
                    message: "Copied Invoice-2026-06.pdf to OneDrive/Documents"))
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .warning,
                    message: "Skipped cloud-only file (not downloaded): Budget.xlsx"))
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .error,
                    message: "Move failed: destination folder is read-only | Location: FileSyncManager.swift:412 / moveItem(_:to:)"))
            }
            .padding(12),
            size: CGSize(width: 560, height: 260),
            named: "severities")
    }

    /// The compact-density twin of `logRowsAllSeverities`: the same four entries collapsed to
    /// one baseline row each (these four all fit; a message too long for the width wraps rather
    /// than truncating — see `LogRowWrapTests`), and — deliberately — NO dimmed `Location:` tail on
    /// the error row (compact drops the developer breadcrumb; it survives in the log file and
    /// in Copy). Pins the H7 single-line collapse against silent regression.
    @Test func logRowsAllSeveritiesCompact() {
        let at = Date(timeIntervalSince1970: 1_780_315_200) // 2026-06-01 12:00:00 UTC
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 0) {
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .debug,
                    message: "Scan enumerated 1,204 items under ~/iCloud Drive"), density: .compact)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .info,
                    message: "Copied Invoice-2026-06.pdf to OneDrive/Documents"), density: .compact)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .warning,
                    message: "Skipped cloud-only file (not downloaded): Budget.xlsx"), density: .compact)
                LogEntryRow(entry: LogEntry(
                    timestamp: at, level: .error,
                    message: "Move failed: destination folder is read-only | Location: FileSyncManager.swift:412 / moveItem(_:to:)"), density: .compact)
            }
            .padding(12),
            size: CGSize(width: 560, height: 150),
            named: "severities-compact")
    }

    // MARK: Fixtures

    /// The Columns-era header: the same pane plus the two controls Columns adds — the Tree|Columns
    /// switch and New Folder — at the 250 pt split clamp with a long provider name.
    ///
    /// This is the measurement the whole design rests on. Added inline the two controls cost 255 pt
    /// in a 222 pt content box, overrunning it before the provider capsule gets a point; the fold
    /// ladder is what buys them back. Pin that at the floor every control is still reachable and
    /// the name still reads, rather than trusting the arithmetic.
    @Test func paneHeaderNarrow250WithColumnsControls() {
        assertViewSnapshot(
            of: Self.header(providerName: "Marketing Team Shared Archive Drive",
                            viewMode: .constant(PaneViewMode.columns), onNewFolder: {}),
            size: CGSize(width: 250, height: 92),
            named: "narrow-250-columns")
    }

    /// The roomy rung: everything inline, including the two-segment switch with Columns selected and
    /// the preview pill wearing the accent.
    @Test func paneHeaderWideWithColumnsControls() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive",
                            viewMode: .constant(PaneViewMode.columns), onNewFolder: {}),
            size: CGSize(width: 660, height: 92),
            named: "wide-660-columns")
    }

    /// The preview pill's other resting state, as an image to look at.
    ///
    /// **It does not pin that state, and this used to claim it did.** The claim was that two images
    /// at the same width with only the setting differing are what make the pill's fill visible to a
    /// test at all. Measured, by rendering the pill from a stale `@AppStorage` while the setting said
    /// off: both references still matched. The pill is ~0.9% of a 660×92 header and
    /// `assertViewSnapshot` runs at `precision: 0.99`, so a control this small fits inside the
    /// tolerance — and this suite is `.machinePinned(.referenceImages)`, so it does not run on CI
    /// either. `PaneHeaderPreviewPillTests` is what actually holds the pill to its state; this image
    /// is here to be looked at.
    @Test func paneHeaderWideWithPreviewOff() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive",
                            viewMode: .constant(PaneViewMode.columns), onNewFolder: {},
                            previewEnabled: false),
            size: CGSize(width: 660, height: 92),
            named: "wide-660-columns-preview-off")
    }

    // MARK: Customize sheet

    /// The customize sheet, whole.
    ///
    /// It shipped once looking, in the user's words, horrible: every palette tile dimmed to 45%
    /// (the default arrangement carries every control, so "already on the bar" greyed all of them),
    /// the sections running together as one field of grey, and — because the track overflowed a
    /// 560pt sheet — the provider capsule's label squeezed away to a bare cloud glyph. Not one of
    /// those is visible to a geometry assertion: the sheet's own size was pinned, so it measured
    /// exactly as intended while rendering nothing of the sort.
    ///
    /// This is the net for that whole class. `availableHere` deliberately omits Collapse Pane so the
    /// "doesn't apply to this pane" treatment is in frame too.
    ///
    /// **The trailing pill in "Your pane bar" is cut off in the reference, and that is real rather
    /// than a rendering artefact.** Delete joining the default took the shipped arrangement to
    /// eleven items, one more than the 600pt track seats — the track is a horizontal `ScrollView`
    /// (built for arrangements up to `maxItems`, which is 16), so the last item is reachable by
    /// scrolling rather than lost. It is the cost of a default bar this long, and it is recorded
    /// here so the next person to see it knows it was looked at and accepted, not missed.
    @Test func paneBarCustomizeSheet() {
        let defaults = ScratchDefaults("DashboardSnapshotTests-customize")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        assertViewSnapshot(
            of: PaneBarCustomizeSheet(
                availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview])
                .defaultAppStorage(defaults),
            size: CGSize(width: 600, height: 545),
            named: "customize-sheet")
    }

    /// The same sheet with a bar item held over the palette — the remove target, lit.
    ///
    /// This state lasts exactly as long as a drag, so nothing else in the suite can reach it, and
    /// that is precisely why it is worth a picture: the first draft drew the card on
    /// `Material.regular` and the tiles beneath it read straight through the words "Remove from
    /// bar". Every geometry assertion passed. Only the image showed it.
    @Test func paneBarCustomizeSheetRemoving() {
        let defaults = ScratchDefaults("DashboardSnapshotTests-customize-removing")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        assertViewSnapshot(
            of: PaneBarCustomizeSheet(
                availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview],
                showingRemoveTarget: true)
                .defaultAppStorage(defaults),
            size: CGSize(width: 600, height: 545),
            named: "customize-sheet-removing")
    }

    /// - Parameter previewEnabled: the preview toggle's state, passed straight in as the binding the
    ///   header now takes. It used to be pinned through the injected defaults domain, because the
    ///   header read the preference itself — left alone, these images rendered from whatever the test
    ///   host's standard domain happened to hold, a reference PNG that was a coin flip on the next
    ///   machine. The header takes no view on which key it is showing any more, so the value comes
    ///   straight down; the injected domain still pins the glass hue, tint and level it does read.
    private static func header(providerName: String,
                               viewMode: Binding<PaneViewMode>? = nil,
                               onNewFolder: (() -> Void)? = nil,
                               previewEnabled: Bool = true) -> some View {
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
            previewEnabled: .constant(previewEnabled),
            onNewFolder: onNewFolder)
        .defaultAppStorage(defaults)
    }
}
