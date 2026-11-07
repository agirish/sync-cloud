import AppKit
import Testing
@testable import FileExplorer

/// Pins how the pane's two AppKit attachments recover their table when SwiftUI stops calling them.
///
/// `PaneListSelectionStyler` and `PaneBackgroundDeselect` both find their `NSTableView` by an
/// ancestor scan, bounded by a burst budget so an unresolvable hierarchy can't burn a full scan on
/// every layout pass. `FileTreeView` is `Equatable`, so the pane rarely re-renders and
/// `updateNSView` can't be relied on to refill that budget. Without a periodic retry, a spent
/// budget gives up for good and the OS selection highlight shows under the app's accent wash: blue
/// with key focus, gray without, the accent only on lists that resolved in time.
///
/// These drive `resolveTableView()` directly, not through SwiftUI, because the case is precisely
/// that SwiftUI stops calling.
@MainActor
@Suite struct PaneListStylerRecoveryTests {

    /// A list: a table inside a scroll view. The scroll view's frame is what the resolver matches.
    private func list(at frame: CGRect) -> (scroll: NSScrollView, table: NSTableView) {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("c0")))
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = table
        return (scroll, table)
    }

    /// Mounts an anchor in a real window: `resolveTableView` rightly refuses without one, since an
    /// unmounted anchor has no hierarchy to search.
    private func mount(_ subviews: [NSView], frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: frame)
        subviews.forEach { root.addSubview($0) }
        window.contentView = root
        return window
    }

    private static let listFrame = CGRect(x: 0, y: 0, width: 210, height: 520)

    // MARK: The regression

    /// The budget is spent while no table can be found; then the list arrives (or is swapped in)
    /// beneath a stationary anchor. Without the periodic retry this returns nil forever and the row
    /// keeps the OS highlight for the rest of the session.
    @Test("A list that appears after the budget is spent is still found")
    func recoversAfterBudgetExhaustion() {
        let styler = PaneListSelectionStyler.StylerView(frame: Self.listFrame)
        let window = mount([styler])
        _ = window

        // Spend the burst with nothing in the hierarchy to find.
        for _ in 0..<10 { #expect(styler.resolveTableView() == nil) }

        // SwiftUI mounts the list, in the same place, without touching the anchor.
        let (scroll, table) = list(at: Self.listFrame)
        window.contentView?.addSubview(scroll)

        // The periodic retry has to carry this: the anchor hasn't moved and there was never a
        // cached table, so neither change signal fires.
        var found: NSTableView?
        for _ in 0..<40 where found == nil { found = styler.resolveTableView() }
        #expect(found === table)
    }

    /// The cheaper of the two recovery paths, and the common one: SwiftUI rebuilds the column stack,
    /// so the table this anchor had is replaced by a different instance in the same place.
    @Test("A table replaced in place is re-resolved immediately")
    func recoversWhenItsTableIsReplaced() {
        let styler = PaneListSelectionStyler.StylerView(frame: Self.listFrame)
        let (firstScroll, firstTable) = list(at: Self.listFrame)
        let window = mount([firstScroll, styler])
        #expect(styler.resolveTableView() === firstTable)

        firstScroll.removeFromSuperview()
        let (secondScroll, secondTable) = list(at: Self.listFrame)
        window.contentView?.addSubview(secondScroll)

        // Losing the table it had is a hierarchy change, so this takes the immediate path, without
        // waiting on the periodic retry.
        #expect(styler.resolveTableView() === secondTable)
    }

    /// A drill moves the anchor over a different column. The frame is the identity
    /// (`PaneListResolver`), so a moved anchor must re-search even with a valid cache.
    @Test("A moved anchor re-resolves to the list it now sits over")
    func recoversWhenTheAnchorMoves() {
        let leftFrame = Self.listFrame
        let rightFrame = Self.listFrame.offsetBy(dx: 210, dy: 0)
        let styler = PaneListSelectionStyler.StylerView(frame: leftFrame)
        let (leftScroll, leftTable) = list(at: leftFrame)
        let (rightScroll, rightTable) = list(at: rightFrame)
        _ = mount([leftScroll, rightScroll, styler])

        #expect(styler.resolveTableView() === leftTable)
        styler.frame = rightFrame
        #expect(styler.resolveTableView() === rightTable)
    }

    // MARK: The bound the budget exists for

    /// Everything above would also pass with the budget deleted and every call scanning, which
    /// would mean a six-ancestor walk per layout pass on every column of both panes. So the steady
    /// state is asserted too: with nothing to find and nothing changing, scans must be rare, not
    /// continuous.
    @Test("An unresolvable hierarchy settles into rare retries, not a scan per pass")
    func unresolvableHierarchyStopsScanningContinuously() {
        let styler = PaneListSelectionStyler.StylerView(frame: Self.listFrame)
        let window = mount([styler])

        // Burn the burst.
        for _ in 0..<10 { _ = styler.resolveTableView() }

        // Count how many of the next 100 passes reach the scan. A table is present but placed where
        // the anchor is not, so any scan comes back empty and the count measures only how often we
        // looked.
        let (elsewhere, _) = list(at: Self.listFrame.offsetBy(dx: 600, dy: 0))
        window.contentView?.addSubview(elsewhere)

        var scans = 0
        for _ in 0..<100 {
            let before = styler.searchesPerformed
            _ = styler.resolveTableView()
            if styler.searchesPerformed > before { scans += 1 }
        }
        #expect(scans <= 4, "expected the retry to be periodic, saw \(scans) scans in 100 passes")
        #expect(scans >= 1, "expected it to keep looking occasionally, saw none")
    }

    // MARK: The deselect catcher carries the identical rule

    /// `PaneBackgroundDeselect` shares the pattern, and its failure is worse because it is
    /// invisible: no recognizer is installed and clicking empty space silently stops deselecting.
    @Test("The deselect catcher recovers on the same terms")
    func deselectCatcherRecoversToo() {
        let catcher = PaneBackgroundDeselect.CatcherView(onDeselect: {})
        catcher.frame = Self.listFrame
        let window = mount([catcher])

        for _ in 0..<10 { #expect(catcher.resolveTableView() == nil) }

        let (scroll, table) = list(at: Self.listFrame)
        window.contentView?.addSubview(scroll)

        var found: NSTableView?
        for _ in 0..<40 where found == nil { found = catcher.resolveTableView() }
        #expect(found === table)
    }
}
