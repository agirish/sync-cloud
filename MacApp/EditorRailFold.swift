import FileExplorer

/// **Edit's Text Files / Outline list, folded into the strip by hand** (TE77, asked 2026-10-16).
///
/// Edit drew four columns side by side — the sidebar, the file pane's strip, this list and the
/// text — and the list was the one of them nothing could put away on its own: only Expand hid it,
/// and Expand takes the pane and the sidebar with it. Folded, the list becomes two buttons in the
/// pane's strip, one per tab, so it never adds a second strip beside the first.
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

    /// One rule for both buttons. `railDrawn` is the list as drawn — folded by hand, put away by
    /// Expand, or yielding to an open pane all read as not drawn, and the strip is only on screen
    /// while the pane is folded, so in practice "not drawn" means one of the first two.
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
        case .fold: return tab == .files ? "Hide the text files" : "Hide the outline"
        case .show, .switchTo: return tab == .files ? "Show the text files" : "Show the outline"
        }
    }
}
