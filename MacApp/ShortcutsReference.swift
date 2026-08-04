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
            Item(keys: "⌘ ,", action: "Open Settings"),
            Item(keys: "⌘ /", action: "Show this shortcuts reference"),
            Item(keys: "⌘ Z / ⇧⌘ Z", action: "Undo / redo the last file operation"),
            Item(keys: "Esc", action: "Close the Settings overlay"),
        ]),
        Group(title: "Panes", items: [
            // Undocumented until the ⌥-reveal work went looking for every real shortcut in the
            // app and found this one had a control, a tooltip and no entry here.
            Item(keys: "⌘ F", action: "Find a file or folder in this pane"),
            Item(keys: "Space", action: "Quick Look the selected item"),
            Item(keys: "⌘-click / ⇧-click", action: "Select multiple items"),
            Item(keys: "⌥-click a breadcrumb", action: "Navigate both panes to that folder"),
        ]),
        Group(title: "Differences", items: [
            Item(keys: "⌘ → / ⌘ ←", action: "Copy the selected differences to the right / left pane"),
            Item(keys: "⇧⌘ → / ⇧⌘ ←", action: "Move the selected differences to the right / left pane"),
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
            .keyboardShortcut("/", modifiers: .command)
    }
}

/// The Help-menu shortcuts window: three titled groups of key/action rows. Static content,
/// sized to fit — no state beyond what `ShortcutsReference` provides.
struct ShortcutsReferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ShortcutsReference.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .scaledFont(.headline)
                        ForEach(group.items, id: \.action) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.keys)
                                    .scaledFont(.system(.callout, design: .monospaced).weight(.medium))
                                    .frame(width: 190, alignment: .leading)
                                Text(item.action)
                                    .scaledFont(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 420)
        .navigationTitle("Keyboard Shortcuts")
    }
}
