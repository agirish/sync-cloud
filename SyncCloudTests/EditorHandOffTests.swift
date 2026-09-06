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
                isSingleSource: false, ownsOrganizeScope: false,
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
