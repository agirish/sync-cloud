import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Picking a keeper on a Duplicates card leaves the rows where they were. A pick is a comparison,
/// and a list that rearranges under the click destroys what it is compared against; the row then
/// under the pointer isn't the one clicked, so the click looks like the whole card repainting.
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

    /// The order is the group's, before and after. `choosingKeeper` returning
    /// `[newKeeper] + rest` would move the clicked row to the top of the card.
    @Test func pickingAKeeperLeavesEveryRowWhereItWas() {
        let g = group([copy("/a/x.pdf", keeper: true), copy("/b/x.pdf"), copy("/c/x.pdf")])
        let before = g.copies.map(\.id)
        let after = g.choosingKeeper("/c/x.pdf")
        #expect(after.copies.map(\.id) == before)
        #expect(after.keeper.id == "/c/x.pdf", "a positive control: the pick did land")
        // And back again: the first copy becoming the keeper again must not sort anything either.
        #expect(after.choosingKeeper("/a/x.pdf").copies.map(\.id) == before)
    }

    /// The order holds when the group didn't arrive keeper-first, as after a second pick. A rule
    /// that preserved only the scan's own layout would pass one click and fail the second.
    @Test func theOrderIsNotSilentlyReSortedByDepthOrPath() {
        // Hostile to sorting by depth or by path: the keeper is last, and the ids run in reverse
        // alphabetical order with a deep copy in the middle.
        let g = group([copy("/z/x.pdf", depth: 1), copy("/m/deep/x.pdf", depth: 3),
                       copy("/a/x.pdf", depth: 1, keeper: true)])
        let after = g.choosingKeeper("/m/deep/x.pdf")
        #expect(after.copies.map(\.id) == ["/z/x.pdf", "/m/deep/x.pdf", "/a/x.pdf"])
    }

    /// The figures still follow the pick: a stable order must not make the card static where it
    /// should react.
    @Test func theReclaimAndRemovalStillFollowThePick() {
        let g = group([copy("/a/x.pdf", size: 10, keeper: true), copy("/b/x.pdf", size: 500)])
        let after = g.choosingKeeper("/b/x.pdf")
        #expect(after.recommendedRemovalPaths == ["/a/x.pdf"])
        #expect(after.reclaimableBytes == 10)
    }

    /// The removal list keeps the card's order: `redundantCopies` is a plain filter over `copies`.
    /// The order is harmless, since every path on it is trashed, but the confirmation dialog
    /// counts from this list.
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

    /// The card's title names the copy being kept. Rendered, not checked as a string, because a
    /// `titleName` nothing draws would pass and leave the card headed by the file it will trash.
    /// The two arms differ only in which same-sized copy is the keeper, so every differing pixel
    /// is the name.
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
                                   onOpenInEditor: nil, headerLayout: .row),
                width: 620, height: 64)
        }
        let before = try #require(header(first))
        let after = try #require(header(second))
        #expect(RestructureRender.inkedPixels(before) > 200, "a positive control: the header drew")
        #expect(RestructureRender.differingPixels(before, after) > 40,
                "the header follows the pick — it named the trashed copy before this")
    }

    // MARK: The copy row

    /// A long file name must not make the card taller. The path is one concatenated `Text`, which
    /// truncates as a single string; an `HStack` of one `Text` per crumb can't truncate and wraps
    /// instead. Height is checked because growth is the harm: it pushes the thumbnail, fate chip
    /// and actions apart.
    ///
    /// Not pinned: that the path line drops the file name. `crumbs(path)` in place of
    /// `crumbs(path).dropLast()` survives this test, since the line truncates either way.
    @MainActor
    @Test func aVeryLongFileNameDoesNotGrowTheCard() {
        // Over 90 characters, wider than the 460pt card, shaped like a real name
        // ("Passport Old - Mother - All Pages (Jul 2020) - Compressed.pdf").
        let long = String(repeating: "Passport Old - Mother - All Pages ", count: 3) + ".pdf"
        #expect(long.count > 90, "a positive control: this name really is too long for the card")

        func height(name: String) -> CGFloat {
            var reported: CGFloat = -1
            let g = group([copy("/Docs/Passport/Mother/Archive/\(name)", name: name, keeper: true),
                           copy("/Docs/Passport/Mother/Old/\(name)", name: name)])
            let card = DuplicateGroupCard(
                group: g, isExpanded: true, providerName: "iCloud", scanRoot: "/Docs",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .stacked)
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

    /// Why the stacked layout exists, measured: at a grid column's width the one-line header doesn't
    /// fit, and a SwiftUI view that doesn't fit draws at the width it wants, not the one given. A
    /// row header in a two-column grid would draw over the tile beside it.
    ///
    /// 220pt is the minimum the duplicates lens asks `LensCardGrid` for, the narrowest tile drawn.
    @MainActor
    @Test func theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot() {
        let offered: CGFloat = 220
        let group = group([copy("/a/Passport - Mother - All Pages.pdf",
                                name: "Passport - Mother - All Pages.pdf", size: 26_300_000,
                                keeper: true),
                           copy("/b/Passport - Mother - All Pages (Jul 2020).pdf",
                                name: "Passport - Mother - All Pages (Jul 2020).pdf",
                                size: 26_300_000)])

        func drawnWidth(_ layout: DuplicateCardHeaderLayout,
                        offered: CGFloat = offered) -> CGFloat {
            var reported: CGFloat = -1
            let card = DuplicateGroupCard(
                group: group, isExpanded: false, providerName: "iCloud", scanRoot: "/",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: layout)
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

        // The constant that picks the layout is held to the measured fit plus a budget. The scan
        // finds where the row stops overflowing, but there the name has truncated to almost
        // nothing (two `Passport - … - All Pages.pdf` files both read `Passpor…ages.pdf`), which
        // no fit measurement sees. So the constant must clear the fit by `rowHeaderNameBudget`,
        // and not by so much that roomy cards stack for nothing.
        var fits: CGFloat = 0
        for candidate in stride(from: CGFloat(200), through: 640, by: 4)
        where drawnWidth(.row, offered: candidate) <= candidate {
            fits = candidate
            break
        }
        #expect(fits > 0, "the row header never fits, even at 640pt")
        let budget = DuplicateCardHeaderLayout.rowHeaderNameBudget
        #expect(DuplicateCardHeaderLayout.rowHeaderMinimumWidth >= fits + budget,
                "the row stops overflowing at \(fits)pt and the constant is \(DuplicateCardHeaderLayout.rowHeaderMinimumWidth) — that leaves the name under \(budget)pt, where two long names truncate to the same string")
        #expect(DuplicateCardHeaderLayout.rowHeaderMinimumWidth <= fits + budget + 100,
                "the constant is \(DuplicateCardHeaderLayout.rowHeaderMinimumWidth) against a measured \(fits) + \(budget) — roomy cards lose the dense header for nothing")
    }
}

/// The card's note: short enough to read, without losing the claims it carries.
@Suite struct DuplicateGroupNoteTests {

    /// The name is a parameter so the length budget can be measured against a realistic name, not
    /// a five-character stand-in.
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

    /// Every kind of note stays within the length budget, the only checkable form of "too long": a
    /// note grows a clause at a time, each defensible, until nobody reads any of them.
    @Test func everyNoteStaysInsideItsLengthBudget() {
        // A real name from his cards, not a five-character stand-in.
        let realistic = "Passport Old - Mother - All Pages (Jul 2020) - Compressed.pdf"
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

    /// Short, not weak: the same-text note keeps every claim, since it sits above a destructive
    /// button on the one match kind that is not proof of identity.
    @Test func theSameTextNoteKeepsItsClaims() {
        let note = try! #require(DuplicateGroupNote.text(for: group(.sameText)))
        #expect(note.contains("bytes differ"), "the match is weaker than byte identity")
        #expect(note.contains("signed"), "and here is how a false match happens")
        #expect(note.contains("Open both first"), "so the user is told what to do about it")
        #expect(note.contains("⌘Z"))
        // "Never part of Apply recommended" is a fact about a header button, not these two files,
        // so it lives in `batchInformativeText`, the last thing read before that button acts.
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

    /// The overlapping note reads its counts off the group; the numbers are why this note is
    /// longer than the others.
    @Test func theOverlappingNoteCountsWhatMergingWouldBringAcross() {
        let note = try! #require(DuplicateGroupNote.text(for: group(.overlapping(sharedFraction: 0.72))))
        #expect(note.hasPrefix("72% shared"))
        #expect(note.contains("1 unique item"))
        // The keeper is not named here (see `lengthBudget`); the card's header and the row's
        // "Keep" chip say which copy that is.
        #expect(!note.contains("x.pdf"), "the note must not interpolate a file name")
        #expect(note.contains("the one you keep"))
    }
}
