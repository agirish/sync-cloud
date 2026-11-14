import Testing
import SwiftUI
import AppKit
import Design
@testable import Dashboard

/// Where the drag's insertion line lands, measured off the render. Row midpoints are in the
/// `sidebarDrag` coordinate space, so a line drawn in the section's space (whose origin is partway
/// down the column) lands rows below its gap while `SidebarReorderTests` still passes. An origin
/// error is invisible to anything relative, so the line is compared against the rows, both read off
/// one bitmap: the line by its accent ink, each row by the wash it gets when current.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct SidebarInsertionIndicatorTests {

    static let accent = LiquidGlassHue.blue.accentColor
    static let canvas = CGSize(width: FolderSidebarView.defaultWidth, height: 420)

    /// Four clouds, so Locations is a real ladder. Favorites sits above it on purpose: a section at
    /// the top of the column has an origin near zero and would hide an origin error.
    static let locations: [SidebarSourceRow] = (0..<4).map { i in
        SidebarSourceRow(id: "loc\(i)", name: "Location \(i)", detail: nil,
                         symbol: "externaldrive", absolutePath: "/loc\(i)",
                         band: .cloud, state: .configured, isAvailable: true)
    }

    /// Two rows above Locations, so the section it reorders starts well down the column.
    static let shortcuts: [SidebarSourceRow] = ["Desktop", "Documents"].map { name in
        SidebarSourceRow(id: name, name: name, detail: nil, symbol: "folder",
                         absolutePath: "/\(name)", band: .shortcut, state: .configured,
                         isAvailable: true)
    }

    private func render(drag: FolderSidebarView.DragInFlight?, current: String = "",
                        folderRows: [FolderSidebarRow] = []) -> NSBitmapImageRep? {
        let column = FolderSidebarView(folderRows: folderRows, locationRows: Self.locations,
                                       shortcutRows: Self.shortcuts,
                                       currentRoot: "/loc0", currentRelativePath: "",
                                       currentSourceId: current,
                                       accent: Self.accent,
                                       onOpen: { _, _ in }, onToggleFavorite: { _ in },
                                       onOpenSource: { _, _ in }, onToggleSection: { _ in })
        let subject = (drag.map { column.withDragInFlight($0) } ?? column)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        // Three passes, not one: the midpoints arrive through a preference, which writes state and
        // schedules another update. The line cannot be drawn until that has landed.
        for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How many pixels in one scanline are close to the raw accent — the indicator's bar is solid
    /// accent, and nothing else in this fixture is (no row is current in the drag renders, so the
    /// 16%-accent wash is absent).
    private func accentRun(_ rep: NSBitmapImageRep, y: Int) -> Int {
        guard let want = Self.accent.nsColor.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(c.redComponent - want.redComponent) < 0.12,
               abs(c.greenComponent - want.greenComponent) < 0.12,
               abs(c.blueComponent - want.blueComponent) < 0.12 { count += 1 }
        }
        return count
    }

    /// The indicator's vertical centre, in pixels — the scanline carrying the most accent ink. Nil
    /// when nothing wide enough is painted, which is itself the finding for a cue that renders as
    /// nothing.
    private func lineY(_ rep: NSBitmapImageRep) -> Double? {
        var best = (y: -1, run: 0)
        for y in 0..<rep.pixelsHigh {
            let run = accentRun(rep, y: y)
            if run > best.run { best = (y, run) }
        }
        // The bar spans the column less two 10pt margins; anything much narrower is a glyph.
        guard best.run > Int(Self.canvas.width) else { return nil }
        return Double(best.y)
    }

    /// A location row's vertical midpoint, in pixels — found by making it the current source and
    /// diffing against a render where nothing is current. The wash is drawn at the row's own
    /// rectangle, so the band that changes IS the row.
    private func rowMidY(_ index: Int) throws -> Double {
        let plain = try #require(render(drag: nil))
        let marked = try #require(render(drag: nil, current: Self.locations[index].id))
        var top = -1, bottom = -1
        for y in 0..<plain.pixelsHigh {
            var differs = false
            for x in stride(from: 0, to: plain.pixelsWide, by: 3) {
                guard let a = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = marked.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 { differs = true; break }
            }
            if differs {
                if top < 0 { top = y }
                bottom = y
            }
        }
        try #require(top >= 0, "no row wash was found — the differential anchor is measuring nothing")
        return (Double(top) + Double(bottom)) / 2
    }

    private func drag(to: Int) -> FolderSidebarView.DragInFlight {
        .init(section: .locations, from: 0, to: to, translation: 20)
    }

    /// The line sits in the gap between the two rows it names. Drawing it in the section's space
    /// instead would put it about three rows lower here.
    @Test func theLineLandsInTheGapItNames() throws {
        for to in 1..<Self.locations.count {
            let rep = try #require(render(drag: drag(to: to)))
            let line = try #require(lineY(rep), "no insertion line was painted for a drop at \(to)")
            let expected = try (rowMidY(to - 1) + rowMidY(to)) / 2
            #expect(abs(line - expected) < 5,
                    "a drop at \(to) drew its line at \(line), but the gap between rows \(to - 1) and \(to) is at \(expected)")
        }
    }

    /// A drop at the top of the section goes above its first row: the one index with no preceding
    /// midpoint, which `insertionY` handles by subtracting half a row.
    @Test func aDropAtTheTopGoesAboveTheFirstRow() throws {
        let rep = try #require(render(drag: drag(to: 0)))
        let line = try #require(lineY(rep))
        let first = try rowMidY(0)
        let pitch = try rowMidY(1) - first
        #expect(line < first, "the line for a top drop sits below the row it should sit above")
        #expect(first - line < pitch, "the line for a top drop is more than a row above it")
    }

    /// An unarmed recents drag paints no line: one that hasn't reached the Favorites band is a
    /// cancel (`DragInFlight.willDrop` false), so a slip must not look like an insertion offer. The
    /// armed render is the premise, so "no line" can't come from a fixture that paints nothing.
    @Test func anUnarmedRecentsDragDrawsNoLine() throws {
        let recents = [FolderSidebarRow(group: .recents, root: "/loc0", sourceName: nil,
                                        relativePath: "Notes", name: "Notes", detail: nil,
                                        isAvailable: true)]
        func recentsDrag(willDrop: Bool) -> FolderSidebarView.DragInFlight {
            .init(section: .recents, from: 0, to: 0, translation: -40, willDrop: willDrop)
        }

        let armed = try #require(render(drag: recentsDrag(willDrop: true), folderRows: recents))
        try #require(lineY(armed) != nil,
                     "the ARMED render of this drag paints no line either — the fixture cannot see the bit, and the assertion below would pass vacuously")

        let unarmed = try #require(render(drag: recentsDrag(willDrop: false), folderRows: recents))
        #expect(lineY(unarmed) == nil,
                "an unarmed recents drag painted an insertion line — promising a commit the release must refuse")
    }

    /// The mark is an insertion caret, not a rule. A bare bar looks like the divider Locations draws
    /// between clouds and disks; the ring at the leading end says "a row goes in here". Measured as
    /// ink height: tall at the leading end, two points across the rest.
    @Test func theIndicatorCarriesACaretAtItsLeadingEnd() throws {
        let rep = try #require(render(drag: drag(to: 2)))
        let line = try #require(lineY(rep))
        let y = Int(line)

        func inkHeight(x: Int) -> Int {
            guard let want = Self.accent.nsColor.usingColorSpace(.sRGB) else { return 0 }
            var count = 0
            for probe in max(0, y - 12)...min(rep.pixelsHigh - 1, y + 12) {
                guard let c = rep.colorAt(x: x, y: probe)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - want.redComponent) < 0.2,
                   abs(c.greenComponent - want.greenComponent) < 0.2,
                   abs(c.blueComponent - want.blueComponent) < 0.2 { count += 1 }
            }
            return count
        }

        // The leading end: the first column of accent ink on the line's own scanline.
        var lead = -1
        for x in 0..<rep.pixelsWide where accentRun(rep, y: y) > 0 {
            if inkHeight(x: x) > 0 { lead = x; break }
        }
        try #require(lead >= 0, "no accent ink on the indicator's scanline")
        let middle = rep.pixelsWide / 2
        #expect(inkHeight(x: lead + 1) >= inkHeight(x: middle) + 3,
                "the leading end is no taller than the bar — the caret is not being drawn")
    }
}

private extension Color {
    var nsColor: NSColor { NSColor(self) }
}
