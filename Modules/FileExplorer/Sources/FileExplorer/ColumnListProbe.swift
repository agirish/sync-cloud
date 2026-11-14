import AppKit
import Events
import SwiftUI
import Sync

/// One column's list, watched once for the two things the pane keeps from it: where its visible
/// rows end, for the action bar, and where it is scrolled, for the pane's scroll memory. One probe,
/// not one per job: both answers come from the same `NSTableView` and change on the same two
/// signals, the column's own vertical scroll and its table resizing as rows arrive, leave or change
/// height.
///
/// Row bottoms come from the table, not a `GeometryReader` per row. `PaneBarPlacement` needs every
/// visible row's bottom before a click lands (its `rowBottoms`), and reading a `.global` frame
/// subscribes a view to everything that moves it: the column stack scrolls sideways, so every
/// frame of a swipe would re-run every visible row's reader and re-lay out its hosting view (per-row
/// readers measured at about 42% of sideways scroll throughput). A row's bottom is a vertical fact,
/// and nothing vertical moves when the stack slides.
///
/// It reports the row's cell bottom, where its selection highlight ends, 4–6pt below the centred
/// content (AppKit can't see the content's height). Deliberate: the highlight is the row as the
/// user sees it.
///
/// The column's own viewport, not `visibleRect`, which the stack clips too and reads empty for a
/// column scrolled out sideways, so a column brought back would report nothing until its next
/// layout. `documentVisibleRect` of the column's clip is vertical visibility alone.
///
/// Only while the table agrees with `rows`. A republish hands this view the new rows before the
/// List applies them, so for a moment row N of the table isn't row N of `rows`, and when the folder
/// shrank the visible range can begin past the end. Reporting then would give rows their
/// neighbours' bottoms, or trap on the range. The probe keeps what it last wrote and reports again
/// once the two agree, which the table's resize signals.
///
/// The list's scroll position: see `PaneScrollMemory` for what is kept, and why as a meaning rather
/// than a number. A kept position is put back once the column's rows are in and its table has grown
/// to hold them, resolved against the list as it is now; it is dropped if the user scrolls first.
///
/// Writes straight into the placement and the memory, both plain classes, so nothing here
/// invalidates a view.
struct ColumnListProbe: NSViewRepresentable {
    /// The column's rows, top to bottom; a row's table index is its position here.
    let rows: [PaneRow]
    /// Where the bar reads row bottoms from, and who to tell when a report flips its edge. `nil` on
    /// a surface with no action bar.
    let placement: PaneBarPlacement?
    let onBarEdgeFlip: (() -> Void)?
    /// The pane's scroll memory; `nil` when the host keeps none.
    let memory: PaneScrollMemorySlot?
    /// The folder this column lists: the key its position is kept under.
    let directory: String
    /// Whether this column may put a kept position back. Read once, when the column mounts
    /// (`PaneColumnsView.listRestores(directory:)`).
    let restores: Bool

    /// The rows a report may read: the table's visible range, clamped to `rows`, but only while the
    /// table holds exactly as many rows as `rows`. `nil` while they disagree (a republish half
    /// applied), when a report would hand rows their neighbours' bottoms or read past the end. An
    /// empty range is a report of nothing, which takes back what was written.
    static func reportableRows(tableRows: Int, rowsCount: Int, visible: NSRange) -> Range<Int>? {
        guard tableRows == rowsCount else { return nil }
        let lower = min(visible.location, rowsCount)
        let upper = min(visible.location + visible.length, rowsCount)
        return lower..<max(lower, upper)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(restores: restores)
        view.configure(rows: rows, placement: placement, onBarEdgeFlip: onBarEdgeFlip,
                       memory: memory, directory: directory)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(rows: rows, placement: placement, onBarEdgeFlip: onBarEdgeFlip,
                       memory: memory, directory: directory)
        view.rearm()
    }

    final class ProbeView: FrameAnchoredResolveView {
        private let restores: Bool
        private var rows: [PaneRow] = []
        private weak var placement: PaneBarPlacement?
        private var onBarEdgeFlip: (() -> Void)?
        private var memory: PaneScrollMemorySlot?
        private var directory = ""

        private weak var table: NSTableView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        /// What this column last wrote into the placement, id → bottom. Withdrawals take back only
        /// values still ours: the tree's rows and a column's share ids (both are node paths), and an
        /// entry the other presentation wrote since isn't this probe's to erase.
        private var written: [String: CGFloat] = [:]
        /// The kept position waiting to be put back, read once per mount, before anything this mount
        /// does can be recorded over it. Recording is held while it waits, for the same reason.
        private var pending: PaneScrollMemory.Position?
        private var hasReadPending = false
        private var attemptsLeft = 0
        /// Holds the list clear while its kept position waits (`PaneScrollVeil`).
        private var veil = PaneScrollVeil()
        /// Whether this mount has said it found no table: once, not on every pass.
        private var reportedMissingTable = false

        init(restores: Bool) {
            self.restores = restores
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Test seam: the table this probe resolved, so a mounted test can assert it found its own
        /// column's list and not a sibling's.
        var resolvedTable: NSTableView? { table }

        func configure(rows: [PaneRow], placement: PaneBarPlacement?, onBarEdgeFlip: (() -> Void)?,
                       memory: PaneScrollMemorySlot?, directory: String) {
            self.rows = rows
            if self.placement !== placement {
                withdrawAll()
                self.placement = placement
            }
            self.onBarEdgeFlip = onBarEdgeFlip
            self.memory = memory
            self.directory = directory
        }

        override func windowDidExit() {
            stopObserving()
            table = nil
            forgetResolvedTable()
            withdrawAll()
            pending = nil
            veil.lift()
            hasReadPending = false
            reportedMissingTable = false
        }

        /// Runs on every layout pass and after `rearm()`'s hop: resolves the column's table (by
        /// frame, and only once this view has one; see `FrameAnchoredResolveView`), then reports.
        override func resolvePass() {
            guard window != nil else { return }
            guard let found = resolveTableView() else {
                if searchBudgetIsSpent, !reportedMissingTable {
                    reportedMissingTable = true
                    Logger.shared.debug("[columns] no list found for \(directory): the bar cannot see its rows, and its scroll is not kept")
                }
                return
            }
            if found !== table { observe(found) }
            if !hasReadPending {
                hasReadPending = true
                let kept = memory?.memory.listPosition(directory: directory)
                if restores {
                    pending = kept
                } else if kept != nil {
                    Logger.shared.debug("[columns] scroll memory: \(directory) left to a reveal")
                }
                if let pending, let scroller = found.enclosingScrollView {
                    // Not for a list kept at its top: the restore can't move it, so a cover would
                    // only blank it for a frame, and every list ever shown is kept at its top from
                    // its first layout. Only a list that will move is held clear.
                    if !pending.isAtStart(of: scroller.contentView.restingRangeY) { veil.cover(scroller) }
                }
                if pending != nil {
                    attemptsLeft = PaneScrollMemory.restoreAttempts
                    scheduleRestore()
                }
            }
            tableChanged()
        }

        private func observe(_ found: NSTableView) {
            stopObserving()
            table = found
            if let clip = found.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                // A vertical scroll of this column is the one thing that moves its rows. The stack's
                // sideways scroll isn't observed at all, which is the point.
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                }
            }
            // Rows arriving, leaving or changing height resize the table: the bottoms moved, and a
            // kept position may just have become holdable.
            found.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: found, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tableChanged() }
            }
        }

        private func stopObserving() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            boundsObserver = nil
            frameObserver = nil
        }

        /// The column scrolled vertically: the user, a reveal, or a restore landing.
        private func scrolled() {
            if pending != nil, PaneScrollMemory.isUserScroll(NSApp.currentEvent) {
                pending = nil
                veil.lift()
                Logger.shared.debug("[columns] scroll memory: \(directory) position dropped — scrolled first")
            }
            report()
            record()
        }

        /// A layout pass ran, or the table resized.
        private func tableChanged() {
            report()
            if pending != nil, isSettled() { scheduleRestore(immediately: true) }
        }

        // MARK: The bar's row bottoms

        /// Writes this column's visible rows' bottoms, in the window content view's top-down space:
        /// the space SwiftUI's `.global` frames use, and so the one `viewportGlobalMinY` is in.
        private func report() {
            guard let placement, let table, let clip = table.enclosingScrollView?.contentView,
                  let content = window?.contentView,
                  let reportable = ColumnListProbe.reportableRows(
                      tableRows: table.numberOfRows, rowsCount: rows.count,
                      visible: table.rows(in: clip.documentVisibleRect))
            else { return }
            var fresh: [String: CGFloat] = [:]
            for row in reportable {
                let rect = table.convert(table.rect(ofRow: row), to: content)
                fresh[rows[row].id] = content.isFlipped ? rect.maxY : content.bounds.maxY - rect.minY
            }
            for (id, bottom) in written where fresh[id] == nil && placement.rowBottoms[id] == bottom {
                placement.rowBottoms[id] = nil
            }
            for (id, bottom) in fresh { placement.rowBottoms[id] = bottom }
            written = fresh
            placement.flipIfEdgeMoved(onBarEdgeFlip)
        }

        private func withdrawAll() {
            if let placement {
                for (id, bottom) in written where placement.rowBottoms[id] == bottom {
                    placement.rowBottoms[id] = nil
                }
            }
            written = [:]
        }

        // MARK: The list's scroll position

        private func record() {
            guard pending == nil, let memory, let clip = table?.enclosingScrollView?.contentView else { return }
            memory.memory.recordList(directory: directory,
                                     position: .resting(at: clip.bounds.origin.y, in: clip.restingRangeY))
        }

        /// Whether the column's rows are all in and its table has grown to hold them, what a kept
        /// position waits for, since a list's height arrives with its rows. An empty folder has
        /// nothing to wait for.
        private func isSettled() -> Bool {
            guard let table, table.numberOfRows == rows.count,
                  let clip = table.enclosingScrollView?.contentView, clip.bounds.height > 0 else { return false }
            guard let last = rows.indices.last else { return true }
            return (clip.documentView?.frame.height ?? 0) >= table.rect(ofRow: last).maxY - 0.5
        }

        private func scheduleRestore(immediately: Bool = false) {
            if immediately {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromEvent: true) }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + PaneScrollMemory.restoreStep) { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromEvent: false) }
                }
            }
        }

        /// Puts the list back once its rows are in, never from inside a layout pass or a
        /// notification; both only schedule this. Called for a resize or layout pass that found the
        /// rows settled (`fromEvent`), and by the counted fallback.
        private func applyRestore(fromEvent: Bool) {
            guard let position = pending, let table, let scroller = table.enclosingScrollView else {
                veil.lift()   // nothing left to restore into: never leave a list clear
                return
            }
            if !isSettled() {
                guard !fromEvent else { return }
                veil.lift()
                attemptsLeft -= 1
                if attemptsLeft > 0 {
                    scheduleRestore()
                    return
                }
                Logger.shared.debug("[columns] scroll memory: \(directory) waited out \(PaneScrollMemory.restoreAttempts) checks for its rows; putting its position back anyway")
            }
            // Released before the move, so the move's own notification records where it landed.
            pending = nil
            let clip = scroller.contentView
            let y = position.resolved(in: clip.restingRangeY)
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scroller.reflectScrolledClipView(clip)
            veil.lift()
            record()
        }
    }
}
