import FileExplorer

/// **Edit's Files / Outline list, folded into the strip by hand** (TE77, asked 2026-10-16).
///
/// Edit drew four columns side by side — the sidebar, the file pane's strip, this list and the
/// text — and the list was the one of them nothing could put away on its own: only Expand hid it,
/// and Expand takes the pane and the sidebar with it. Folded, the list becomes buttons in the
/// pane's strip, one per tab — three with a PDF open — so it never adds a second strip beside the
/// first.
///
/// The bit is `ContentView.editorRailFolded`; ``TopPaneVisibility/editorRailIsDrawn(paneHidden:railHidden:railFolded:)``
/// reads it. This type is the strip buttons' rule, kept pure so a test can walk it without a window.
enum EditorRailFold {

    /// What a strip button does when clicked.
    enum RungAct: Equatable {
        /// The list is not on screen: bring it back, on this tab.
        case show(EditorRailTab)
        /// The list is showing this tab already: the lit button folds it, as a second click on a
        /// toolbar toggle does.
        case fold
        /// The list is showing the other tab: switch to this one and leave it open.
        case switchTo(EditorRailTab)
    }

    /// One rule for every list button. `railDrawn` is the list as drawn — folded by hand, put away
    /// by Expand, or yielding to an open pane all read as not drawn. **The strip is beside an open
    /// pane too** (asked 2026-10-17), so "not drawn" can mean the pane is showing; `.show` then
    /// folds the pane on its way, because the pane and the list are never on screen together.
    static func rungAct(for tab: EditorRailTab, railDrawn: Bool, currentTab: EditorRailTab) -> RungAct {
        guard railDrawn else { return .show(tab) }
        return currentTab == tab ? .fold : .switchTo(tab)
    }

    /// Whether a strip button is lit: the list is on screen, on that button's tab. So the strip
    /// also says which half of the list is showing.
    static func rungIsLit(_ tab: EditorRailTab, railDrawn: Bool, currentTab: EditorRailTab) -> Bool {
        railDrawn && currentTab == tab
    }

    /// The button's tooltip and VoiceOver label — its next act, as the Expand button's word is.
    static func rungTitle(_ tab: EditorRailTab, railDrawn: Bool, currentTab: EditorRailTab) -> String {
        switch rungAct(for: tab, railDrawn: railDrawn, currentTab: currentTab) {
        case .fold: return "Hide the \(noun(tab))"
        case .show, .switchTo: return "Show the \(noun(tab))"
        }
    }

    // MARK: - The pane's button

    /// What the pane's button does (asked 2026-10-17): **the pane is one of the strip's columns**,
    /// lit while it shows, and the lit button folds it — the list buttons' rule, so the strip has
    /// one. Opening it takes the list's place; see `ContentView.runEditorPaneRung`.
    enum PaneRungAct: Equatable {
        case openPane
        case foldPane
    }

    static func paneRungAct(paneOpen: Bool) -> PaneRungAct {
        paneOpen ? .foldPane : .openPane
    }

    /// The pane button's tooltip and VoiceOver label — its next act, as the list buttons' are.
    static func paneRungTitle(paneOpen: Bool, source: String) -> String {
        paneOpen ? "Hide the \(source) pane" : "Show the \(source) pane to browse folders"
    }

    /// What a strip button names: the tab's half of the list.
    static func noun(_ tab: EditorRailTab) -> String {
        switch tab {
        case .files: return "files"
        case .pages: return "pages"
        case .outline: return "outline"
        }
    }
}
