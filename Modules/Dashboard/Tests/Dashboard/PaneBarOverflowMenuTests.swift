import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// What the ⋯ menu is for, and what happens to the command it stopped carrying.
///
/// ⋯ appears only when this rung folded something away or the customize sheet took something off
/// the bar — `PaneBarArrangementTests` pins that arithmetic. What it used to carry *besides* those
/// controls was "Customize Pane Bar…", which is a different kind of thing: not a control that lost
/// its pill, but a command with its own front door on the bar's context menu. It is gone from ⋯,
/// so the context menu is now the only door — and a door nobody can aim at is a door that is shut.
/// That is what the second half of this suite measures, by really right-clicking.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneBarOverflowMenuTests {

    // MARK: - What ⋯ no longer offers

    /// The removal itself. A scan, because a SwiftUI `Menu`'s content is built only when the menu
    /// opens and nothing in a unit test can open one — `NSHostingView.menu(for:)` answers for
    /// `.contextMenu`, not for a `Menu` button's items.
    ///
    /// Guarded on both sides so it cannot pass by matching nothing: the extraction must produce a
    /// body that really is `viewOptionsMenu`, and the string it looks for must still exist in the
    /// file, in `barContextMenu`, exactly once. A scan for an absent token passes just as happily
    /// against a renamed function, an empty read, or a command deleted from the app entirely.
    @Test func theOverflowMenuNoLongerCarriesCustomize() throws {
        let body = try PaneBarInkChokePointTests.functionBody("private func viewOptionsMenu(")
        #expect(body.contains("Image(systemName: \"ellipsis\")"),
                "the extracted body is not `viewOptionsMenu`")
        #expect(body.contains("overflowEntry(item)"),
                "the extracted body no longer draws the folded controls — it is not the menu this scans")

        let code = PaneBarInkChokePointTests.codeOnly(body)
        #expect(!code.contains("Customize Pane Bar"),
                "⋯ carries Customize again: the glyph earns a slot in the bar for a command that has its own menu")
        #expect(!code.contains("isCustomizing"),
                "⋯ opens the customize sheet by some other wording")

        // …and the command still exists, in the one place it belongs.
        let offers = try Self.source().components(separatedBy: "Customize Pane Bar…").count - 1
        #expect(offers == 1, "Customize is offered from \(offers) places in the header, not the one this suite assumes")
        let contextMenu = try PaneBarInkChokePointTests.functionBody("private func barContextMenu(")
        #expect(contextMenu.contains("Customize Pane Bar…"), "the last route to the customize sheet is gone")
    }

    /// A divider between entries, not after each one. `backForward` alone expands to two buttons, so
    /// the old trailing-rule-per-item shape leant on Customize being there to sit under; without it
    /// the last entry would trail a rule against the bottom of the menu.
    @Test func theEntriesAreSeparatedRatherThanEachTrailingARule() throws {
        let body = PaneBarInkChokePointTests
            .codeOnly(try PaneBarInkChokePointTests.functionBody("private func viewOptionsMenu("))
        #expect(body.contains("if index > 0 { Divider() }"),
                "the menu draws a rule after its last entry")
    }

    // MARK: - Can you actually aim at the door that is left

    /// **Right-clicking the bar reaches Customize from anywhere along it — including on top of the
    /// controls.** The row sets `.contentShape(Rectangle())` so its bare stretches are hit-testable,
    /// but the pills sit on top of that shape, and a bar packed edge to edge has no bare stretch
    /// left. If a control swallowed the right-click, the only remaining route to the customize sheet
    /// would be missing exactly where the bar is fullest.
    ///
    /// Driven for real: SwiftUI answers `NSView.menu(for:)` by hit-testing the point, which is the
    /// one interaction here a unit test can perform — a `Button` is not an `NSControl` and cannot be
    /// clicked. The sweep walks the whole row rather than one hand-picked pill, because which x a
    /// given pill occupies is a function of the arrangement and would rot silently.
    @Test func theBarsMenuIsAimableAcrossTheWholeRow() throws {
        let probe = try Self.probe()
        var unreachable: [Int] = []
        for x in Self.sampleXs() {
            let menu = Self.menu(of: probe.host, at: CGPoint(x: CGFloat(x), y: probe.barRowY))
            if menu?.items.contains(where: { $0.title.hasPrefix("Customize Pane Bar") }) != true {
                unreachable.append(x)
            }
        }
        #expect(unreachable.isEmpty,
                "the bar's context menu does not answer at x = \(unreachable) — something there swallows the right-click, and Customize has no other route")
    }

    /// The guard on the sweep: it would report "reachable everywhere" just as cheerfully against a
    /// header that drew no controls at all, or one whose ladder had folded the lot into ⋯. So count
    /// the sampled columns that actually cross painted ink in the controls' half of the row. The
    /// sweep is only a statement about aiming at a pill if it crossed some.
    ///
    /// The floor is set between two measurements rather than under both, and both are taken here so
    /// the gap is re-measured rather than remembered: the full bar and the same header stripped back
    /// to no view mode, no collapse, no New Folder and no Delete. A floor far below the stripped
    /// figure would pass for a bar that had lost most of its controls.
    ///
    /// **Counted across the whole row, not the trailing half.** The half was a proxy for "where the
    /// controls are" that held only while a flexible space pinned the bar right; it is packed left
    /// now, so the old filter counted the empty end of the row.
    @Test func theSweptRowIsFullOfControls() throws {
        let full = try Self.inkedColumns(.default)
        let stripped = try Self.inkedColumns(PaneBarArrangement([.backForward, .scan, .sort, .hiddenFiles, .preview]))
        #expect(full > stripped,
                "the full bar (\(full) inked columns) crosses no more ink than a bar with four controls removed (\(stripped)) — this sweep cannot see controls at all")
        #expect(full >= stripped + 5,
                "only \(full) swept columns cross ink against \(stripped) for a stripped bar — the sweep is not crossing the controls it claims to")
    }

    /// Sampled columns that cross a control on the bar's row.
    private static func inkedColumns(_ arrangement: PaneBarArrangement) throws -> Int {
        let probe = try Self.probe(arrangement)
        return sampleXs().filter { hasInk(probe.rep, atX: $0, aroundY: probe.barRowY) }.count
    }

    // MARK: - Fixtures

    /// The rendered header, plus the row the bar was drawn on.
    private struct Probe {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let rep: NSBitmapImageRep
        let barRowY: CGFloat
    }

    private static let box = CGSize(width: 700, height: 96)

    /// In POINTS, the coordinate space a click is delivered in — not the bitmap's pixels, which are
    /// twice as many on a Retina machine and would put every sample past the trailing edge.
    private static func sampleXs() -> [Int] {
        Array(stride(from: 20, to: Int(box.width) - 20, by: 20))
    }

    /// A header offering every control, in a real window, with the arrangement injected so the
    /// render does not depend on whatever this machine's own customized bar happens to hold.
    ///
    /// Borderless, and never ordered in — a `.titled` window cannot be parked off screen, and
    /// `constrainFrameRect` would drag it onto his desktop over whatever he is doing.
    private static func probe(_ arrangement: PaneBarArrangement = .default) throws -> Probe {
        let defaults = ScratchDefaults("PaneBarOverflowMenuTests")
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        let host = NSHostingView(rootView: AnyView(
            header()
                .defaultAppStorage(defaults)
                .frame(width: box.width, height: box.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: box)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Probe(host: host, window: window, rep: rep, barRowY: barRowY(of: host))
    }

    /// Which row of the header the bar is on, **read off the controls themselves** rather than
    /// hunted for in the pixels.
    ///
    /// It used to take the inkiest bitmap row of the *trailing half*, on the grounds that the
    /// controls were there and the leading-anchored breadcrumb was not. That was true only while a
    /// leading flexible space pinned the bar to the trailing edge; the bar packs left now, the
    /// trailing half is empty, and the search returned whatever the header's own chrome inked. So
    /// did narrowing it to the top half — it came back 45.5, one and a half points below the row,
    /// where every right-click sampled empty space and the whole sweep read as unreachable.
    ///
    /// An ink heuristic was always a proxy. The bar's pills each host a `_FocusRingView` (a SwiftUI
    /// `Button` with a custom style puts no `NSControl` in the tree, so the rings are the only
    /// handle on where a pill physically is — `PaneBarCanvasTests` leans on the same fact), and the
    /// bar is the upper of the two focusable rows. That is an exact answer to the question this was
    /// approximating, and it does not move when the arrangement does.
    private static func barRowY(of host: NSView) -> CGFloat {
        var frames: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                frames.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        guard let top = frames.map(\.minY).min() else {
            Issue.record("the header drew no focusable controls at all")
            return 0
        }
        let row = frames.filter { abs($0.minY - top) < 2 }
        return row.map(\.midY).reduce(0, +) / CGFloat(row.count)
    }

    /// Whether a column crosses one of the bar's controls, on the bar's own row.
    ///
    /// **The band is the pill's height, and the threshold is the pill's fill.** Both were wrong, and
    /// both in the direction that made this guard blind.
    ///
    /// The band was ±6 *pixels* around the row's centre — a hairline through the middle of a pill,
    /// which a glyph's strokes mostly miss. And the threshold asked for a pixel darker than 0.6,
    /// which is a *glyph*; measured on this fixture, an offscreen `cacheDisplay` renders the pills'
    /// hover-affordance chrome as flat fills and drops most of the glyph strokes, so the whole
    /// default bar answered in 3 of 33 columns. Sampled the same way, a header that had lost every
    /// control would have answered in about the same number.
    ///
    /// What the render does give, cleanly, is the fill: measured across the row, a column over a
    /// control reads 0.92–0.96 and a column over bare header reads 1.00. That separation is the
    /// honest handle on "is there a control here", so it is the one used. ±11pt covers a regular
    /// pill top to bottom and still clears the breadcrumb row below.
    private static func hasInk(_ rep: NSBitmapImageRep, atX x: Int, aroundY y: CGFloat) -> Bool {
        let scale = CGFloat(rep.pixelsHigh) / box.height
        let centre = Int(y * scale)
        let half = Int(11 * scale)
        let px = Int(CGFloat(x) * CGFloat(rep.pixelsWide) / box.width)
        for row in max(0, centre - half)...min(rep.pixelsHigh - 1, centre + half)
        where isInk(rep.colorAt(x: px, y: row)) {
            return true
        }
        return false
    }

    /// A pixel darker than the bare header behind it — a pill's fill, its border, or a glyph.
    private static func isInk(_ colour: NSColor?) -> Bool {
        guard let px = colour?.usingColorSpace(.sRGB) else { return false }
        return px.redComponent < 0.98 && px.greenComponent < 0.98 && px.blueComponent < 0.98
    }

    private static func header() -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: true, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onCollapse: {}, onRefresh: {}, isRefreshing: false,
            showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {},
            onDelete: {}, selectionCount: 1)
    }

    private static func menu(of host: NSHostingView<AnyView>, at point: CGPoint) -> NSMenu? {
        guard let window = host.window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown,
                                             location: host.convert(point, to: nil),
                                             modifierFlags: [],
                                             timestamp: 0,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: 1) else { return nil }
        return host.menu(for: event)
    }

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/Dashboard/<this>.swift
            .deletingLastPathComponent()                          // …/Tests/Dashboard
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/Dashboard
            .appendingPathComponent("Sources/Dashboard/DashboardViews.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read DashboardViews.swift — this scan would be vacuous")
    }
}
