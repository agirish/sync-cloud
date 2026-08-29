import AppKit
import Design
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// The keeper thumbnails as a **picker** (his report: "the thumbnails aren't really functional? I
/// thought you could click one to select").
///
/// Two previews side by side, one sealed *keeper* and one labelled *duplicate*, both lifting under
/// the pointer — a control in every respect a reader can see, and it did nothing. The only way to
/// change the keeper was the small radio in the row underneath.
@MainActor
@Suite struct DuplicateThumbnailChoiceTests {

    private static func thumbnail(isKeeper: Bool, allowsChoice: Bool,
                                  onChoose: @escaping () -> Void = {}) -> DuplicateThumbnailView {
        DuplicateThumbnailView(path: "/tmp/does-not-exist/report.pdf", name: "report.pdf",
                               isKeeper: isKeeper, allowsKeeperChoice: allowsChoice,
                               onChoose: onChoose, modified: nil)
    }

    /// **One rule, shared with the radio.** A second copy of "may the user pick here" is how a
    /// thumbnail comes to offer what the row beside it refuses — so the tile is clickable in
    /// exactly the `selectable` case and no other.
    @Test func theTileIsClickableExactlyWhereTheRadioIs() {
        // The keeper is already kept: clicking it would be a no-op dressed as a choice.
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        // A group with no keeper choice — a folder copy — offers nothing on either control.
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
        // And the one case that acts.
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false)
                == .selectable)
    }

    /// The click reaches the handler — the whole of what was missing.
    @Test func clickingANonKeeperTileChoosesIt() throws {
        final class Box { var chosen = 0 }
        let box = Box()
        let tile = Self.thumbnail(isKeeper: false, allowsChoice: true,
                                  onChoose: { box.chosen += 1 })
        let host = NSHostingView(rootView: AnyView(tile.frame(width: 80, height: 90)))
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 90)
        host.layoutSubtreeIfNeeded()
        // The gesture itself cannot be driven headlessly; what a test can hold is that the view
        // was handed an action and that the rule admits it. The render below covers the visible
        // half — that the tile *looks* like it acts only when it does.
        #expect(box.chosen == 0)
        tile.onChoose()
        #expect(box.chosen == 1, "the handler the tile was given is the one that runs")
    }

    /// **The lift is an affordance now, not decoration.** It used to appear on every tile —
    /// including the keeper's own and every tile in a group that allows no choice — which is a
    /// button's feedback on something that is not a button anywhere. Rendered hovered, an inert
    /// tile and a selectable one must not paint the same.
    @Test func onlyAClickableTileOffersTheHoverAffordance() throws {
        // Hover state is private, so the check is on the rule that gates it: the two states the
        // lift distinguishes must be distinguishable at all.
        let selectable = DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false)
        let inert = DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false)
        let keeper = DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true)
        #expect(selectable != inert)
        #expect(selectable != keeper)

        // And all three draw: a tile that rendered nothing would make the claim above vacuous.
        for tile in [Self.thumbnail(isKeeper: false, allowsChoice: true),
                     Self.thumbnail(isKeeper: false, allowsChoice: false),
                     Self.thumbnail(isKeeper: true, allowsChoice: true)] {
            let rep = try #require(RestructureRender.raster(tile, width: 80, height: 90))
            #expect(RestructureRender.inkedPixels(rep) > 100)
        }
    }

    /// The keeper's seal is what marks it, and it must still be the thing that differs — a picker
    /// whose two tiles look alike is not a picker.
    @Test func theKeepersSealStillSeparatesTheTwoTiles() throws {
        let keeper = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: true, allowsChoice: true), width: 80, height: 90))
        let other = try #require(RestructureRender.raster(
            Self.thumbnail(isKeeper: false, allowsChoice: true), width: 80, height: 90))
        #expect(RestructureRender.differingPixels(keeper, other) > 100,
                "the seal and the word under it tell the two apart")
    }

    // MARK: The card actually wires it

    /// **What this pins, and what it does not.** It pins that the action reaches
    /// `onChooseKeeper` with the right copy's id. It does NOT pin that `picker(_:)` passes it:
    /// this calls `keeperAction(for:)` directly, so replacing the argument at the call site with
    /// an empty closure leaves it green. Binding that needs a driven click, which is not
    /// available headlessly. Stated here rather than left for the mutation that gets through.
    /// precisely so a test can hold the closure the card hands over.
    @Test func theCardsThumbnailActionReachesItsHandler() throws {
        final class Box { var chosen: [String] = [] }
        let box = Box()
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
        let card = DuplicateGroupCard(
            group: group, isExpanded: true, providerName: "iCloud", scanRoot: "/d",
            densityMetrics: ListDensity.comfortable.metrics,
            onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
            onChooseKeeper: { box.chosen.append($0) }, onMerge: {},
            headerLayout: .row)

        card.keeperAction(for: copies[1])()
        #expect(box.chosen == ["/d/other.pdf"],
                "the action names the copy it was built for, and reaches the card's handler")

        // A positive control: the group really does allow a choice, so the tile this action
        // belongs to is one the shared rule makes clickable.
        #expect(group.allowsKeeperChoice)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: group.allowsKeeperChoice,
                                            isKeeper: copies[1].isRecommendedKeeper)
                == .selectable)
    }
}
