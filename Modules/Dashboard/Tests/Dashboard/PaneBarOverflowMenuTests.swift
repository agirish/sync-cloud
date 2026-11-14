import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
import FileExplorerTestSupport

/// What the ⋯ menu carries, and where "Customize Pane Bar…" lives instead. ⋯ holds only controls
/// this rung folded away (`PaneBarArrangementTests` pins that arithmetic). Customize is a command,
/// offered only from the bar's context menu, so that menu must be aimable everywhere along the bar;
/// the second half of this suite checks it by really right-clicking.
@MainActor
@Suite(.serialized) struct PaneBarOverflowMenuTests {

    // MARK: - What ⋯ no longer offers

    /// ⋯ doesn't carry Customize. A source scan, because a SwiftUI `Menu`'s content is built only
    /// when it opens, and `NSHostingView.menu(for:)` answers for `.contextMenu`, not a `Menu`.
    /// Guarded both ways: the extracted body must really be `viewOptionsMenu`, and the string must
    /// still exist in the file exactly once, in `barContextMenu`, or a renamed function, an empty
    /// read or a deleted command would pass.
    @Test func theOverflowMenuNoLongerCarriesCustomize() throws {
        let body = try PaneBarInkChokePointTests.functionBody("private func viewOptionsMenu(")
        #expect(body.contains("Image(systemName: \"ellipsis\")"),
                "the extracted body is not `viewOptionsMenu`")
        #expect(body.contains("overflowEntry(item)"),
                "the extracted body no longer draws the folded controls — it is not the menu this scans")

        let code = DashboardSource.codeOnly(body)
        #expect(!code.contains("Customize Pane Bar"),
                "⋯ carries Customize again: the glyph earns a slot in the bar for a command that has its own menu")
        #expect(!code.contains("isCustomizing"),
                "⋯ opens the customize sheet by some other wording")

        // …and the command still exists, in the one place it belongs.
        let views = try DashboardSource.read("DashboardViews.swift")
        let offers = views.components(separatedBy: "Customize Pane Bar…").count - 1
        #expect(offers == 1, "Customize is offered from \(offers) places in the header, not the one this suite assumes")
        let contextMenu = try PaneBarInkChokePointTests.functionBody("private func barContextMenu(")
        #expect(contextMenu.contains("Customize Pane Bar…"), "the last route to the customize sheet is gone")
    }

    /// A divider between entries, not after each one, or the last entry would trail a rule against
    /// the bottom of the menu.
    @Test func theEntriesAreSeparatedRatherThanEachTrailingARule() throws {
        let body = DashboardSource
            .codeOnly(try PaneBarInkChokePointTests.functionBody("private func viewOptionsMenu("))
        #expect(body.contains("if index > 0 { Divider() }"),
                "the menu draws a rule after its last entry")
    }

    // MARK: - Can you actually aim at the door that is left

    /// Right-clicking anywhere along the bar, controls included, reaches Customize. The row's
    /// `.contentShape(Rectangle())` covers bare stretches, but pills sit on top, and a control that
    /// swallowed the right-click would hide the only route to the sheet where the bar is fullest.
    /// Driven for real (SwiftUI answers `NSView.menu(for:)` by hit-testing), sweeping the whole row
    /// because a pill's x depends on the arrangement.
    @Test(.machinePinned(.pixelSampling)) func theBarsMenuIsAimableAcrossTheWholeRow() throws {
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

    /// Guards the sweep, which would report "reachable everywhere" for a header with no controls,
    /// or one that folded them all into ⋯. It counts sampled columns, across the whole row, that
    /// cross a control. The floor sits between two measurements taken here, the full bar and one
    /// stripped to four controls, so the gap is re-measured rather than remembered.
    @Test(.machinePinned(.pixelSampling)) func theSweptRowIsFullOfControls() throws {
        let full = try Self.inkedColumns(.default)
        let stripped = try Self.inkedColumns(PaneBarArrangement([.backForward, .scan, .sort, .hiddenFiles]))
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
        let rig: ProbeRig<AnyView>
        let rep: NSBitmapImageRep
        let barRowY: CGFloat
        @MainActor var host: NSHostingView<AnyView> { rig.host }
    }

    private static let box = CGSize(width: 700, height: 96)

    /// In points, the space a click is delivered in, not bitmap pixels, which on Retina would put
    /// every sample past the trailing edge.
    private static func sampleXs() -> [Int] {
        Array(stride(from: 20, to: Int(box.width) - 20, by: 20))
    }

    /// A header offering every control, in a real window, with the arrangement injected so this
    /// machine's own bar doesn't decide the render. Borderless and never ordered in:
    /// `constrainFrameRect` drags a `.titled` window back on screen, over whatever the user is doing.
    private static func probe(_ arrangement: PaneBarArrangement = .default) throws -> Probe {
        let defaults = ScratchDefaults("PaneBarOverflowMenuTests")
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        let rig = ProbeRig(AnyView(
            header()
                .defaultAppStorage(defaults)
                .frame(width: box.width, height: box.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ), size: box)
        return Probe(rig: rig, rep: rig.capture(), barRowY: barRowY(of: rig.host))
    }

    /// Which row of the header the bar is on, read off the controls rather than guessed from ink.
    /// Each pill hosts a `_FocusRingView` (a custom-styled SwiftUI `Button` puts no `NSControl` in
    /// the tree; `PaneBarCanvasTests` relies on the same fact), and the bar is the upper of the two
    /// focusable rows. Exact, and it doesn't move with the arrangement.
    private static func barRowY(of host: NSView) -> CGFloat {
        let frames = FocusRings.frames(in: host)
        guard let top = frames.map(\.minY).min() else {
            Issue.record("the header drew no focusable controls at all")
            return 0
        }
        let row = frames.filter { abs($0.minY - top) < 2 }
        return row.map(\.midY).reduce(0, +) / CGFloat(row.count)
    }

    /// Whether a column crosses one of the bar's controls, on the bar's row. The band is a pill's
    /// height and the threshold a pill's fill: an offscreen `cacheDisplay` drops most glyph strokes
    /// but renders the fill cleanly, 0.92–0.96 over a control against 1.00 over bare header. ±11pt
    /// covers a regular pill and clears the breadcrumb row below.
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

    /// A pixel darker than the bare header behind it: a pill's fill, its border, or a glyph.
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
}
