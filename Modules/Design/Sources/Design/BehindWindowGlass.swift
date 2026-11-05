import SwiftUI
import AppKit

/// Clears the hosting window's opacity and paints a behind-window vibrancy layer, so the desktop
/// reads through the app as it does through Control Center.
///
/// The only way `GlassLevel.clear` can look clear: the window is otherwise a stock opaque SwiftUI
/// window, so glass over it has only a flat wash behind it. At `.frosted` and `.solid` this view
/// is inert (see `isEnabled`). The accepted cost: at `.clear` the app looks like its wallpaper.
struct BehindWindowGlass: NSViewRepresentable {
    /// When false the layer hides and the window gets its opacity back, so leaving `.clear` doesn't
    /// strand it transparent.
    let isEnabled: Bool

    /// How much of the blur layer to composite, 0...1: whether Clear reads as frost or glass. At 1
    /// the material is near opaque in light; at 0 the desktop shows unblurred. The window stays
    /// transparent either way; `LiquidGlass.clearVibrancyAlpha` says why Clear sits just under 1.
    var vibrancyAlpha: Double = 1.0

    /// The behind-window material. `.underWindowBackground` everywhere but None in light, which
    /// takes `LiquidGlass.clearNoneLightMaterial` (see it, and `makeNSView` for why this one).
    var material: NSVisualEffectView.Material = .underWindowBackground

    /// Carries the desired window transparency across the gap where `view.window` is still nil.
    /// A deferred write that bails on a nil window can lose the launch-time value, leaving a stored
    /// `.clear` window opaque until the setting is touched; `viewDidMoveToWindow` re-applies it.
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
            // AppKit's layout can overwrite window flags set during a SwiftUI update, so defer a
            // tick. `viewDidMoveToWindow` covers a block that runs before the view is windowed.
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
        // Not `.hudWindow`: it is more see-through but applies vibrancy to the content on top,
        // bleaching the folder icons. No layer at all leaves the file list unreadable.
        view.material = .underWindowBackground
        // `.followsWindowActiveState` would drop the vibrancy whenever the window loses key,
        // which reads as the glass "switching off" every time you tab away.
        view.state = .active
        return view
    }

    func updateNSView(_ view: Backing, context: Context) {
        if view.material != material { view.material = material }
        // Alpha 0 hides the layer entirely but keeps the window transparent.
        view.isHidden = !isEnabled || vibrancyAlpha <= 0
        view.alphaValue = vibrancyAlpha
        view.wantsTransparentWindow = isEnabled
    }
}

/// A within-window blur: it blurs what the window draws behind it, as `BehindWindowGlass` blurs the
/// desktop. A floating panel over the window uses it to take the window's own glass — see
/// `LiquidGlass.panelTakesWindowGlass`.
struct WithinWindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
    }
}
