/// Single source of truth for the pane-relationship glyphs split apart in UX 1.2, where three
/// unrelated features used to share the ⇄ arrows. The ⇄ arrows are now reserved for swap-panes;
/// these constants pin what the other two features use instead, so the sites can't drift apart
/// (the link toggle lives in Dashboard, the Compare button and pre-scan empty state in the app).
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
