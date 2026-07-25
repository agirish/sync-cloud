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

    /// How much of the blur layer to composite, 0...1. This is the knob that decides whether Clear
    /// reads as frost or as glass — at 1 the material is effectively opaque in light, at 0 the
    /// desktop reaches the screen unblurred. The window stays transparent either way; see
    /// `LiquidGlass.clearVibrancyAlpha` for why Clear settles just under 1.
    var vibrancyAlpha: Double = 1.0

    /// Carries the desired window transparency across the gap where `view.window` is still nil.
    /// A plain `updateNSView` that defers a tick and bails on a nil window drops the launch-time
    /// application entirely when the deferred block outruns window attachment — with `.clear`
    /// stored and no later state change, the window would stay opaque until the user next
    /// touched the setting. `viewDidMoveToWindow` re-applies whatever was last requested.
    final class Backing: NSVisualEffectView {
        var wantsTransparentWindow = false {
            didSet { applyWindowFlags() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowFlags()
        }

        private func applyWindowFlags() {
            let transparent = wantsTransparentWindow
            // Window flags set during a SwiftUI update pass are liable to be overwritten by
            // AppKit's own layout — so defer a tick. `viewDidMoveToWindow` above catches the
            // case where this block runs before the view is windowed.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                window.isOpaque = !transparent
                window.backgroundColor = transparent ? .clear : .windowBackgroundColor
            }
        }
    }

    func makeNSView(context: Context) -> Backing {
        let view = Backing()
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

    func updateNSView(_ view: Backing, context: Context) {
        // Alpha 0 hides the layer entirely but keeps the window transparent.
        view.isHidden = !isEnabled || vibrancyAlpha <= 0
        view.alphaValue = vibrancyAlpha
        view.wantsTransparentWindow = isEnabled
    }
}
