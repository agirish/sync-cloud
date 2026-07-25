import Foundation

/// How much the differences header has had to give up to fit the pane's width.
///
/// The header renders as a `ViewThatFits` over one row per case, in this order, so the ladder IS
/// the shedding order: SwiftUI takes the first row whose ideal width fits and every case below it
/// is a further concession. Ordering it here rather than inline in the view is what lets a test
/// assert the concessions directly.
///
/// The order answers one question per rung — what can this row lose and still tell you where your
/// files are about to go? Verify and Review name no destination, so they go first (into the
/// overflow menu, which exists only once one of them has been folded in). The reverse button's
/// destination goes next, then the filter's name, and the primary's destination is last: it is the
/// one word the bar exists to say. That is the exact inverse of what the header did before, where
/// `.truncationMode(.middle)` ate the provider name out of the widest button first.
enum HeaderCompaction: Int, CaseIterable, Comparable, Sendable {
    /// Everything spelled out; no overflow menu.
    case full
    /// Verify folds into the overflow menu.
    case foldVerify
    /// Review folds in too.
    case foldReview
    /// The reverse transfer button drops to its arrow and count — unless it is the bulk of the
    /// work, in which case it keeps its destination and this rung buys nothing.
    case shortReverse
    /// The filter menu drops to its glyph; the active filter still shows in the menu's check column.
    case glyphFilter
    /// Last resort: the primary drops to its arrow and count. It never loses the fill or the arrow.
    case shortPrimary

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The wording of the header's two fixed-direction transfer buttons, and the rules for how much of
/// it survives a narrow window. Pure so the rules can be asserted without laying out a view.
enum BulkActionLabel {

    /// A transfer button's label.
    ///
    /// Copy is the unmarked default and carries no verb — the arrow in the button's icon says
    /// "to there", and the destination says where. Only Move is spelled out, because it is the
    /// one that removes the source: the marked, destructive variant should be the one that reads
    /// differently, not the one you get by default.
    static func text(count: Int, destination: String?, isMove: Bool) -> String {
        let verb = isMove ? "Move " : ""
        guard let destination else { return "\(verb)\(count.formatted())" }
        return "\(verb)\(count.formatted()) to \(destination)"
    }

    /// The tooltip, which always spells out the verb and the destination however terse the label
    /// has become. A label may shed words; the explanation may not.
    static func help(count: Int, destination: String, isMove: Bool) -> String {
        let verb = isMove ? "Move" : "Copy"
        let noun = count == 1 ? "item" : "items"
        return "\(verb) \(count.formatted()) \(noun) to \(destination)"
    }

    /// Whether the reverse (right-to-left) button keeps its destination name.
    ///
    /// It always does when the reverse is the bulk of the work, at any width. That is the one
    /// thing a fixed-direction primary cannot tell you — the loudest button on the bar is pointing
    /// away from most of the work — so it is the last thing the row is allowed to swallow. When the
    /// reverse is the minority the name is redundant with the primary's and can go early.
    static func reverseNamesDestination(reverseIsMajority: Bool, compaction: HeaderCompaction) -> Bool {
        reverseIsMajority || compaction < .shortReverse
    }

    /// Whether the primary keeps its destination name. Only the bottom rung takes it.
    static func primaryNamesDestination(compaction: HeaderCompaction) -> Bool {
        compaction < .shortPrimary
    }
}
