import Foundation

/// How much the differences header has had to give up to fit the pane's width.
///
/// The header is a `ViewThatFits` over one row per case, in this order, so the ladder is the
/// shedding order: SwiftUI takes the first row that fits. Ordering it here lets a test assert the
/// concessions directly.
///
/// Each rung asks what the row can lose and still say where your files are going. Verify and Review
/// name no destination, so they fold first (into the overflow menu, which exists only once one has
/// folded). The reverse button's destination goes next, then the filter's name; the primary's
/// destination goes last, because it is the one word the bar exists to say.
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
    /// Both verbs are spelled out while there is room for a destination ("Copy 17 to Dropbox",
    /// "Move 17 to Dropbox"): a verbless "17 to Dropbox" relies on a convention nothing on screen
    /// teaches, and with both verbs the ⇧ flip reads as one swapped word.
    ///
    /// Once the destination is shed (`destination == nil`), Copy drops to a bare count, but
    /// **Move never sheds its verb at any width**: it is the word saying the source will not
    /// survive.
    static func text(count: Int, destination: String?, isMove: Bool) -> String {
        guard let destination else {
            // Narrow rung: Move keeps its verb, Copy is a bare count.
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
    /// Always, at any width, when the reverse is the bulk of the work: the loudest button then
    /// points away from most of it, which a fixed-direction primary can't say. As the minority, its
    /// name repeats the primary's and can go early.
    static func reverseNamesDestination(reverseIsMajority: Bool, compaction: HeaderCompaction) -> Bool {
        reverseIsMajority || compaction < .shortReverse
    }

    /// Whether the primary keeps its destination name. Only the bottom rung takes it.
    static func primaryNamesDestination(compaction: HeaderCompaction) -> Bool {
        compaction < .shortPrimary
    }
}
