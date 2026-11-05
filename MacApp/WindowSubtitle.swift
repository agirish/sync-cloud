import SwiftUI
import AppKit

/// What this window is looking at, in words: the pair being compared, or the one source a lens is
/// working.
///
/// The title bar is hidden, but the Window menu and Mission Control still read the window's name,
/// and "SyncCloud" alone says nothing about which folders it is on. Pure, so the wording can be
/// asserted directly; `WindowChromeBinder` below is the only thing that touches AppKit.
enum WindowSubtitle {

    /// One pane's location: who it is and where in them.
    struct Source: Equatable {
        /// The provider's display name, or nil when the id resolves to no configured provider, a
        /// real state (a provider removed while a tab remembers it).
        var provider: String?
        /// The path within that provider's root. Empty at the root.
        var relativePath: String

        init(provider: String?, relativePath: String) {
            self.provider = provider
            self.relativePath = relativePath
        }
    }

    /// The glyph between the two sides: `⇄`, the arrow pair the swap control already uses, so the
    /// two cannot come to mean different things.
    static let pairSeparator = " ⇄ "

    /// One side, as `iCloud/Documents`, or just `iCloud` at its root. Nil, not a placeholder, for an
    /// unresolved provider: a window named after the app beats one named "—".
    static func describe(_ source: Source) -> String? {
        guard let provider = source.provider, !provider.isEmpty else { return nil }
        let path = source.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? provider : "\(provider)/\(path)"
    }

    /// The window's name: both sides on a comparison, the single source on a lens, nil when
    /// neither side resolves. A side that does not resolve drops out, since one named side is more
    /// use in the Window menu than the app's name.
    static func text(mode: TopPaneVisibility.Mode, left: Source, right: Source) -> String? {
        let sides = mode == .compare ? [left, right] : [left]
        let named = sides.compactMap(describe)
        return named.isEmpty ? nil : named.joined(separator: pairSeparator)
    }
}

/// Puts `WindowSubtitle.text` onto the real `NSWindow`.
///
/// Sets `subtitle` only. AppKit composes the window-list entry as `"<title> (<subtitle>)"`
/// (`WindowChromeBinderTests.theWindowListEntryComposesTitleAndSubtitle`), so with the scene's own
/// title left alone the Window menu reads
///
///     SyncCloud (iCloud/Documents ⇄ Dropbox/Documents)
///
/// Setting `title` too would show the pair twice. With nothing to say it clears to `""`, and the
/// entry falls back to plain "SyncCloud".
struct WindowChromeBinder: NSViewRepresentable {
    let subtitle: String?

    func makeNSView(context: Context) -> NSView { Probe(subtitle: subtitle) }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.subtitle = subtitle
    }

    /// A zero-sized view whose only job is to have a `window`. The write happens in two places,
    /// neither enough alone: on first mount `updateNSView` runs before there is a window, and
    /// `viewDidMoveToWindow` runs once and would miss every later change.
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
