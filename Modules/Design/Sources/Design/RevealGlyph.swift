/// Single source of truth for the "Reveal in Finder" glyph. Reveal actions appear in the
/// Dashboard details sidebar, the tree right-click menu, the Differences row menu, and the
/// Tidy group card, so the constant lives here in Design — the one module both Dashboard and
/// FileExplorer already import.
///
/// The magnifier (`magnifyingglass`) is reserved for SEARCH (the Differences search toggle,
/// the log viewer's search field); using it for Reveal too made one glyph mean two different
/// verbs. Reveal is instead the outward box-arrow, SF Symbols' "take me out of this app to
/// the thing" shape.
///
/// `public` is load-bearing: this crosses module boundaries, and an internal symbol passes
/// `swift test` but breaks the xcodebuild app build.
public enum RevealGlyph {
    /// Reveal the item in Finder.
    public static let inFinder = "arrow.up.forward.square"
}
