import Testing
import Foundation
import SwiftUI
import Sync
@testable import FileExplorer

/// **The facts strip states the page count, which for a year it was built to do and did not.**
///
/// `ComparePairFacts.make` has always taken a `pages:` argument, `.pages` has always had a label
/// and a plural-safe formatter, and `Row.isPending` exists for the one row whose answer arrives
/// late. No production caller passed it. So the row never drew, `isPending` was never true in a
/// shipped build, and a whole tested sub-feature sat one argument away from working — the shape
/// [[a-tested-rule-with-no-caller]] describes.
///
/// Three checks, because the failure could return at three different heights: the rule itself,
/// the view's reading of it, and the call that hands it to `make`.
@Suite struct ComparePageFactsWiringTests {

    private func copy(_ path: String) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 1000, itemCount: 1,
                      modificationDate: Date(timeIntervalSince1970: 1_780_000_000),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false,
                      isProtectedFromRemoval: false)
    }

    // MARK: The rule

    /// Not paged, paged-but-unanswered, and answered are three outcomes, not two. The middle one
    /// is the whole reason the argument is an optional tuple of optionals.
    @Test func aPairWithNoPagesOmitsTheRowAndAPdfStillReadingLeavesItPending() throws {
        #expect(ComparePairFacts.pages(for: .text, pairing: nil) == nil,
                "a text pair was offered a page row")
        #expect(ComparePairFacts.pages(for: .image, pairing: PagePairing(leftPages: 0, rightPages: 0)) == nil,
                "an image pair was offered a page row — images have no pages to count")
        #expect(ComparePairFacts.pages(for: .other, pairing: nil) == nil)

        // `try #require`, not `try?` and an optional-chained compare: `pending?.left == nil` is
        // TRUE when the whole tuple is nil, which is the one answer this line exists to reject.
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

    /// The real view, built from real paths, so the kind comes from `PairContentKind.classify`
    /// rather than from a value the test chose. `pairing` is `@State` and starts nil, which is
    /// exactly the pending case a reader sees for the first moments of every PDF pair.
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

    /// **The call site, which neither check above can see.** Both would still pass with `pages:`
    /// deleted from `facts` — the rule would be right and unread, which is the state this whole
    /// suite exists to end. Scoped to the `facts` member, because a character window around a
    /// call breaks the first time an unrelated line moves near it.
    @Test func theFactsStripIsBuiltWithThePageCounts() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/CompareCopiesSheet.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read CompareCopiesSheet.swift — this check is vacuous")

        let start = try #require(source.range(of: "    private var facts: ComparePairFacts {"),
                                 "`facts` is gone or renamed — re-aim this scan")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        #expect(body.contains("pages: pageFacts"), """
                the facts strip is built without `pages:` again (\(body.trimmingCharacters(in: .whitespacesAndNewlines))) \
                — the Pages row, its pending state and the summary's hedge all go dark together, \
                and every test above this one still passes
                """)
    }
}
