import SwiftUI
import AppKit

/// **What this window is looking at, in words** — the pair being compared, or the one source a lens
/// is working.
///
/// The window has no visible title bar (`.windowStyle(.hiddenTitleBar)`), which is why nothing has
/// ever set `NSWindow.title` here beyond the app's own name. But two surfaces read that string
/// whether or not it is drawn — **the Window menu** and **Mission Control** — and both of them
/// have been showing "SyncCloud" for a window that could be on any pair of folders in any cloud.
///
/// Pure and separate from the view so the wording can be asserted directly; `WindowChromeBinder`
/// below is the only thing that touches AppKit.
enum WindowSubtitle {

    /// One pane's location: who it is and where in them.
    struct Source: Equatable {
        /// The provider's display name, or nil when the id resolves to no configured provider —
        /// which is a real state (a provider removed while a tab remembers it), not a defect.
        var provider: String?
        /// The path within that provider's root. Empty at the root.
        var relativePath: String

        init(provider: String?, relativePath: String) {
            self.provider = provider
            self.relativePath = relativePath
        }
    }

    /// The glyph between the two sides. `⇄` and not `↔`: it is the same arrow pair the app already
    /// uses for the swap control, so the two cannot come to mean different things.
    static let pairSeparator = " ⇄ "

    /// One side, as `iCloud/Documents` — or just `iCloud` at its root, where a trailing slash would
    /// claim a folder that is not there.
    ///
    /// Returns nil rather than a placeholder for an unresolved provider: a window named "—" is
    /// worse in the Window menu than a window named after the app.
    static func describe(_ source: Source) -> String? {
        guard let provider = source.provider, !provider.isEmpty else { return nil }
        let path = source.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? provider : "\(provider)/\(path)"
    }

    /// The window's name: both sides on a comparison, the single source on a lens, nil when
    /// neither side resolves.
    ///
    /// **A side that does not resolve drops out rather than making the whole line nil.** A
    /// comparison with one provider removed is still meaningfully "the iCloud/Documents window",
    /// and that is more use in a Window menu than the app's name.
    static func text(mode: TopPaneVisibility.Mode, left: Source, right: Source) -> String? {
        let sides = mode == .compare ? [left, right] : [left]
        let named = sides.compactMap(describe)
        return named.isEmpty ? nil : named.joined(separator: pairSeparator)
    }
}

/// Puts `WindowSubtitle.text` onto the real `NSWindow`.
///
/// **`subtitle` only, and the reason is measured rather than assumed**
/// (`WindowChromeBinderTests.theWindowListEntryComposesTitleAndSubtitle`). The first draft of this
/// set `title` instead, reasoning that a hidden titlebar means `subtitle` is drawn nowhere and
/// therefore read by nothing. AppKit disagrees: it composes the window-list entry as
/// **`"<title> (<subtitle>)"`**, so with the scene's own `Window("SyncCloud", …)` title left alone
/// the Window menu reads
///
///     SyncCloud (iCloud/Documents ⇄ Dropbox/Documents)
///
/// — which names the app *and* the place, and is distinguishable from the scene's opener above it.
/// Setting `title` as well would have produced the pair twice in one entry, in parentheses.
///
/// Clearing it back to `""` is what a window with nothing to say wants: the entry falls back to
/// plain "SyncCloud" rather than keeping a pair that is no longer true.
struct WindowChromeBinder: NSViewRepresentable {
    let subtitle: String?

    func makeNSView(context: Context) -> NSView { Probe(subtitle: subtitle) }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.subtitle = subtitle
    }

    /// A zero-sized view whose only job is to have a `window`.
    ///
    /// The write has to happen in **two** places and neither is sufficient alone: `updateNSView`
    /// runs before the view is in a window on first mount (`view.window` is nil there), and
    /// `viewDidMoveToWindow` runs once and would miss every later change of location.
    final class Probe: NSView {
        var subtitle: String? { didSet { apply() } }

        init(subtitle: String?) {
            self.subtitle = subtitle
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.subtitle = subtitle ?? ""
        }
    }
}
