import AppKit
import SwiftUI
import Testing
import Sync
import Events
@testable import Dashboard

/// Visual snapshot net over Dashboard's composite surfaces: PaneHeader (with the freshness
/// pill in its fresh and stale states, and the 250 pt narrow-pane truncation that burned us),
/// and LogViewer's severity rows. Fixed sizes, frozen or bucket-safe dates, light + dark;
/// workflow and caveats in Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized) struct DashboardSnapshotTests {

    // MARK: PaneHeader

    /// A comfortable-width header, freshly scanned: provider capsule, GREEN "Scanned just
    /// now" pill, nav cluster, breadcrumb. `Date()` is safe here — the "just now" display
    /// bucket spans 45 s, orders of magnitude beyond render latency.
    @Test func paneHeaderFresh() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive", lastScan: Date()),
            size: CGSize(width: 560, height: 92),
            named: "fresh")
    }

    /// Stale freshness: 15 minutes past the scan (well past the 10-minute threshold, and
    /// mid-bucket — "15m ago" holds for a full minute), so the pill must turn amber and grow
    /// the re-scan glyph.
    @Test func paneHeaderStaleFreshnessPill() {
        assertViewSnapshot(
            of: Self.header(providerName: "iCloud Drive", lastScan: Date(timeIntervalSinceNow: -915)),
            size: CGSize(width: 560, height: 92),
            named: "stale")
    }

    /// The burned edge case: a long custom provider name in a 250 pt pane. Pins CURRENT
    /// behavior: the header never wraps taller, but the Menu label's fixedSize means the
    /// long name does NOT middle-truncate — the nav cluster overflows the pane's trailing
    /// edge instead (the canvas clips it, leading-aligned, exactly as a pane would). If the
    /// intended truncation ever starts working, this reference is the one to re-record.
    @Test func paneHeaderNarrow250LongProviderName() {
        assertViewSnapshot(
            of: Self.header(
                providerName: "Marketing Team Shared Archive Drive",
                lastScan: Date()),
            size: CGSize(width: 250, height: 92),
            named: "narrow-250")
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

    // MARK: Fixtures

    private static func header(providerName: String, lastScan: Date?) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(
                id: "icloud",
                displayName: providerName,
                imageName: "icloud-logo",
                path: "/Users/test/iCloud",
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
            lastScanDate: lastScan,
            showHiddenFiles: .constant(false))
    }
}
