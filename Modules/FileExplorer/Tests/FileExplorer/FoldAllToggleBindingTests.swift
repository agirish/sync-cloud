import AppKit
import Design
import SwiftUI
import Sync
import Testing
import FileExplorerTestSupport
@testable import FileExplorer

/// The header's master disclosure is wired and sits where it was put: this mounts the real
/// `DifferencesView` and reads back the controls its header laid out (`FoldAllActionTests` pins the
/// rule).
///
/// Not accessibility: a never-ordered-in `NSHostingView` has an empty accessibility tree, so "the
/// control is absent" would pass vacuously. SwiftUI does lay out one `_FocusRingView` per focusable
/// control offscreen, sized to it and in document order. That class is private, so every case is
/// written against a baseline: if SwiftUI stops making focus rings these fail loudly.
///
/// From `DifferencesTableIdentityTests`: the tests are `async` (a `@MainActor` test that spins
/// `RunLoop.run` starves the `.task(id:)` it waits on), and the window is never ordered in, because
/// the owner drives the real app while these run. Nothing sleeps a fixed duration and then
/// measures: `headerControls` waits on the table's own row count.
///
/// `.oneMountedDifferencesTable` keeps these mounts from stacking on other mounting suites'. Each
/// mount seeds its own `ScratchDefaults` suite, so no other suite or leftover plist can reach the
/// grouping preference.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct FoldAllToggleBindingTests {

    /// The toggle's 24×24 hit target, distinct from every other control in the row, which makes it
    /// findable by measurement.
    private static let toggleSize = "24x24"

    // MARK: Fixture

    /// Three folders of four rows: clears `isWorthGrouping` (sections must average >= 3 rows), or
    /// every "absent when there is nothing to fold" case would be vacuously true.
    /// `theToggleSitsBetweenTheCountPillAndTheFilter` checks it.
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

    /// Preferences come from a fresh `ScratchDefaults` suite, seeded before the view exists, never
    /// `UserDefaults.standard`: `@AppStorage`'s process-wide location for a (store, key) pair outlives
    /// its views and can re-attach to a fresh view without re-reading defaults, so a `grouped: false`
    /// mount could draw grouped rows. Full account: `DifferencesTableIdentityTests`.
    private func mount(grouped: Bool, width: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let store = ScratchDefaults("FoldAllToggleBindingTests")
        store.set(grouped, forKey: "differencesGroupByFolder")
        // Cards, so the toolbar is its own top-level card, the branch `focusRingSizes` reads as the
        // header. In Unified the toolbar and table are one region, so the walk would find nothing.
        store.set(SurfaceStyle.cards.rawValue, forKey: LiquidGlass.surfaceStyleKey)
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

    /// A sectioned `Table` counts its section headers as rows, so grouped is one per folder more.
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

    /// The header's focusable controls, `WxH`, left to right, scoped to the header strip so the
    /// table's rows can never contribute a coincidentally-24×24 ring.
    ///
    /// Waits on the table, not a clock: the rows come from an async `.task(id:)`, and until they land
    /// `sections` is empty, so a header measured too early has no toggle and every "absent" case
    /// passes vacuously. A bounded poll on `NSTableView.numberOfRows`, with the count asserted; the
    /// signal is neutral to the header chrome asserted, unlike waiting for the toggle itself.
    private func headerControls(grouped: Bool, width: CGFloat = 1200,
                                sourceLocation: SourceLocation = #_sourceLocation) async -> [String] {
        let (host, window) = mount(grouped: grouped, width: width)
        defer { window.contentView = nil }

        // Floored on passes, not bounded by seconds: the rows need main-actor turns, and a congested
        // run has fewer per second. See `LayoutPumpWait.pumpFloor` and "Fixed pumps and fixed
        // sleeps" in `docs/flaky-tests.md`.
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
    /// A method, not a local function: nested inside an `async` member of a `@MainActor` type it
    /// would capture `host` and, under whole-module optimization only, be inferred to cross an
    /// isolation boundary, so `swift test -c release` fails to compile (`sending 'host' risks causing
    /// data races`) while Debug is clean.
    private func focusRingSizes(in view: NSView, host: NSView, insideHeader: Bool = false) -> [String] {
        var sizes: [String] = []
        if insideHeader, FocusRings.isRing(view) {
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

    /// Grouping inserts the toggle right after the count pill and before the filter, changing
    /// nothing else. The flat header is also the ungrouped case: with no sections nothing folds.
    @Test func theToggleSitsBetweenTheCountPillAndTheFilter() async throws {
        let flat = await headerControls(grouped: false)
        let grouped = await headerControls(grouped: true)
        // The harness check that keeps a broken measurement from reading as a missing button.
        try #require(flat.count >= 4, "harness: the header should always draw several controls, saw \(flat)")
        #expect(!flat.contains(Self.toggleSize), "no 24×24 toggle should be in \(flat)")
        let expected = [flat[0], Self.toggleSize] + flat.dropFirst()
        #expect(grouped == expected,
                "expected \(expected), got \(grouped)")
    }

    /// It yields at a width narrow enough to force the filter to its glyph, the rung
    /// `FoldAllAction.isOffered` names.
    @Test func aNarrowHeaderYieldsTheToggle() async {
        let narrow = await headerControls(grouped: true, width: 460)
        let wide = await headerControls(grouped: true, width: 1200)
        #expect(wide.contains(Self.toggleSize), "precondition: the wide header should offer it")
        #expect(!narrow.isEmpty, "harness: even a narrow header draws controls")
        #expect(!narrow.contains(Self.toggleSize),
                "a narrow header should shed the toggle, saw \(narrow)")
    }
}
