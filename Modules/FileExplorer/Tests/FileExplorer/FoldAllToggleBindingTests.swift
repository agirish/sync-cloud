import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Proves the header's master disclosure is actually WIRED, and sits where it was put.
///
/// `FoldAllActionTests` pins the rule; a pure rule nothing calls is still a rule. This mounts the
/// real `DifferencesView` and reads back the controls its header laid out.
///
/// **What it measures, and why not accessibility.** The first version of this suite walked the
/// accessibility tree looking for the button by its announced name. It found nothing — an
/// `NSHostingView` that is never ordered in has an EMPTY accessibility tree, no assistive client
/// having asked for one — so "the control is absent when ungrouped" passed for a table that had no
/// reachable controls at all, grouped or not. It was a green test measuring nothing. What SwiftUI
/// does lay out offscreen is one `_FocusRingView` per focusable control, sized to that control and
/// in document order, so that is what this reads. The class name is private, which is exactly why
/// every case here is written against a BASELINE: the ungrouped header still draws five controls,
/// so the day SwiftUI stops making focus rings these fail loudly instead of quietly agreeing that
/// the button isn't there.
///
/// Both harness lessons from `DifferencesTableIdentityTests` are kept: the tests are `async` and
/// yield with `Task.sleep` (a `@MainActor` test that spins `RunLoop.run` starves the `.task(id:)`
/// it is waiting on), and the window is created but never ordered in, because this machine's owner
/// drives the real app while these run. What is NOT kept is sleeping a fixed duration and then
/// measuring: see `headerControls`, which waits on the table's own row count and asserts it.
///
/// `.serialized` orders the cases here; `.oneMountedDifferencesTable` keeps this suite's mounts
/// from stacking on top of the other mounting suites' (see that trait). Isolation needs neither:
/// every mount seeds its own `ScratchDefaults` suite (see `mount`), so no other suite — and no
/// leftover plist from a previous run — can reach the grouping preference this one renders.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct FoldAllToggleBindingTests {

    /// The toggle's laid-out size: a 24×24 hit target, matching `collapseToggle`'s. Distinct from
    /// every other control in the row, which is what makes it findable by measurement.
    private static let toggleSize = "24x24"

    // MARK: Fixture

    /// Three folders of four rows. Clears `isWorthGrouping` (sections must average >= 3 rows), so
    /// the grouped mount really is sectioned — `theFixtureReallyIsSectioned` checks that before
    /// anything else leans on it, because a fixture that silently failed the gate would make every
    /// "absent when there is nothing to fold" case vacuously true.
    private static let folders = ["Documents", "Photos", "Projects"]
    private static let rowsPerFolder = 4

    private func differences() -> [FileDifference] {
        Self.folders.flatMap { folder in
            (1...Self.rowsPerFolder).map { index in
                FileDifference(
                    relativePath: "\(folder)/file-\(index).txt",
                    leftItemPath: "/left/\(folder)/file-\(index).txt",
                    rightItemPath: "/right/\(folder)/file-\(index).txt",
                    type: .missingOnRight,
                    action: .copyToRight,
                    description: "Only on the left",
                    leftFileSize: 1024 * index)
            }
        }
    }

    /// The view reads its preferences from a fresh `ScratchDefaults` suite, seeded before the
    /// view exists, via `.defaultAppStorage`. `UserDefaults.standard` is never touched:
    /// `@AppStorage`'s process-wide storage location for a (store, key) pair outlives every view
    /// that used it and can re-attach to a fresh view without re-reading the defaults — which is
    /// how a `grouped: false` mount here drew 15 rows for the whole of `headerControls`' 5s wait
    /// under CPU load on 2026-07-28, no matter what the standard domain's plist said. A location
    /// born from this mount's own store cannot hold anything but this test's value. Full
    /// account: `DifferencesTableIdentityTests`.
    private func mount(grouped: Bool, width: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let store = ScratchDefaults("FoldAllToggleBindingTests")
        store.set(grouped, forKey: "differencesGroupByFolder")
        let manager = FileSyncManager()
        manager.differences = differences()
        manager.hasScanned = true

        let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore())
            .defaultAppStorage(store)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 700)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    // MARK: Reading the header back

    /// Rows the differences table has drawn. A sectioned `Table` counts its section headers as
    /// rows, so grouped is one per folder more than flat — the same fact that once made row 0 of a
    /// sectioned table the header rather than the first difference.
    private static var flatRowCount: Int { folders.count * rowsPerFolder }
    private static var groupedRowCount: Int { flatRowCount + folders.count }

    /// `NSTableView.numberOfRows` for the differences table, or nil before one exists.
    private func tableRowCount(_ view: NSView) -> Int? {
        if let table = view as? NSTableView { return table.numberOfRows }
        for child in view.subviews {
            if let rows = tableRowCount(child) { return rows }
        }
        return nil
    }

    /// The header's focusable controls, `WxH`, left to right.
    ///
    /// Scoped to the header strip — the shallow, ~48pt-tall branch of the hierarchy — so the
    /// table's own rows below can never contribute a coincidentally-24×24 ring.
    ///
    /// **Why it waits on the table rather than on a clock.** The rows are built by an async
    /// `.task(id:)`, and the header's shape depends on them: `sections` is empty until they land,
    /// so a mount measured too early draws a header with no fold toggle — indistinguishable, to
    /// this measurement, from a header that correctly withheld one. This used to sleep a flat 1.2s
    /// and measure whatever was there, which makes every "the toggle is absent" case vacuously
    /// true whenever the wait loses, and produced one unexplained failure of the narrow case in a
    /// full-package run that could not be reproduced in isolation. A duration is not a fact about
    /// the view; the row count is.
    ///
    /// So the wait is a bounded poll on `NSTableView.numberOfRows`, and the expected count is
    /// asserted rather than assumed: if the table never reaches it, the test fails saying the rows
    /// never landed instead of quietly reporting a header the user would never see. The signal is
    /// neutral to everything this suite asserts — those are all header chrome — so waiting on it
    /// cannot beg the question the way waiting for the toggle itself would.
    private func headerControls(grouped: Bool, width: CGFloat = 1200,
                                sourceLocation: SourceLocation = #_sourceLocation) async -> [String] {
        let (host, window) = mount(grouped: grouped, width: width)
        defer { window.contentView = nil }

        // Waiting for the EXACT row count is what keeps a half-built table from being measured.
        //
        // **The wait is floored on PASSES, not bounded by seconds.** This was a bare
        // `while Date() < deadline` with fifteen generous-looking seconds, and on 2026-08-04 it gave
        // up in a full-package run with the table showing 0 rows — then passed three times out of
        // three in isolation. Seconds were never the unit: what the rows need is main-actor turns,
        // and a congested run has fewer of them per second, not more. See `LayoutPumpWait.pumpFloor`
        // and `docs/flaky-tests.md` mechanism 2.
        let expected = grouped ? Self.groupedRowCount : Self.flatRowCount
        let settled = await LayoutPumpWait.pump(host, upTo: 15) { tableRowCount(host) == expected }
        let drew = tableRowCount(host).map(String.init) ?? "no"
        #expect(settled.held,
                "harness: the table drew \(drew) row(s), expected \(expected) after \(settled.pumps) passes — the measurement below would be of a half-built header",
                sourceLocation: sourceLocation)
        host.layoutSubtreeIfNeeded()

        return focusRingSizes(in: host, host: host)
    }

    /// The header strip's focus-ring sizes, collected by walking down from `host`.
    ///
    /// A method rather than the local function it used to be. Nested inside an `async` member of a
    /// `@MainActor` type, `walk` captured `host` and — under whole-module optimization only — was
    /// inferred to cross an isolation boundary, so `swift test -c release` failed to COMPILE this
    /// package (`sending 'host' risks causing data races`) while the Debug build was clean. Nothing
    /// about the walk changes; it just inherits the type's isolation explicitly instead of having it
    /// inferred differently by two optimization modes.
    private func focusRingSizes(in view: NSView, host: NSView, insideHeader: Bool = false) -> [String] {
        var sizes: [String] = []
        if insideHeader, String(describing: type(of: view)) == "_FocusRingView" {
            sizes.append("\(Int(view.frame.width))x\(Int(view.frame.height))")
        }
        for child in view.subviews {
            sizes += focusRingSizes(
                in: child, host: host,
                insideHeader: insideHeader || (view === host && child.frame.height <= 60))
        }
        return sizes
    }

    // MARK: Tests

    /// The fixture check the rest of the suite leans on, and the harness check that keeps a broken
    /// measurement from reading as a missing button.
    @Test func theFixtureReallyIsSectionedAndTheHeaderIsReadable() async {
        let flat = await headerControls(grouped: false)
        let grouped = await headerControls(grouped: true)
        #expect(flat.count >= 4, "harness: the header should always draw several controls, saw \(flat)")
        #expect(grouped.count == flat.count + 1,
                "grouping should add exactly one control — flat \(flat), grouped \(grouped)")
    }

    /// The placement, stated as one comparison: grouping inserts the toggle into the header
    /// immediately after the count pill and immediately before the filter, changing nothing else.
    ///
    /// This is the assertion that would have caught the first placement — trailing, beside the
    /// pane's show/hide chevron — which is where it was built before being moved.
    @Test func theToggleSitsBetweenTheCountPillAndTheFilter() async {
        let flat = await headerControls(grouped: false)
        let grouped = await headerControls(grouped: true)
        let expected = [flat[0], Self.toggleSize] + flat.dropFirst()
        #expect(grouped == expected,
                "expected \(expected), got \(grouped)")
    }

    /// Withheld when there is nothing to fold. Ungrouped means no sections, and the same emptiness
    /// covers "isWorthGrouping declined it".
    @Test func anUngroupedHeaderOffersNoToggle() async {
        let flat = await headerControls(grouped: false)
        #expect(!flat.isEmpty, "harness: the flat header should still draw controls")
        #expect(!flat.contains(Self.toggleSize), "no 24×24 toggle should be in \(flat)")
    }

    /// It yields when the row runs out of width. Measured at a width narrow enough to force the
    /// filter down to its glyph, which is the rung `FoldAllAction.isOffered` names.
    @Test func aNarrowHeaderYieldsTheToggle() async {
        let narrow = await headerControls(grouped: true, width: 460)
        let wide = await headerControls(grouped: true, width: 1200)
        #expect(wide.contains(Self.toggleSize), "precondition: the wide header should offer it")
        #expect(!narrow.isEmpty, "harness: even a narrow header draws controls")
        #expect(!narrow.contains(Self.toggleSize),
                "a narrow header should shed the toggle, saw \(narrow)")
    }
}
