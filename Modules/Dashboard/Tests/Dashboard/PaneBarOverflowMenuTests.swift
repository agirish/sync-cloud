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
    /// The floor is set between two measurements rather than under both: this fixture inks 9 of the
    /// 16 trailing columns, and the same fixture stripped back to a header with no view mode, no
    /// collapse, no New Folder and no Delete inks 3. A floor far below the stripped figure would
    /// pass for a bar that had lost most of its controls.
    @Test func theSweptRowIsFullOfControls() throws {
        let probe = try Self.probe()
        let inked = Self.sampleXs()
            .filter { CGFloat($0) > Self.box.width / 2 }
            .filter { Self.hasInk(probe.rep, atX: $0, aroundY: probe.barRowY) }
        #expect(inked.count >= 6,
                "only \(inked.count) of the swept columns in the trailing half cross any ink — the sweep is not crossing the controls it claims to")
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
    private static func probe() throws -> Probe {
        let defaults = ScratchDefaults("PaneBarOverflowMenuTests")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
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
        return Probe(host: host, window: window, rep: rep, barRowY: barRowY(in: rep))
    }

    /// Which row of the header the bar is on, found rather than assumed: the header stacks the bar
    /// over the breadcrumb, and a hard-coded fraction of the box would quietly start sampling the
    /// breadcrumb the first time either one changed height. The bar's row is the one carrying the
    /// most ink in the trailing half, which is where its controls are and where the breadcrumb —
    /// anchored leading — has none.
    private static func barRowY(in rep: NSBitmapImageRep) -> CGFloat {
        var best = (y: 0, ink: 0)
        for y in 0..<rep.pixelsHigh {
            var ink = 0
            for x in (rep.pixelsWide / 2)..<rep.pixelsWide where isInk(rep.colorAt(x: x, y: y)) {
                ink += 1
            }
            if ink > best.ink { best = (y, ink) }
        }
        #expect(best.ink > 20, "no row of the header carries controls — nothing was drawn")
        // Bitmap rows run top-down and `NSHostingView` is flipped, so the two indices agree.
        return CGFloat(best.y) * box.height / CGFloat(rep.pixelsHigh)
    }

    private static func hasInk(_ rep: NSBitmapImageRep, atX x: Int, aroundY y: CGFloat) -> Bool {
        let scale = CGFloat(rep.pixelsHigh) / box.height
        let centre = Int(y * scale)
        let px = Int(CGFloat(x) * CGFloat(rep.pixelsWide) / box.width)
        for row in max(0, centre - 6)...min(rep.pixelsHigh - 1, centre + 6)
        where isInk(rep.colorAt(x: px, y: row)) {
            return true
        }
        return false
    }

    /// A pixel darker than any of the header's own fills — a glyph or a word, not the card.
    private static func isInk(_ colour: NSColor?) -> Bool {
        guard let px = colour?.usingColorSpace(.sRGB) else { return false }
        return px.redComponent < 0.6 && px.greenComponent < 0.6 && px.blueComponent < 0.6
    }

    private static func header() -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
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
