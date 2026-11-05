import Design
import Foundation

/// What the pane bar's scan rung is at this moment: the button that starts a scan, the button that
/// stops the running one, or a disabled spinner.
///
/// One rung with two actions drifts quietly: a Stop glyph with a ⌘R tooltip, or a badge whose chord
/// starts a scan on a control that cancels one. Every such choice is decided here from two facts,
/// so the header reads one value and a test can hold the whole table. Stop lives on this rung
/// because it is the one `PaneBarItem.pinned` refuses to remove, so it is in every arrangement.
///
/// Internal: no public signature uses it (`PaneHeader` takes an `onCancelScan` closure), and tests
/// reach it with `@testable`.
enum ScanRungMode: Equatable, Sendable {
    /// Idle. Pressing it starts a scan.
    case scan
    /// A scan is running and the host offered a way to stop it.
    case stop
    /// A scan is running and the host offered no way to stop it, as for every caller outside the
    /// app. Disabled, with the arrow spinning.
    case busy

    /// `canCancel` means "the host passed an `onCancelScan`", not "a scan is cancellable": a header
    /// with no cancel handler keeps the plain busy rung.
    static func resolve(isRefreshing: Bool, canCancel: Bool) -> ScanRungMode {
        guard isRefreshing else { return .scan }
        return canCancel ? .stop : .busy
    }

    var symbol: String { self == .stop ? "stop.circle" : "arrow.clockwise" }

    /// Only `.busy` is disabled; `.stop` is a live control.
    var isEnabled: Bool { self != .busy }

    /// The arrow spins only while it is the arrow; `.stop` swaps the glyph.
    var spins: Bool { self == .busy }

    /// `nil` on `.stop`: ⌘R starts a scan, so a badge there would advertise the wrong act.
    /// `shortcutKeycap` withholds the VoiceOver hint with it.
    var keycap: String? { self == .stop ? nil : AppChord.rescan.display }

    /// Spoken and shown the same, because on screen the glyph alone carries the difference.
    var label: String { self == .stop ? "Stop scanning" : "Scan for changes" }

    /// The word under the pill in `PaneBarLabelMode.iconAndText`. Published so
    /// `PaneBarItem.titleVariants` can reserve room for it without restating the string.
    static let stopTitle = "Stop"

    /// The bar title, which swaps with the glyph, the one title on the bar that does. Elsewhere a
    /// title names the control while the glyph shows its state, but mid-scan this rung does a
    /// different act (cancel, not start), so "Scan" under a stop glyph would name the wrong one.
    /// Resolved here beside the other properties so none of them can drift apart.
    var barTitle: String { self == .stop ? Self.stopTitle : PaneBarItem.scan.barTitle }

    /// The tooltip. Only the scan form names a chord (see `keycap`).
    var help: String {
        self == .stop ? label : ShortcutHint.tooltip(label, AppChord.rescan.display)
    }
}
