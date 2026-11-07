import AppKit
import Design
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// In a copy row the whole row is the control, and the thumbnail and radio are pictures of state.
/// A clickable tile inside the clickable row would mean two hit targets, two tooltips, two hover
/// treatments, and VoiceOver announcing one action twice.
///
/// The compiler holds most of this (`DuplicateThumbnailView` takes no action); the rest is held
/// here, because "this view is not a button" is not a claim a render can make.
@MainActor
@Suite struct DuplicateRowPickerTests {

    private static func thumbnail(isKeeper: Bool) -> DuplicateThumbnailView {
        DuplicateThumbnailView(path: "/tmp/does-not-exist/report.pdf", name: "report.pdf",
                               isKeeper: isKeeper, modified: nil)
    }

    private static func card(onChoose: @escaping (String) -> Void = { _ in })
    -> (card: DuplicateGroupCard, copies: [DuplicateCopy]) {
        let copies = [
            DuplicateCopy(id: "/d/keep.pdf", name: "keep.pdf", isDirectory: false, size: 10,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 2,
                          isRecommendedKeeper: true),
            DuplicateCopy(id: "/d/other.pdf", name: "other.pdf", isDirectory: false, size: 10,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 2,
                          isRecommendedKeeper: false),
        ]
        let group = DuplicateGroup(matchType: .identical, name: "keep.pdf", isDirectory: false,
                                   copies: copies, reclaimableBytes: 10)
        return (DuplicateGroupCard(
            group: group, isExpanded: true, providerName: "iCloud", scanRoot: "/d",
            densityMetrics: ListDensity.comfortable.metrics,
            onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
            onChooseKeeper: onChoose, onMerge: {}, onOpenInEditor: nil, headerLayout: .row), copies)
    }

    // MARK: The row acts

    /// The pick reaches the handler through `keeperAction(for:)`, the one closure `copyRow`'s
    /// button is built on, so this exercises what the row actually calls.
    @Test func theRowsActionReachesTheHandlerNamingItsCopy() {
        final class Box { var chosen: [String] = [] }
        let box = Box()
        let (card, copies) = Self.card(onChoose: { box.chosen.append($0) })

        card.keeperAction(for: copies[1])()
        #expect(box.chosen == ["/d/other.pdf"],
                "the action names the copy it was built for, and reaches the card's handler")
    }

    /// One rule, read by one control: the row is a button exactly in the `selectable` case, never
    /// on the keeper and never where no choice exists.
    @Test func theRowIsPickableExactlyWhereTheMarkerIsSelectable() {
        let (card, copies) = Self.card()
        #expect(!card.isRowPickable(copies[0]), "the keeper's own row offers no pick")
        #expect(card.isRowPickable(copies[1]))
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false)
                == .selectable)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
    }

    // MARK: Nothing inside the row is also a control

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return text
    }

    /// Whole-line comments stripped, so prose naming a pattern can't satisfy or trip a scan for it.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The tile carries no control semantics. Scanned, not rendered: a nested tap target, a second
    /// tooltip and a duplicate `.isButton` paint nothing. The control below finds the row's own
    /// controls, so an empty result here isn't a mis-aimed scan.
    @Test func theThumbnailIsPresentationAndNotASecondControl() throws {
        let tile = Self.codeOnly(try Self.source("DuplicateThumbnail.swift"))
        #expect(!tile.contains("onTapGesture"),
                "the tile has a tap target again — the row is the control, and two nested targets is what this row already shipped once")
        #expect(!tile.contains(".isButton"),
                "the tile announces itself as a button inside a row that is one: VoiceOver reads two controls for one action")
        #expect(!tile.contains("NSCursor"),
                "the pointing hand belongs to the whole row; pushed from the tile it marks one island of a row that is clickable end to end")
        #expect(!tile.contains("scaleEffect"),
                "the tile grows on hover again — HoverAffordance's table has no hover scale at all, only the 0.97 press")
    }

    /// `copyRow`'s own body, not the whole file. The card has two
    /// `.hoverAffordance(.row, tint: hueAccent)` buttons, the collapsed header and this row, so a
    /// whole-file `contains` would pass on the header alone with `copyRow`'s style deleted.
    private static func copyRowBody(_ card: String) throws -> String {
        let start = try #require(card.range(of: "private func copyRow("),
                                 "copyRow is gone or renamed — this scan is aimed at nothing")
        let end = try #require(card.range(of: "private func copyRowContent(",
                                          range: start.upperBound..<card.endIndex),
                               "copyRowContent no longer follows copyRow — the slice is wrong")
        return String(card[start.upperBound..<end.lowerBound])
    }

    /// The control for the tile scan, and its inverse claim: the row really carries the control.
    @Test func theRowsFileIsWhereTheControlActuallyLives() throws {
        let card = Self.codeOnly(try Self.source("DuplicateGroupCard.swift"))
        let row = try Self.copyRowBody(card)
        #expect(row.contains("Button(action: keeperAction(for: copy))"),
                "the row's button is what makes the tile's emptiness a design rather than an omission")
        #expect(row.contains(".pointingHandCursor()"),
                "the cursor moved to the row rather than being dropped")
        #expect(row.contains(".buttonStyle(.hoverAffordance(.row, tint: hueAccent))"),
                "the row's wash is the affordance that replaced the tile's lift")
        #expect(row.contains(".help("),
                "the row states what clicking does; with no tooltip on the row and none on the tile, nothing does")
    }

    /// The slice really is narrower than the file, or `copyRowBody` returning the whole document
    /// would make the checks above pass for the wrong reason.
    @Test func theSliceIsJustTheRowAndNotTheWholeCard() throws {
        let card = Self.codeOnly(try Self.source("DuplicateGroupCard.swift"))
        let row = try Self.copyRowBody(card)
        #expect(row.count < card.count / 4,
                "the copyRow slice is \(row.count) of \(card.count) characters — it is not a slice")
        #expect(!row.contains("private var header"),
                "the slice reaches the collapsed header, whose own .row button is what this scan must not be reading")
    }

    /// The keeper radio takes the row's hover and can't light on its own: it is a picture, tinted
    /// only by the enclosing button's published phase.
    ///
    /// Scanned, not rendered: `HoverAffordanceStyle` writes `\.hoverAffordancePhase` inside its own
    /// body, so a value set from outside would be overwritten before the radio read it. The paint
    /// side is `HoverTintRenderTests` in Design.
    @Test func theSelectableRadioTintsFromTheRowsHoverPhase() throws {
        let card = Self.codeOnly(try Self.source("DuplicateGroupCard.swift"))
        #expect(card.contains(".hoverTint(hueAccent)"),
                "the selectable radio no longer takes the accent from the row's hover — it is a picture, so nothing else can light it")
        #expect(!card.contains("SelectableKeeperRadio"),
                "the radio is a Button again, nested inside the row's Button")
    }

    // MARK: What the tile still says

    /// The keeper's seal still tells the two tiles apart: a picker whose copies look alike is not a
    /// picker.
    @Test func theKeepersSealStillSeparatesTheTwoTiles() throws {
        let keeper = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: true), width: 80, height: 90))
        let other = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: false), width: 80, height: 90))
        #expect(RestructureRender.differingPixels(keeper, other) > 100,
                "the seal tells the kept copy from the redundant one")
    }

    /// Both tiles draw at all, or the comparison above would be vacuous.
    @Test func bothTilesDraw() throws {
        for tile in [Self.thumbnail(isKeeper: true), Self.thumbnail(isKeeper: false)] {
            let rep = try #require(RestructureRender.raster(tile, width: 80, height: 90))
            #expect(RestructureRender.inkedPixels(rep) > 100)
        }
    }
}
