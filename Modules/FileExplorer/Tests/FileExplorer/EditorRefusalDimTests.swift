import Testing
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer

/// **A row Edit cannot open recedes, and says why.** Measured in pixels, because the row's
/// `.opacity` is one ternary and a test that read the source would pass with the modifier deleted.
///
/// **The detector is positive-controlled** against the search-dim path, which is the same
/// `PaneSearchDim.opacity` applied by the same modifier: a refused row must come out exactly as
/// dim as a search-dimmed one. A dim test that cannot tell dim from bright proves nothing
/// (fittingSize-overstates, glyph-box sweep), so the bright/dim ratio is asserted on the control
/// first and the refusal is held to the same number.
@MainActor
@Suite(.serialized) struct EditorRefusalDimTests {

    private static let size = CGSize(width: 320, height: 28)

    private func row(editorRefusal: String? = nil, searchDimmed: Bool = false) -> FileRowView {
        var search = PaneSearchRowContext.none
        search.isDimmed = searchDimmed
        return FileRowView(
            node: FileRowInfo(FileNode(id: "/a/Quarterly report.pdf", name: "Quarterly report.pdf",
                                       isDirectory: false, fileSize: 4096)),
            isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, fonts: .unscaled,
            editorRefusal: editorRefusal, searchContext: search)
    }

    /// The row on a plain light ground, in a real window so text really rasterises.
    private func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How much the bitmap departs from white, summed over every pixel. Compositing at opacity α
    /// scales every pixel's departure by α, so the ratio of two rows' ink IS the opacity.
    private func ink(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += (1 - c.redComponent) + (1 - c.greenComponent) + (1 - c.blueComponent)
            }
        }
        return total
    }

    @Test func aRefusedRowRecedesAtTheSearchDimOpacity() throws {
        let bright = ink(try #require(render(row())))
        let searchDim = ink(try #require(render(row(searchDimmed: true))))
        let refused = ink(try #require(render(row(editorRefusal: "Not a kind Edit opens."))))
        #expect(bright > 50, "the bright row painted almost nothing (\(bright)) — the detector is blind")

        // The control first: the search-dim path must measurably dim, and by about the opacity.
        let controlRatio = searchDim / bright
        #expect(controlRatio < 0.8, "a search-dimmed row is not dimmer than a bright one (\(controlRatio)) — the detector cannot see opacity")
        #expect(abs(controlRatio - PaneSearchDim.opacity) < 0.08,
                "the search-dim row measures \(controlRatio) of bright; the opacity is \(PaneSearchDim.opacity)")

        // Then the claim: a refusal dims exactly as a search miss does.
        let refusedRatio = refused / bright
        #expect(abs(refusedRatio - controlRatio) < 0.02,
                "a refused row measures \(refusedRatio) of bright; a search-dimmed one \(controlRatio)")
    }

    /// The reason is the row's tooltip, attached unconditionally as `?? ""` so the row keeps one
    /// structural identity. A source scan, because a hosted SwiftUI tree exposes no tooltip under
    /// `swift test` (measured 2026-09-16: `NSView.toolTip` is nil throughout) — the same instrument
    /// `DuplicateRowPickerTests` uses for its row's help. Sliced to `FileRowView`'s body so a
    /// `.help` elsewhere in the file cannot stand in.
    @Test func theRefusalIsTheRowsTooltip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/FileTreeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "struct FileRowView: View {"), "FileRowView moved")
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "\nstruct "), "no struct follows FileRowView")
        let rowSource = body[..<end.lowerBound]
        #expect(rowSource.contains(".help(editorRefusal ?? \"\")"),
                "FileRowView no longer attaches the refusal as its tooltip")
        // And the dim rides the same modifier as the search dim — one opacity, two reasons.
        #expect(rowSource.contains(".opacity(searchContext.isDimmed || editorRefusal != nil ? PaneSearchDim.opacity : 1)"),
                "FileRowView's opacity no longer reads the refusal beside the search dim")
    }
}
