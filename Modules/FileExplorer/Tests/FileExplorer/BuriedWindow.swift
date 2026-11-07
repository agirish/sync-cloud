import AppKit

/// How a fixture window that must be ordered in stays out of the user's sight: it is buried,
/// ordered in at the lowest window level there is, under the display's own opaque backstop.
///
/// Some suites need a window the window server treats as visible (a SwiftUI popover only presents
/// from one), and ordered in at a normal level it would cover whatever the user is doing.
///
/// Buried, not parked off every display:
/// - Off every display a window has no `screen`, so its popover isn't placed against its anchor
///   (the Go to Line field lands at x 0, which `EditorGoToLineFieldTests` checks). AppKit also
///   moves a titled window back onto a display, in `init` and again as it is ordered in.
/// - Buried, the window keeps its frame and screen, and a popover, a child window, takes its
///   parent's level, so it lands where it would on top and draws no visible pixel. The wallpaper
///   isn't deep enough: it sits at the desktop level minus one.
enum BuriedWindow {

    /// `.minimumWindow`: below the wallpaper and the display backstop under it.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))

    /// The window is at the buried level, as is a popover, which takes its parent's.
    static func isBuried(_ window: NSWindow) -> Bool { window.level == level }
}

extension NSWindow {
    /// Buries the window under everything on screen. Call before ordering it in.
    func buryUnderEverything() { level = BuriedWindow.level }
}
