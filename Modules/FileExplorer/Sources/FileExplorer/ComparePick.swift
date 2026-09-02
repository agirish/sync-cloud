import Foundation
import Sync

/// One file armed for comparison, waiting for the click that names its counterpart.
///
/// **The whole idea is one inversion: the click that used to destroy the state is the click that
/// completes it.** Comparing two files across the panes was reachable only by right-clicking, and
/// only a RIGHT-click — a left-click in the other pane writes a selection, and
/// `PaneLogic.applySelectionWrite` clears the first pane in the same update to hold the
/// one-pane-selected invariant. So the gesture that most people try is the gesture that throws away
/// the half they had already armed, silently, with nothing on screen teaching otherwise.
///
/// **The armed file lives HERE, outside both selection sets.** That is what makes this cheap: the
/// invariant is not relaxed, not special-cased and not touched, because nothing about an armed path
/// is a selection. The selection may move, be cleared, or land in the other pane — the pick does not
/// care, and survives all three.
///
/// The armed `FileNode` is held by value rather than by path, so navigating away from its folder
/// (which finding the counterpart usually requires) cannot strand the pick. It may of course go
/// stale on disk; the viewer re-reads both sides when it opens, and says so when a side has gone.
public struct ComparePick: Equatable, Sendable {

    /// The file waiting for a counterpart.
    public let armed: FileNode
    /// Which pane it was armed in — needed to tell a same-pane pair from a cross-pane one, since
    /// the two are ordered by different rules.
    public let armedPaneIsLeft: Bool

    public init(armed: FileNode, armedPaneIsLeft: Bool) {
        self.armed = armed
        self.armedPaneIsLeft = armedPaneIsLeft
    }

    /// What the mode indicator says while this pick is live.
    ///
    /// Names the armed file, because the reader may have navigated a long way from it by the time
    /// they find the other one — "Click the file to compare with…" naming nothing would be a mode
    /// indicator that cannot tell you what mode you are in.
    public var prompt: String { "Click the file to compare with “\(armed.name)”" }

    /// What a click resolves to while a pick is armed.
    public enum Outcome: Equatable {
        /// The armed row was clicked again. **The marker is also the off switch** — the natural
        /// undo for a mode whose only visible anchor is that row.
        case cancelled
        /// A folder. Navigation is how the counterpart gets found, so the click does its ordinary
        /// job and the mode stands.
        case standing
        /// Two files, ordered for the viewer.
        case paired(DifferencePair)
    }

    /// Resolve a click on `node`, in the pane `inLeftPane`.
    ///
    /// **Ordering is `PaneComparePairMenu.pair` unchanged** — pick mode is a different gesture
    /// supplying the same two arguments, not a second ordering rule. A cross-pane pair is ordered
    /// by pane side so the viewer's columns match its subtitle; a same-pane pair leads with the
    /// ARMED file, which is the one the reader chose first and the one the strip has been naming.
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
