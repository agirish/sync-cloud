import Foundation
import Testing
@testable import FileExplorer

/// The rule that decides between a spinner, a typed viewer, and the Quick Look fallback. Two of its
/// four kinds have a state that looks like waiting and isn't, and each is a permanent spinner if
/// the rule gets it wrong, the defect ``PairRenderOutcome`` exists to prevent.
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

    /// Nothing can be decided about a pair whose sides haven't been probed: which of the four
    /// branches applies isn't yet knowable.
    @Test(arguments: PairContentKind.allCases)
    func anUnclassifiedPairWaitsWhateverItsKind(_ kind: PairContentKind) {
        #expect(resolving(kind, sidesClassified: false))
    }

    /// A PDF waits on its page counts and nothing else: a count of zero is an answer (the document
    /// wouldn't open), and `bothSidesOpened` sends it to the fallback panes with a caption, which a
    /// spinner here would cover for ever.
    @Test func aPDFWaitsForItsPageCountsOnly() {
        #expect(resolving(.pdf, pageCountsResolved: false))
        #expect(!resolving(.pdf, pageCountsResolved: true))
        #expect(!resolving(.pdf, pageCountsResolved: true, outcome: .rendering),
                "a PDF's side-by-side panes draw themselves — they need no raster")
    }

    /// An image pair waits for its first raster. `ImagePairView` draws the two `CGImage`s, so
    /// mounting it while they are nil shows two empty scroll views, saying nothing about something
    /// that hasn't arrived; on a 100-megapixel raw that lasts seconds.
    @Test func anImagePairWaitsForItsFirstRaster() {
        #expect(resolving(.image, outcome: .rendering))
        #expect(!resolving(.image, outcome: .ready))
    }

    /// A re-render of a picture the pane already has doesn't blank it. Leaving a pixel mode re-keys
    /// the raster task (the difference image is computed there and side by side doesn't want it),
    /// so the outcome drops back to `.rendering` for a decode of the same file. On the wait alone,
    /// every `1`–`4` press would flash a spinner over the picture already showing.
    @Test func aReRenderDoesNotBlankAPaneThatAlreadyHasItsPicture() {
        #expect(!resolving(.image, outcome: .rendering, hasRasters: true))
        #expect(resolving(.image, outcome: .rendering, hasRasters: false),
                "positive control: the FIRST render still waits, which is the whole point")
    }

    /// A spinner here would hide the only way out. The raster refresh bails when a side isn't
    /// readable, so the outcome stays `.rendering` for the life of the surface; a cloud-only copy
    /// must fall through to its placeholder, which carries the Download button.
    @Test func anUndownloadedImageSideFallsThroughRatherThanSpinning() {
        #expect(!resolving(.image, bothSidesReadable: false, outcome: .rendering))
    }

    /// A render that will never land is not waiting either: it falls through to the Quick Look
    /// panes and the caption naming the copy that could not be read.
    @Test func afailedRenderIsNotWaiting() {
        #expect(!resolving(.image, outcome: .failed(left: true, right: false)))
        #expect(!resolving(.image, outcome: .failed(left: false, right: true)))
    }

    /// Kinds with no typed viewer never wait on one. Not reached in production (the caller gates on
    /// `hasSyncedViewer`), and answered rather than trapped.
    @Test(arguments: [PairContentKind.text, .other])
    func akindWithNoTypedViewerNeverWaits(_ kind: PairContentKind) {
        #expect(!resolving(kind, pageCountsResolved: false, bothSidesReadable: false,
                           outcome: .rendering))
    }
}
