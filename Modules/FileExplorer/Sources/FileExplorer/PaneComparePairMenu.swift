import Foundation
import Sync

/// Pure logic behind the panes' two Compare items: which pair a row offers, and how that pair is
/// ordered once it reaches the viewer.
///
/// Extracted, like `DifferenceRowMenu`, so the preconditions can be tested without rendering a
/// context menu: an absent Compare item looks the same as one correctly withheld.
public enum PaneComparePairMenu {

    /// The counterpart for a cross-pane compare, or nil when the row offers none.
    ///
    /// - Not the single-source rail: there is no opposite pane, the same gate as the "Copy '…' from
    ///   ⟨pane⟩" item beside it.
    /// - Exactly one file selected over there, or "compare with which?" has no answer.
    /// - Both sides are files: the viewer can't render a folder pair, as in
    ///   `DifferencesPairCompare.pair(for:paneNames:)`.
    ///
    /// Resolved against the other tree, because a selected row may have gone; the count is still the
    /// path set's, so two paths with one gone stay two. `resolve` defaults to
    /// `PaneTree.selectedNodes(at:)`; the menu passes its `PaneSelectionResolver`, which walks once
    /// for every visible row. The rule still does the lookup, so no caller can hand it the wrong
    /// pane's nodes.
    @MainActor
    public static func crossPaneCounterpart(
        clicked: FileNode, otherTree: PaneTree, otherSelection: Set<String>, isSingleSource: Bool,
        resolve: @MainActor (Set<String>, PaneTree) -> [FileNode] = { $1.selectedNodes(at: $0) }
    ) -> FileNode? {
        guard !isSingleSource, !clicked.isDirectory, otherSelection.count == 1 else { return nil }
        guard let counterpart = resolve(otherSelection, otherTree).first,
              !counterpart.isDirectory,
              counterpart.id != clicked.id else { return nil }
        return counterpart
    }

    /// The counterpart for a same-pane compare, or nil when the row offers none: exactly two files
    /// selected, and the clicked row one of them. A third row right-clicked is not a pair anyone
    /// chose, and `resolvedSelection` would collapse the menu onto it anyway.
    public static func samePaneCounterpart(clicked: FileNode,
                                           selectedNodes: [FileNode]) -> FileNode? {
        guard !clicked.isDirectory, selectedNodes.count == 2,
              selectedNodes.contains(where: { $0.id == clicked.id }),
              // By id, not by index: `selectedNodes` is in tree order, and the clicked row is not
              // reliably its head.
              let counterpart = selectedNodes.first(where: { $0.id != clicked.id }),
              !counterpart.isDirectory else { return nil }
        return counterpart
    }

    /// The pair a pane click opens, ordered for the viewer.
    ///
    /// A cross-pane pair is ordered by pane side, not by which row was clicked, so the viewer's
    /// columns match its left-to-right subtitle. A same-pane pair has no side: the clicked row
    /// leads and the subtitle names the pane once ("iCloud vs iCloud" would say nothing).
    public static func pair(clicked: FileNode, counterpart: FileNode,
                            counterpartIsInOtherPane: Bool, clickedPaneIsLeft: Bool,
                            leftPaneName: String, rightPaneName: String) -> DifferencePair {
        guard counterpartIsInOtherPane else {
            return .withinPane(firstPath: clicked.id, secondPath: counterpart.id,
                               paneName: clickedPaneIsLeft ? leftPaneName : rightPaneName)
        }
        let (left, right) = clickedPaneIsLeft ? (clicked, counterpart) : (counterpart, clicked)
        return .acrossPanes(leftPath: left.id, rightPath: right.id,
                            leftPaneName: leftPaneName, rightPaneName: rightPaneName)
    }
}
