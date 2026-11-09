import SwiftUI
import AppKit
import Design

/// What a Text Files rail row's context menu can do, each act taking the row's path.
///
/// Most go through the host, because each needs something only the app owns: Browse's pane, the
/// Info inspector, the window's one Quick Look panel, the download that clears the pane's cloud
/// badge, and Browse's rename prompt and delete confirmation. Reveal in Finder is defaulted to the
/// pane row menu's direct call; a test passes its own to watch which path arrives. Built by the host
/// and passed through `EditorWorkspaceView` untouched; the host acts have no defaults, so no
/// construction site can draw the menu wired to nothing.
public struct EditorRailRowActions {
    let revealInBrowse: (String) -> Void
    /// Why Browse can't show a path, or `nil` when it can. Browse shows the left pane's source, so
    /// for a file from Compare's right side or another source, Reveal in Browse would switch and then
    /// leave it unselected. The item is greyed with this line under it; Reveal in Finder still works.
    let revealInBrowseRefusal: (String) -> String?
    let quickLook: (String) -> Void
    let revealInFinder: (String) -> Void
    /// Asks for a cloud-only file's content (Browse's Download); the file opens here if it is the
    /// one Edit was refused.
    let download: (String) -> Void
    /// Browse's Rename and Delete, on this row's file: the same prompt, confirmation and undo.
    let rename: (String) -> Void
    let delete: (String) -> Void

    public init(revealInBrowse: @escaping (String) -> Void,
                revealInBrowseRefusal: @escaping (String) -> String?,
                quickLook: @escaping (String) -> Void,
                download: @escaping (String) -> Void,
                rename: @escaping (String) -> Void,
                delete: @escaping (String) -> Void,
                revealInFinder: @escaping (String) -> Void = EditorRailRowActions.revealInFinder) {
        self.revealInBrowse = revealInBrowse
        self.revealInBrowseRefusal = revealInBrowseRefusal
        self.quickLook = quickLook
        self.download = download
        self.rename = rename
        self.delete = delete
        self.revealInFinder = revealInFinder
    }

    /// Finder, selecting the file: the pane row menu's own call, word for word.
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The same acts with Reveal in Browse sent through another door: the header's file name, whose
    /// reveal logs as the header's rather than a row's.
    func revealing(through reveal: @escaping (String) -> Void) -> EditorRailRowActions {
        EditorRailRowActions(revealInBrowse: reveal, revealInBrowseRefusal: revealInBrowseRefusal,
                             quickLook: quickLook, download: download,
                             rename: rename, delete: delete, revealInFinder: revealInFinder)
    }
}

/// The context menu on a row of the Edit rail's Text Files list, and on the file name above the
/// document: the way back out from any file in the list, not only the open one.
///
/// Dim rows keep the whole menu: a file too large or not downloaded is the one worth revealing,
/// since the editor can't show it. A file still in the cloud adds Download at the top, as Browse
/// offers it.
///
/// Order: Download · Reveal in Browse · Get Info · Reveal in Finder · Quick Look · Rename · Delete,
/// in three groups. Reveal in Browse leads, as Open in Edit leads the pane's row menu; the next
/// three follow that menu's order, titles and glyphs, and Rename and Delete are Browse's, at the
/// bottom. Reveal in Browse is greyed, with the reason, where Browse can't show the file.
///
/// Only Rename and Delete touch the open document, through Browse's own prompt and confirmation:
/// the document follows a rename and says so when its file is gone. Reveal in Browse leaves the
/// buffer as it is, unsaved edits and all.
struct EditorRailRowMenu: View {

    let path: String
    /// Whether the file is still in the cloud: the one fact about the row the menu reads.
    var isCloudOnly: Bool = false
    let actions: EditorRailRowActions

    /// One menu item: its words, its glyph, and the act bound to this row's path.
    struct Item: Identifiable {
        let title: String
        let systemImage: String
        /// Why the item is greyed, drawn as a line under it, or `nil` for a live item.
        var refusal: String? = nil
        var isDestructive = false
        /// Whether a separator comes before it.
        var startsGroup = false
        /// Whether it writes to disk, and so waits while a long run is going.
        var writes = false
        let perform: () -> Void
        var id: String { title }
    }

    /// The items, in drawn order, each already bound to `path`.
    ///
    /// A function rather than `Button`s in a body, so a test can assert the order, the words, the
    /// groups, and that every act gets this row's path; a hosted menu doesn't allow that. The body
    /// draws exactly this list.
    static func items(for path: String, isCloudOnly: Bool = false,
                      actions: EditorRailRowActions) -> [Item] {
        var items: [Item] = []
        if isCloudOnly {
            items.append(Item(title: "Download", systemImage: "icloud.and.arrow.down",
                              perform: { actions.download(path) }))
        }
        items += [
            Item(title: "Reveal in Browse", systemImage: "folder",
                 refusal: actions.revealInBrowseRefusal(path), startsGroup: isCloudOnly,
                 perform: { actions.revealInBrowse(path) }),
            Item(title: "Reveal in Finder", systemImage: RevealGlyph.inFinder,
                 perform: { actions.revealInFinder(path) }),
            Item(title: "Quick Look", systemImage: "doc.viewfinder",
                 perform: { actions.quickLook(path) }),
            Item(title: "Rename", systemImage: "pencil", startsGroup: true, writes: true,
                 perform: { actions.rename(path) }),
            Item(title: "Move to Trash…", systemImage: "trash", isDestructive: true, writes: true,
                 perform: { actions.delete(path) }),
        ]
        return items
    }

    /// The header name's tooltip: the whole name, which the header truncates in the middle, and the
    /// menu behind it, its acts in the menu's own order.
    static func nameTooltip(_ name: String) -> String {
        "“\(name)” — right-click to reveal or rename"
    }

    var body: some View {
        ForEach(Self.items(for: path, isCloudOnly: isCloudOnly, actions: actions)) { item in
            if item.startsGroup { Divider() }
            Button(role: item.isDestructive ? .destructive : nil, action: item.perform) {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(item.refusal != nil)
            .lockedDuringRun(item.writes)
            // A menu draws a `Text` as a greyed line of its own: the reason, under the item.
            if let refusal = item.refusal { Text(refusal) }
        }
    }
}
