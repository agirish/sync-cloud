import AppKit
import SwiftUI
import Testing
@testable import SyncCloud
import Design
import Sync

/// **The result message fits a pane** (Banner Room, CA). It used to span the window; now it docks in
/// a pane's list, and a Compare pane can be 250pt wide. At that width the words wrap and the buttons
/// drop under them — nothing may be pushed past the pane's edge or truncated away.
///
/// Laid out, not pixel-sampled: the question is the width SwiftUI asks for, at each width a pane can
/// have. Each render is also written to the temporary directory, for looking at.
@MainActor
@Suite(.serialized) struct ResultMessageLayoutTests {

    private static let deleted = OperationBanner(
        message: "Deleted “Quarterly statement — October 2026 (final).pdf”", severity: .success,
        isUndoable: true)
    private static let wrote = OperationBanner(
        message: "Rotated “Lease 2026.pdf” — saved a copy", severity: .success,
        followUps: [.openInEdit("/x/Lease 2026 (rotated).pdf"), .revealInBrowse(["/x/Lease 2026 (rotated).pdf"])])

    private func view(_ banner: OperationBanner) -> some View {
        OperationBannerView(banner: banner, glassLevel: .frosted, canUndo: true,
                            onUndo: {}, onClose: {}, onHover: { _ in })
    }

    private func fitted(_ banner: OperationBanner, width: CGFloat, name: String) -> CGSize {
        let host = NSHostingController(rootView: view(banner).frame(width: width).background(Color.white))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))
        let render = NSHostingView(rootView: view(banner).frame(width: width).padding(10).background(Color.white))
        render.frame = CGRect(origin: .zero, size: CGSize(width: width + 20, height: size.height + 20))
        let window = NSWindow(contentRect: render.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = render
        render.layoutSubtreeIfNeeded()
        if let rep = render.bitmapImageRepForCachingDisplay(in: render.bounds) {
            render.cacheDisplay(in: render.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("result-message-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return size
    }

    @Test(arguments: [250, 400, 560] as [CGFloat])
    func aLongMessageFitsTheNarrowestPane(width: CGFloat) {
        for (banner, name) in [(Self.deleted, "deleted"), (Self.wrote, "wrote")] {
            let size = fitted(banner, width: width, name: "\(name)-\(Int(width))")
            #expect(size.width <= width + 0.5, "\(name) at \(width)pt asks for \(size.width)pt — it runs past the pane")
            #expect(size.height > 30 && size.height < 220, "\(name) at \(width)pt is \(size.height)pt tall")
        }
    }

    /// Wide enough, it is one row; narrow, it takes more — the words wrap rather than truncate.
    @Test func narrowWrapsWideDoesNot() {
        let narrow = fitted(Self.wrote, width: 250, name: "wrote-narrow")
        let wide = fitted(Self.wrote, width: 900, name: "wrote-wide")
        #expect(narrow.height > wide.height + 10, "narrow \(narrow.height) vs wide \(wide.height): no wrap at 250pt")
    }
}
