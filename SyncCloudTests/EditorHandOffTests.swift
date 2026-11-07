import Testing
import Foundation
import Sync
import Settings
import FileExplorer
@testable import SyncCloud

/// Pointing a pane at a folder the Editor hand-off names.
///
/// The prefix trap is why this is a named function. "Open in Edit" on a file deep in another
/// source must decide whether it is inside the pane's root, and `hasPrefix` answers yes for a
/// sibling that merely shares an opening, landing the pane somewhere real and wrong, which is
/// worse than not moving it.
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

    /// A sibling that shares an opening is not inside. `/Users/me/iCloudArchive` begins with
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

    /// The volumes this runs on are case-insensitive, so a path differing only in case is the same
    /// folder and the pane has to follow it.
    @Test func caseDoesNotDecideWhetherAFolderIsInsideTheRoot() {
        #expect(PaneLogic.relativePath(of: "/Users/me/icloud/Notes", under: "/Users/me/iCloud")
                == "Notes")
        // The folder's own spelling comes back: this path goes to the filesystem, and correcting
        // capitalisation is not this function's job.
        #expect(PaneLogic.relativePath(of: "/Users/me/iCloud/notes", under: "/Users/me/iCloud")
                == "notes")
    }

    /// A relative path is not "inside" anything. `split(separator:)` drops the leading empty
    /// component, so without the absoluteness guard `Users/me/Docs` would match the root
    /// `/Users/me`.
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
/// Which rows it appears on is asserted inside `FileExplorer`, by `OpenInEditorVerbTests`, where
/// `PairContentKind` (the table both the menu item and the editor's rail filter on) is visible.
@Suite struct OpenInEditorMenuTests {

    /// Every conformer answers the hand-off, and none inherits a silent no-op. The protocol's other
    /// growth points (`handleChooseDestination`, the risky-name pair) have documented defaults
    /// because their menu items are gated to hosts that implement them. This one is drawn on any
    /// text row, so a default would be a menu item that quietly does nothing.
    @Test func theHandOffIsARequirementRatherThanADefaultedMember() throws {
        let source = try Self.source("FileActionDelegate.swift")
        let body = CodeText(try declarationBody(of: "public protocol FileActionDelegate", in: source))
        #expect(body.contains("func handleOpenInEditor(_ path: String)"),
                "the hand-off is no longer a protocol requirement — a conformer can now inherit a no-op")
        // …and no default hides in an extension, below the protocol or above it: the requirement
        // is the file's only declaration of it, in code.
        #expect(CodeText(source).count(of: "func handleOpenInEditor") == 1,
                "a default implementation of the hand-off was added — conformers can stop answering")
    }

    /// The delegate the app really wires forwards the path to its closure.
    ///
    /// `PaneActionDelegate` is the only conformer the app builds, and `handleOpenInEditor` is a
    /// one-line forward, the shape that gets reviewed by eye and never run, so this drives the
    /// production type rather than a recorder of its own.
    ///
    /// The forward takes no pane: the editor reads only the left pane, so re-rooting "the pane the
    /// row was in" would move a pane the editor never draws while the rail lists the left one.
    @MainActor
    @Test func theDelegateForwardsThePathAndSaysNothingAboutWhichPane() {
        final class Box: @unchecked Sendable { var paths: [String] = [] }
        let box = Box()
        func delegate(isLeft: Bool) -> PaneActionDelegate {
            PaneActionDelegate(
                handler: nil, syncManager: FileSyncManager.scratch(), settings: SettingsManager.scratch(),
                isLeft: isLeft, leftProviderId: "left", rightProviderId: "right",
                isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
                forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
                onOpenInEditor: { box.paths.append($0) },
                ignoreStateToken: [], keptNamesToken: [],
                onFindDuplicatesOf: { _ in },
                onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in },
                onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
        }

        delegate(isLeft: true).handleOpenInEditor("/a/left.md")
        delegate(isLeft: false).handleOpenInEditor("/b/right.md")

        #expect(box.paths == ["/a/left.md", "/b/right.md"],
                "the delegate did not forward the paths it was handed")
    }

    /// The two doors the app wires itself: the Info inspector and File ▸ Open in Edit.
    ///
    /// Their pure rules and mounted tests inject their own closures, so `open: { _ in }` at the
    /// inspector's construction site, or a menu closure that does nothing, would leave every suite
    /// green while the button or ⌘O did nothing. So the two construction sites are scanned.
    ///
    /// The predicate half matters as much as the action: `opensInEdit: true` in the menu, or
    /// `isOffered: { _ in true }` in the inspector, would offer a PDF to a text editor, and the
    /// resolver's own tests can't see it because they inject `opensInEdit` directly.
    @Test func theInspectorAndTheFileMenuAreWiredToTheRealHandOff() throws {
        let content = sourceCodeOnly(try Self.macApp("ContentView.swift"))
        // The construction's own argument list, not a fixed-length window.
        let inspector = try #require(argumentLists(of: "EditorHandOff(", in: content).first,
                                     "the Info inspector is built without an editor hand-off")
        #expect(CodeText(content).contains("editorHandOff: EditorHandOff("),
                "the hand-off is built, but not handed to the inspector")
        let handOff = CallArguments(inspector)
        #expect(handOff.passes("isOffered", "{ EditableText.opensInEdit(path: $0) }"),
                "the inspector no longer asks the row menu's own predicate what the editor opens")
        #expect(handOff.passes("open", "{ handOffToEditor($0) }"),
                "the inspector's Open in Edit is not wired to handOffToEditor")

        let shortcuts = try Self.macApp("ShortcutCommands.swift")
        let resolverText = try declarationBody(of: "var shortcutPaneRowVerbs", in: shortcuts)
        let resolver = CodeText(resolverText)
        #expect(resolver.contains("return PaneRowVerbs("), "the slice is not the resolver's body")
        #expect(try CallArguments(of: "PaneRowVerbAvailability.resolve(", in: resolverText)
                    .passes("opensInEdit", "node.map { EditableText.opensInEdit(path: $0.id) } ?? false"),
                "File ▸ Open in Edit no longer asks the row menu's own predicate about the selection")
        // Of the resolver's two `PaneRowVerbs(`, the one that offers anything; the other is `none`.
        let offered = argumentLists(of: "PaneRowVerbs(", in: resolverText).map(CallArguments.init)
            .first { $0.value("openInEditor") != "nil" }
        #expect(offered?.value("openInEditor")?.contains(normalizedCode("? { node.map { delegate.handleOpenInEditor($0.id) } } : nil")) == true,
                "File ▸ Open in Edit is not wired to the delegate's hand-off")
    }

    /// Compare's differences list: the fifth door, wired to the same hand-off.
    ///
    /// `DifferencesView` takes its editor as an optional closure defaulting to `nil` (as
    /// `onQuickLook` does, and as package tests construct it), so only this argument at the app's
    /// one construction site puts Open in Edit on a differences row. Dropping it compiles and draws
    /// no editor items; `{ _ in }` draws items that do nothing. The drawn tests in
    /// `DifferenceRowMenuDrawnTests` inject their own closure and see neither.
    @Test func theDifferencesListIsWiredToTheRealHandOff() throws {
        let content = sourceCodeOnly(try Self.macApp("ContentView.swift"))
        // The construction's own argument list, not the rest of its first line, so a call broken
        // over lines keeps every argument.
        let constructions = argumentLists(of: "DifferencesView(", in: content)
        let differences = CallArguments(try #require(constructions.first,
                                                     "the differences list is built somewhere this scan does not look"))
        #expect(differences.passes("syncManager", "syncManager"), "the slice is not the differences list's construction")
        // `.staysPut`: the differences list opens the file without moving the left pane, which is
        // half of the comparison the list shows. `EditorHandOffRunTests` measures what each
        // variant does to a real pane.
        #expect(differences.passes("onOpenInEditor", "{ handOffToEditor($0, pane: .staysPut) }"),
                "the differences list's Open in Edit is not wired to the hand-off that leaves the pane where it is")
        // Exactly one construction, so the call read above is the one.
        #expect(constructions.count == 1,
                "a second DifferencesView construction appeared — scan it too")
    }

    /// A duplicate copy's row menu reaches the real hand-off, through both hops.
    ///
    /// `DuplicateRowMenuTests` drives the card with its own recorder, which stays green when the
    /// app's closure is `{ _ in }`. The card's parameter has no default, but the lens can pass nil,
    /// and the lens's own parameter defaults to nil, so the app can forget outright. Both hops are
    /// read: the app hands the lens `handOffToEditor`, and the lens hands the card what it was
    /// given, deciding nothing on the way.
    @Test func theDuplicateRowMenuIsWiredToTheRealHandOff() throws {
        let content = sourceCodeOnly(try Self.macApp("ContentView.swift"))
        // The construction's own argument list, read by label.
        let lens = try CallArguments(of: "LensWorkspaceView(", in: content)
        #expect(lens.passes("onCompareCopies", "reviewCoordinator.compareCopies"),
                "the slice is not the lens workspace's construction")
        #expect(lens.passes("onOpenInEditor", "{ handOffToEditor($0) }"),
                "the duplicate row's Open in Edit is not wired to handOffToEditor")

        let view = try Self.source("LensWorkspaceView.swift")
        #expect(CodeText(view).contains("self.onOpenInEditor = onOpenInEditor"),
                "the lens drops the hand-off it is given")
        // The builder's own body, not a window up to a nearby marker.
        let cardBody = try declarationBody(of: "private func duplicateCard(", in: view)
        let card = CodeText(cardBody)
        #expect(card.contains("DuplicateGroupCard("), "the slice is not the card's construction")
        #expect(try CallArguments(of: "DuplicateGroupCard(", in: cardBody).passes("onOpenInEditor", "onOpenInEditor"),
                "the lens builds its cards without forwarding the hand-off")
        #expect(!card.contains("EditableText") && !card.contains("PairContentKind"),
                "the lens has started deciding for itself what the editor opens")
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

/// The Edit rail's row menu, wired to the app's real acts.
///
/// `EditorRailRowMenuTests` in FileExplorer proves the menu's order, its words, that each item
/// hands on the row's path, and that the workspace forwards its closures to the rail. It can't see
/// what the app passes in: `onGetInfo: { _ in }` at the one construction site would draw the item
/// and do nothing.
@Suite struct EditorRailRowMenuWiringTests {

    /// The app's one `EditorWorkspaceView` construction, read by label.
    static func workspaceConstruction() throws -> CallArguments {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        // The construction's own argument list inside the builder.
        let builder = try declarationBody(of: "func editorWorkspace(showsRail: Bool, railWidth: CGFloat = EditorLayoutMetrics.railWidth) -> some View {", in: editor)
        return try CallArguments(of: "EditorWorkspaceView(", in: builder)
    }

    /// The rail row menu's acts as the workspace is handed them: the `EditorRailRowActions(` passed
    /// as its `railRowActions:`, so actions built and not passed don't count.
    static func railRowActions() throws -> CallArguments {
        let passed = try #require(try workspaceConstruction().value("railRowActions"),
                                  "the workspace is not handed the rail row actions")
        return try CallArguments(of: "EditorRailRowActions(", in: passed)
    }

    /// The three closures at the app's one `EditorWorkspaceView` construction.
    @Test func theRailRowMenuIsWiredToTheInspectorQuickLookAndBrowse() throws {
        let site = try Self.workspaceConstruction()
        #expect(site.passes("onRevealInBrowse", "{ path in revealInBrowse(path, from: .header) }"),
                "the header's Reveal in Browse is not wired to revealInBrowse")
        let rail = try Self.railRowActions()
        #expect(rail.passes("revealInBrowse", "{ path in revealInBrowse(path, from: .railRow) }"),
                "the rail rows' Reveal in Browse is not wired to revealInBrowse as its own door")
        #expect(rail.passes("getInfo", "{ path in showInfo(for: path) }"),
                "the rail row menu's Get Info is not wired to the Info inspector")
        // `followsPane: false`: a rail row is not the pane's selection, so a pane click must not
        // retarget a preview opened from here (`CurrentSelection.previewFollow`).
        #expect(rail.passes("quickLook", "{ path in toggleQuickLook(URL(fileURLWithPath: path), followsPane: false) }"),
                "the rail row menu's Quick Look is not wired to the window's shared panel")
    }

    /// Four more acts, wired to the app's own: Download to Edit's download (Browse's verb, then
    /// open on arrival); the greying to the reveal's own reach; Rename and Delete to Browse's
    /// handler (its prompt, its confirmation) on a node for the row's file.
    @Test func downloadRenameDeleteAndTheGreyingAreWired() throws {
        let rail = try Self.railRowActions()
        #expect(rail.passes("download", "{ path in downloadFromEdit(path) }"),
                "the rail row menu's Download is not wired to Edit's download")
        #expect(rail.passes("rename", "{ path in actionHandler?.beginRename(Self.editorRailNode(path)) }"),
                "the rail row menu's Rename is not Browse's rename")
        #expect(rail.passes("delete", "{ path in actionHandler?.confirmDelete([Self.editorRailNode(path)]) }"),
                "the rail row menu's Delete is not Browse's confirmed delete")
        let greying = try #require(rail.value("revealInBrowseRefusal"), "Reveal in Browse is never greyed")
        #expect(CodeText(greying).contains("EditorRevealInBrowse.refusal(")
                    && CodeText(greying).contains("settings.rootPath(for: leftProviderId)"),
                "Reveal in Browse is greyed by something other than the reveal's own reach into the left source")
    }

    /// Download opens the file only while Edit still shows its refusal, and asks Browse's verb
    /// first so the pane's cloud badge clears as it does from Browse.
    @Test func downloadFromEditOpensOnlyTheStillRefusedFile() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let body = CodeText(try declarationBody(of: "func downloadFromEdit(_ path: String) {", in: editor))
        #expect(body.contains("CloudDownloadRequest.requestDownload(path: path, name: name,"),
                "Edit's Download no longer asks through Browse's verb")
        // A refusal must not reveal the file in Finder: the fetch below reaches every provider and
        // opens it here, so Finder over Edit would be a second answer.
        #expect(body.contains("whenUnavailable: { _ in })"),
                "Edit's Download takes Browse's reveal-in-Finder fallback, over the fetch it already starts")
        #expect(body.contains("await ExternalOpen.fetch(path, timeout: Self.editDownloadWait)"),
                "Edit's Download no longer waits for the file, or waits only the external open's minute")
        // Download was asked for here, and the note promises the file opens when it arrives: a
        // one-minute wait would call a large file on a slow link a failure while it downloads.
        #expect(ContentView.editDownloadWait >= .seconds(300))
        #expect(body.contains("guard editorOpenPath == path, editorOpenIsRefused else {")
                    && body.contains("openInEditor(path: path)"),
                "Edit's Download opens a file the reader has moved on from, or never opens it")
    }

    /// Reveal in Browse leaves the open document alone, from any rail row as from the open file's
    /// header. ⌘4 must come back to the document exactly as it was, unsaved edits and all, so the
    /// verb may move the pane and the workspace and nothing else.
    @Test func revealInBrowseMovesThePaneAndTheWorkspaceAndNotTheDocument() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let text = try declarationBody(of: "func revealInBrowse(_ path: String, with companions: [String] = [], replacing replaces: Set<String> = [],",
                                       in: editor)
        let body = CodeText(text)
        let reveal = try CallArguments(of: "EditorRevealInBrowse.reveal(", in: text)
        #expect(reveal.unlabeled == ["path"] && reveal.passes("from", "door"),
                "Reveal in Browse no longer moves the pane to the path it was handed")
        #expect(body.contains("selectedWorkspace = .browse"), "Reveal in Browse no longer switches to Browse")
        for touch in ["editorDocument", "settleEditorDocument", "loadIntoEditor", "openInEditor"] {
            #expect(!body.contains(touch),
                    "Reveal in Browse now touches the open document (\(touch)) — ⌘4 may not find it as left")
        }
    }

    /// Get Info's destination: the inspector, on the path it was handed.
    @Test func showInfoOpensTheInspectorOnThePathItWasHanded() throws {
        let content = try OpenInEditorMenuTests.macApp("ContentView.swift")
        let body = CodeText(try declarationBody(of: "func showInfo(for path: String) {", in: content))
        #expect(body.contains("infoPath = path"), "Get Info no longer aims the inspector at its path")
        #expect(body.contains("showInspector = true"), "Get Info no longer opens the inspector")
    }
}

/// The hand-off path rule knows the folders a root links in from outside (iCloud Drive's
/// `Documents`) and answers through the link's name, keeping its case rule below the link.
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
