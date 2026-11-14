import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// `CommandPaletteHost.swift`'s own behaviour, beside the wiring `CommandPaletteRouteCallSiteTests`
/// pins: `isMountedFolder` on a real disk, the two halves of the aimed-pane rule compared to each
/// other, and the action switch checked against `PaletteAction.allCases`, a public enum in another
/// module that can grow without touching the app target.
@Suite struct CommandPaletteHostTests {

    // MARK: - isMountedFolder, against a real disk

    /// A scratch directory. Real files, because `isMountedFolder` is a question for the filesystem.
    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandPaletteHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A source's folder counts as mounted only when it is there and is a directory. The directory
    /// answers yes first, so the two refusals can't be met by a function that says no to everything.
    /// `SettingsManager` requires a directory too; dropping `&& isDirectory.boolValue` would make a
    /// Location pointing at a file read as mounted here while Settings calls it invalid.
    @Test func onlyAnExistingDirectoryCountsAsMounted() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("statement.pdf")
        try Data("not a folder".utf8).write(to: file)

        #expect(ContentView.isMountedFolder(dir.path),
                "a directory that is plainly there reads as unmounted — the rest of this test is vacuous")
        #expect(!ContentView.isMountedFolder(file.path),
                "a regular file reads as a mounted folder; Settings would call the same path invalid")
        #expect(!ContentView.isMountedFolder(dir.appendingPathComponent("gone").path),
                "a path that does not exist reads as mounted")
    }

    /// The path is tilde-expanded before the disk is asked, as Settings validates it, or a Location
    /// is green in Settings and "Not mounted" here. A literal `~` doesn't exist in the working
    /// directory, so a true answer can only mean it expanded.
    @Test func aTildePathIsExpandedBeforeTheDiskIsAsked() {
        #expect(ContentView.isMountedFolder(NSHomeDirectory()),
                "the home directory itself reads as unmounted — the harness is broken, not the rule")
        #expect(!FileManager.default.fileExists(atPath: "~"),
                "a literal `~` exists as a relative path here, so the check below proves nothing")
        #expect(ContentView.isMountedFolder("~"),
                "`~` is asked of the disk unexpanded — a hand-typed Location will read Not mounted")
    }

    // MARK: - The aimed pane: the write half must agree with the read half

    static func host() throws -> String {
        try macAppFile("CommandPaletteHost.swift")
    }

    /// The provider id named in a member's `aimedAtRight == true` branch, read positionally (both are
    /// written aimed-at-right first; an inverted rewrite fails loudly, the safe way to be wrong). Nil
    /// when the body doesn't consult the aim or name both panes.
    static func paneNamedWhenAimedRight(_ body: String) -> String? {
        guard body.contains("aimedAtRight"),
              let left = body.range(of: "leftProviderId"),
              let right = body.range(of: "rightProviderId") else { return nil }
        return right.lowerBound < left.lowerBound ? "rightProviderId" : "leftProviderId"
    }

    /// `aimProvider` writes the pane `paletteProviderId` reads.
    /// `thePaletteRevealsIntoThePaneItIndexed` stops at the signature; with the branches swapped,
    /// the palette would describe the right pane but point the left one at the source picked,
    /// firing its provider-switch teardown on the side not being worked in.
    @Test func theWriteHalfOfTheAimedPaneRuleAgreesWithTheReadHalf() throws {
        let host = try Self.host()
        let read = try declarationBody(of: "var paletteProviderId: String", in: host)
        let write = try declarationBody(of: "func aimProvider(_ id: String) {", in: host)

        let readsWhenRight = try #require(Self.paneNamedWhenAimedRight(read),
                                          "paletteProviderId no longer picks a pane off the aim")
        let writesWhenRight = try #require(Self.paneNamedWhenAimedRight(write),
                                           "aimProvider no longer picks a pane off the aim")
        #expect(readsWhenRight == writesWhenRight,
                "with the right pane focused the palette READS \(readsWhenRight) and WRITES \(writesWhenRight) — choosing a source from ⌘K points the pane it was not describing")
        // And the answer is the right pane, so the pair cannot agree on being wrong together.
        #expect(readsWhenRight == "rightProviderId",
                "both halves now name the left pane when the right one is aimed at")
    }

    // MARK: - The pane-swap prompt's words

    /// The dialog names the folder and both sources: the user can't answer a request to rearrange
    /// their window without them. The wording is a `static func` because the alert ends in
    /// `runModal()`, which a test can't dismiss.
    @Test func theSwapPromptNamesTheFolderAndBothSources() {
        let folder = "/Users/abhishek/Library/CloudStorage/Dropbox/Legal/Immigration"
        let prompt = ContentView.organizePaneSwapPrompt(folder: folder,
                                                        aimedProvider: "Dropbox",
                                                        shownProvider: "iCloud Drive")
        #expect(prompt.informativeText.contains("Immigration"),
                "the prompt does not name the folder the route was about")
        #expect(prompt.informativeText.contains("Dropbox"),
                "the prompt does not name the source the folder is in")
        #expect(prompt.informativeText.contains("iCloud Drive"),
                "the prompt does not name the source Organize would otherwise open on")
        // The leaf, not the path: a dialog is no place to publish `/Users/<you>/…`, and the chip
        // beside it shows the same folder by name.
        #expect(!prompt.informativeText.contains(folder),
                "the prompt dumps the absolute path at the user")
        // The message line states the constraint, the informative text explains the trade; an
        // alert would truncate a first line carrying the whole explanation.
        #expect(prompt.messageText.contains("one source at a time"),
                "the message line no longer states why the swap is needed")
        #expect(prompt.informativeText.contains("swap") || prompt.informativeText.contains("Swapping"),
                "the prompt never says what confirming does")
        // The reassurance, a fact about `swapPanesAction`: nothing is removed, the two sides trade
        // places. Without it "swap" reads as though a source is about to be dropped.
        #expect(prompt.informativeText.contains("Compare keeps both sources"),
                "the prompt does not say Compare keeps both sources — “swap” reads as losing one")
    }

    /// The two provider names are not transposed, or the dialog would offer to move the source
    /// already showing. The test above can't see that.
    @Test func theSwapPromptDoesNotConfuseTheTwoSources() throws {
        let prompt = ContentView.organizePaneSwapPrompt(
            folder: "/Users/abhishek/Library/CloudStorage/Dropbox/Legal",
            aimedProvider: "Dropbox", shownProvider: "iCloud Drive")
        // "…puts <aimed> on the left" is the clause that has to name the source being moved there.
        let promise = try #require(prompt.informativeText.range(of: "on the left"),
                                   "the prompt no longer says which source ends up on the left")
        #expect(prompt.informativeText[..<promise.lowerBound].hasSuffix("Dropbox "),
                "the source promised the left pane is not the one the route named")
    }

    // MARK: - Routes

    /// Every `PaletteAction` is applied, and the switch has no `default:` to swallow a new one.
    /// Driven off `allCases`: a case added in `FileExplorer` appears in the palette's rows, and a
    /// list typed here would go on passing while `runPaletteAction` ignored it.
    @Test func everyPaletteActionIsApplied() throws {
        let host = try Self.host()
        let body = try declarationBody(of: "private func runPaletteAction(_ action: PaletteAction) {", in: host)
        #expect(PaletteAction.allCases.count >= 7,
                "PaletteAction has shrunk to \(PaletteAction.allCases.count) cases — check this suite still means something")
        for action in PaletteAction.allCases {
            #expect(body.contains("case .\(action.rawValue):"),
                    "runPaletteAction ignores `\(action.rawValue)` — the palette offers “\(action.title)” and it does nothing")
        }
        #expect(!body.contains("default:"),
                "a default arm would swallow a PaletteAction case added in FileExplorer")
    }

    /// A lens-only route still moves the rail, because the scope guard sits after the lens write:
    /// hoisted above it, "Organize ▸ Duplicates" would land on whichever lens was already selected.
    @Test func aLensWithoutAScopeStillMovesTheRail() throws {
        let host = try Self.host()
        // The shared comment-stripping reader, like every other body scan in this target.
        let body = try declarationBody(of: "func aimOrganize(lens: OrganizeLens?, scope: String?) {",
                                       in: host)
        let lensWrite = try #require(body.range(of: "paletteRailLens = lens"),
                                     "aimOrganize no longer writes the rail selection")
        let scopeGuard = try #require(body.range(of: "guard let scope else { return }"),
                                      "aimOrganize no longer returns early for a scope-less route")
        #expect(lensWrite.lowerBound < scopeGuard.lowerBound,
                "the scope guard runs before the rail is written — “Organize ▸ Duplicates”, which carries no scope, leaves the rail wherever it was")
        #expect(!body.contains("resolvedForPresentation"),
                "a per-write fold is back — that resolution belongs in the launch migration now")
    }
}
