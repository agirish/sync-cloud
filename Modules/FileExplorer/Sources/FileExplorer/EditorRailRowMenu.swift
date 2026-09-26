import SwiftUI
import AppKit
import Design

/// What a Text Files rail row's context menu can do, each act taking the ROW's path.
///
/// **Three of the four leave through the host**, because each needs something only the app owns:
/// Browse's pane, the Info inspector, and the window's one Quick Look panel. Reveal in Finder does
/// not — it hands the file to Finder the same direct way the pane's row menu does — so it is
/// defaulted to that, and a test passes its own to watch which path arrives.
///
/// **Built by the host and handed to `EditorWorkspaceView` whole**, which passes it to the rail
/// untouched. The three host acts have no defaults, so a construction site cannot draw the menu
/// wired to nothing — the property the workspace's three separate closures used to carry.
public struct EditorRailRowActions {
    let revealInBrowse: (String) -> Void
    let getInfo: (String) -> Void
    let quickLook: (String) -> Void
    let revealInFinder: (String) -> Void

    public init(revealInBrowse: @escaping (String) -> Void,
                getInfo: @escaping (String) -> Void,
                quickLook: @escaping (String) -> Void,
                revealInFinder: @escaping (String) -> Void = EditorRailRowActions.revealInFinder) {
        self.revealInBrowse = revealInBrowse
        self.getInfo = getInfo
        self.quickLook = quickLook
        self.revealInFinder = revealInFinder
    }

    /// Finder, selecting the file — the pane row menu's own call, word for word.
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The context menu on a row of the Edit rail's Text Files list.
///
/// **The way back out, from any file in the list — not only the open one.** The rail's rows had no
/// menu, so the only reverse verb in Edit was the header filename's one-item menu, which can only
/// ever name the document already open. A file you are about to open, or one the editor refuses,
/// had no way to be looked at anywhere else.
///
/// **Dim rows keep the whole menu.** A file too large to read or not yet downloaded is exactly the
/// one worth revealing or inspecting — the editor cannot show it, so somewhere else has to. The
/// menu therefore takes a path and nothing about the row's state; there is no input it could gate
/// on.
///
/// **Order: Reveal in Browse · Get Info · Reveal in Finder · Quick Look.** The in-app way back
/// leads, as Open in Edit leads the pane's row menu for the opposite trip; the other three follow
/// in the order the pane's row menu gives them, with its titles and glyphs, so the same act reads
/// the same on both lists. Reveal in Browse wears the header's own title and glyph.
///
/// **Nothing here touches the open document.** Reveal in Browse switches workspace and leaves the
/// buffer where it is — ⌘4 comes back to it, unsaved edits and all — which is the header verb's
/// contract, reached through the same host closure.
struct EditorRailRowMenu: View {

    let path: String
    let actions: EditorRailRowActions

    /// One menu item: its words, its glyph, and the act bound to this row's path.
    struct Item: Identifiable {
        let title: String
        let systemImage: String
        let perform: () -> Void
        var id: String { title }
    }

    /// The items, in drawn order, each already bound to `path`.
    ///
    /// **A function rather than four `Button`s in a body** so the claims worth making — the order,
    /// the words, and that every act receives THIS row's path — can be asserted by calling it,
    /// which a menu inside a hosted view does not allow. The body below draws exactly this list.
    static func items(for path: String, actions: EditorRailRowActions) -> [Item] {
        [
            Item(title: "Reveal in Browse", systemImage: "folder",
                 perform: { actions.revealInBrowse(path) }),
            Item(title: "Get Info", systemImage: "info.circle",
                 perform: { actions.getInfo(path) }),
            Item(title: "Reveal in Finder", systemImage: RevealGlyph.inFinder,
                 perform: { actions.revealInFinder(path) }),
            Item(title: "Quick Look", systemImage: "doc.viewfinder",
                 perform: { actions.quickLook(path) }),
        ]
    }

    var body: some View {
        ForEach(Self.items(for: path, actions: actions)) { item in
            Button(action: item.perform) {
                Label(item.title, systemImage: item.systemImage)
            }
        }
    }
}
