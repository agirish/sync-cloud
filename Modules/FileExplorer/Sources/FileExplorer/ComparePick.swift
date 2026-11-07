import Foundation
import Sync

/// One file armed for comparison, waiting for the click that names its counterpart. A left-click
/// in the other pane completes the pair; as a plain selection it would clear the first pane
/// (`PaneLogic.applySelectionWrite` keeps one pane selected).
///
/// The armed file lives here, outside both selection sets, so that invariant is untouched and the
/// pick survives any selection change. It is held by value, not by path, so navigating away to find
/// the counterpart can't strand it; the viewer re-reads both sides when it opens and says when one
/// has gone.
public struct ComparePick: Equatable, Sendable {

    /// The file waiting for a counterpart.
    public let armed: FileNode
    /// Which pane it was armed in, to tell a same-pane pair from a cross-pane one: they are
    /// ordered by different rules.
    public let armedPaneIsLeft: Bool

    public init(armed: FileNode, armedPaneIsLeft: Bool) {
        self.armed = armed
        self.armedPaneIsLeft = armedPaneIsLeft
    }

    /// The armed file's name, for the mode indicator. The name alone, not a sentence: long names
    /// must truncate, and a sentence built around one would lose its instruction too. The strip adds
    /// the words and truncates only this.
    public var armedName: String { armed.name }

    /// What a click resolves to while a pick is armed.
    public enum Outcome: Equatable {
        /// The armed row was clicked again. The marker is also the off switch, since that row is
        /// the mode's only visible anchor.
        case cancelled
        /// A folder. Navigation is how the counterpart gets found, so the click does its ordinary
        /// job and the mode stands.
        case standing
        /// Two files, ordered for the viewer.
        case paired(DifferencePair)
    }

    /// Resolve a click on `node`, in the pane `inLeftPane`. Ordered by `PaneComparePairMenu.pair`,
    /// not a rule of its own: a cross-pane pair by pane side, so the viewer's columns match its
    /// subtitle; a same-pane pair leads with the armed file, the one the strip has been naming.
    public func outcome(clicking node: FileNode, inLeftPane: Bool,
                        leftPaneName: String, rightPaneName: String) -> Outcome {
        if node.id == armed.id { return .cancelled }
        guard !node.isDirectory else { return .standing }
        let acrossPanes = inLeftPane != armedPaneIsLeft
        guard acrossPanes else {
            return .paired(PaneComparePairMenu.pair(
                clicked: armed, counterpart: node,
                counterpartIsInOtherPane: false, clickedPaneIsLeft: armedPaneIsLeft,
                leftPaneName: leftPaneName, rightPaneName: rightPaneName))
        }
        return .paired(PaneComparePairMenu.pair(
            clicked: node, counterpart: armed,
            counterpartIsInOtherPane: true, clickedPaneIsLeft: inLeftPane,
            leftPaneName: leftPaneName, rightPaneName: rightPaneName))
    }

    /// Whether `path` is the armed row — what a row asks to decide if it wears the marker.
    public func marks(_ path: String) -> Bool { path == armed.id }
}
