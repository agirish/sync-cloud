import AppKit

/// How a fixture window that must be ordered in stays out of the user's sight: it is **buried**,
/// ordered in at the lowest window level there is, under the display's own opaque backstop.
///
/// Some suites need a window the window server treats as visible — a SwiftUI popover only presents
/// from one — and these used to order theirs in at the screen's origin or at (200, 200). Every
/// package run (the user's, another session's, and CI's on this Mac) then stood status lines,
/// popovers and whole editor workspaces over whatever the user was doing.
///
/// **Why buried and not parked off every display**, both measured 2026-10-16:
/// - Off every display a window has no `screen`, and its popover is never placed against its anchor:
///   the Go to Line field came up at x 0 whatever the caret's x, which is the very thing
///   `EditorGoToLineFieldTests` checks. AppKit also moves a titled window back onto a display, once
///   in `init` and again as it is ordered in.
/// - Buried, the window keeps its frame and its screen, and a popover is a child window that takes
///   its parent's level, so it is buried with it and lands where it would on top. A screenshot of a
///   900×110 region over the window and its open popover differed from the same region before by
///   **0** pixels buried, and by 337,681 of 396,000 at the normal level. The wallpaper is not deep
///   enough: it sits at the desktop level minus one.
enum BuriedWindow {

    /// `.minimumWindow` — below the wallpaper and below the display backstop under it.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))

    /// The window is at the buried level — true of a popover too, which takes its parent's.
    static func isBuried(_ window: NSWindow) -> Bool { window.level == level }
}

extension NSWindow {
    /// Buries the window under everything on screen. Call before ordering it in.
    func buryUnderEverything() { level = BuriedWindow.level }
}
