import Testing
import AppKit
import SwiftUI
import Design
@testable import Dashboard

/// RD46.9 — the folder sidebar hosts two selection lenses, one for the current place and one for
/// the current folder: in Frosted and Clear each lands exactly where Solid draws that row's wash.
///
/// Two, because two rows can be current at once, and this suite pins that too: with both a place
/// and a folder current, the probe covers both rows. Rendered with the lens probe (glass draws
/// nothing offscreen — see `SelectionLensTests` in Design) and compared with the Solid render.
@MainActor
@Suite(.serialized) struct SelectionLensSidebarTests {

    static let canvas = CGSize(width: 220, height: 420)
    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    static func locations(unavailable: Set<Int> = []) -> [SidebarSourceRow] {
        (0..<3).map { i in
            SidebarSourceRow(id: "loc\(i)", name: "Location \(i)", detail: nil,
                             symbol: "externaldrive", absolutePath: "/loc\(i)",
                             band: .cloud, state: .configured, isAvailable: !unavailable.contains(i))
        }
    }

    static func folders(available: Bool = true) -> [FolderSidebarRow] {
        FolderSidebarModel.rows(
            sources: [.init(root: "/iCloud", name: "iCloud", favorites: ["Work", "Archive", "Taxes"],
                            isAvailable: available)],
            recents: [])
    }

    /// A cloud account the user has favourited: drawn in Favorites, not Locations.
    static func favouritePlace(available: Bool) -> [SidebarSourceRow] {
        [SidebarSourceRow(id: "fav", name: "Dropbox", detail: nil, symbol: "externaldrive",
                          absolutePath: "/fav", band: .shortcut, state: .configured, isAvailable: available)]
    }

    static func sidebar(folder: String, source: String, unavailable: Set<Int> = [],
                        foldersAvailable: Bool = true, shortcuts: [SidebarSourceRow] = []) -> some View {
        FolderSidebarView(folderRows: folders(available: foldersAvailable), locationRows: locations(unavailable: unavailable),
                          shortcutRows: shortcuts,
                          currentRoot: "/iCloud", currentRelativePath: folder,
                          currentSourceId: source, collapsed: [],
                          accent: LiquidGlassHue.blue.accentColor,
                          onOpen: { _, _ in }, onToggleFavorite: { _ in },
                          onOpenSource: { _, _ in }, onToggleSection: { _ in })
    }

    static func render<V: View>(_ view: V, appearance: SelectionLensAppearance) -> NSBitmapImageRep {
        ProbeRig(AnyView(view
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color.white)), size: canvas).capture()
    }

    /// One box per marked row.
    static func boxes(_ rep: NSBitmapImageRep, _ match: Pixel.Match) -> [CGRect] {
        Pixel.rowRuns(rep, width: canvas.width, match)
    }

    /// The current row's wash — Blue at 0.16 over white, about `(0.87, 0.92, 1.0)`: a pale blue
    /// nothing else in the column paints. The current row's glyph is accent too, but saturated
    /// (red near 0.2), so `red > 0.8` keeps it out — apart from a few anti-aliased edge pixels,
    /// which is why "the wash stepped aside" is asserted as a count, not as none.
    nonisolated static let isWash: Pixel.Match = { r, g, b in r > 204 && b > 242 && Int(b) - Int(r) > 15 }

    static func expectSame(_ markers: [CGRect], _ lenses: [CGRect],
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(markers.count == lenses.count,
                "\(markers.count) washed rows, \(lenses.count) lenses", sourceLocation: sourceLocation)
        for (marker, lens) in zip(markers, lenses) {
            #expect(Pixel.same(marker, lens), "lens \(lens) is not the washed row \(marker)",
                    sourceLocation: sourceLocation)
        }
    }

    @Test(.machinePinned(.pixelSampling), arguments: ["Work", "Taxes"])
    func theFolderLensLandsOnTheCurrentFolder(folder: String) throws {
        let view = Self.sidebar(folder: folder, source: "")
        let solid = Self.render(view, appearance: .today)
        let glass = Self.render(view, appearance: Self.probe)
        let markers = Self.boxes(solid, Self.isWash)
        #expect(markers.count == 1, "the fixture should wash exactly one row")
        Self.expectSame(markers, Self.boxes(glass, Pixel.lensProbe))
        let washed = Pixel.count(solid, width: Self.canvas.width, Self.isWash)
        let left = Pixel.count(glass, width: Self.canvas.width, Self.isWash)
        #expect(left * 20 < washed, "today's wash must step aside for the lens — \(left) of \(washed) pixels remain")
    }

    @Test(.machinePinned(.pixelSampling))
    func theSourceLensLandsOnTheCurrentPlace() throws {
        let view = Self.sidebar(folder: "", source: "loc1")
        let markers = Self.boxes(Self.render(view, appearance: .today), Self.isWash)
        #expect(markers.count == 1, "the fixture should wash exactly one row")
        Self.expectSame(markers, Self.boxes(Self.render(view, appearance: Self.probe), Pixel.lensProbe))
    }

    @Test(.machinePinned(.pixelSampling))
    func aPlaceAndAFolderCanBothBeCurrent() throws {
        // The reason there are two lenses: one could only ever mark one of these rows.
        let view = Self.sidebar(folder: "Archive", source: "loc2")
        let markers = Self.boxes(Self.render(view, appearance: .today), Self.isWash)
        #expect(markers.count == 2)
        Self.expectSame(markers, Self.boxes(Self.render(view, appearance: Self.probe), Pixel.lensProbe))
    }

    /// **A dimmed current row's lens dims with it.** A place that stopped answering is drawn at
    /// 0.45; today's wash sits inside the row and fades with it, but the lens is drawn by the host,
    /// outside the row, and was full strength over a faded label until the host was told. Read as
    /// the probe's face: full magenta on an available place, faded toward white on an unavailable
    /// one — at the row's own place.
    @Test(.machinePinned(.pixelSampling))
    func aDimmedPlacesLensDimsWithIt() throws {
        let live = Self.render(Self.sidebar(folder: "", source: "loc1"), appearance: Self.probe)
        let lens = try #require(Self.boxes(live, Pixel.lensProbe).first, "no lens on the available place")
        let dimmed = Self.render(Self.sidebar(folder: "", source: "loc1", unavailable: [1]), appearance: Self.probe)
        #expect(Self.boxes(dimmed, Pixel.lensProbe).isEmpty, "the unavailable place's lens is full strength")
        // Not gone: faded. 0.45 of the probe over white is about (255, 169, 255).
        let face = Pixel.at(dimmed, width: Self.canvas.width, CGPoint(x: lens.minX + 4, y: lens.midY))
        #expect(face.0 > 240 && face.2 > 240 && (140...200).contains(face.1),
                "the unavailable place's lens reads \(face), not the probe at 0.45")
    }

    /// The other dimming the lens must follow: a folder that cannot be opened, at 0.4. Read the
    /// same way — a faded probe at the row's own place, never the full one.
    @Test(.machinePinned(.pixelSampling))
    func anUnopenableFoldersLensDimsWithIt() throws {
        let live = Self.render(Self.sidebar(folder: "Work", source: ""), appearance: Self.probe)
        let lens = try #require(Self.boxes(live, Pixel.lensProbe).first, "no lens on the open folder")
        let dimmed = Self.render(Self.sidebar(folder: "Work", source: "", foldersAvailable: false), appearance: Self.probe)
        #expect(Self.boxes(dimmed, Pixel.lensProbe).isEmpty, "the unopenable folder's lens is full strength")
        // 0.4 of the probe over white is about (255, 153, 255).
        let face = Pixel.at(dimmed, width: Self.canvas.width, CGPoint(x: lens.minX + 4, y: lens.midY))
        #expect(face.0 > 240 && face.2 > 240 && (130...180).contains(face.1),
                "the unopenable folder's lens reads \(face), not the probe at 0.4")
    }

    /// **A favourited place dims its lens too.** A cloud account or a disk the user has put in
    /// Favorites is drawn there, not in Locations — and the lens's dimming looked in Locations only,
    /// so a favourited place that stopped answering wore a full-strength lens over its faded row.
    @Test(.machinePinned(.pixelSampling))
    func aFavouritedPlaceThatStoppedAnsweringDimsItsLens() throws {
        let live = Self.render(Self.sidebar(folder: "", source: "fav", shortcuts: Self.favouritePlace(available: true)),
                               appearance: Self.probe)
        let lens = try #require(Self.boxes(live, Pixel.lensProbe).first, "no lens on the favourited place")
        let dimmed = Self.render(Self.sidebar(folder: "", source: "fav", shortcuts: Self.favouritePlace(available: false)),
                                 appearance: Self.probe)
        #expect(Self.boxes(dimmed, Pixel.lensProbe).isEmpty, "the favourited place's lens is full strength")
        let face = Pixel.at(dimmed, width: Self.canvas.width, CGPoint(x: lens.minX + 4, y: lens.midY))
        #expect(face.0 > 240 && face.2 > 240 && (140...200).contains(face.1),
                "the favourited place's lens reads \(face), not the probe at 0.45")
    }
}
