import Foundation
import Sync

/// Pure logic behind the panes' two Compare items: which pair a row offers, and how that pair is
/// ordered once it reaches the viewer.
///
/// **Extracted for the reason `DifferenceRowMenu` is**: written inline in the menu's `ViewBuilder`
/// these rules are only reachable by rendering a context menu, and the preconditions are exactly
/// the part worth pinning — a Compare item that is merely absent looks identical to one correctly
/// withheld, which is the failure mode this module has already shipped once.
public enum PaneComparePairMenu {

    /// The counterpart for a CROSS-pane compare, or nil when the row offers none.
    ///
    /// Three preconditions, and each one is load-bearing:
    /// - **Not the single-source rail.** There is no opposite pane, so `otherSelection` describes a
    ///   tree nobody can see — the same gate the "Copy '…' from ⟨pane⟩" item beside it takes.
    /// - **Exactly one file selected over there.** Two would make "compare with which?" a question
    ///   the menu cannot ask, and the cross-pane copy item handles a multi-selection by copying all
    ///   of them, which has no analogue here.
    /// - **Both sides are files.** A folder pair has nothing the viewer can render, and Compare
    ///   owns two folders already — the rule `DifferencesPairCompare.pair(for:paneNames:)` applies
    ///   to its own rows.
    ///
    /// Resolved against the other tree rather than trusting the path set, because a selection can
    /// name a row that has since gone: `selectedNodes(at:)` answers with what is actually there.
    public static func crossPaneCounterpart(clicked: FileNode,
                                            otherTree: PaneTree,
                                            otherSelection: Set<String>,
                                            isSingleSource: Bool) -> FileNode? {
        guard !isSingleSource, !clicked.isDirectory, otherSelection.count == 1 else { return nil }
        guard let counterpart = otherTree.selectedNodes(at: otherSelection).first,
              !counterpart.isDirectory,
              counterpart.id != clicked.id else { return nil }
        return counterpart
    }

    /// The counterpart for a SAME-pane compare, or nil when the row offers none.
    ///
    /// **This is the entry that needs no new rules at all.** A pane's selection is a `Set`, so two
    /// files picked in one tree is a state the app already reaches and the one-pane-selected
    /// invariant has nothing to say about it.
    ///
    /// The clicked row must be one of the two: right-clicking a third row with two others selected
    /// is not a pair anybody chose, and `resolvedSelection` would have collapsed the menu onto the
    /// clicked row anyway.
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
    /// **A cross-pane pair is ordered by PANE SIDE, not by which row was clicked.** The viewer
    /// draws two columns and names them left-to-right in its subtitle; if the reader right-clicks
    /// in the right pane and their file turns up in the left column, the subtitle and the columns
    /// disagree and the surface becomes a puzzle to read. A same-pane pair has no side to match, so
    /// there the clicked row leads and the subtitle names the one pane once — "iCloud vs iCloud"
    /// would name nothing.
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
