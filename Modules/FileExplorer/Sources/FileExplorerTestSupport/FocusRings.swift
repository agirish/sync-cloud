import AppKit

/// **Where the hosted SwiftUI controls are — one `_FocusRingView` per focusable control.**
///
/// A SwiftUI `Button` with a custom style puts no `NSControl` in the AppKit tree, but AppKit still
/// gives each focusable control a `_FocusRingView` at exactly its frame, so the rings are the
/// only handle a test has on where a control physically is and how many there are. Fifteen test
/// files across FileExplorer and Dashboard walked the tree for them, each with its own copy of the
/// same function (one with three); this is that function.
///
/// Callers filter and sort as their question needs (the topmost row, reading order, sizes) — the
/// walk itself is the part that was copied.
@MainActor
public enum FocusRings {

    /// Every ring under `root`, in depth-first walk order, each frame in `root`'s coordinates.
    public static func frames(in root: NSView) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ view: NSView) {
            if isRing(view) { found.append(view.convert(view.bounds, to: root)) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// How many rings are under `root`.
    public static func count(in root: NSView) -> Int { frames(in: root).count }

    /// Whether `view` is a focus ring — by its class name, which is private.
    public static func isRing(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("_FocusRingView")
    }
}
