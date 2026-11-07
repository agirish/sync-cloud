import Foundation

/// What the app looked like at the last answered heartbeat before a stall. Read on the main thread
/// while it was free: once it stalls, nothing newer can be read.
struct StallAppState: Equatable, Sendable {
    var active: Bool
    var everyWindowOccluded: Bool
}

/// One sampled stall, as ``MainThreadStallWatch`` knows it when its line is due.
struct StallFacts: Equatable, Sendable {
    /// Uptimes of the heartbeat the stall held and of its end; `ended` is nil while it goes on.
    var began: TimeInterval
    var ended: TimeInterval?
    /// Main-thread CPU over the stall, when both ends were read.
    var cpu: TimeInterval?
    /// nil when unknown: a test's watch over a private queue never reads `NSApp`.
    var app: StallAppState?
}

/// Whether a sampled stall gets its line at WARN, or only a place in the background count.
///
/// A stall over a hidden, inactive app, short and mostly idle, is the system starving a
/// background process (App Nap, a sleeping display): written up per stall, it filled the Warnings
/// with lines nobody felt. Everything else is one the user may have felt, and stays a line. Any
/// doubt keeps the line: an unknown state, unknown CPU, an activation near it.
enum StallClassifier {
    enum Verdict: Equatable, Sendable {
        /// Tallied, and written in the next count line.
        case counted
        /// Not decidable yet: an activation made during the stall is delivered only after it ends,
        /// so the verdict waits a heartbeat past the end.
        case wait(until: TimeInterval)
        /// Its own line, at WARN.
        case warn
    }

    /// Over this, a stall is never counted, and one still going gets its own line.
    static let longAfter: TimeInterval = 10
    /// The share of the stall's wall time the main thread may spend on CPU and still be counted.
    static let busyShare = 0.10

    /// Pure. `activations` are the uptimes of `didBecomeActive`, as the watch received them.
    static func classify(_ stall: StallFacts, now: TimeInterval, beat: TimeInterval,
                         activations: [TimeInterval]) -> Verdict {
        guard let app = stall.app, !app.active, app.everyWindowOccluded,
              let ended = stall.ended, ended - stall.began <= longAfter else { return .warn }
        // From a beat before it began: the app state is up to a beat old when the stall starts.
        let opens = stall.began - beat, closes = ended + beat
        if activations.contains(where: { $0 >= opens && $0 <= closes }) { return .warn }
        if now < closes { return .wait(until: closes) }
        guard let cpu = stall.cpu else { return .warn }
        return cpu / max(ended - stall.began, 0.001) < busyShare ? .counted : .warn
    }
}
