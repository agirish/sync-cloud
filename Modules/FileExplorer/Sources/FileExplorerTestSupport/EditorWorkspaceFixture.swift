import SwiftUI
import FileExplorer

/// One `EditorWorkspaceView` for tests, with every argument a test doesn't care about filled in,
/// so a test names only what it is about.
///
/// The initializer leaves most of its thirty-odd arguments without defaults on purpose, so an app
/// call site can't forget a closure and draw a dead control. Tests get inert defaults here and
/// override the ones they assert on.
///
/// Test-only: linked by the FileExplorer and Dashboard test targets, never by the app.
extension EditorWorkspaceView {

    @MainActor
    public static func fixture(
        document: EditorDocument = EditorDocument(),
        pdf: EditorPDFDocument? = nil,
        folder: String = "/n",
        entries: [EditorRailEntry] = [],
        showsRail: Bool = false,
        railIsHidden: Bool = false,
        mode: EditorMode = .edit,
        isNaming: Bool = false,
        stopped: String? = nil,
        onShowWhatChanged: (() -> Void)? = nil,
        onSaveNow: (() -> Void)? = nil,
        onSaveAgain: (() -> Void)? = nil,
        diskBanner: EditorDiskBanner? = nil,
        onRevealInBrowse: @escaping (String) -> Void = { _ in },
        location: EditorDocumentLocation? = nil,
        railRowActions: EditorRailRowActions = .inert,
        onNewTextFile: (() -> Void)? = {},
        paneShowsTabStrip: Bool = false,
        folderDisplayName: String? = nil,
        newFileFolderName: String? = nil,
        goToLineRequest: Int = 0,
        undoManager: UndoManager = UndoManager(),
        recentFiles: EditorRecentFiles? = nil,
        onOpenRecent: ((String) -> Void)? = nil
    ) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            pdf: pdf,
            folder: folder,
            entries: entries,
            showsRail: showsRail,
            railIsHidden: railIsHidden,
            accent: .blue,
            accentFill: .blue,
            onAccent: .white,
            mode: .constant(mode),
            splitFraction: .constant(0.5),
            isNaming: .constant(isNaming),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            goToLineRequest: goToLineRequest,
            undoManager: undoManager,
            stopped: stopped,
            onShowWhatChanged: onShowWhatChanged,
            onSaveNow: onSaveNow,
            onSaveAgain: onSaveAgain,
            diskBanner: diskBanner,
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
            folderDisplayName: folderDisplayName,
            newFileFolderName: newFileFolderName,
            folderTrail: nil,
            onGoToFolder: nil,
            recentFiles: recentFiles,
            onOpenRecent: onOpenRecent)
    }
}

public extension EditorRailRowActions {
    /// Row actions that do nothing, for a test about something else. Reveal in Finder included, so
    /// a test that performs every item never brings Finder forward.
    static var inert: EditorRailRowActions {
        EditorRailRowActions(revealInBrowse: { _ in }, revealInBrowseRefusal: { _ in nil },
                             quickLook: { _ in }, download: { _ in },
                             rename: { _ in }, delete: { _ in }, revealInFinder: { _ in })
    }
}
