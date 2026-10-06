import Foundation

/// **Which half of Split leads the scroll, and which scroll is only the echo** (TE67.4).
///
/// With both halves editable both can be scrolled, and each follows the other by line. Without a
/// rule they chase each other: the follower's programmatic scroll reports a line too, which sends
/// the leader to it, which reports again. The rule: **the pane last scrolled by the person leads**,
/// and a report from the other pane within ``echoWindow`` of the leader's is that echo, and is
/// dropped. A person scrolling the other pane after that takes the lead.
struct SplitScrollFollow {

    enum Pane: Equatable { case source, preview }

    /// How long after the leader moved a report from the other pane is taken for the echo.
    static let echoWindow: TimeInterval = 0.15

    private(set) var leader: Pane?
    private var ledAt = Date.distantPast

    /// Whether `pane`'s report should move the other pane. Records it as the leader when so.
    mutating func shouldFollow(from pane: Pane, now: Date = Date()) -> Bool {
        if let leader, leader != pane, now.timeIntervalSince(ledAt) < Self.echoWindow { return false }
        leader = pane
        ledAt = now
        return true
    }
}
