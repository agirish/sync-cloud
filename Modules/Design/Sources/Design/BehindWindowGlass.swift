import SwiftUI
import AppKit

/// Clears the hosting window's opacity and paints a behind-window vibrancy layer, so the desktop
/// reads through the app the way it does through Control Center or Notification Center.
///
/// This is the only way `GlassLevel.clear` can look clear. SyncCloud's window is otherwise a stock
/// opaque SwiftUI window (`.windowStyle(.hiddenTitleBar)` and nothing else), so the "glass" had
/// nothing behind it but a flat wash — turning frost off just revealed more flat colour, which is
/// why Clear and Frosted were hard to tell apart. Glass only reads as glass when there is
/// something behind it worth seeing.
///
/// Only `.clear` uses this: at `.frosted` and `.solid` the window stays opaque, and this view is
/// inert (see `isEnabled`). Trade-off accepted deliberately — at `.clear` the app's appearance is
/// no longer its own, it's whatever the wallpaper behind it happens to be.
struct BehindWindowGlass: NSViewRepresentable {
    /// When false this is inert: the layer hides and the window is handed back its opacity, so
    /// switching off `.clear` restores the normal window rather than stranding it transparent.
    let isEnabled: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // `.underWindowBackground` over the alternatives: `.hudWindow` is more see-through but
        // applies its own vibrancy to the content on top, bleaching the folder icons from blue to
        // pale outlines; no layer at all leaves the desktop unblurred and the file list unusable.
        view.material = .underWindowBackground
        // `.followsWindowActiveState` would drop the vibrancy whenever the window loses key,
        // which reads as the glass "switching off" every time you tab away.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isHidden = !isEnabled
        let enabled = isEnabled
        // `view.window` is nil while the view is being made, and window flags set during a SwiftUI
        // update pass are liable to be overwritten by AppKit's own layout — so defer a tick.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !enabled
            window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        }
    }
}
