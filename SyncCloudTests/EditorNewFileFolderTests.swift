import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Where ⌘N makes a file when the pane's folder is no place for one: `EditorNewFileFolder`'s rule,
/// then the wiring that takes the pane to Notes and makes the file there.
@Suite struct EditorNewFileFolderTests {

    static let home = "/Users/tester"

    private func refusal(_ folder: String, home: String = Self.home) -> EditorNewFileFolder.Refusal? {
        // The leading `~` only: iCloud's `com~apple~CloudDocs` has two more.
        let path = folder.hasPrefix("~") ? home + folder.dropFirst() : folder
        return EditorNewFileFolder.pathRefusal(of: path, home: home)
    }

    // MARK: The rule

    /// The system's folders, writable or not (`/Applications` is, for an admin). Case-folded, as
    /// the boot volume is, and a trailing slash changes nothing. The final `return .system` as `nil`
    /// fails every line but the `~/Library` ones; dropping the `~/Library` arm fails those.
    @Test(arguments: ["/", "/Applications", "/Applications/Utilities", "/applications", "/Applications/",
                      "/Library", "/Library/Fonts", "/System/Library", "/usr/local/bin", "/private/tmp",
                      "/opt/homebrew", "/Users", "/Volumes",
                      "~/Library", "~/Library/Preferences", "~/Library/Mobile Documents",
                      "~/Library/CloudStorage"])
    func aSystemFolderIsNoPlaceForAFile(_ folder: String) {
        #expect(refusal(folder) == .system, "\(folder)")
    }

    /// The top of the home folder holds Desktop, Documents and the rest, not files. Both fail
    /// without the `path == home` arm (the home is otherwise allowed as a folder inside itself).
    @Test(arguments: ["~", "~/"])
    func theTopOfTheHomeFolderIsNoPlaceForAFile(_ folder: String) {
        #expect(refusal(folder) == .homeTop)
    }

    /// Every Trash, wherever it is, including ones in places otherwise allowed.
    @Test(arguments: ["~/.Trash", "~/.Trash/old", "~/Library/Mobile Documents/com~apple~CloudDocs/.Trash",
                      "/Volumes/Ext/.Trashes/501"])
    func aTrashIsNoPlaceForAFile(_ folder: String) {
        #expect(refusal(folder) == .trash, "\(folder)")
    }

    /// No folder, or not a path.
    @Test(arguments: ["", "Documents/Notes"])
    func noFolderIsNoPlaceForAFile(_ folder: String) {
        #expect(refusal(folder) == .noFolder)
    }

    /// Everywhere a person keeps files, including the cloud folders under `~/Library` (iCloud
    /// Drive, an app's iCloud folder, OneDrive and Google Drive) from their own top down. Dropping
    /// the cloud carve-out fails their four lines; dropping the `/Volumes` or `/Users` arm, theirs.
    @Test(arguments: ["~/Documents", "~/Documents/Notes", "~/Desktop/x", "~/.config/app",
                      "~/Library/Mobile Documents/com~apple~CloudDocs",
                      "~/Library/Mobile Documents/com~apple~CloudDocs/Documents",
                      "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault",
                      "~/Library/CloudStorage/OneDrive-Personal",
                      "~/Library/CloudStorage/GoogleDrive-me/My Drive/a",
                      "/Volumes/Ext", "/Volumes/Ext/Projects", "/Users/Shared"])
    func aFolderOfYoursTakesTheFile(_ folder: String) {
        #expect(refusal(folder) == nil, "\(folder)")
    }

    /// An empty home claims nothing. Without the guard every absolute path is "inside" an empty
    /// home, which would let a file into `/Applications`.
    @Test func anEmptyHomeDoesNotOpenTheSystemFolders() {
        #expect(refusal("/Applications", home: "") == .system)
        #expect(refusal("/Users/someone/Documents", home: "") == nil)
    }

    /// The disk is asked only about a folder the spelling allows, and a folder it refuses goes to
    /// Notes, so a writable `/Applications` is still refused without asking. Fails on the first
    /// expectation if `isWritable` is asked first.
    @Test func writabilityIsAskedOnlyOfAnAllowedFolder() {
        var asked: [String] = []
        let ask: (String) -> Bool = { asked.append($0); return true }
        #expect(EditorNewFileFolder.refusal(of: "/Applications", home: Self.home, isWritable: ask) == .system)
        #expect(asked.isEmpty)
        #expect(EditorNewFileFolder.refusal(of: "/Volumes/Disk", home: Self.home, isWritable: { _ in false })
                == .notWritable)
        #expect(EditorNewFileFolder.refusal(of: "/Volumes/Disk", home: Self.home, isWritable: { _ in true }) == nil)
    }

    /// Where a link leads counts: `/Volumes/Macintosh HD` is `/`, so its `Applications` is the
    /// system's, writable for an admin, though the spelling sits under `/Volumes`. Resolved only
    /// for a spelling that passes. Dropping the resolved check fails the first expectation;
    /// resolving before the spelling check fails the second.
    @Test func aLinkIntoASystemFolderIsNoPlaceForAFile() {
        let boot: (String) -> String = { $0.replacingOccurrences(of: "/Volumes/Macintosh HD", with: "") }
        #expect(EditorNewFileFolder.refusal(of: "/Volumes/Macintosh HD/Applications", home: Self.home,
                                            isWritable: { _ in true }, resolve: boot) == .system)
        var resolved: [String] = []
        _ = EditorNewFileFolder.refusal(of: "/Applications", home: Self.home, isWritable: { _ in true },
                                        resolve: { resolved.append($0); return $0 })
        #expect(resolved.isEmpty, "a spelling already refused was resolved anyway")
        // A link that leads somewhere allowed stays allowed: `~/OneDrive` into CloudStorage.
        #expect(EditorNewFileFolder.refusal(of: "/Users/tester/OneDrive/x", home: Self.home, isWritable: { _ in true },
                                            resolve: { _ in "/Users/tester/Library/CloudStorage/OneDrive-Personal/x" }) == nil)
    }

    /// The pane's folder when it takes the file; `~/Documents/Notes` and the reason when it does not.
    @Test func theDestinationIsThePanesFolderOrNotes() {
        let kept = EditorNewFileFolder.destination(paneFolder: "/Users/tester/Desktop", home: Self.home,
                                                   isWritable: { _ in true })
        #expect(kept.folder == "/Users/tester/Desktop" && kept.refusal == nil)
        let moved = EditorNewFileFolder.destination(paneFolder: "/", home: Self.home, isWritable: { _ in true })
        #expect(moved.folder == "/Users/tester/Documents/Notes" && moved.refusal == .system)
        let none = EditorNewFileFolder.destination(paneFolder: "", home: Self.home, isWritable: { _ in true })
        #expect(none.folder == "/Users/tester/Documents/Notes" && none.refusal == .noFolder)
    }

    /// The log line says why, naming the folder, except where there is none.
    @Test func theReasonNamesTheFolder() {
        #expect(EditorNewFileFolder.Refusal.system.why("/Applications") == "/Applications is a system folder")
        #expect(EditorNewFileFolder.Refusal.notWritable.why("/Volumes/X") == "/Volumes/X can't be written to")
        #expect(EditorNewFileFolder.Refusal.noFolder.why("") == "There is no folder in the file pane")
    }

    /// The top of a whole-disk source is `/` in Columns too, as in Tree, not the `""` that
    /// `PaneBrowsePath.normalized` leaves of it, which reads as no folder at all. An empty root
    /// stays empty. Fails on the first expectation without the `/` line.
    @Test func theWholeDisksTopIsSlashInBothViews() {
        #expect(ContentView.paneFolder(treeRoot: "/", browsePath: PaneBrowsePath(), drawsColumns: true) == "/")
        #expect(ContentView.paneFolder(treeRoot: "/", browsePath: PaneBrowsePath(), drawsColumns: false) == "/")
        #expect(ContentView.paneFolder(treeRoot: "/", browsePath: PaneBrowsePath(components: ["Applications"]),
                                       drawsColumns: true) == "/Applications")
        #expect(ContentView.paneFolder(treeRoot: "", browsePath: PaneBrowsePath(), drawsColumns: true) == "")
    }

    // MARK: The wiring

    /// ⌘N takes the pane to Notes before the row opens, and after the workspace switch, since
    /// before it `editorFolder` would be read for the workspace being left. A Notes that couldn't be
    /// made opens no row. Fails if the call moves above the switch, after `editorIsNaming = true`,
    /// or out of its `guard`.
    @Test func theChordTakesThePaneToNotesBeforeTheRowOpens() throws {
        let chord = try memberBody("var shortcutNewTextFile: () -> Void", inFile: "ContentView+Editor.swift")
        let switchTo = try #require(chord.range(of: "selectedWorkspace = .editor"))
        let move = try #require(chord.range(of: "guard takePaneToNotesIfItIsNoPlaceForAFile() else { return }"),
                                "⌘N no longer takes the pane to Notes, or opens the row when Notes could not be made")
        let row = try #require(chord.range(of: "editorIsNaming = true"))
        #expect(switchTo.lowerBound < move.lowerBound, "Notes is decided before the switch to Edit")
        #expect(move.lowerBound < row.lowerBound, "the row opens before the pane reaches Notes")
    }

    /// Notes is made, then the pane follows it by tab, and only when the pane's folder was refused.
    /// A Notes made just now is re-read after the move: a tab on the pane's own source keeps its
    /// scope, so the switch re-reads nothing, and a column for a folder no walk has seen would stay
    /// blank, then be pruned, sending ⌘N's file to Documents. Fails without `guard let refusal`,
    /// the make or the re-read, if the follow takes `paneFolder`, or if the re-read precedes it.
    @Test func thePaneFollowsNotesOnlyOnceItExists() throws {
        let take = try memberBody("func takePaneToNotesIfItIsNoPlaceForAFile() -> Bool", inFile: "ContentView+Editor.swift")
        #expect(take.contains("guard let refusal else { return true }"))
        let make = try #require(take.range(of: "let notes = makeNotesFolder(folder) guard notes != .couldNotMake else { return false }"))
        let follow = try #require(take.range(of: "followFolderInTabs(folder, for: \"the file ⌘N is about to make\","),
                                  "the pane is not taken to Notes, or the log says a file is being opened")
        #expect(make.lowerBound < follow.lowerBound, "the pane is sent to a Notes that may not exist yet")
        let reread = try #require(take.range(of: "if notes == .madeNow { rereadPanesAfterEditorWrite(folder) }"),
                                  "a Notes made just now is not re-read")
        #expect(follow.lowerBound < reread.lowerBound, "the re-read reads the pane as it was, not as the move left it")
    }

    /// The file is made where the rule says, not in `editorFolder`, and the name the row offers and
    /// refuses is checked against that same folder. Fails if any of the three reads `editorFolder`.
    @Test func theFileTheRowNamesAndTheFileMadeShareOneFolder() throws {
        let create = try memberBody("func createTextFile(named name: String) -> Bool", inFile: "ContentView+Editor.swift")
        #expect(create.contains("let (folder, refusal) = newTextFileDestination"))
        #expect(create.contains("EditorFileStore.createEmptyFile(named: name, in: folder)"))
        #expect(!create.contains("editorFolder"), "createTextFile reads the pane's folder, not the destination")
        #expect(create.contains("if refusal != nil, editorNewFilePane != .staysPut { followFolderInTabs(folder, keepsSource: editorNewFilePane == .followsOnItsSource) }"),
                "a file made in Notes leaves the pane behind, drags it out of a comparison, or out of Organize's source")
        let workspace = try memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat", inFile: "ContentView+Editor.swift")
        let args = try call("EditorWorkspaceView(", in: workspace)
        #expect(args.passes("prefilledName", "{ EditorFileStore.availableUntitledName(in: newTextFileDestination.folder) }"))
        #expect(args.passes("refusal", "{ typed in EditorFileStore.refusal(forName: typed, in: newTextFileDestination.folder) }"))
        #expect(args.passes("newFileFolderName", "editorNewFileFolderName"))
    }

    /// From Compare the pane stays half of the comparison; from Organize it keeps its source, as
    /// every other way into Edit from there does (`ExternalOpen.pane`). Asked of the workspace being
    /// left, so before the switch to Edit; the file still goes to Notes. Fails if the read moves
    /// below the switch (it would always say Edit), Compare's arm follows, or the follow ignores
    /// `.followsOnItsSource`.
    @Test func fromCompareTheFileGoesToNotesAndThePaneStays() throws {
        let chord = try memberBody("var shortcutNewTextFile: () -> Void", inFile: "ContentView+Editor.swift")
        let ask = try #require(chord.range(of: "editorNewFilePane = ExternalOpen.pane(workspace: selectedWorkspace, isReviewing: reviewStore.isReviewing, atLaunch: false)"),
                               "⌘N no longer asks what the workspace it was pressed in does to the pane")
        let switchTo = try #require(chord.range(of: "selectedWorkspace = .editor"))
        #expect(ask.lowerBound < switchTo.lowerBound, "the workspace is asked after ⌘N has already left it")
        let take = try memberBody("func takePaneToNotesIfItIsNoPlaceForAFile() -> Bool", inFile: "ContentView+Editor.swift")
        let stays = try #require(take.range(of: "case .staysPut:"))
        let follows = try #require(take.range(of: "case .followsTheFile, .followsOnItsSource:"))
        let follow = try #require(take.range(of: "followFolderInTabs(folder,"))
        #expect(stays.lowerBound < follows.lowerBound && follows.lowerBound < follow.lowerBound,
                "the pane follows Notes out of a comparison")
        #expect(take.contains("keepsSource: editorNewFilePane == .followsOnItsSource)"),
                "from Organize, ⌘N's move adopts another source")
        #expect(take.contains("it is half of the comparison"), "the stay is not logged")
    }

    /// A body reads only the spelling half: the ＋'s tooltip is drawn on every pass, and
    /// `isWritable` is an `access(2)` that can wait on a slow volume. Both fail if it reads
    /// `newTextFileDestination`.
    @Test func theTooltipsNameNeverReadsTheDisk() throws {
        let name = try memberBody("var editorNewFileFolderName: String?", inFile: "ContentView+Editor.swift")
        #expect(name.contains("EditorNewFileFolder.pathRefusal(of: editorFolder"))
        #expect(!name.contains("isWritable") && !name.contains("newTextFileDestination"))
    }

    /// The destination reads the pane on screen and the real home.
    @Test func theDestinationReadsThePaneAndTheHome() throws {
        let destination = try memberBody("var newTextFileDestination: (folder: String, refusal: EditorNewFileFolder.Refusal?)", inFile: "ContentView+Editor.swift")
        #expect(destination.contains("paneFolder: editorFolder, home: NSHomeDirectory()"))
        #expect(destination.contains("FileManager.default.isWritableFile(atPath: $0)"))
        #expect(destination.contains("resolve: { Self.resolved($0) }"), "a link into a system folder is not followed")
    }
}
