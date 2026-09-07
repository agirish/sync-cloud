import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The treemap's tail fold. The claims that could rot: every byte stays on screen (visible +
/// folded always sum to the input — a part-of-whole picture must not drop its smallest parts),
/// the fold is exactly the sub-label-width suffix, and a fold of one never happens (a "+1 more"
/// tile would spend its space on not-saying a name that fits).
@Suite struct TreemapFoldTests {

    private func node(_ name: String, _ bytes: Int) -> TreemapNode {
        TreemapNode(name: name, path: "", bytes: bytes)
    }

    @Test func nothingFoldsWhenEveryTileCanCarryItsLabel() {
        let fold = TreemapView.fold(nodes: [node("A", 500), node("B", 400), node("C", 300)],
                                    availableWidth: 900)
        #expect(fold.folded.isEmpty)
        #expect(fold.visible.count == 3)
    }

    @Test func theSubThresholdSuffixFoldsAndBytesAreConserved() {
        let nodes = [node("Granny", 28_000), node("Daughter", 12_900), node("Uncle", 10_500),
                     node("Gifts", 9_700), node("Son", 6_600), node("Events", 2_000),
                     node("Elder", 1_500), node("Mother", 900), node("Home", 400)]
        let fold = TreemapView.fold(nodes: nodes, availableWidth: 700)
        #expect(!fold.folded.isEmpty)
        // Conservation: the picture still accounts for every byte.
        let total = nodes.reduce(0) { $0 + $1.bytes }
        let visibleBytes = fold.visible.reduce(0) { $0 + $1.bytes }
        #expect(visibleBytes + fold.tailBytes == total)
        // Suffix: everything folded is smaller than everything visible.
        if let smallestVisible = fold.visible.map(\.bytes).min(),
           let largestFolded = fold.folded.map(\.bytes).max() {
            #expect(largestFolded <= smallestVisible)
        }
    }

    @Test func aFoldOfOneNeverHappens() {
        // One sub-threshold straggler keeps its identity — the view widens it to the label
        // floor instead of renaming it "+1 more".
        let nodes = [node("A", 10_000), node("B", 8_000), node("tiny", 100)]
        let fold = TreemapView.fold(nodes: nodes, availableWidth: 900)
        #expect(fold.folded.isEmpty)
        #expect(fold.visible.count == 3)
    }

    @Test func theTailClampCannotSqueezeAVisibleTileUnderTheFloor() {
        // Adversarial case: sizes arranged so a single-pass fold leaves its smallest visible
        // tile just above the floor, and the tail's clamp (which takes real width) would push
        // it back under — the anonymous sliver, reintroduced at the boundary. The fold must
        // settle instead. Replays the view's own width arithmetic over many shapes.
        let shapes: [[Int]] = [
            [40_000, 8_000, 7_000, 900, 800, 700, 600, 500],
            [100, 99, 98, 9, 8, 7, 6, 5, 4, 3, 2, 1],
            [50_000, 4_000, 3_900, 3_800, 500, 400, 300],
        ]
        for (i, sizes) in shapes.enumerated() {
            let nodes = sizes.enumerated().map { node("n\($0.offset)", $0.element) }
            for width: CGFloat in [300, 420, 560, 700] {
                let fold = TreemapView.fold(nodes: nodes, availableWidth: width)
                guard !fold.folded.isEmpty else { continue }
                let spacing: CGFloat = 3
                let total = CGFloat(max(1, nodes.reduce(0) { $0 + $1.bytes }))
                let tileCount = fold.visible.count + 1
                let available = max(0, width - spacing * CGFloat(tileCount - 1))
                let tailWidth = max(TreemapView.labelMinWidth,
                                    available * CGFloat(fold.tailBytes) / total)
                let visibleBytes = CGFloat(max(1, nodes.reduce(0) { $0 + $1.bytes } - fold.tailBytes))
                let visibleAvailable = max(0, available - tailWidth)
                for tile in fold.visible {
                    let w = visibleAvailable * CGFloat(tile.bytes) / visibleBytes
                    #expect(w >= TreemapView.labelMinWidth - 0.5,
                            "shape \(i) at \(width)pt: \(tile.name) settles at \(w)pt — under the label floor")
                }
            }
        }
    }

    @Test func degenerateInputsPassThrough() {
        #expect(TreemapView.fold(nodes: [], availableWidth: 700).folded.isEmpty)
        let one = [node("A", 1)]
        #expect(TreemapView.fold(nodes: one, availableWidth: 700).visible == one)
        #expect(TreemapView.fold(nodes: one, availableWidth: 0).folded.isEmpty)
    }
}
