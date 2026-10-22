import SwiftUI
import AppKit
import Design

/// What a Text Files rail row's context menu can do, each act taking the ROW's path.
///
/// **Most leave through the host**, because each needs something only the app owns: Browse's pane,
/// the Info inspector, the window's one Quick Look panel, the download that clears the pane's cloud
/// badge, and the rename prompt and delete confirmation Browse's own menu goes through. Reveal in
/// Finder does not — it hands the file to Finder the same direct way the pane's row menu does — so
/// it is defaulted to that, and a test passes its own to watch which path arrives.
///
/// **Built by the host and handed to `EditorWorkspaceView` whole**, which passes it to the rail
/// untouched. The host acts have no defaults, so a construction site cannot draw the menu wired to
/// nothing — the property the workspace's three separate closures used to carry.
public struct EditorRailRowActions {
    let revealInBrowse: (String) -> Void
    /// **Why Browse cannot show a path, or `nil` when it can** (TE116). Browse shows the left
    /// pane's source, so a file opened from Compare's right side, or from another source, is one
    /// Reveal in Browse would switch to and then leave unselected. The item is greyed for those,
    /// with this line under it; Reveal in Finder still reaches them.
    let revealInBrowseRefusal: (String) -> String?
    let getInfo: (String) -> Void
    let quickLook: (String) -> Void
    let revealInFinder: (String) -> Void
    /// Asks for a cloud-only file's content — Browse's Download (TE96), and the file opens here if
    /// it is the one Edit was refused.
    let download: (String) -> Void
    /// Browse's Rename and Delete, on this row's file (TE117, decided AY): the same prompt, the
    /// same confirmation, the same undo.
    let rename: (String) -> Void
    let delete: (String) -> Void

    public init(revealInBrowse: @escaping (String) -> Void,
                revealInBrowseRefusal: @escaping (String) -> String?,
                getInfo: @escaping (String) -> Void,
                quickLook: @escaping (String) -> Void,
                download: @escaping (String) -> Void,
                rename: @escaping (String) -> Void,
                delete: @escaping (String) -> Void,
                revealInFinder: @escaping (String) -> Void = EditorRailRowActions.revealInFinder) {
        self.revealInBrowse = revealInBrowse
        self.revealInBrowseRefusal = revealInBrowseRefusal
        self.getInfo = getInfo
        self.quickLook = quickLook
        self.download = download
        self.rename = rename
        self.delete = delete
        self.revealInFinder = revealInFinder
    }

    /// Finder, selecting the file — the pane row menu's own call, word for word.
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The same acts with Reveal in Browse sent through another door — the header's file name
    /// (TE112), whose reveal logs as the header's rather than a row's.
    func revealing(through reveal: @escaping (String) -> Void) -> EditorRailRowActions {
        EditorRailRowActions(revealInBrowse: reveal, revealInBrowseRefusal: revealInBrowseRefusal,
                             getInfo: getInfo, quickLook: quickLook, download: download,
                             rename: rename, delete: delete, revealInFinder: revealInFinder)
    }
}

/// The context menu on a row of the Edit rail's Text Files list — and, the same menu, on the file
/// name above the document (TE112).
///
/// **The way back out, from any file in the list — not only the open one.** The rail's rows had no
/// menu, so the only reverse verb in Edit was the header filename's one-item menu, which can only
/// ever name the document already open. A file you are about to open, or one the editor refuses,
/// had no way to be looked at anywhere else.
///
/// **Dim rows keep the whole menu.** A file too large to read or not yet downloaded is exactly the
/// one worth revealing or inspecting — the editor cannot show it, so somewhere else has to. The one
/// thing a row's state adds is **Download, at the top, for a file still in the cloud** (TE96):
/// Browse offers it on the same file, and in Edit it was a dead end.
///
/// **Order: Download · Reveal in Browse · Get Info · Reveal in Finder · Quick Look · Rename ·
/// Delete**, in three groups. The in-app way back leads the middle group, as Open in Edit leads the
/// pane's row menu for the opposite trip; the other three follow in the order the pane's row menu
/// gives them, with its titles and glyphs, so the same act reads the same on both lists. Rename and
/// Delete are Browse's, in their own group at the bottom (TE117), with Browse's words and glyphs.
///
/// **Reveal in Browse is greyed where Browse cannot show the file** (TE116), with the reason under
/// it, rather than switching to a Browse that lands on nothing.
///
/// **Nothing here but Rename and Delete touches the open document.** Reveal in Browse switches
/// workspace and leaves the buffer where it is — ⌘4 comes back to it, unsaved edits and all. Rename
/// and Delete go through Browse's own prompt and confirmation, and the open document answers them
/// as it answers the same act from Browse: it follows a rename, and says so when its file is gone.
struct EditorRailRowMenu: View {

    let path: String
    /// Whether the file is still in the cloud — the one fact about the row the menu reads.
    var isCloudOnly: Bool = false
    let actions: EditorRailRowActions

    /// One menu item: its words, its glyph, and the act bound to this row's path.
    struct Item: Identifiable {
        let title: String
        let systemImage: String
        /// Why the item is greyed, drawn as a line under it — or `nil` for a live item.
        var refusal: String? = nil
        var isDestructive = false
        /// Whether a separator comes before it.
        var startsGroup = false
        let perform: () -> Void
        var id: String { title }
    }

    /// The items, in drawn order, each already bound to `path`.
    ///
    /// **A function rather than `Button`s in a body** so the claims worth making — the order, the
    /// words, the groups, and that every act receives THIS row's path — can be asserted by calling
    /// it, which a menu inside a hosted view does not allow. The body below draws exactly this list.
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
            Item(title: "Get Info", systemImage: "info.circle",
                 perform: { actions.getInfo(path) }),
            Item(title: "Reveal in Finder", systemImage: RevealGlyph.inFinder,
                 perform: { actions.revealInFinder(path) }),
            Item(title: "Quick Look", systemImage: "doc.viewfinder",
                 perform: { actions.quickLook(path) }),
            Item(title: "Rename", systemImage: "pencil", startsGroup: true,
                 perform: { actions.rename(path) }),
            Item(title: "Delete", systemImage: "trash", isDestructive: true,
                 perform: { actions.delete(path) }),
        ]
        return items
    }

    /// **The header name's tooltip** (TE157): the whole name, which the header cuts off in the
    /// middle when it runs long, and the menu behind it, its acts named in the menu's own order.
    static func nameTooltip(_ name: String) -> String {
        "“\(name)” — right-click to reveal, get info or rename"
    }

    var body: some View {
        ForEach(Self.items(for: path, isCloudOnly: isCloudOnly, actions: actions)) { item in
            if item.startsGroup { Divider() }
            Button(role: item.isDestructive ? .destructive : nil, action: item.perform) {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(item.refusal != nil)
            // A menu draws a `Text` as a greyed line of its own — the reason, under the item.
            if let refusal = item.refusal { Text(refusal) }
        }
    }
}
