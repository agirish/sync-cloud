import AppKit
import Design
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// **Which thing in a copy row is the control** — a question this row answered twice, wrongly, in
/// two steps that were each right on their own.
///
/// First the thumbnail was made clickable, because it looked like a control and was not ("the
/// thumbnails aren't really functional? I thought you could click one to select"). Then the whole
/// row was made clickable, because the tile being the only target was not discoverable ("it's not
/// obvious that only the thumbnail needs to be clicked"). The second change did not retire the
/// first, and the two gates were *the same predicate* — `DuplicateGroupCard.isRowPickable` and the
/// tile's own `choice` both reduced to `DuplicateKeeperMarker.style(…) == .selectable` — so every
/// pickable row shipped with two hit targets, two `.help` tooltips, two hover treatments, and two
/// nested `.isButton` elements announcing one action to VoiceOver twice.
///
/// The row is the control now and the tile and radio are pictures of state. Most of that invariant
/// is held by the compiler — `DuplicateThumbnailView` has no action to be given — and the rest is
/// held here, because "this view is not a button" is not a claim a render can make.
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
            onChooseKeeper: onChoose, onMerge: {}, headerLayout: .row), copies)
    }

    // MARK: The row acts

    /// The pick reaches the handler, from the function the row is wired to.
    ///
    /// `keeperAction(for:)` is now `copyRow`'s own argument rather than the thumbnail's, which
    /// closes the hole the previous version of this test had to state and leave open: it called
    /// this function while the *call site* passed its own inline closure, so replacing that
    /// argument left the suite green. There is one closure now and this is it.
    @Test func theRowsActionReachesTheHandlerNamingItsCopy() {
        final class Box { var chosen: [String] = [] }
        let box = Box()
        let (card, copies) = Self.card(onChoose: { box.chosen.append($0) })

        card.keeperAction(for: copies[1])()
        #expect(box.chosen == ["/d/other.pdf"],
                "the action names the copy it was built for, and reaches the card's handler")
    }

    /// **One rule, and now one control reading it.** The row is a button in exactly the
    /// `selectable` case: never on the keeper (already kept), never where no choice exists.
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

    /// Whole-line comments stripped, so the prose above describing the defect cannot satisfy a scan
    /// looking for its absence.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The tile carries no control semantics.** Scanned rather than rendered because none of it
    /// is visible: a nested tap target, a second tooltip and a duplicated `.isButton` all paint
    /// exactly nothing, which is why the doubling survived a full visual review.
    ///
    /// The positive control is below — the same scan run against the row's own file must FIND
    /// these, or an empty result here would only mean the scan was aimed wrong.
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

    /// `copyRow`'s own body, sliced out of the file — **not the whole file.**
    ///
    /// The card draws two `.hoverAffordance(.row, tint: hueAccent)` buttons: the collapsed header
    /// and this row. A whole-file `contains` for that string is therefore satisfied by the header
    /// alone, so it would stay green with `copyRow`'s style deleted — which is the exact
    /// regression the assertion exists to catch. Slicing is what makes it mean what it says.
    private static func copyRowBody(_ card: String) throws -> String {
        let start = try #require(card.range(of: "private func copyRow("),
                                 "copyRow is gone or renamed — this scan is aimed at nothing")
        let end = try #require(card.range(of: "private func copyRowContent(",
                                          range: start.upperBound..<card.endIndex),
                               "copyRowContent no longer follows copyRow — the slice is wrong")
        return String(card[start.upperBound..<end.lowerBound])
    }

    /// The positive control for the scan above, and the claim it is the inverse of: the row's file
    /// really does carry the control, in the file the other scan asserts is empty of it.
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

    /// **The slice really is narrower than the file** — without this, `copyRowBody` returning the
    /// whole document would make every assertion above pass for the wrong reason.
    @Test func theSliceIsJustTheRowAndNotTheWholeCard() throws {
        let card = Self.codeOnly(try Self.source("DuplicateGroupCard.swift"))
        let row = try Self.copyRowBody(card)
        #expect(row.count < card.count / 4,
                "the copyRow slice is \(row.count) of \(card.count) characters — it is not a slice")
        #expect(!row.contains("private var header"),
                "the slice reaches the collapsed header, whose own .row button is what this scan must not be reading")
    }

    /// **The keeper radio takes the row's hover, and cannot light on its own.** It used to be a
    /// `Button` with its own `isHovering`; it is a picture now, so the only thing that can tint it
    /// is the enclosing button's published phase.
    ///
    /// Scanned rather than rendered, and deliberately: `HoverAffordanceStyle` writes
    /// `\.hoverAffordancePhase` inside its own body, so a test that set that environment value
    /// from outside the button would have it overwritten before the radio read it — it would
    /// measure nothing while looking exactly like it measured something. What the paint side of
    /// this claim needs is `HoverTintRenderTests` in Design, which already holds it: `hoverTint`
    /// applies the colour when engaged and nothing at rest.
    @Test func theSelectableRadioTintsFromTheRowsHoverPhase() throws {
        let card = Self.codeOnly(try Self.source("DuplicateGroupCard.swift"))
        #expect(card.contains(".hoverTint(hueAccent)"),
                "the selectable radio no longer takes the accent from the row's hover — it is a picture, so nothing else can light it")
        #expect(!card.contains("SelectableKeeperRadio"),
                "the radio is a Button again, nested inside the row's Button")
    }

    // MARK: What the tile still says

    /// The keeper's seal is what marks it, and it must still be the thing that differs — a picker
    /// whose two copies look alike is not a picker, control or no control.
    @Test func theKeepersSealStillSeparatesTheTwoTiles() throws {
        let keeper = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: true), width: 80, height: 90))
        let other = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: false), width: 80, height: 90))
        #expect(RestructureRender.differingPixels(keeper, other) > 100,
                "the seal tells the kept copy from the redundant one")
    }

    /// And both draw at all — a tile that rendered blank would make the comparison above vacuous.
    @Test func bothTilesDraw() throws {
        for tile in [Self.thumbnail(isKeeper: true), Self.thumbnail(isKeeper: false)] {
            let rep = try #require(RestructureRender.raster(tile, width: 80, height: 90))
            #expect(RestructureRender.inkedPixels(rep) > 100)
        }
    }
}
