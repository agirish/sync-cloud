import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// The differences list has to take the keyboard when it is clicked, for a reason the panes did not
/// have: something else already holds it.
///
/// Measured in the app on 2026-09-25, with `PaneListKeyFocus` shipped for the panes and nothing for
/// this table: clicking a difference left first responder on the LEFT PANE's list, so ⇧↓ went on
/// extending the pane's selection while the user watched the differences list — `[sel] left list
/// wrote 2 … 3 … 4 … 5 item(s)` against a table the click had never touched. Keys landing on the
/// surface you are not looking at is worse than keys doing nothing, which is what the same gesture
/// did before the panes could take focus at all.
///
/// **The click cannot be found by hit-testing.** In the app it reports the window's root hosting
/// view, with no `NSTableView` in the chain — `[hit] DOWN … | no enclosing table` on a click that
/// really does select a row. That is what `target(covering:in:)` exists for, and why these tests
/// assert on it rather than on the hit-test route the pane tests already cover.
/// A content view whose hit-testing always answers one view, whatever the point — the app's
/// behaviour, staged. See `aHitOutsideItsOwnViewportIsNotBelieved`.
private final class LyingContent: NSView {
    weak var answer: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { answer }
}

@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct DifferencesKeyFocusTests {

    // MARK: Harness

    private func rows(_ count: Int = 12) -> [FileDifference] {
        (1...count).map { index in
            FileDifference(relativePath: "Documents/file-\(index).txt",
                           leftItemPath: "/left/Documents/file-\(index).txt",
                           rightItemPath: "/right/Documents/file-\(index).txt",
                           type: .missingOnRight,
                           action: .copyToRight,
                           description: "Only on the left",
                           leftFileSize: 1024 * index)
        }
    }

    /// Mounts the real `DifferencesView`, ungrouped, in a real never-ordered-in window.
    private func mount() -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let store = ScratchDefaults("DifferencesKeyFocusTests")
        store.set(false, forKey: "differencesGroupByFolder")
        let manager = FileSyncManager()
        manager.differences = rows()
        manager.hasScanned = true
        let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore())
            .defaultAppStorage(store)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// The differences table: the window's one MULTI-column table, which is how every other piece
    /// of this code tells it from a pane list.
    private func differencesTable(in view: NSView) -> NSTableView? {
        PaneListResolver.tables(in: view, multiColumn: true).first
    }

    /// Mounts and waits until the table exists, has rows, and has registered itself.
    private func mountedAndRegistered() async -> (NSWindow, NSTableView)? {
        let (host, window) = mount()
        let ready = await LayoutPumpWait.pump(host, upTo: 5) {
            guard let table = differencesTable(in: host) else { return false }
            return table.numberOfRows > 4 && PaneListKeyFocus.isRegistered(table)
        }
        guard let table = differencesTable(in: host) else {
            Issue.record("no multi-column table mounted at all — the fixture is not exercising it")
            return nil
        }
        guard ready.held else {
            Issue.record("table has \(table.numberOfRows) rows, registered=\(PaneListKeyFocus.isRegistered(table)) after \(ready.pumps) pumps")
            return nil
        }
        return (window, table)
    }

    private func key(_ code: UInt16, shift: Bool, in window: NSWindow) -> NSEvent {
        let chars = code == 125 ? "\u{F701}" : "\u{F700}"
        var flags: NSEvent.ModifierFlags = [.function, .numericPad]
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars,
                                isARepeat: false, keyCode: code)!
    }

    /// A left mouse-up over the table's visible area, in window coordinates.
    private func mouseUp(onRow row: Int, of table: NSTableView, in window: NSWindow) -> NSEvent {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    // MARK: The outcome

    /// **The report, end to end, with its own control.** Asserted on the table's OWN selection: the
    /// view's `selection` is private `@State`, and `selectedRowIndexes` is what AppKit actually did
    /// with the keystroke either way.
    @Test("A click in the differences list gives it the keyboard, and ⇧↓ then extends its selection")
    func clickThenShiftArrowExtends() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        table.selectRowIndexes(IndexSet([2]), byExtendingSelection: false)
        window.makeFirstResponder(nil)
        #expect(window.firstResponder === window, "the fixture must start with the window holding focus")

        // Control: the app as it is today. The key reaches the window and moves nothing here.
        window.sendEvent(key(125, shift: true, in: window))
        _ = await LayoutPumpWait.pump(window, upTo: 2) { table.selectedRowIndexes.count > 1 }
        #expect(table.selectedRowIndexes == IndexSet([2]),
                "⇧↓ extended with the WINDOW focused — the control cannot fail, so nothing below proves anything")

        PaneListKeyFocus.noteClick(mouseUp(onRow: 2, of: table, in: window), schedule: { $0() })
        #expect(window.firstResponder === table, "the click did not give the differences list focus")

        window.sendEvent(key(125, shift: true, in: window))
        let extended = await LayoutPumpWait.pump(window, upTo: 5) { table.selectedRowIndexes.count == 2 }
        #expect(extended.held,
                "⇧↓ after the click should select two rows (\(extended.pumps) pumps, got \(table.selectedRowIndexes.map { $0 }))")
    }

    /// The call site: mounting the real view registers its table. Without this the rule above is a
    /// function nothing calls.
    @Test("Mounting the differences view registers its table for key focus")
    func theViewRegistersItsTable() async {
        guard let (_, table) = await mountedAndRegistered() else { return }
        #expect(PaneListKeyFocus.isRegistered(table))
        #expect(table.tableColumns.count > 1, "control: this is the multi-column differences table, not a pane list")
    }

    // MARK: The frame route

    /// The property the app needs: the table is found from the click's POINT, with no reliance on
    /// hit-testing reaching it. Prints what hit-testing manages here, because the test window and
    /// the app disagree about that and a reader will want to know which they are looking at.
    @Test("The differences list is found by the point a click lands on")
    func foundByFrame() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        let rect = table.rect(ofRow: 2)
        let inWindow = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let hit = window.contentView?.hitTest(window.contentView!.convert(inWindow, from: nil))
        print("[diff-focus] hit-test at a row: \(hit.map { String(describing: type(of: $0)) } ?? "nil") "
              + "→ hit route \(PaneListKeyFocus.target(forHit: hit) === table ? "found it" : "did NOT find it")")

        #expect(PaneListKeyFocus.target(covering: inWindow, in: window) === table)

        // Far outside the list: the fallback must be able to say no.
        let outside = NSPoint(x: inWindow.x, y: window.frame.height + 500)
        #expect(PaneListKeyFocus.target(covering: outside, in: window) == nil)
    }

    /// **The app's actual condition, staged.** In the app the click's hit view is the window's root
    /// hosting view with no table above it, so the hit route returns nothing and the claim has to
    /// come from the point alone. Here an opaque overlay over the table produces the same shape —
    /// a hit view that is not in any table — which is what makes this the one test that fails if the
    /// frame route is removed. The end-to-end test above cannot: hit-testing reaches the table in a
    /// test window (it prints which route it took), so it passes either way.
    @Test("A click whose hit view is not in any table still gives the list the keyboard")
    func claimSurvivesHitTestingThatCannotSeeTheTable() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        let overlay = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(overlay)
        defer { overlay.removeFromSuperview() }

        let rect = table.rect(ofRow: 2)
        let inWindow = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let hit = window.contentView!.hitTest(window.contentView!.convert(inWindow, from: nil))
        #expect(hit === overlay, "the overlay must be what hit-testing finds, or this stages nothing")
        #expect(PaneListKeyFocus.target(forHit: hit) == nil, "control: the hit route is blind here")

        window.makeFirstResponder(nil)
        #expect(window.firstResponder === window)
        PaneListKeyFocus.noteClick(mouseUp(onRow: 2, of: table, in: window), schedule: { $0() })
        #expect(window.firstResponder === table,
                "with hit-testing blind, the point alone must still find the list")
    }

    /// The call site for the normalizer: mounting the real view puts one on its table. This is the
    /// half that has no other proof — the harness cannot show that a recognizer is NEEDED, because
    /// in a test window these clicks reach the event stream perfectly well. That necessity was
    /// measured in the app by adding, removing and re-adding it; this only pins that it is there.
    @Test("Mounting the differences view puts a click normalizer on its table")
    func theViewInstallsAClickNormalizer() async {
        guard let (_, table) = await mountedAndRegistered() else { return }
        let normalizers = table.gestureRecognizers.filter { $0.delegate is PaneListKeyFocus.ClickNormalizer }
        #expect(normalizers.count == 1,
                "want exactly one normalizer, found \(normalizers.count) among \(table.gestureRecognizers.count) recognizers")
    }

    /// It observes and never recognizes: a recognizer that claimed the click would make the rows
    /// dead to selection, the failure `PaneBackgroundDeselect` documents for its own.
    @Test("The normalizer never consumes the click")
    func theNormalizerNeverRecognizes() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        let normalizer = PaneListKeyFocus.ClickNormalizer.install(on: table)
        let recognizer = try! #require(table.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
            .first { $0.delegate === normalizer })
        #expect(normalizer.gestureRecognizer(recognizer,
                                             shouldAttemptToRecognizeWith: mouseUp(onRow: 2, of: table, in: window)) == false)
    }

    /// **The defect that made this positional.** A pane's table answers hit-tests for points well
    /// outside its own viewport, so a click on the differences list's top rows resolved to a pane
    /// row and the keys went there. Staged with two registered lists whose viewports do not
    /// overlap: the click's POINT is in the lower one, its HIT VIEW is in the upper one.
    @Test("A hit-test answer is ignored when the click is outside that list's viewport")
    func aHitOutsideItsOwnViewportIsNotBelieved() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        func list(at frame: NSRect) -> NSTableView {
            let scroll = NSScrollView(frame: frame)
            let table = NSTableView(frame: NSRect(origin: .zero, size: frame.size))
            table.addTableColumn(NSTableColumn(identifier: .init("c")))
            scroll.documentView = table
            window.contentView?.addSubview(scroll)
            return table
        }
        let upper = list(at: NSRect(x: 0, y: 400, width: 400, height: 200))
        let lower = list(at: NSRect(x: 0, y: 0, width: 400, height: 360))
        window.contentView?.layoutSubtreeIfNeeded()
        // **Hit-testing has to lie, because that is the defect.** In the app the pane's table
        // answers for points outside its own viewport; a plain test window never would, so the
        // content view is replaced by one that always answers `upper` — and without that, this
        // test passes with the validation deleted (measured: the first version did exactly that).
        let liar = LyingContent(frame: window.contentView!.bounds)
        for view in window.contentView!.subviews { liar.addSubview(view) }
        liar.answer = upper
        window.contentView = liar
        liar.layoutSubtreeIfNeeded()
        PaneListKeyFocus.register(upper)
        PaneListKeyFocus.register(lower)

        let point = NSPoint(x: 200, y: 180)           // inside `lower`'s viewport only
        #expect(PaneListKeyFocus.visibleRect(of: lower).contains(point))
        #expect(!PaneListKeyFocus.visibleRect(of: upper).contains(point),
                "the fixture needs viewports that do not overlap")
        // The control that makes this test capable of failing: hit-testing at the click's own
        // point resolves INTO the upper list, which is what the validation has to overrule.
        let hit = liar.hitTest(liar.convert(point, from: nil))
        #expect(PaneListKeyFocus.target(forHit: hit) === upper,
                "the staged hit-test must answer `upper`, or the validation is never exercised")

        let event = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 0)!
        window.makeFirstResponder(nil)
        PaneListKeyFocus.noteClick(event, schedule: { $0() })
        #expect(window.firstResponder === lower,
                "the click belongs to the list it landed in, not the one whose hit-test reaches over it")
    }

    // MARK: The normalizer's lifetime

    /// **A rebuild must not stack recognizers.** SwiftUI recreates the styler that holds the
    /// normalizer, and the first version installed one per instance — each outliving the object
    /// whose delegate call refuses it, on a table that keeps them all.
    @Test("Installing a normalizer twice leaves one recognizer, not two")
    func installIsIdempotent() async {
        guard let (_, table) = await mountedAndRegistered() else { return }
        let first = PaneListKeyFocus.ClickNormalizer.install(on: table)
        let countAfterFirst = PaneListKeyFocus.ClickNormalizer.count(on: table)
        let second = PaneListKeyFocus.ClickNormalizer.install(on: table)
        #expect(PaneListKeyFocus.ClickNormalizer.count(on: table) == countAfterFirst,
                "a second install added a recognizer (now \(PaneListKeyFocus.ClickNormalizer.count(on: table)))")
        #expect(second === first, "the second install should adopt the recognizer already there")
    }

    /// **The retain that closes the orphan hazard.** The recognizer's `delegate` is weak and its
    /// `target` unowned, so nothing but this association keeps the normalizer alive — and a
    /// recognizer whose delegate has gone stops being refused, begins recognizing clicks, and sends
    /// its action to freed memory. Dropping every reference the test holds must not collect it.
    @Test("The recognizer keeps its normalizer alive on its own")
    func theRecognizerOwnsItsNormalizer() {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        do {
            let normalizer = PaneListKeyFocus.ClickNormalizer.install(on: table)
            #expect(PaneListKeyFocus.ClickNormalizer.count(on: table) == 1)
            _ = normalizer
        }
        // Nothing in this test holds it now; only the recognizer does.
        #expect(PaneListKeyFocus.ClickNormalizer.count(on: table) == 1,
                "the normalizer was collected, leaving a recognizer nothing refuses")
        let recognizer = table.gestureRecognizers.first { $0.delegate is PaneListKeyFocus.ClickNormalizer }
        #expect(recognizer?.delegate != nil, "a nil delegate is exactly the orphan this guards against")
    }

    /// The recognizer stays with the TABLE across a styler that comes and goes — the opposite of
    /// what an earlier version did, where the styler leaving the window took the recognizer with it
    /// and left a mounted list carrying none (measured, and the reason ownership moved).
    @Test("A styler leaving the window leaves the list's recognizer in place")
    func leavingTheWindowKeepsTheRecognizer() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        #expect(PaneListKeyFocus.ClickNormalizer.count(on: table) == 1,
                "the mounted view should carry exactly one")
        window.contentView = NSView(frame: window.contentView!.bounds)   // the styler leaves the window
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }
        #expect(PaneListKeyFocus.ClickNormalizer.count(on: table) == 1,
                "the list still needs its clicks normalized; only the styler went")
    }

    /// A list with no scroll view around it is its own viewport. Answering `.zero` would make such a
    /// list permanently unclaimable, since both routes test containment against this rect.
    @Test("A list with no scroll view reports its own frame as its viewport")
    func visibleRectFallsBackToTheTableFrame() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bare = NSTableView(frame: NSRect(x: 10, y: 20, width: 120, height: 60))
        window.contentView?.addSubview(bare)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bare.enclosingScrollView == nil, "the fixture needs a table with no scroll view")

        // A table with no columns shrinks to fit its content, so the point comes FROM the rect
        // rather than from the frame it was created with (measured: it resized to 20x15).
        let rect = PaneListKeyFocus.visibleRect(of: bare)
        #expect(!rect.isEmpty, "an empty rect would make this list unclaimable by either route")
        #expect(rect == bare.convert(bare.bounds, to: nil), "got \(NSStringFromRect(rect))")

        PaneListKeyFocus.register(bare)
        #expect(PaneListKeyFocus.target(covering: NSPoint(x: rect.midX, y: rect.midY), in: window) === bare)
    }

    /// A table nobody registered is invisible to the frame route too — otherwise every `NSTableView`
    /// in the window would take the keyboard, the review queue included.
    @Test("The frame route ignores a table that never registered")
    func frameRouteIgnoresUnregistered() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        window.contentView?.layoutSubtreeIfNeeded()
        let inside = NSPoint(x: 200, y: 150)

        #expect(PaneListKeyFocus.target(covering: inside, in: window) == nil,
                "an unregistered table must not answer")
        PaneListKeyFocus.register(table)
        #expect(PaneListKeyFocus.target(covering: inside, in: window) === table,
                "control: the same point finds it once registered, so the refusal above was the registry")
    }

    /// **The refusal, driven through the door the app uses.** The rule alone is not enough: a
    /// `noteMouseUp` that never consults it would leave the rule green and still take the keys off
    /// a caret. The field sits OVER a registered table, so the frame route would otherwise claim it.
    @Test("A click into a field over the list does not take the list's keyboard")
    func noteMouseUpRefusesAClickInAField() async {
        guard let (window, table) = await mountedAndRegistered() else { return }
        let rect = table.rect(ofRow: 2)
        let inWindow = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let field = NSTextField(frame: NSRect(x: inWindow.x - 60, y: inWindow.y - 11, width: 120, height: 22))
        field.isEditable = true
        window.contentView!.addSubview(field)
        defer { field.removeFromSuperview() }
        let hit = window.contentView!.hitTest(window.contentView!.convert(inWindow, from: nil))
        #expect(hit is NSTextField || hit?.superview is NSTextField,
                "the field must be what hit-testing finds, or this stages nothing (got \(hit.map { String(describing: type(of: $0)) } ?? "nil"))")

        window.makeFirstResponder(nil)
        PaneListKeyFocus.noteClick(mouseUp(onRow: 2, of: table, in: window), schedule: { $0() })
        #expect(window.firstResponder !== table,
                "a click that put a caret in a field must leave the keys with the field")
    }

    /// The frame route asks what is VISIBLE, not how tall the table is. A list is as tall as its
    /// rows, so a long table's own frame reaches far outside its scroll view — and a click out
    /// there, on whatever else is in the window, would otherwise be claimed by it.
    ///
    /// The rows are what make this measurable: a document view is sized by its content, so an
    /// empty table shrinks to fit its viewport and the two rects coincide (measured — the first
    /// version of this test staged nothing and let the mutation live).
    @Test("A click outside a long list's visible area is not claimed by it")
    func frameRouteAsksTheVisibleArea() {
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 200 }
            func tableView(_ t: NSTableView, objectValueFor c: NSTableColumn?, row: Int) -> Any? { "row \(row)" }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A short scroll view at the TOP of the window, holding a table far taller than it.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 400, width: 400, height: 200))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        let rows = Rows()
        table.dataSource = rows
        scroll.documentView = table
        table.reloadData()
        window.contentView?.addSubview(scroll)
        window.contentView?.layoutSubtreeIfNeeded()
        PaneListKeyFocus.register(table)

        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let whole = table.convert(table.bounds, to: nil)
        #expect(whole.height > visible.height + 100,
                "the fixture needs a table taller than its viewport (table \(whole.height), viewport \(visible.height))")

        let insideVisible = NSPoint(x: visible.midX, y: visible.midY)
        #expect(PaneListKeyFocus.target(covering: insideVisible, in: window) === table,
                "control: a point inside the viewport is the list's")

        // Inside the TABLE's frame, outside its viewport: the mutation's point of view versus this one.
        let outside = NSPoint(x: visible.midX, y: visible.minY - 100)
        #expect(whole.contains(outside) && !visible.contains(outside),
                "the fixture needs a point in the table's frame but outside the viewport (table \(whole), viewport \(visible))")
        #expect(PaneListKeyFocus.target(covering: outside, in: window) == nil,
                "a click outside the list's viewport is not a click in the list")
    }

    /// A caret keeps its click on BOTH routes. The field is outside any table here, which is the
    /// case the frame route would otherwise claim for whatever list sits under the point.
    @Test("A click that puts a caret in a field is refused before either route")
    func aCaretKeepsItsClick() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.isEditable = true
        #expect(PaneListKeyFocus.landedInAnEditableField(field))
        field.isEditable = false
        #expect(!PaneListKeyFocus.landedInAnEditableField(field),
                "a label is not a caret — refusing here would make ordinary row content unclickable")
        #expect(!PaneListKeyFocus.landedInAnEditableField(nil))
    }
}
