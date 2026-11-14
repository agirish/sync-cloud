/// The pane-relationship glyphs, in one place so their sites can't drift apart (the link toggle in
/// Dashboard, the Compare button and pre-scan empty state in the app).
///
/// `public` is load-bearing: this crosses module boundaries, and an internal symbol passes
/// `swift test` but breaks the xcodebuild app build.
public enum PaneGlyph {
    /// The breadcrumb "link both panes" sticky toggle — a chain, not arrows.
    public static let linkBothPanes = "link"
    /// "Compare these two panes": the toolbar Compare button and the pre-scan empty-state icon
    /// share this deliberately — one glyph, one verb.
    public static let compare = "rectangle.split.2x1"
}
