import AppKit
import Design
import EventsTestSupport
import SwiftUI
import Testing
@testable import FileExplorer
@testable import Sync

/// The Missing lens drawn to pixels: a list that is present, sized and positioned can still paint
/// nothing, so this reads the image back.
@MainActor
@Suite struct MissingLensRenderTests {

    static let size = CGSize(width: 1080, height: 620)

    static func host(_ manager: FileSyncManager) -> NSHostingView<some View> {
        let view = MissingLensView(syncManager: manager, providerName: "iCloud", query: "", inScope: { _ in true },
                                   onFind: {}, onReveal: { _ in }, onShowIn: { _, _ in })
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func manager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.missingReport = MissingStatements.find(paths: MissingLensModelTests.paths, now: MissingLensModelTests.now,
                                                       calendar: MissingLensModelTests.utc)
        manager.missingLifecycle.root = URL(fileURLWithPath: "/Users/x/Documents")
        manager.missingLifecycle.hasCompleted = true
        return manager
    }

    /// Orange enough to be a missing cell, a count or a year bar.
    static func isWarning(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent > 0.8 && rgb.greenComponent > 0.35 && rgb.greenComponent < 0.75 && rgb.blueComponent < 0.35
    }

    @Test("The list, the strip and the detail column all paint", .machinePinned(.pixelSampling))
    func theReportPaints() throws {
        let host = Self.host(Self.manager())
        let rep = try #require(PixelProbe.render(host, host.bounds))
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-lens-render.png"))
        }
        // The strip's missing cells and the counts are the only orange on the page, and they sit
        // in the list (left of the detail column) as well as in the detail's year bars.
        let scale = CGFloat(rep.pixelsWide) / Self.size.width
        let orange = try #require(PixelProbe.bounds(in: rep, where: Self.isWarning),
                                  "nothing orange was drawn: no missing cell, count or bar reached the screen")
        #expect(orange.minX / scale < 700, "no missing cell is drawn in the list")
        #expect(orange.maxX / scale > Self.size.width - 290, "nothing orange is drawn in the detail column")
        #expect(orange.height / scale > 150, "the orange marks span \(orange.height / scale)pt: fewer rows painted than the fixture has")
    }

    @Test("Before a walk the card offers one, and draws no list", .machinePinned(.pixelSampling))
    func theIntroPaintsWithoutAReport() throws {
        let host = Self.host(FileSyncManager())
        let rep = try #require(PixelProbe.render(host, host.bounds))
        #expect(PixelProbe.bounds(in: rep, where: Self.isWarning) == nil, "a missing cell is drawn with no report behind it")
        // Something is on the card: the setup card's text is not the background.
        let ink = PixelProbe.bounds(in: rep) { c in
            guard let g = c.usingColorSpace(.deviceGray) else { return false }
            return g.whiteComponent < 0.5 && g.alphaComponent > 0.5
        }
        #expect(ink != nil, "the card before a walk is blank")
    }
}
