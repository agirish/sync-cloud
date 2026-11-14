import Testing
import Foundation
import SwiftUI
import Sync
@testable import FileExplorer

/// The facts strip states the page count. `ComparePairFacts.make` takes `pages:`, and
/// `Row.isPending` covers the late answer, but a tested rule with no caller never draws. Three
/// checks, for the three heights the wiring can break at: the rule, the view, and the call site.
@Suite struct ComparePageFactsWiringTests {

    private func copy(_ path: String) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 1000, itemCount: 1,
                      modificationDate: Date(timeIntervalSince1970: 1_780_000_000),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false,
                      isProtectedFromRemoval: false)
    }

    // MARK: The rule

    /// Not paged, paged-but-unanswered, and answered are three outcomes; the middle one is why the
    /// argument is an optional tuple of optionals.
    @Test func aPairWithNoPagesOmitsTheRowAndAPdfStillReadingLeavesItPending() throws {
        #expect(ComparePairFacts.pages(for: .text, pairing: nil) == nil,
                "a text pair was offered a page row")
        #expect(ComparePairFacts.pages(for: .image, pairing: PagePairing(leftPages: 0, rightPages: 0)) == nil,
                "an image pair was offered a page row — images have no pages to count")
        #expect(ComparePairFacts.pages(for: .other, pairing: nil) == nil)

        // `try #require`, not an optional-chained compare: `pending?.left == nil` is true when the
        // whole tuple is nil, the one answer this line must reject.
        let pending = try #require(ComparePairFacts.pages(for: .pdf, pairing: nil),
                                   "a PDF whose counts have not landed dropped the row instead of pending it")
        #expect(pending.left == nil && pending.right == nil)

        let answered = try #require(ComparePairFacts.pages(for: .pdf,
                                                           pairing: PagePairing(leftPages: 12, rightPages: 9)))
        #expect(answered.left == 12 && answered.right == 9)
    }

    /// A locked PDF answers zero pages, and zero is a count. The row says "0 pages" rather than
    /// hiding, because the pane beside it is already saying the file could not be opened.
    @Test func anUnopenablePdfStatesZeroRatherThanStayingPending() throws {
        let counts = try #require(ComparePairFacts.pages(for: .pdf,
                                                         pairing: PagePairing(leftPages: 0, rightPages: 4)))
        #expect(counts.left == 0, "an unopenable side went back to pending, where it will stay for ever")
        #expect(ComparePairFacts.pageText(counts.left) == "0 pages")
    }

    // MARK: The view's reading of it

    /// The real view, built from real paths, so the kind comes from `PairContentKind.classify`.
    /// `pairing` is `@State` and starts nil: the pending case a reader sees as every PDF pair opens.
    @MainActor @Test func theViewAsksAboutItsOwnPairRatherThanAConstant() {
        func view(_ ext: String) -> FilePairCompareView<Text> {
            FilePairCompareView(
                left: copy("/root/a/report.\(ext)"), right: copy("/root/b/report.\(ext)"),
                title: "report.\(ext)", subtitle: "identical", claimHeadline: nil, offersVerify: false,
                keeperPath: nil, allowsKeeperChoice: false, notice: nil,
                scanRoot: "/root", providerName: nil, hue: .blue,
                availableSize: CGSize(width: 900, height: 700),
                onClose: {}, verdict: { _ in Text("Done") })
        }
        #expect(view("pdf").pageFacts != nil, "a PDF pair was given no page row at all")
        #expect(view("txt").pageFacts == nil, "a text pair was given a page row")
    }

    // MARK: The call that hands it over

    /// The call site, which neither check above can see: both pass with `pages:` deleted from
    /// `facts`. Scoped to the `facts` member, because a character window around a call breaks when
    /// an unrelated line moves near it.
    @Test func theFactsStripIsBuiltWithThePageCounts() throws {
        let source = try SourceText.fileExplorer("CompareCopiesSheet.swift")
        let body = try SourceText.body(of: "    private var facts: ComparePairFacts {", in: source)

        #expect(body.contains("pages: pageFacts"), """
                the facts strip is built without `pages:` again (\(body.trimmingCharacters(in: .whitespacesAndNewlines))) \
                — the Pages row, its pending state and the summary's hedge all go dark together, \
                and every test above this one still passes
                """)
    }
}
