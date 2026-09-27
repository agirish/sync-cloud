import AppKit
import Events
import SwiftUI
import Sync

/// One column's list, watched once for the two things the pane keeps from it: where its visible rows
/// end, for the action bar, and where it is scrolled, for the pane's scroll memory.
///
/// One probe rather than one per job: both answers come from the same `NSTableView` and change on
/// the same two signals — the column's own vertical scroll, and its table resizing as rows arrive,
/// leave or change height. Two probes were two resolves of one table and two observers on one clip,
/// for every column.
///
/// **The bar's row bottoms, and why they replaced a `GeometryReader` on every row.**
/// `PaneBarPlacement` needs every visible row's bottom edge before a click lands (see its
/// `rowBottoms`), and each column row used to report its own through a `.global` `GeometryReader` and
/// a preference. Reading a GLOBAL frame subscribes a view to everything that moves it, and the column
/// stack scrolls sideways: every frame of a sideways swipe re-ran every visible row's reader,
/// re-laid out every row's hosting view and pushed the preference up through the window. Measured
/// 2026-09-27 — a 12 s swipe in the app kept the main thread 47% busy, nearly all of it SwiftUI
/// invalidation and nested `NSHostingView.layout`; in the headless fixture the per-row readers
/// accounted for 536 of the 603 nested-layout samples (67 with them off) and cost 42% of sideways
/// scroll throughput. A row's bottom is a VERTICAL fact, nothing vertical moves when the stack slides
/// sideways, and the table already knows it.
///
/// **What it reports is the row's CELL bottom — where its selection highlight ends.** The reader
/// measured the row's content, which sits centred in a slightly taller cell: 4pt above the cell's
/// bottom at comfortable spacing, 6pt at compact (measured). AppKit cannot see the content's height —
/// the cell's hosting view reports the whole cell — so the bar flips when it would reach the selected
/// row's highlight rather than its text, 4–6pt earlier than it did. Deliberate: the highlight is the
/// row as the user sees it.
///
/// **The column's OWN viewport, not `visibleRect`.** `visibleRect` is clipped by the stack too, and
/// reads empty for a column scrolled out sideways — so a column brought back into view would report
/// nothing until its next layout, and a click landing in that window would find its row missing.
/// `documentVisibleRect` of the column's clip is vertical visibility alone, which is the question.
///
/// **Only while the table agrees with `rows`.** A republish hands this view the column's new rows
/// before the List has applied them to its table, so for a moment row N of the table is not row N of
/// `rows` — and when the folder shrank, the table's visible range can begin past the end of the new
/// rows altogether. Reporting then would give rows their neighbours' bottoms, or trap on the range.
/// The probe keeps what it last wrote and reports again once the two agree, which the table's resize
/// tells it.
///
/// **The list's scroll position** — see `PaneScrollMemory` for what is kept, and why as a meaning
/// rather than a number. A kept position is put back once the column's rows are all in and its table
/// has grown to hold them, resolved against the list as it is now; it is dropped if the user scrolls
/// first.
///
/// Writes straight into the placement and the memory, both plain classes, so nothing here invalidates
/// a view.
struct ColumnListProbe: NSViewRepresentable {
    /// The column's rows, top to bottom — a row's table index is its position here.
    let rows: [PaneRow]
    /// Where the bar reads row bottoms from, and who to tell when a report flips its edge. `nil` on a
    /// surface with no action bar.
    let placement: PaneBarPlacement?
    let onBarEdgeFlip: (() -> Void)?
    /// The pane's scroll memory; `nil` when the host keeps none.
    let memory: PaneScrollMemorySlot?
    /// The folder this column lists — the key its position is kept under.
    let directory: String
    /// Whether this column may put a kept position back. Read ONCE, when the column is mounted — see
    /// `PaneColumnsView.listRestores(directory:)`.
    let restores: Bool

    /// The rows a report may read: the table's visible range, clamped to `rows` — but only while the
    /// table holds exactly as many rows as `rows` does. `nil` while they disagree, which is a republish
    /// half applied: row N of the table is not row N of `rows` then, and a report would hand rows their
    /// neighbours' bottoms (or, where the folder shrank, read past the end). An empty range is a
    /// report of nothing, which takes back what was written.
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
        /// entry the other presentation has written since is not this probe's to erase.
        private var written: [String: CGFloat] = [:]
        /// The kept position waiting to be put back, read ONCE per mount — before anything this mount
        /// does can be recorded over it. Recording is held while it waits, for the same reason.
        private var pending: PaneScrollMemory.Position?
        private var hasReadPending = false
        private var attemptsLeft = 0
        /// Whether this mount has said it found no table — once, not on every pass.
        private var reportedMissingTable = false

        init(restores: Bool) {
            self.restores = restores
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Test seam: the table this probe resolved, so a mounted test can assert it found ITS
        /// column's list and not a sibling's.
        var resolvedTable: NSTableView? { table }

        /// Test seam: how many fallback checks the last restore used before it landed. A restore that
        /// landed on its content settling uses a few at most; one that ran them all out waited for a
        /// room that was never coming, which is the three-second stall this probe was rebuilt to end.
        private(set) var checksUsedByLastRestore: Int?

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
            hasReadPending = false
            reportedMissingTable = false
        }

        /// Runs on every layout pass and after `rearm()`'s hop: resolves the column's table — by frame,
        /// and only once this view has one (see `FrameAnchoredResolveView`) — then reports.
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
                // A vertical scroll of THIS column is the one thing that moves its rows. The stack's
                // sideways scroll is not observed at all, which is the point.
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                }
            }
            // Rows arriving, leaving or changing height resize the table: the bottoms moved, and a kept
            // position may just have become holdable.
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

        /// The column scrolled vertically — the user, a reveal, or a restore landing.
        private func scrolled() {
            if pending != nil, PaneScrollMemory.isUserScroll(NSApp.currentEvent) {
                pending = nil
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

        /// Writes this column's visible rows' bottoms, in the window content view's top-down space —
        /// the space SwiftUI's `.global` frames use, and so the space `viewportGlobalMinY` is in.
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

        /// Whether the column's rows are all in and its table has grown to hold them — what a kept
        /// position waits for, since a list's height arrives with its rows. An empty folder has nothing
        /// to wait for.
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

        /// Puts the list back once its rows are in — never from inside a layout pass or a notification;
        /// both only schedule this. Called for a resize or layout pass that found the rows settled
        /// (`fromEvent`), and by the counted fallback.
        private func applyRestore(fromEvent: Bool) {
            guard let position = pending, let table, let scroller = table.enclosingScrollView else { return }
            if !isSettled() {
                guard !fromEvent else { return }
                attemptsLeft -= 1
                if attemptsLeft > 0 {
                    scheduleRestore()
                    return
                }
                Logger.shared.debug("[columns] scroll memory: \(directory) waited out \(PaneScrollMemory.restoreAttempts) checks for its rows; putting its position back anyway")
            }
            // Released before the move, so the move's own notification records where it landed.
            pending = nil
            checksUsedByLastRestore = PaneScrollMemory.restoreAttempts - attemptsLeft
            let clip = scroller.contentView
            let y = position.resolved(in: clip.restingRangeY)
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scroller.reflectScrolledClipView(clip)
            record()
        }
    }
}
