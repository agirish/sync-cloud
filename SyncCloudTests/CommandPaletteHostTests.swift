import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// `CommandPaletteHost.swift`'s own behaviour, as opposed to its wiring, which
/// `CommandPaletteRouteCallSiteTests` pins as exact strings. This covers what those scans can't:
///
/// - `isMountedFolder` is run against a real disk. It is a `static func`, so a test can call it,
///   unlike `runPaletteRoute`: `ContentView`'s private stored properties make its memberwise
///   initializer `private`, which `@testable` cannot raise.
/// - The two halves of the aimed-pane rule are compared to each other, so inverting
///   `aimProvider`'s branches fails: a source chosen from ⌘K while the right pane is focused
///   would point the left one at it.
/// - The action switch is checked against `PaletteAction.allCases` at runtime, not a list typed
///   here: `PaletteAction` is a public enum in another module, so a case can be added without
///   touching the app target.
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

    /// The path is tilde-expanded before the disk is asked. Settings accepts a hand-typed `~/…` and
    /// validates it expanded, so without this a Location would be green in Settings and "Not
    /// mounted" in the palette. `FileManager` resolves a bare `~` against the working directory, and
    /// the middle check shows it doesn't exist there, so a true answer can only mean it expanded.
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
        try CommandPaletteRouteCallSiteTests.source("CommandPaletteHost.swift")
    }

    /// The provider id named in a member's `aimedAtRight == true` branch. Positional and strict:
    /// both members are written aimed-at-right first, so the first id is the pane that answers when
    /// the right pane has focus. An equivalent rewrite with the condition inverted would fail
    /// loudly, the safe direction to be wrong in. Nil when the body doesn't consult the aim or name
    /// both panes, so the `#require` at the call site fails instead.
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
        let read = try #require(Self.declaration("var paletteProviderId: String", in: host),
                                "paletteProviderId is gone — this comparison would be vacuous")
        let write = try #require(Self.body(of: "func aimProvider(_ id: String) {", in: host),
                                 "aimProvider is gone — this comparison would be vacuous")

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

    /// One member's body, bounded by its closing brace, as in
    /// `BrowseWorkspaceCallSiteTests.body(of:in:)`: a fixed character window goes wrong as the
    /// member grows.
    static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// A single-line computed property, taken to the end of its line. `body(of:)` cannot read one:
    /// its closing brace is on the same line as its declaration.
    static func declaration(_ prefix: String, in source: String) -> String? {
        guard let start = source.range(of: prefix) else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.firstIndex(of: "\n") ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - The pane-swap prompt's words

    /// The dialog names the folder and both sources. It asks the user to rearrange their window,
    /// which they can't answer without knowing which folder, which source it is in, and which one
    /// Organize is about to show. The wording is a `static func` so it can be tested:
    /// `NativeAlerts.confirmChange` ends in `runModal()`, which a test can't dismiss.
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
        let body = try #require(
            Self.body(of: "private func runPaletteAction(_ action: PaletteAction) {", in: host),
            "runPaletteAction is gone — this scan would be vacuous")
        #expect(PaletteAction.allCases.count >= 7,
                "PaletteAction has shrunk to \(PaletteAction.allCases.count) cases — check this suite still means something")
        for action in PaletteAction.allCases {
            #expect(body.contains("case .\(action.rawValue):"),
                    "runPaletteAction ignores `\(action.rawValue)` — the palette offers “\(action.title)” and it does nothing")
        }
        #expect(!CommandPaletteRouteCallSiteTests.codeOnly(body).contains("default:"),
                "a default arm would swallow a PaletteAction case added in FileExplorer")
    }

    /// A lens-only route still moves the rail, because the scope guard sits after the lens write.
    /// "Organize ▸ Duplicates" supplies no scope; with `guard let scope` hoisted above
    /// `paletteRailLens = …`, ⌘K would land on Organize showing whichever lens was already selected.
    ///
    /// The lens is stored as given: every `OrganizeLens` is a rail item, and
    /// `Workspace.migrateOrganizeLens` resolves old stored lenses once, at launch.
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
