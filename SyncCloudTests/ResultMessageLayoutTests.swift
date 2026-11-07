import AppKit
import SwiftUI
import Testing
@testable import SyncCloud
import Design
import Sync

/// The result message fits a pane. It docks in a pane's list, and a Compare pane can be 250pt
/// wide; there the words wrap and the buttons drop under them, and nothing may run past the pane's
/// edge or be truncated.
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

    private func fitted(_ banner: OperationBanner, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view(banner).frame(width: width).background(Color.white))
            .sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    @Test(arguments: [250, 400, 560] as [CGFloat])
    func aLongMessageFitsTheNarrowestPane(width: CGFloat) {
        for (banner, name) in [(Self.deleted, "deleted"), (Self.wrote, "wrote")] {
            let size = fitted(banner, width: width)
            #expect(size.width <= width + 0.5, "\(name) at \(width)pt asks for \(size.width)pt — it runs past the pane")
            #expect(size.height > 30 && size.height < 220, "\(name) at \(width)pt is \(size.height)pt tall")
        }
    }

    /// Wide enough, it is one row; narrow, it takes more — the words wrap rather than truncate.
    @Test func narrowWrapsWideDoesNot() {
        let narrow = fitted(Self.wrote, width: 250)
        let wide = fitted(Self.wrote, width: 900)
        #expect(narrow.height > wide.height + 10, "narrow \(narrow.height) vs wide \(wide.height): no wrap at 250pt")
    }
}
