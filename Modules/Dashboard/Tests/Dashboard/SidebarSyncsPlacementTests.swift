import Testing
import SwiftUI
import AppKit
import Design
@testable import Dashboard

/// Compare's Syncs section sits right below Favorites, not above every section, measured off the
/// render. Both anchors come from one bitmap: where a render with Syncs first differs from one
/// without is where Syncs begins, and a Favorites row and a Locations row are found by the wash
/// each gets when current. Favorites must end above that line and Locations start below the
/// section.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct SidebarSyncsPlacementTests {

    static let canvas = CGSize(width: FolderSidebarView.defaultWidth, height: 420)
    static let markerHeight: CGFloat = 24

    static let favorites = [FolderSidebarRow(group: .pinned, root: "/fav", sourceName: "Fav",
                                             relativePath: "Taxes", name: "Taxes", detail: nil,
                                             isAvailable: true)]
    static let locations: [SidebarSourceRow] = (0..<2).map { i in
        SidebarSourceRow(id: "loc\(i)", name: "Location \(i)", detail: nil,
                         symbol: "externaldrive", absolutePath: "/loc\(i)",
                         band: .cloud, state: .configured, isAvailable: true)
    }

    private func render(syncs: Bool, root: String = "", relativePath: String = "",
                        source: String = "") -> NSBitmapImageRep? {
        // A solid block stands in for the Syncs section, so its band is unmistakable.
        let marker = syncs ? AnyView(Color(red: 1, green: 0, blue: 0).frame(height: Self.markerHeight)) : nil
        let column = FolderSidebarView(folderRows: Self.favorites, locationRows: Self.locations,
                                       shortcutRows: [],
                                       currentRoot: root, currentRelativePath: relativePath,
                                       currentSourceId: source,
                                       accent: LiquidGlassHue.blue.accentColor,
                                       onOpen: { _, _ in }, onToggleFavorite: { _ in },
                                       onOpenSource: { _, _ in }, onToggleSection: { _ in },
                                       syncs: marker)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(column))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The scanlines on which two renders differ, top to bottom.
    private func differingRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [Int] {
        (0..<min(a.pixelsHigh, b.pixelsHigh)).filter { y in
            stride(from: 0, to: a.pixelsWide, by: 3).contains { x in
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02
            }
        }
    }

    @Test func syncsSitsBetweenFavoritesAndLocations() throws {
        let withSyncs = try #require(render(syncs: true))
        let without = try #require(render(syncs: false))
        let syncsTop = try #require(differingRows(withSyncs, without).first,
                                    "adding Syncs changed nothing — the section isn't drawn")

        let favoriteCurrent = try #require(render(syncs: true, root: "/fav", relativePath: "Taxes"))
        let favoriteRows = differingRows(withSyncs, favoriteCurrent)
        let favoriteBottom = try #require(favoriteRows.last, "no Favorites wash — the anchor measures nothing")

        let locationCurrent = try #require(render(syncs: true, source: "loc0"))
        let locationTop = try #require(differingRows(withSyncs, locationCurrent).first,
                                       "no Locations wash — the anchor measures nothing")

        let scale = Double(withSyncs.pixelsHigh) / Double(Self.canvas.height)
        #expect(favoriteBottom < syncsTop, "Favorites' row ends at \(favoriteBottom)px, below Syncs' top at \(syncsTop)px")
        #expect(Double(locationTop) >= Double(syncsTop) + Double(Self.markerHeight) * scale,
                "Locations' first row starts at \(locationTop)px, inside or above Syncs (top \(syncsTop)px)")
    }
}
