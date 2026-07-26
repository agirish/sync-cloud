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
    /// Both verbs are spelled out while the button has room for a destination — "Copy 17 to
    /// Dropbox" against "Move 17 to Dropbox". This deliberately REPLACES the markedness rule the
    /// button shipped with, where Copy was the unmarked default and carried no verb at all on the
    /// grounds that the arrow glyph already said "to there". The argument against it: a bare
    /// "17 to Dropbox" is only unambiguous once you know the convention, and the convention is
    /// invisible — nothing on screen teaches that a verbless button means copy. Symmetry costs one
    /// word and needs no prior knowledge; the ⇧ flip then reads as one swapped word rather than a
    /// verb materialising out of nowhere.
    ///
    /// What survives from the old rule is its safety half, at the narrow rungs. When the
    /// destination has been shed (`destination == nil`) Copy drops its verb with it and the button
    /// falls back to a bare count, exactly as before — but **Move never sheds its verb at any
    /// width**. The asymmetry is the point: the word that has to be there is the one saying the
    /// source will not survive, and losing "Copy" costs a narrow window nothing it can act on.
    static func text(count: Int, destination: String?, isMove: Bool) -> String {
        guard let destination else {
            // Narrow rung: Move keeps its verb, Copy is the bare count it has always been.
            return isMove ? "Move \(count.formatted())" : count.formatted()
        }
        return "\(isMove ? "Move" : "Copy") \(count.formatted()) to \(destination)"
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
