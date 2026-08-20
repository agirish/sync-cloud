import Design
import SwiftUI

/// The static keyboard/mouse shortcut listing behind Help → Keyboard Shortcuts (⌘/).
/// Pure data, pinned by SyncCloudTests so the reference can't silently drift from reality —
/// when a shortcut is added or changed, update this list and the pin test together.
enum ShortcutsReference {
    struct Item: Equatable {
        let keys: String
        let action: String
    }

    struct Group: Equatable {
        let title: String
        let items: [Item]
    }

    /// Where to break `groups` into two columns so their row counts come out closest.
    ///
    /// Counts a header as a row, because it occupies one. Never returns 0 or `count`, so both
    /// columns hold something even for a degenerate list.
    static func balancedSplit(_ groups: [Group]) -> Int {
        guard groups.count > 1 else { return groups.count }
        let weights = groups.map { $0.items.count + 1 }
        let total = weights.reduce(0, +)
        var running = 0
        var best = 1
        var bestGap = Int.max
        for index in 1..<groups.count {
            running += weights[index - 1]
            let gap = abs(running - (total - running))
            if gap < bestGap { bestGap = gap; best = index }
        }
        return best
    }

    static let groups: [Group] = [
        Group(title: "General", items: [
            // First, because it is the one entry that teaches all the others: hold it and the
            // shortcuts below appear on the controls themselves. A reference nobody opens can't
            // do that, which is the whole reason the reveal exists.
            Item(keys: "Hold ⌥", action: "Show every on-screen shortcut as a key badge"),
            // Derived from the bar rather than typed, because the bar has changed length three
            // times and this row is the kind of thing that stays behind: it read "⌘ 1 – ⌘ 5" for a
            // whole commit after the bar dropped to three segments, promising two chords that do
            // nothing. `ShortcutsReferenceTests` pins the derived string against the enum.
            Item(keys: "⌘ 1 – ⌘ \(Workspace.allCases.count)",
                 action: "Switch workspace, in the bar's order"),
            // Second: it is the one shortcut that can reach a place not currently on screen — a
            // workspace, one of Organize's lenses, a folder, a person, or an action — so it is
            // the entry that makes the rest of this list optional. (Unnumbered on purpose: the
            // count above is derived for exactly this reason, and Names folding into Renames took
            // the rail from six to five.)
            Item(keys: "⌘ K", action: "Go to — any place, folder, person, or a typed path"),
            Item(keys: "⌘ I", action: "Show or hide the Info inspector"),
            Item(keys: "⌘ L", action: "Open the Activity Log"),
            Item(keys: "⌘ ,", action: "Open Settings"),
            Item(keys: "⌘ /", action: "Show this shortcuts reference"),
            Item(keys: "⌘ ?", action: "Open SyncCloud Help"),
            Item(keys: "⌘ Z / ⇧⌘ Z", action: "Undo / redo the last file operation"),
            // The file clipboard, not the text one — though each of these four hands the keystroke
            // back to the caret when a text field has it (`TextEditingChord`).
            Item(keys: "⌘ A", action: "Select everything in the focused pane's current folder"),
            Item(keys: "⌘ C / ⌘ X / ⌘ V", action: "Copy or cut files, then paste — cut then paste is a move"),
            Item(keys: "Esc", action: "Close the Settings overlay"),
        ]),
        Group(title: "Panes", items: [
            // Undocumented until the ⌥-reveal work went looking for every real shortcut in the
            // app and found this one had a control, a tooltip and no entry here.
            // First in this group, because it decides which pane every other row here acts on.
            // "In Compare" is load-bearing, not padding: this chord is the pane switch only where
            // there are two panes, and in Browse it steps tabs instead. The Tabs group below states
            // the split from the other side; leaving this row unqualified made one of the two wrong
            // wherever the reader happened to be.
            Item(keys: "⌃ ⇥", action: "In Compare, focus the other pane — aims ⌘F, ⌘[ / ⌘], ⇧⌘N and ⇧⌘P"),
            Item(keys: "⌘ F", action: "Find a file or folder in this pane"),
            Item(keys: "⌘ [ / ⌘ ]", action: "Back / forward in the focused pane"),
            Item(keys: "⌘ R", action: "Scan both panes for changes"),
            Item(keys: "⇧⌘ N", action: "New folder in the focused pane's current folder"),
            Item(keys: "⇧⌘ .", action: "Show or hide hidden files"),
            Item(keys: "⇧⌘ P", action: "Show or hide the Columns preview"),
            Item(keys: "⌘ ⌫", action: "Delete the selected items, after confirming"),
            Item(keys: "Space", action: "Quick Look the selected item"),
            Item(keys: "⌘-click / ⇧-click", action: "Select multiple items"),
            Item(keys: "⌥-click a breadcrumb", action: "Navigate both panes to that folder"),
        ]),
        Group(title: "Tabs", items: [
            Item(keys: "⌘ T", action: "New tab, at the folder this pane is showing"),
            Item(keys: "⌘ W", action: "Close the tab — or the window, on the last one"),
            Item(keys: "⇧⌘ ] / ⇧⌘ [", action: "Next / previous tab"),
            // The split is stated, because one chord doing two things is exactly what a reference
            // is for: ⌃⇥ has always been the pane switch, and Browse has one pane for it to switch
            // between. The Go menu's item names whichever it will do.
            Item(keys: "⌃ ⇥", action: "Next tab in Browse — the other pane in Compare"),
            Item(keys: "⇧⌘ T", action: "Show or hide the tab bar"),
            Item(keys: "Right-click a folder", action: "Open that folder in a new tab"),
            Item(keys: "⌘-double-click a folder", action: "Open it in a new tab, in Columns"),
            // ⌘1…⌘9 are the workspaces', and a reader coming from Finder or Safari will try them.
            Item(keys: "⌘ 1 – ⌘ \(Workspace.allCases.count)", action: "Switch workspace — never tabs"),
        ]),
        Group(title: "Differences", items: [
            Item(keys: "⌘ → / ⌘ ←", action: "Copy the selected differences to the right / left pane"),
            Item(keys: "⇧⌘ → / ⇧⌘ ←", action: "Move the selected differences to the right / left pane"),
            Item(keys: "⇧⌘ R", action: "Step through each difference (Review)"),
            Item(keys: "⇧⌘ V", action: "Verify date-only differences by checksum"),
            Item(keys: "⌘ D", action: "Show or hide the differences list"),
            Item(keys: "⇧⌘ F", action: "Collapse or expand all folders"),
            Item(keys: "Space", action: "Quick Look the selected difference"),
        ]),
        Group(title: "Guided review", items: [
            Item(keys: "Return", action: "Copy the current item"),
            Item(keys: "Delete", action: "Skip the current item"),
            Item(keys: "Space", action: "Quick Look the current item"),
            Item(keys: "Esc", action: "End the review"),
        ]),
    ]
}

/// The Help-menu item that opens the shortcuts window. A separate View (not inline in the
/// `.commands` builder) because `openWindow` is an Environment value, which the App struct
/// itself doesn't carry.
struct ShortcutsWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
            .keyboardShortcut(AppChord.shortcutsReference.key, modifiers: AppChord.shortcutsReference.modifiers)
    }
}

/// The Help-menu shortcuts window: titled groups of key/action rows. Static content,
/// sized to fit — no state beyond what `ShortcutsReference` provides.
struct ShortcutsReferenceView: View {
    /// The window is `.contentSize`-resizable — the user cannot enlarge it — so this frame has
    /// to show the whole reference. The single 480pt column fit the sixteen rows it opened
    /// with; the twelve menu-bar chords took it to twenty-nine, which is 865pt of column —
    /// taller than a MacBook Air's screen — so the content went to two columns instead.
    /// `theReferenceFitsItsWindowWithoutScrolling` measures the laid-out content against this
    /// number, so a future row can move it but never silently overflow it; the ScrollView stays
    /// for the larger Settings ▸ Text sizes, which is all it is for.
    ///
    /// **560 → 600 when ⌘K was added.** The palette's row went into General, which is in the taller
    /// left column, and the content measured 593pt — the test caught it, which is exactly what it
    /// is for. Raising the window is the right half of its "raise windowSize or trim rows": every
    /// row here documents a chord that exists, so trimming would mean hiding one. 600pt still fits
    /// a 13" display's usable height with room to spare.
    ///
    /// **600 → 640 when ⌘? was listed.** Same column, same story, and the test caught it the same
    /// way: the content went to 614pt the moment the Help chord got the row it should always have
    /// had. 640 keeps a comparable margin and still clears a 13" display's usable height.
    ///
    /// **640 → 720 when the file clipboard arrived** (⌘A / ⌘X / ⌘C / ⌘V, §10). Four chords, and the
    /// test caught it the same way for the third time — three rows measured 707pt, so they were
    /// tightened to two and the content settled at **686pt measured**. 720 keeps a 34pt margin,
    /// comparable to the 26pt the last raise left, and still clears a 13" display. The pattern is
    /// worth naming now that it has repeated three times: **this window grows by chords, and the
    /// test is the only thing that notices** — nothing about the reference looks wrong until it is
    /// scrolled, and it is not scrollable.
    static let windowSize = CGSize(width: 880, height: 720)

    var body: some View {
        ScrollView {
            ShortcutsReferenceContent()
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .navigationTitle("Keyboard Shortcuts")
    }
}

/// The rows themselves, split from the ScrollView so the fits-the-window test can measure their
/// laid-out height — a ScrollView reports whatever frame it is given, never its content's size.
///
/// Two columns of groups, because one column of the full reference is taller than a small display.
///
/// **Split where the ROWS balance, not at the middle of the list.** It was the midpoint, and a
/// fifth group broke it: three groups landed left and two right, giving a 29-row column against a
/// 15-row one and a content height of 918pt against a 640pt window — the exact failure
/// `theReferenceFitsItsWindowWithoutScrolling` exists to catch, on a window the user cannot
/// enlarge. Balancing by row count keeps the reading order (General, Panes, Tabs, …) and puts the
/// break wherever the two columns come out closest, so a sixth group cannot reintroduce it.
struct ShortcutsReferenceContent: View {
    var body: some View {
        let groups = ShortcutsReference.groups
        let mid = ShortcutsReference.balancedSplit(groups)
        HStack(alignment: .top, spacing: 32) {
            column(Array(groups[..<mid]))
            column(Array(groups[mid...]))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ groups: [ShortcutsReference.Group]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .scaledFont(.headline)
                    ForEach(group.items, id: \.action) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.keys)
                                .scaledFont(.system(.callout, design: .monospaced).weight(.medium))
                                .frame(width: 165, alignment: .leading)
                            Text(item.action)
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
