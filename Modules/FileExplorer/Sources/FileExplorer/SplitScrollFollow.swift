import Foundation

/// Which half of Split leads the scroll, and which scroll is only the echo.
///
/// Each half follows the other by line, and without a rule they chase each other: the follower's
/// programmatic scroll reports a line too. The pane the person last scrolled leads; a report from
/// the other pane within ``echoWindow`` of the leader's is the echo and is dropped. Scrolling the
/// other pane after that takes the lead.
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
