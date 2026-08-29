import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// His report on the Duplicates card: "when clicking on the thumbnail or the checkboxes, the
/// ordering changes and it is very confusing if we selected anything."
///
/// A pick is a comparison — this one, not that one — and a list that rearranges itself under the
/// click destroys the before it would be compared against. Worse, the row that lands under the
/// pointer afterwards is not the row that was clicked, so the one signal that the click landed is
/// indistinguishable from the whole card repainting.
@Suite struct DuplicateCardStabilityTests {

    private func copy(_ path: String, name: String? = nil, size: Int = 100, depth: Int = 1,
                      keeper: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: name ?? (path as NSString).lastPathComponent,
                      isDirectory: false, size: size, itemCount: 1, modificationDate: nil,
                      uniqueItemCount: 0, depth: depth, isRecommendedKeeper: keeper)
    }

    private func group(_ copies: [DuplicateCopy],
                       matchType: DuplicateMatchType = .sameText) -> DuplicateGroup {
        DuplicateGroup(matchType: matchType, name: "x.pdf", isDirectory: false,
                       copies: copies, reclaimableBytes: 100)
    }

    // MARK: The rows

    /// **The order is the group's, before and after.** `choosingKeeper` used to return
    /// `[newKeeper] + rest`, which is what moved the clicked row to the top of the card.
    @Test func pickingAKeeperLeavesEveryRowWhereItWas() {
        let g = group([copy("/a/x.pdf", keeper: true), copy("/b/x.pdf"), copy("/c/x.pdf")])
        let before = g.copies.map(\.id)
        let after = g.choosingKeeper("/c/x.pdf")
        #expect(after.copies.map(\.id) == before)
        #expect(after.keeper.id == "/c/x.pdf", "a positive control: the pick did land")
        // And back again — the deepest copy becoming the keeper must not sort anything either.
        #expect(after.choosingKeeper("/a/x.pdf").copies.map(\.id) == before)
    }

    /// The order holds even when the group did not arrive keeper-first, which is what a second
    /// pick produces. A rule that only preserved order from the scan's own layout would pass a
    /// single-click test and fail the second click.
    @Test func theOrderIsNotSilentlyReSortedByDepthOrPath() {
        // Deliberately hostile to both sort keys the old code used: the keeper is last, and the
        // ids are in reverse alphabetical order with a deep copy in the middle.
        let g = group([copy("/z/x.pdf", depth: 1), copy("/m/deep/x.pdf", depth: 3),
                       copy("/a/x.pdf", depth: 1, keeper: true)])
        let after = g.choosingKeeper("/m/deep/x.pdf")
        #expect(after.copies.map(\.id) == ["/z/x.pdf", "/m/deep/x.pdf", "/a/x.pdf"])
    }

    /// The figures still follow the pick — the ordering fix must not have made the card static in
    /// the ways it is supposed to react.
    @Test func theReclaimAndRemovalStillFollowThePick() {
        let g = group([copy("/a/x.pdf", size: 10, keeper: true), copy("/b/x.pdf", size: 500)])
        let after = g.choosingKeeper("/b/x.pdf")
        #expect(after.recommendedRemovalPaths == ["/a/x.pdf"])
        #expect(after.reclaimableBytes == 10)
    }

    /// **The removal list keeps the card's own order**, which is the half of "nothing needs
    /// keeper-first order" that was asserted rather than measured. `redundantCopies` is a plain
    /// filter over `copies`, so dropping the sort changed this list's order too — harmless only
    /// because every path on it is trashed, and worth pinning because the confirmation dialog
    /// counts from it.
    @Test func theRemovalListFollowsTheRowsAfterAReAim() {
        let g = group([copy("/a/x.pdf", keeper: true), copy("/b/x.pdf"), copy("/c/x.pdf")],
                      matchType: .identical)
        #expect(g.recommendedRemovalPaths == ["/b/x.pdf", "/c/x.pdf"])
        let after = g.choosingKeeper("/b/x.pdf")
        #expect(after.recommendedRemovalPaths == ["/a/x.pdf", "/c/x.pdf"],
                "the list is the rows minus the keeper, in row order")
        #expect(after.recommendedRemovalPaths.count == 2, "and the count the dialog reads is right")
    }

    // MARK: The title

    /// **The card's title names the copy being kept.** Rendered rather than asserted on a string,
    /// because the claim is about the header a reader sees: a pure `titleName` that nothing draws
    /// would pass a string test and leave the card headed by the file it is about to trash.
    ///
    /// The two arms differ only in which copy carries the keeper flag, and the copies are the same
    /// size — so the reclaim figure, the subtitle, the badge and the chevron all draw identically
    /// and every differing pixel is the name.
    @MainActor
    @Test func theHeaderShowsThePickedCopysName() throws {
        let copies = [copy("/a/Passport.pdf", name: "Passport.pdf", keeper: true),
                      copy("/b/Passport (Jul 2020).pdf", name: "Passport (Jul 2020).pdf")]
        let first = group(copies)
        let second = first.choosingKeeper("/b/Passport (Jul 2020).pdf")
        #expect(second.keeper.name == "Passport (Jul 2020).pdf",
                "a positive control: the pick landed on the differently named copy")
        #expect(first.reclaimableBytes == second.reclaimableBytes,
                "equal sizes, so the header's figure is not what differs")

        func header(_ g: DuplicateGroup) -> NSBitmapImageRep? {
            RestructureRender.raster(
                DuplicateGroupCard(group: g, isExpanded: false, providerName: "iCloud",
                                   scanRoot: "/", densityMetrics: ListDensity.comfortable.metrics,
                                   onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                                   onChooseKeeper: { _ in }, onMerge: {},
                                   headerLayout: .row),
                width: 620, height: 64)
        }
        let before = try #require(header(first))
        let after = try #require(header(second))
        #expect(RestructureRender.inkedPixels(before) > 200, "a positive control: the header drew")
        #expect(RestructureRender.differingPixels(before, after) > 40,
                "the header follows the pick — it named the trashed copy before this")
    }

    // MARK: The copy row

    /// **A long file name must not make the card taller.** His report: the breadcrumb cell "goes to
    /// multi-row for that cell".
    ///
    /// The cause was structural, not a missing `lineLimit`: the breadcrumb was an `HStack` of one
    /// `Text` per path component ending in the file name, and an `HStack` cannot truncate — each
    /// crumb is its own view, so a long name pushed the row and the stack wrapped. The name has its
    /// own line now and the path is one concatenated `Text`, which truncates as a single string.
    ///
    /// Height rather than pixels, because height is the harm: a card that grows by two lines per
    /// copy is what pushed the thumbnail, the fate chip and the actions apart.
    ///
    /// **What this does NOT pin, stated rather than implied:** that the path line drops the file
    /// name. Putting it back — `crumbs(path)` instead of `crumbs(path).dropLast()` — survives this
    /// test, because a single-line `Text` truncates either way and the card is the same height. The
    /// two changes are separable: one `Text` instead of an `HStack` is what stopped the wrapping,
    /// and dropping the leaf is a separate improvement (the name is stated on the line above) that
    /// costs nothing to get wrong and shows only as a longer, more truncated path.
    @MainActor
    @Test func aVeryLongFileNameDoesNotGrowTheCard() {
        // 90 characters — comfortably wider than the 460pt card, and the shape of the real one
        // ("Passport Old - Shweta - All Pages (Jul 2020) - Compressed.pdf").
        let long = String(repeating: "Passport Old - Shweta - All Pages ", count: 3) + ".pdf"
        #expect(long.count > 90, "a positive control: this name really is too long for the card")

        func height(name: String) -> CGFloat {
            var reported: CGFloat = -1
            let g = group([copy("/Docs/Passport/Shweta/Archive/\(name)", name: name, keeper: true),
                           copy("/Docs/Passport/Shweta/Old/\(name)", name: name)])
            let card = DuplicateGroupCard(
                group: g, isExpanded: true, providerName: "iCloud", scanRoot: "/Docs",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .stacked)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reported = $0 }
            let host = NSHostingView(rootView: card.frame(width: 460))
            host.frame = NSRect(x: 0, y: 0, width: 460, height: 1200)
            host.layoutSubtreeIfNeeded()
            return reported
        }

        let short = height(name: "a.pdf")
        let stretched = height(name: long)
        #expect(short > 0 && stretched > 0, "a geometry read never fired")
        #expect(stretched == short,
                "the card grew from \(short)pt to \(stretched)pt on a long name — a cell is wrapping")
    }

    // MARK: The grid tile

    /// **The whole reason the stacked layout exists**, measured rather than asserted: at a grid
    /// column's width the one-line header does not fit, and a SwiftUI view that does not fit draws
    /// at the width it wants instead of the width it was given (`LensHeaderCardOverflowTests` pins
    /// that mechanism). So a row header in a two-column grid would not have looked cramped — it
    /// would have drawn over the tile beside it.
    ///
    /// 220pt is the minimum the duplicates lens asks `LensCardGrid` for, i.e. the narrowest a tile
    /// is ever drawn at.
    @MainActor
    @Test func theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot() {
        let offered: CGFloat = 220
        let group = group([copy("/a/Passport - Shweta - All Pages.pdf",
                                name: "Passport - Shweta - All Pages.pdf", size: 26_300_000,
                                keeper: true),
                           copy("/b/Passport - Shweta - All Pages (Jul 2020).pdf",
                                name: "Passport - Shweta - All Pages (Jul 2020).pdf",
                                size: 26_300_000)])

        func drawnWidth(_ layout: DuplicateCardHeaderLayout,
                        offered: CGFloat = offered) -> CGFloat {
            var reported: CGFloat = -1
            let card = DuplicateGroupCard(
                group: group, isExpanded: false, providerName: "iCloud", scanRoot: "/",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: layout)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { reported = $0 }
            let host = NSHostingView(rootView: card.frame(width: offered))
            host.layoutSubtreeIfNeeded()
            return reported
        }

        let row = drawnWidth(.row)
        let tile = drawnWidth(.stacked)
        #expect(row > 0 && tile > 0, "a geometry read never fired — row \(row), tile \(tile)")
        #expect(row > offered,
                "a positive control: the row header really does not fit a grid column (\(row)pt)")
        #expect(tile == offered,
                "the stacked header drew \(tile)pt into \(offered)pt — it is insisting like the row does")

        // **And the constant that decides which one is drawn is held to the measurement.** It was
        // chosen from prose ("a one-line header needs about 530pt") and the prose was wrong — the
        // scan below puts the threshold at 364. A constant under it would draw the row header at
        // widths where it overflows and gets clipped at the pane edge; one far over it would send
        // roomy cards to the stacked header for no reason.
        var fits: CGFloat = 0
        for candidate in stride(from: CGFloat(200), through: 640, by: 4)
        where drawnWidth(.row, offered: candidate) <= candidate {
            fits = candidate
            break
        }
        #expect(fits > 0, "the row header never fits, even at 640pt")
        #expect(DuplicateCardHeaderLayout.rowHeaderMinimumWidth >= fits,
                "the header needs \(fits)pt and the constant is \(DuplicateCardHeaderLayout.rowHeaderMinimumWidth)")
        #expect(DuplicateCardHeaderLayout.rowHeaderMinimumWidth < fits + 80,
                "the constant is \(DuplicateCardHeaderLayout.rowHeaderMinimumWidth) against a measured \(fits) — roomy cards lose the dense header for nothing")
    }
}

/// The card's note — his second report: "too long and distracting".
@Suite struct DuplicateGroupNoteTests {

    /// **The name is a parameter because the overlapping note interpolates it.** Every fixture
    /// used to be "x.pdf", so the length budget was measured against five characters where his
    /// actual case is sixty-one — and the note went over, unmeasured.
    private func group(_ matchType: DuplicateMatchType, unverified: Int = 0,
                       isDirectory: Bool = false, name: String = "x.pdf") -> DuplicateGroup {
        let copies = (0..<2).map { i in
            DuplicateCopy(id: "/c\(i)/\(name)", name: name, isDirectory: isDirectory, size: 100,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 1, depth: 1,
                          isRecommendedKeeper: i == 0, contentUnverified: i < unverified)
        }
        return DuplicateGroup(matchType: matchType, name: name, isDirectory: isDirectory,
                              copies: copies, reclaimableBytes: 100)
    }

    /// **The budget, per kind.** A length assertion is the only checkable form of "too long", and
    /// the failure it guards against is the one that already happened: a note grows a clause at a
    /// time, each defensible on its own, until nobody reads any of them.
    @Test func everyNoteStaysInsideItsLengthBudget() {
        // The name that actually appears on his cards, not a five-character stand-in.
        let realistic = "Passport Old - Shweta - All Pages (Jul 2020) - Compressed.pdf"
        #expect(realistic.count > 55, "a positive control: this is the length that went over")
        for matchType: DuplicateMatchType in [.identical, .versions, .sameText,
                                              .overlapping(sharedFraction: 0.72)] {
            let note = DuplicateGroupNote.text(for: group(matchType, name: realistic))
            let count = note?.count ?? 0
            #expect(count > 0, "\(matchType) says nothing at all")
            #expect(count <= DuplicateGroupNote.lengthBudget,
                    "\(matchType) note is \(count) characters")
        }
    }

    /// Shorter, not weaker. Every claim the long same-text note carried is still there — this is
    /// the note above a destructive button on the one match kind that is *not* proof of identity.
    @Test func theSameTextNoteKeepsItsClaims() {
        let note = try! #require(DuplicateGroupNote.text(for: group(.sameText)))
        #expect(note.contains("bytes differ"), "the match is weaker than byte identity")
        #expect(note.contains("signed"), "and here is how a false match happens")
        #expect(note.contains("Open both first"), "so the user is told what to do about it")
        #expect(note.contains("⌘Z"))
        // **"Never part of Apply recommended" is deliberately NOT here any more.** It is a fact
        // about a button on the header, not about these two files, and it was a fifth of a note
        // reported as too long. It moved to `batchInformativeText`, which is the last thing read
        // before that button acts — and which was understating the exclusions anyway.
        #expect(!note.contains("Apply recommended"))
        #expect(DuplicateRemovalPrompt.batchInformativeText(copyCount: 3, reclaimText: "1 MB")
                    .contains("same-text"),
                "the fact has to survive somewhere, and this is where it belongs")
    }

    /// The caveat is appended, and only when a copy really went unverified.
    @Test func theUnverifiedCaveatIsAppendedOnlyWhenItApplies() {
        let clean = try! #require(DuplicateGroupNote.text(for: group(.identical)))
        #expect(!clean.contains("content-verified"))
        let caveated = try! #require(DuplicateGroupNote.text(for: group(.identical, unverified: 1)))
        #expect(caveated.hasPrefix(clean), "the base note is unchanged by the caveat")
        #expect(caveated.contains("1 not content-verified"))
    }

    /// The overlapping note reads its counts off the group rather than asserting them — the
    /// numbers are the whole reason this note is longer than its neighbours.
    @Test func theOverlappingNoteCountsWhatMergingWouldBringAcross() {
        let note = try! #require(DuplicateGroupNote.text(for: group(.overlapping(sharedFraction: 0.72))))
        #expect(note.hasPrefix("72% shared"))
        #expect(note.contains("1 unique item"))
        // The keeper is NOT named here — see `lengthBudget`. The card's header and the "Keep"
        // chip on the row above say which copy that is.
        #expect(!note.contains("x.pdf"), "the note must not interpolate a file name")
        #expect(note.contains("the one you keep"))
    }
}
