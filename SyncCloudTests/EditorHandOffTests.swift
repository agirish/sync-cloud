import Testing
import Foundation
import Sync
import Settings
import FileExplorer
@testable import SyncCloud

/// Pointing a pane at a folder the Editor hand-off names.
///
/// **The prefix trap is the whole reason this is a named function.** "Open in Edit" on a file
/// deep in another source has to decide whether that file is inside the pane's root, and a
/// `hasPrefix` answers yes for a sibling that merely shares an opening — landing the pane somewhere
/// real and wrong, which is worse than not moving it at all.
@Suite struct EditorHandOffTests {

    @Test func aFolderInsideTheRootComesBackRelativeToIt() {
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/Notes", under: "/Users/me/iCloud")
                == "Notes")
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/Notes/2026/June",
                                       under: "/Users/me/iCloud") == "Notes/2026/June")
    }

    /// The root is its own answer: `focusOn` takes `""` for the pane's resting position.
    @Test func theRootItselfIsTheEmptyRelativePath() {
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud", under: "/Users/me/iCloud") == "")
    }

    /// **A sibling that shares an opening is NOT inside.** `/Users/me/iCloudArchive` begins with
    /// `/Users/me/iCloud`, and a string-prefix test would put it under that root.
    @Test func aSiblingSharingAPrefixIsNotInsideTheRoot() {
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloudArchive/Notes",
                                       under: "/Users/me/iCloud") == nil)
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloudArchive",
                                       under: "/Users/me/iCloud") == nil)
    }

    @Test func aFolderOutsideTheRootIsRefusedRatherThanGuessedAt() {
        #expect(PaneLogic.relativePath(of: "/Volumes/Backup/Notes", under: "/Users/me/iCloud") == nil)
        // A parent of the root is not inside it either.
        #expect(PaneLogic.relativePath(of: "/Users/me", under: "/Users/me/iCloud") == nil)
    }

    /// Trailing slashes and doubled separators are the same folder, and the pane must not be
    /// refused because a path arrived spelled differently.
    @Test func spellingDifferencesDoNotChangeTheAnswer() {
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/Notes/", under: "/Users/me/iCloud")
                == "Notes")
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/Notes", under: "/Users/me/iCloud/")
                == "Notes")
        #expect(PaneLogic.relativePath(of: "/Users/me//iCloud/Notes", under: "/Users/me/iCloud")
                == "Notes")
    }

    /// **The volumes this runs on are case-insensitive**, so a path differing only in case is the
    /// same folder and the pane has to follow it.
    @Test func caseDoesNotDecideWhetherAFolderIsInsideTheRoot() {
        #expect(PaneLogic.relativePath(of: "/Users/me/icloud/Notes", under: "/Users/me/iCloud")
                == "Notes")
        // The folder's own spelling comes back — this path goes to the filesystem, and correcting
        // somebody's capitalisation is not this function's job.
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/notes", under: "/Users/me/iCloud")
                == "notes")
    }

    /// A relative path is not "inside" anything. `split(separator:)` drops the leading empty
    /// component, so without the absoluteness guard `Users/me/Docs` matched the root `/Users/me`.
    @Test func aRelativeInputIsRefusedRatherThanTreatedAsAbsolute() {
        #expect(PaneLogic.relativePath(of: "Users/me/Docs", under: "/Users/me") == nil)
        #expect(PaneLogic.relativePath(of: "/Users/me/Docs", under: "Users/me") == nil)
    }

    @Test func anEmptyRootTakesEverythingAndAnEmptyFolderIsTheRoot() {
        // A root of "/" is every absolute path's root.
        #expect(PaneLogic.relativePath(of: "/Users/me", under: "/") == "Users/me")
        #expect(PaneLogic.relativePath(of: "/", under: "/") == "")
    }
}

/// The verb the hand-off puts on a row.
///
/// Which rows it appears on is asserted inside `FileExplorer`, by `OpenInEditorVerbTests` — that
/// is where `PairContentKind`, the table both the menu item and the editor's rail filter on, is
/// visible. (This pointer named `EditorRailTests` while that suite said nothing about the menu.)
@Suite struct OpenInEditorMenuTests {

    /// **Every conformer answers the hand-off, and none of them inherits a silent no-op.** The
    /// protocol's other growth points (`handleChooseDestination`, the risky-name pair) carry
    /// documented defaults because the menu items that reach them are gated to hosts that
    /// implement them. This one is not gated that way — it is drawn on any text row — so a default
    /// would be a menu item that quietly does nothing.
    @Test func theHandOffIsARequirementRatherThanADefaultedMember() throws {
        let source = try Self.source("FileActionDelegate.swift")
        let body = try #require(source.range(of: "public protocol FileActionDelegate"))
        let rest = source[body.upperBound...]
        let end = try #require(rest.range(of: "\n}"))
        #expect(String(rest[..<end.lowerBound]).contains("func handleOpenInEditor(_ path: String)"),
                "the hand-off is no longer a protocol requirement — a conformer can now inherit a no-op")
        // …and there is no default hiding in an extension below.
        #expect(!source[end.upperBound...].contains("func handleOpenInEditor"),
                "a default implementation of the hand-off was added — conformers can stop answering")
    }

    /// **The delegate the app really wires forwards the path to its closure.**
    ///
    /// `PaneActionDelegate` is the only conformer the app builds, and `handleOpenInEditor` is a
    /// one-line forward — the shape that gets reviewed by eye and never run. What stood in for this
    /// was a test in `FileExplorer` that built its own recorder, called the recorder's method, and
    /// asserted the recorder had recorded: no production symbol in the room, so this forward could
    /// have been deleted outright and stayed green.
    ///
    /// The parameter it does NOT take is the point of the second assertion. It threaded `isLeft` for
    /// a while so the hand-off could re-root "the pane the row was in" — but the editor reads the
    /// LEFT pane and only the left pane, so a right-pane row moved a pane the editor never draws
    /// while the rail carried on listing the left one.
    @MainActor
    @Test func theDelegateForwardsThePathAndSaysNothingAboutWhichPane() {
        final class Box: @unchecked Sendable { var paths: [String] = [] }
        let box = Box()
        func delegate(isLeft: Bool) -> PaneActionDelegate {
            PaneActionDelegate(
                handler: nil, syncManager: FileSyncManager(), settings: SettingsManager(),
                isLeft: isLeft, leftProviderId: "left", rightProviderId: "right",
                isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
                forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
                onOpenInEditor: { box.paths.append($0) },
                ignoreStateToken: [], keptNamesToken: [],
                homeBadgeCoverage: nil, onFindDuplicatesOf: { _ in },
                onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in },
                onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
        }

        delegate(isLeft: true).handleOpenInEditor("/a/left.md")
        delegate(isLeft: false).handleOpenInEditor("/b/right.md")

        #expect(box.paths == ["/a/left.md", "/b/right.md"],
                "the delegate did not forward the paths it was handed")
    }

    /// **The preview column's Edit button reaches the same act, from both surfaces that mount it.**
    ///
    /// The button's own click is not drivable from a session — `ColumnPreviewEditorButtonTests`
    /// proves it is DRAWN and `ColumnPreviewTests` proves WHEN, but what it calls when clicked is
    /// two expressions in two files that nothing executes in a test. Both are scanned here, in the
    /// suite that already exists for exactly this class of gap: a one-line forward that gets
    /// reviewed by eye and never run.
    ///
    /// The path matters as much as the delegate. `onOpenInEditor(item.name)` would compile, draw
    /// identically, and open the wrong thing — or nothing.
    @Test func bothPreviewMountsWireTheEditButtonToTheHandOff() throws {
        for file in ["FileTreeView.swift", "PaneColumnsView.swift"] {
            let source = try Self.source(file)
            #expect(source.contains("onOpenInEditor: { delegate.handleOpenInEditor($0) }"),
                    "\(file) mounts the preview without wiring its Edit button to the hand-off")
        }
        // …and the button hands over the file's PATH, not its name or its kind.
        let column = try Self.source("ColumnPreviewColumn.swift")
        #expect(column.contains("Button { onOpenInEditor(item.path) }"),
                "the Edit button no longer hands the editor this column's path")
        // The sidebar in between forwards rather than deciding: a second decision about what is
        // editable is the drift the one public predicate exists to prevent.
        let sidebar = try Self.source("PanePreviewSidebar.swift")
        #expect(sidebar.contains("onOpenInEditor: onOpenInEditor"),
                "PanePreviewSidebar stopped forwarding the hand-off")
        #expect(!sidebar.contains("EditableText") && !sidebar.contains("PairContentKind"),
                "the sidebar has started deciding for itself what the editor opens")
    }

    /// **The two doors the app wires itself: the Info inspector and File ▸ Open in Edit.**
    ///
    /// Both were added with pure rules and mounted tests that inject their own closures — so the
    /// one expression in each that connects the door to the real hand-off was never executed by
    /// any test. Found on review: `open: { _ in }` at the inspector's construction site, or a
    /// menu closure that did nothing, left every suite green while the button or ⌘O did nothing.
    /// The same class of gap `bothPreviewMountsWireTheEditButtonToTheHandOff` closes for the
    /// preview, closed the same way.
    ///
    /// The predicate half matters as much as the action half: `isText: true` in the menu, or
    /// `isOffered: { _ in true }` in the inspector, would offer a PDF to a text editor, and the
    /// resolver's own tests cannot see it because they inject `isText` directly.
    @Test func theInspectorAndTheFileMenuAreWiredToTheRealHandOff() throws {
        let content = try Self.macApp("ContentView.swift")
        let inspector = try #require(content.range(of: "editorHandOff: EditorHandOff("),
                                     "the Info inspector is built without an editor hand-off")
        let handOff = String(content[inspector.upperBound...].prefix(240))
        #expect(handOff.contains("isOffered: { EditableText.isText(path: $0) }"),
                "the inspector no longer asks the row menu's own predicate what the editor opens")
        #expect(handOff.contains("open: { handOffToEditor($0) }"),
                "the inspector's Open in Edit is not wired to handOffToEditor")

        let shortcuts = try Self.macApp("ShortcutCommands.swift")
        let verbs = try #require(shortcuts.range(of: "var shortcutPaneRowVerbs"),
                                 "the row verbs resolver is gone or has moved out of this file")
        let rest = shortcuts[verbs.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "shortcutPaneRowVerbs never closes")
        let resolver = String(rest[..<end.lowerBound])
        #expect(resolver.contains("return PaneRowVerbs("), "the slice is not the resolver's body")
        #expect(resolver.contains("isText: node.map { EditableText.isText(path: $0.id) } ?? false"),
                "File ▸ Open in Edit no longer asks the row menu's own predicate about the selection")
        #expect(resolver.contains("? { node.map { delegate.handleOpenInEditor($0.id) } } : nil"),
                "File ▸ Open in Edit is not wired to the delegate's hand-off")
    }

    /// **Compare's differences list (TE31): the fifth door, wired to the same hand-off.**
    ///
    /// `DifferencesView` takes its editor as an optional closure that defaults to `nil` — the
    /// shape `onQuickLook` has, and the one a dozen package tests construct the view with — so the
    /// only thing that puts Open in Edit on a differences row at all is this argument at the app's
    /// one construction site. Dropping it compiles, draws a menu with no editor items, and leaves
    /// every package test green; `{ _ in }` in its place draws the items and makes them do nothing.
    /// The drawn tests in `DifferenceRowMenuDrawnTests` inject their own closure and see neither.
    @Test func theDifferencesListIsWiredToTheRealHandOff() throws {
        let content = try Self.macApp("ContentView.swift")
        let start = try #require(content.range(of: "DifferencesView(syncManager: syncManager"),
                                 "the differences list is built somewhere this scan does not look")
        let rest = content[start.lowerBound...]
        let line = String(rest[..<(rest.firstIndex(of: "\n") ?? rest.endIndex)])
        // `.staysPut`: the differences list opens the file WITHOUT moving the left pane, which is
        // half of the comparison the list is showing (TE31's fixup) — see
        // `EditorHandOffRunTests`, which measures what each variant does to a real pane.
        #expect(line.contains("onOpenInEditor: { handOffToEditor($0, pane: .staysPut) }"),
                "the differences list's Open in Edit is not wired to the hand-off that leaves the pane where it is")
        // Exactly one construction, so the line read above is THE one.
        #expect(content.components(separatedBy: "DifferencesView(").count == 2,
                "a second DifferencesView construction appeared — scan it too")
    }

    /// A file in `MacApp/`, read from disk.
    static func macApp(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCloudTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("MacApp")
            .appendingPathComponent(name)
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — this scan would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scan would be near-vacuous")
        return text
    }

    /// The module's own source, read from disk. Mirrors the other call-site scans in this suite.
    static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCloudTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer")
            .appendingPathComponent(name)
        let text = try #require(try? String(contentsOf: root, encoding: .utf8),
                                "cannot read \(name) — this scan would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scan would be near-vacuous")
        return text
    }
}

/// **The Edit rail's row menu (TE33), wired to the app's real acts.**
///
/// `EditorRailRowMenuTests` in FileExplorer proves the menu's order, its words, that each item
/// hands on the ROW's path, and that the workspace forwards its closures to the rail. What it
/// cannot see is what the app passes in: `onGetInfo: { _ in }` at the one construction site would
/// draw the item and do nothing, the exact shape of the two wirings the TE27–TE30 review found no
/// test executing.
@Suite struct EditorRailRowMenuWiringTests {

    /// The three closures at the app's one `EditorWorkspaceView` construction.
    @Test func theRailRowMenuIsWiredToTheInspectorQuickLookAndBrowse() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let start = try #require(editor.range(of: "func editorWorkspace(showsRail: Bool) -> some View {"),
                                 "the editor workspace builder is gone or renamed")
        let rest = editor[start.upperBound...]
        let end = try #require(rest.range(of: ".task(id: EditorRailKey("),
                               "the builder no longer ends at the rail survey's task")
        let site = String(rest[..<end.lowerBound])
        #expect(site.contains("EditorWorkspaceView("), "the slice is not the workspace's construction")
        #expect(site.contains("onRevealInBrowse: { path in revealInBrowse(path) }"),
                "Reveal in Browse (header and rail rows) is not wired to revealInBrowse")
        #expect(site.contains("onGetInfo: { path in showInfo(for: path) }"),
                "the rail row menu's Get Info is not wired to the Info inspector")
        // `followsPane: false`: a rail row is not the pane's selection, so a pane click must not
        // retarget a preview opened from here (`CurrentSelection.previewFollow`).
        #expect(site.contains(
            "onQuickLook: { path in toggleQuickLook(URL(fileURLWithPath: path), followsPane: false) }"),
                "the rail row menu's Quick Look is not wired to the window's shared panel")
    }

    /// **Reveal in Browse leaves the open document alone** — the existing contract, now reachable
    /// from any rail row rather than only from the open file's header. ⌘4 must come back to the
    /// document exactly as it was, unsaved edits and all, so the verb may move the pane and the
    /// workspace and nothing else.
    @Test func revealInBrowseMovesThePaneAndTheWorkspaceAndNotTheDocument() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let start = try #require(editor.range(of: "func revealInBrowse(_ path: String) {"),
                                 "revealInBrowse is gone or renamed")
        let rest = editor[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "revealInBrowse never closes")
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("(path as NSString).deletingLastPathComponent"),
                "Reveal in Browse no longer goes to the folder of the path it was handed")
        #expect(body.contains("focusPaneOnFolder(folder)"), "Reveal in Browse no longer moves the pane")
        #expect(body.contains("selectedWorkspace = .browse"), "Reveal in Browse no longer switches to Browse")
        for touch in ["editorDocument", "settleEditorDocument", "loadIntoEditor", "openInEditor"] {
            #expect(!body.contains(touch),
                    "Reveal in Browse now touches the open document (\(touch)) — ⌘4 may not find it as left")
        }
    }

    /// Get Info's destination: the inspector, on the path it was handed.
    @Test func showInfoOpensTheInspectorOnThePathItWasHanded() throws {
        let content = try OpenInEditorMenuTests.macApp("ContentView.swift")
        let start = try #require(content.range(of: "func showInfo(for path: String) {"),
                                 "showInfo is gone or renamed")
        let rest = content[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "showInfo never closes")
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("infoPath = path"), "Get Info no longer aims the inspector at its path")
        #expect(body.contains("showInspector = true"), "Get Info no longer opens the inspector")
    }
}

/// The hand-off path rule knows the folders a root links in from outside — iCloud Drive's
/// `Documents` — and answers through the link's name, keeping its case rule below the link.
@Suite struct EditorHandOffLinkedFolderTests {
    static let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/home/Documents"]]

    @Test func aFolderUnderTheLinkedTargetAnswersThroughTheLinkName() {
        #expect(PaneLogic.relativePath(of: "/home/Documents/Notes/2026", under: "/c", links: Self.links)
                == "Documents/Notes/2026")
        #expect(PaneLogic.relativePath(of: "/home/Documents", under: "/c", links: Self.links) == "Documents")
        #expect(PaneLogic.relativePath(of: "/home/documents/notes", under: "/c", links: Self.links)
                == "Documents/notes", "the case rule stopped applying below the link")
    }

    @Test func aFolderOutsideBothStaysOutside() {
        #expect(PaneLogic.relativePath(of: "/home/DocumentsArchive/x", under: "/c", links: Self.links) == nil)
        #expect(PaneLogic.relativePath(of: "/home/Documents/x", under: "/c", links: [:]) == nil)
    }
}
