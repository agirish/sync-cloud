import SwiftUI
import FileExplorer

/// **One `EditorWorkspaceView` for tests, with every argument a test does not care about filled
/// in** — so a test names only what it is about.
///
/// The initializer takes thirty-odd arguments and leaves most of them without defaults on purpose
/// (see its parameter comments): a construction site in the APP that forgot a closure would draw a
/// control that does nothing. That rule is about the app. In a test it only meant seven hand-copied
/// constructions, each a wall of `{ _ in }` in which the one argument the test was about had to be
/// found by eye — and which drifted whenever the initializer grew. The defaults below are the inert
/// values those copies all used; a test overrides the ones it asserts on.
///
/// Test-only: this target is linked by the FileExplorer and Dashboard test targets, never by the
/// app.
extension EditorWorkspaceView {

    @MainActor
    public static func fixture(
        document: EditorDocument = EditorDocument(),
        folder: String = "/n",
        entries: [EditorRailEntry] = [],
        showsRail: Bool = false,
        railIsHidden: Bool = false,
        mode: EditorMode = .edit,
        isNaming: Bool = false,
        stopped: String? = nil,
        onShowWhatChanged: (() -> Void)? = nil,
        onRevealInBrowse: @escaping (String) -> Void = { _ in },
        location: EditorDocumentLocation? = nil,
        railRowActions: EditorRailRowActions = EditorRailRowActions(revealInBrowse: { _ in },
                                                                     getInfo: { _ in }, quickLook: { _ in }),
        onNewTextFile: (() -> Void)? = {},
        paneShowsTabStrip: Bool = false,
        folderDisplayName: String? = nil
    ) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            folder: folder,
            entries: entries,
            showsRail: showsRail,
            railIsHidden: railIsHidden,
            accent: .blue,
            onAccent: .white,
            mode: .constant(mode),
            splitFraction: .constant(0.5),
            isNaming: .constant(isNaming),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            undoManager: UndoManager(),
            stopped: stopped,
            onShowWhatChanged: onShowWhatChanged,
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true },
            onRevealInBrowse: onRevealInBrowse,
            location: location,
            onLocationDoor: { _ in },
            railRowActions: railRowActions,
            onToggleJustTheText: {},
            onNewTextFile: onNewTextFile,
            onCloseDocument: {},
            paneShowsTabStrip: paneShowsTabStrip,
            folderDisplayName: folderDisplayName)
    }
}
