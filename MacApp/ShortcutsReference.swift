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
            Item(keys: "⌘ K", action: "Command palette — go to any place, folder or person"),
            Item(keys: "⌘ I", action: "Show or hide the Info inspector"),
            Item(keys: "⌘ L", action: "Open the Activity Log"),
            Item(keys: "⌘ ,", action: "Open Settings"),
            Item(keys: "⌘ /", action: "Show this shortcuts reference"),
            Item(keys: "⌘ ?", action: "Open the Help book"),
            Item(keys: "⌘ Z / ⇧⌘ Z", action: "Undo / redo the last file operation"),
            Item(keys: "Esc", action: "Close the Settings overlay"),
        ]),
        Group(title: "Panes", items: [
            // Undocumented until the ⌥-reveal work went looking for every real shortcut in the
            // app and found this one had a control, a tooltip and no entry here.
            // First in this group, because it decides which pane every other row here acts on.
            Item(keys: "⌃ ⇥", action: "Focus the other pane — aims ⌘F, ⌘[ / ⌘], ⇧⌘N and ⇧⌘P"),
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
    static let windowSize = CGSize(width: 880, height: 640)

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
/// Two columns of groups, split at the midpoint, because one column of the full reference is
/// taller than a small display. The split is positional, not by name: the pin test already
/// holds the group list, and a fifth group would flow to the left column and simply move the
/// measured height the fits test checks.
struct ShortcutsReferenceContent: View {
    var body: some View {
        let groups = ShortcutsReference.groups
        let mid = (groups.count + 1) / 2
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
