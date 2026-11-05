/// The "Reveal in Finder" glyph, shared by Dashboard's details sidebar, the tree's right-click
/// menu, the Differences row menu and the Duplicates group card. It lives in Design, the one module
/// both Dashboard and FileExplorer import.
///
/// The magnifier (`magnifyingglass`) is reserved for search, so one glyph never means two verbs;
/// Reveal is the outward box-arrow.
///
/// `public` is load-bearing: this crosses module boundaries, and an internal symbol passes
/// `swift test` but breaks the xcodebuild app build.
public enum RevealGlyph {
    /// Reveal the item in Finder.
    public static let inFinder = "arrow.up.forward.square"
}
