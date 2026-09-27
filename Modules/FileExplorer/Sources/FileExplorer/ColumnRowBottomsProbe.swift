import AppKit
import SwiftUI

/// Reports where each visible row of ONE column ends, for the pane's action bar — read from the
/// column's own `NSTableView`, so sliding the column stack sideways costs the rows nothing.
///
/// **Why this replaced a `GeometryReader` on every row.** `PaneBarPlacement` needs every visible
/// row's bottom edge before a click lands (see its `rowBottoms`), and each column row used to report
/// its own through a `.global` `GeometryReader` and a preference. Reading a GLOBAL frame subscribes a
/// view to everything that moves it, and the column stack scrolls sideways: every frame of a
/// sideways swipe re-ran every visible row's reader, re-laid out every row's hosting view and pushed
/// the preference up through the window. Measured 2026-09-27 — a 12 s swipe in the app kept the main
/// thread 47% busy, nearly all of it SwiftUI invalidation and nested `NSHostingView.layout`; in the
/// headless fixture the per-row readers accounted for 536 of the 603 nested-layout samples (67 with
/// them off) and cost 42% of sideways scroll throughput. A row's bottom is a VERTICAL fact, nothing
/// vertical moves when the stack slides sideways, and the table already knows it.
///
/// **What it reports is the row's CELL bottom — where its selection highlight ends.** The reader
/// measured the row's content, which sits centred in a slightly taller cell: 4pt above the cell's
/// bottom at comfortable spacing, 6pt at compact (measured). AppKit cannot see the content's height
/// — the cell's hosting view reports the whole cell — so the bar now flips when it would reach the
/// selected row's highlight rather than its text, 4–6pt earlier than it did. Deliberate: the
/// highlight is the row as the user sees it.
///
/// **The column's OWN viewport, not `visibleRect`.** `visibleRect` is clipped by the stack too, and
/// reads empty for a column scrolled out sideways — so a column brought back into view would report
/// nothing until its next layout, and a click landing in that window would find its row missing.
/// `documentVisibleRect` of the column's clip is vertical visibility alone, which is the question.
///
/// Written straight into the placement, which is a plain class, so nothing here invalidates a view.
struct ColumnRowBottomsProbe: NSViewRepresentable {
    /// The column's rows, top to bottom — a row's table index is its position here.
    let rowIDs: [String]
    let placement: PaneBarPlacement
    /// Told after every report, so the pane can re-resolve the bar's edge — the job the row
    /// preference's `onPreferenceChange` did before.
    let onReport: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.configure(rowIDs: rowIDs, placement: placement, onReport: onReport)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(rowIDs: rowIDs, placement: placement, onReport: onReport)
        view.rearm()
    }

    final class ProbeView: BoundedResolveView {
        private var rowIDs: [String] = []
        private weak var placement: PaneBarPlacement?
        private var onReport: () -> Void = {}
        private weak var table: NSTableView?
        private var observer: NSObjectProtocol?
        /// The ids this column last wrote, so the next report can take back the rows that scrolled
        /// out, and teardown can take back all of them. Columns never share ids — each lists one
        /// directory's children — so one column's withdrawal cannot erase another's rows.
        private var written: Set<String> = []

        /// Test seam: the table this probe resolved, so a mounted test can assert it found ITS
        /// column's list and not a sibling's.
        var resolvedTable: NSTableView? { table }

        func configure(rowIDs: [String], placement: PaneBarPlacement, onReport: @escaping () -> Void) {
            self.rowIDs = rowIDs
            if self.placement !== placement {
                withdraw()
                self.placement = placement
            }
            self.onReport = onReport
        }

        override func windowDidExit() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            table = nil
            withdraw()
        }

        /// Runs on every layout pass and after `rearm()`'s hop: resolves the column's table once,
        /// then reports. A report is a handful of rect conversions and dictionary writes.
        override func resolvePass() {
            guard window != nil else { return }
            if table?.window !== window || observer == nil {
                guard spendSearchBudget(),
                      let found = PaneListResolver.table(matching: self),
                      let clip = found.enclosingScrollView?.contentView else { return }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                clip.postsBoundsChangedNotifications = true
                // A vertical scroll of THIS column is the one thing that moves its rows. The stack's
                // sideways scroll is not observed at all, which is the point.
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
                table = found
            }
            report()
        }

        /// Writes this column's visible rows' bottoms, in the window content view's flipped space —
        /// the space SwiftUI's `.global` frames use, and so the space `viewportGlobalMinY` is in.
        func report() {
            guard let placement, let table, let clip = table.enclosingScrollView?.contentView,
                  let content = window?.contentView else { return }
            let range = table.rows(in: clip.documentVisibleRect)
            var fresh: [String: CGFloat] = [:]
            if range.length > 0 {
                for row in range.location..<min(range.location + range.length, rowIDs.count) {
                    let rect = table.convert(table.rect(ofRow: row), to: content)
                    fresh[rowIDs[row]] = content.isFlipped ? rect.maxY : content.bounds.height - rect.minY
                }
            }
            for id in written where fresh[id] == nil { placement.rowBottoms[id] = nil }
            for (id, bottom) in fresh { placement.rowBottoms[id] = bottom }
            written = Set(fresh.keys)
            onReport()
        }

        private func withdraw() {
            if let placement {
                for id in written { placement.rowBottoms[id] = nil }
            }
            written = []
        }
    }
}
