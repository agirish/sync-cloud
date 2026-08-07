import Design
import Foundation

/// What the pane bar's scan rung is at this moment: the button that starts a scan, the button that
/// stops the running one, or the disabled spinner it used to be for the whole of a scan.
///
/// One rung with two actions is exactly the shape that goes wrong quietly — the glyph says Stop
/// while the tooltip still offers ⌘R, or the badge advertises a chord that starts a scan on a
/// control that now cancels one. Every one of those is decided here, from two facts, so the
/// header's builder reads a single value and a test can hold the whole table.
///
/// The rung is the only place `PaneBarItem.pinned` refuses to remove, so it is on screen in every
/// arrangement — which is why Stop lives here rather than in chrome of its own.
public enum ScanRungMode: Equatable, Sendable {
    /// Idle. Pressing it starts a scan.
    case scan
    /// A scan is running and the host offered a way to stop it.
    case stop
    /// A scan is running and the host offered no way to stop it — the historical behaviour, and
    /// what every caller outside the app still gets. Disabled, with the arrow spinning.
    case busy

    /// `canCancel` is "the host passed an `onCancelScan`", not "a scan is cancellable": a header
    /// with no cancel handler must keep behaving exactly as it did before Stop existed, or adding
    /// the parameter would change every other caller's rung.
    public static func resolve(isRefreshing: Bool, canCancel: Bool) -> ScanRungMode {
        guard isRefreshing else { return .scan }
        return canCancel ? .stop : .busy
    }

    public var symbol: String { self == .stop ? "stop.circle" : "arrow.clockwise" }

    /// Only `.busy` is dead. `.stop` is the whole point — a live control in chrome that was
    /// disabled anyway.
    public var isEnabled: Bool { self != .busy }

    /// The arrow spins only while it IS the arrow. `.stop` swapped the glyph, and a spinning stop
    /// sign is not a thing.
    public var spins: Bool { self == .busy }

    /// `nil` on `.stop`: ⌘R starts a scan, it does not stop one, so a badge there would advertise
    /// a chord that does something else. `shortcutKeycap` withholds the VoiceOver hint with it.
    public var keycap: String? { self == .stop ? nil : AppChord.rescan.display }

    /// Spoken and shown identically, because the glyph alone carries the difference on screen.
    public var label: String { self == .stop ? "Stop scanning" : "Scan for changes" }

    /// The tooltip. Only the scan form names a chord — see `keycap`.
    public var help: String {
        self == .stop ? label : ShortcutHint.tooltip(label, AppChord.rescan.display)
    }
}
