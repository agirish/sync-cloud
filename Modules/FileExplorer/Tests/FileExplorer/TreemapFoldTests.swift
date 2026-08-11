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
        let nodes = [node("Muktha", 28_000), node("Aditi", 12_900), node("Anuraag", 10_500),
                     node("Gifts", 9_700), node("Divit", 6_600), node("Events", 2_000),
                     node("Girish", 1_500), node("Shweta", 900), node("Home", 400)]
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

    @Test func degenerateInputsPassThrough() {
        #expect(TreemapView.fold(nodes: [], availableWidth: 700).folded.isEmpty)
        let one = [node("A", 1)]
        #expect(TreemapView.fold(nodes: one, availableWidth: 700).visible == one)
        #expect(TreemapView.fold(nodes: one, availableWidth: 0).folded.isEmpty)
    }
}
