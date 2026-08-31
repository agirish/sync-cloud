import Foundation
import Testing
@testable import FileExplorer

/// The rule that decides between a spinner, a typed viewer, and the Quick Look fallback.
///
/// **Two of its four kinds have a state that looks like waiting and is not**, and each of those is
/// a permanent spinner if the rule gets it wrong — the defect ``PairRenderOutcome`` was built to
/// remove, reached through the other door.
@Suite struct TypedViewerReadinessTests {

    private func resolving(_ kind: PairContentKind,
                           sidesClassified: Bool = true,
                           pageCountsResolved: Bool = true,
                           bothSidesReadable: Bool = true,
                           outcome: PairRenderOutcome = .ready,
                           hasRasters: Bool = false) -> Bool {
        TypedViewerReadiness.isStillResolving(kind: kind,
                                              sidesClassified: sidesClassified,
                                              pageCountsResolved: pageCountsResolved,
                                              bothSidesReadable: bothSidesReadable,
                                              outcome: outcome,
                                              hasRasters: hasRasters)
    }

    /// Nothing can be decided about a pair whose sides have not been probed — which of the four
    /// branches applies is not yet knowable.
    @Test(arguments: PairContentKind.allCases)
    func anUnclassifiedPairWaitsWhateverItsKind(_ kind: PairContentKind) {
        #expect(resolving(kind, sidesClassified: false))
    }

    /// A PDF waits on its page counts and on nothing else: a count of zero is an answer — the
    /// document would not open — and `bothSidesOpened` sends it to the fallback panes with a
    /// caption, which a spinner here would sit on top of for ever.
    @Test func aPDFWaitsForItsPageCountsOnly() {
        #expect(resolving(.pdf, pageCountsResolved: false))
        #expect(!resolving(.pdf, pageCountsResolved: true))
        #expect(!resolving(.pdf, pageCountsResolved: true, outcome: .rendering),
                "a PDF's side-by-side panes draw themselves — they need no raster")
    }

    /// **An image pair waits for its first raster.** `ImagePairView` draws the two `CGImage`s, so
    /// mounting it while they are nil puts two empty scroll views on screen — blank rather than
    /// spinning, and the same defect: the interface saying nothing about something that has not
    /// arrived. On a 100-megapixel raw that is seconds of it.
    @Test func anImagePairWaitsForItsFirstRaster() {
        #expect(resolving(.image, outcome: .rendering))
        #expect(!resolving(.image, outcome: .ready))
    }

    /// **The second trap: a re-render of a picture the pane already has.**
    ///
    /// Leaving a pixel mode re-keys the raster task — the difference image is computed there and
    /// side by side does not want it — so the outcome drops back to `.rendering` for a decode of
    /// the very same file. On the wait alone the pane would blank to a spinner on every `1`–`4`
    /// press and come back with the picture it was already showing.
    @Test func aReRenderDoesNotBlankAPaneThatAlreadyHasItsPicture() {
        #expect(!resolving(.image, outcome: .rendering, hasRasters: true))
        #expect(resolving(.image, outcome: .rendering, hasRasters: false),
                "positive control: the FIRST render still waits, which is the whole point")
    }

    /// **The trap that a spinner would hide a control behind.** The raster refresh bails when a
    /// side is not readable, so the outcome stays `.rendering` for the life of the surface. A
    /// cloud-only copy must fall through to its placeholder — which carries the Download button
    /// that is the only way out of the state.
    @Test func anUndownloadedImageSideFallsThroughRatherThanSpinning() {
        #expect(!resolving(.image, bothSidesReadable: false, outcome: .rendering))
    }

    /// A render that will never land is not waiting either: it falls through to the Quick Look
    /// panes and the caption naming the copy that could not be read.
    @Test func afailedRenderIsNotWaiting() {
        #expect(!resolving(.image, outcome: .failed(left: true, right: false)))
        #expect(!resolving(.image, outcome: .failed(left: false, right: true)))
    }

    /// Kinds with no typed viewer never wait on one. Not reached in production — the caller gates
    /// on `hasSyncedViewer` — and answered rather than trapped.
    @Test(arguments: [PairContentKind.text, .other])
    func akindWithNoTypedViewerNeverWaits(_ kind: PairContentKind) {
        #expect(!resolving(kind, pageCountsResolved: false, bothSidesReadable: false,
                           outcome: .rendering))
    }
}
