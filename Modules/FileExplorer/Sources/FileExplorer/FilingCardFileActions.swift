import SwiftUI
import Sync
import Design

/// A card button folded into the action line's ⋯ when the line runs out of room.
struct FilingFoldedItem: Identifiable {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
    var id: String { title }
}

/// The right half of a card's action line (cards mockup v8): what looks at a file or removes it.
/// Open Folder always; Quick Look and Move to Trash for one file only, the single file's card or a
/// group's selected row, so a whole account never goes to the Trash in one click; then ⋯.
///
/// `folded` puts Open Folder, Quick Look and Trash into ⋯, and `foldedItems` adds the left half's
/// buttons the line had no room for, so the line stays one line at every width.
struct FilingCardFileActions: View {
    /// The file the buttons act on: the card's one file, or its selected row. nil on a group card
    /// with nothing selected.
    let target: FilingSuggestion?
    /// The folder the card's files came from, for Open Folder with no file selected.
    let folder: String
    /// Where they go, when that folder is already there.
    let destinationFolder: String?
    let hooks: FilingFileRowsHooks
    var folded = false
    var foldedItems: [FilingFoldedItem] = []

    /// The words on the buttons and in ⋯, apart so they can be tested.
    static func menuActions(target: FilingSuggestion?, folded: Bool) -> [FilingFileAction] {
        guard target != nil else { return folded ? [.openFolder, .openDestinationFolder] : [.openDestinationFolder] }
        let looks: [FilingFileAction] = folded ? [.quickLook, .open, .reveal, .openFolder, .openDestinationFolder]
                                               : [.open, .reveal, .openDestinationFolder]
        return looks + [.copyPath, .copyDestinationPath] + (folded ? [.trash] : [])
    }

    var body: some View {
        HStack(spacing: 6) {
            if !folded {
                Button(action: openFolder) { Label("Open Folder", systemImage: "folder") }
                    .labelStyle(.iconOnly)
                    .help(target == nil ? "Open the folder these came from" : "Open the folder it came from")
                    .accessibilityLabel("Open Folder")
                if let target {
                    Button { hooks.perform(.quickLook, target) } label: {
                        HStack(spacing: 5) {
                            Text("Quick Look")
                            Text("Space").scaledFont(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .help("Quick Look “\(target.fileName)” (Space or ⌘Y)")
                    .accessibilityLabel("Quick Look")
                    .disabled(!hooks.isEnabled(.quickLook, target))
                    Button { hooks.perform(.trash, target) } label: { Label("Move to Trash", systemImage: "trash") }
                        .labelStyle(.iconOnly)
                        .help("Move “\(target.fileName)” to the Trash — ⌘Z puts it back")
                        .accessibilityLabel("Move \(target.fileName) to the Trash")
                        .disabled(!hooks.isEnabled(.trash, target))
                }
            }
            more
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func openFolder() {
        if let target { hooks.perform(.openFolder, target) } else { hooks.openFolder(folder) }
    }

    private var more: some View {
        Menu {
            ForEach(Self.menuActions(target: target, folded: folded)) { action in
                if action == .trash { Divider() }
                if let target {
                    Button(role: action == .trash ? .destructive : nil) { hooks.perform(action, target) } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(!hooks.isEnabled(action, target))
                } else if action == .openFolder {
                    Button { hooks.openFolder(folder) } label: { Label(action.title, systemImage: action.systemImage) }
                } else if let destinationFolder {
                    Button { hooks.openFolder(destinationFolder) } label: { Label(action.title, systemImage: action.systemImage) }
                }
            }
            if !foldedItems.isEmpty {
                Divider()
                ForEach(foldedItems) { item in
                    Button(action: item.action) { Label(item.title, systemImage: item.systemImage) }
                        .disabled(!item.isEnabled)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
