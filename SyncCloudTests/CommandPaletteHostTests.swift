import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// `CommandPaletteHost.swift`'s own behaviour, as opposed to its wiring.
///
/// `CommandPaletteRouteCallSiteTests` reads the same file, and the split between the two is worth
/// stating because it is not "old suite / new suite". That one pins the *decisions already known to
/// have been wrong* as exact strings. This one covers what those scans cannot reach:
///
/// - **`isMountedFolder` is really run**, against a real disk, because it is the one member of this
///   file a test can call. It is a `static func` with no `self` in it, which is precisely why it is
///   reachable while `runPaletteRoute` is not — `ContentView` declares 27 private stored properties,
///   so its synthesized memberwise initializer is `private` and `@testable` cannot raise it.
/// - **The two halves of the aimed-pane rule are compared to each other.** The existing scan asserts
///   `func aimProvider(_ id: String)` *exists*; nothing looks inside it. Inverting its two branches —
///   `if aimedAtRight { leftProviderId = id }` — leaves every assertion in that suite green while
///   reintroducing the exact defect `paletteProviderId` was extracted to kill: a source chosen from
///   ⌘K while the RIGHT pane is focused pointing the LEFT one at it.
/// - **The action switch is checked against `PaletteAction.allCases` at runtime**, rather than
///   against a list typed out here. A hard-coded list is satisfied forever by the cases that existed
///   when it was written, and `PaletteAction` is a public enum in another module — the one place a
///   case can be added without touching this repository's app target at all.
@Suite struct CommandPaletteHostTests {

    // MARK: - isMountedFolder, against a real disk

    /// A scratch directory that cleans itself up. Real files, because the whole point of
    /// `isMountedFolder` is the question it asks the filesystem.
    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandPaletteHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **A source's folder counts as mounted only when it is there AND is a directory.**
    ///
    /// Both halves in one test, and in that order: an assertion that some path is *not* mounted is
    /// satisfied by a function that says no to everything, so the directory has to be shown
    /// answering yes first for the two refusals below to mean anything.
    ///
    /// The file case is the one with teeth. `SettingsManager` requires a directory, and this member
    /// exists to ask the same question the same way; drop `&& isDirectory.boolValue` and a Location
    /// pointing at a *file* reads as mounted here while Settings calls it invalid — the two
    /// surfaces disagreeing about one folder, which is the defect the doc comment records in the
    /// tilde direction.
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

    /// **The path is tilde-expanded before the disk is asked.**
    ///
    /// The recorded defect, stated as a measurement: the Settings field accepts a hand-typed `~/…`
    /// verbatim and validates it expanded, so without the expansion here a Location showed green in
    /// Settings and dimmed "Not mounted" in the palette — about the same folder.
    ///
    /// The proof does not rest on the assertion at the end. `FileManager` resolves a bare `~`
    /// against the working directory, not the home directory, so the middle expectation establishes
    /// that the unexpanded string is not a path that exists at all. Given that, `isMountedFolder`
    /// answering true for it can only mean it expanded — the fixture's expected value and its
    /// fallback answer differently, which a plain "`~/Library` is mounted" check would not.
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

    /// The provider id named in a member's `aimedAtRight == true` branch.
    ///
    /// **Positional, and deliberately strict.** Both members are written aimed-at-right first — the
    /// ternary's then-branch, the `if`'s then-block — so whichever id appears first is the pane that
    /// answers when the right pane has focus. An equivalent rewrite that inverts the condition
    /// (`!aimedAtRight ? leftProviderId : rightProviderId`) would be scored as a disagreement and
    /// fail loudly; that is the safe direction to be wrong in, and the alternative — a scan that
    /// tolerates any phrasing — is a scan that cannot tell the two panes apart at all.
    ///
    /// Returns nil rather than guessing when the body does not consult the aim or does not mention
    /// both panes, so a member that stopped asking the question fails the `#require` at the call
    /// site instead of quietly scoring.
    static func paneNamedWhenAimedRight(_ body: String) -> String? {
        guard body.contains("aimedAtRight"),
              let left = body.range(of: "leftProviderId"),
              let right = body.range(of: "rightProviderId") else { return nil }
        return right.lowerBound < left.lowerBound ? "rightProviderId" : "leftProviderId"
    }

    /// **`aimProvider` writes the pane `paletteProviderId` reads.**
    ///
    /// The gap this closes, exactly: `thePaletteRevealsIntoThePaneItIndexed` asserts that
    /// `aimProvider` is declared and that both provider routes call it, and stops at the signature.
    /// Swap the two branches in its body and the palette indexes the right pane's tree, marks the
    /// right pane's source "current", reveals into the right pane — and points the LEFT pane at
    /// whatever source you pick, firing that pane's provider-switch teardown on the side you were
    /// not working in. Every existing assertion stays green through that, because none of them
    /// looks inside the one member the rule is written down in twice.
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

    /// One member's body, bounded by its closing brace — the same instrument, and the same
    /// reasoning, as `BrowseWorkspaceCallSiteTests.body(of:in:)`: a fixed character window is
    /// silently wrong the moment the member it reads grows.
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

    // MARK: - Routes

    /// **Every `PaletteAction` is applied, and the switch has no `default:` to swallow a new one.**
    ///
    /// Driven off `allCases` rather than a list typed here, which is the whole value of it:
    /// `PaletteAction` is public and lives in `FileExplorer`, so a case can be added there, appear
    /// in the palette's own rows, and reach a `runPaletteAction` that does nothing with it — while a
    /// hard-coded list in this file goes on passing because it was written before the case existed.
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

    /// **A lens-only route still moves the rail**, because the scope guard sits *after* the lens
    /// write.
    ///
    /// `aimOrganize` takes both halves as optionals and "Organize ▸ Duplicates" supplies only the
    /// first. Hoist `guard let scope` above `paletteRailLens = …` — the tidier-looking order, since
    /// it puts both guards together — and every scope-less route returns before touching the rail:
    /// ⌘K lands on Organize showing whichever lens was already selected, silently, which is the
    /// same class of failure as the root-read ordering the neighbouring suite pins.
    ///
    /// The lens is also **resolved before it is stored**. `.names` folds into `.renames`, and the
    /// rail has no item for the folded lens, so writing an unresolved `.names` into the selection
    /// key leaves the rail with nothing highlighted. `LensFoldReachabilityTests` pins the fold
    /// at `LensWorkspaceView`'s read; this is the other writer of the same key, and the existing scan's
    /// `contains("paletteRailLens = lens")` matches with `?.resolvedForPresentation` deleted.
    @Test func aLensWithoutAScopeStillMovesTheRail() throws {
        let host = try Self.host()
        // The shared comment-stripping reader, like every other body scan in this target — the
        // suite next door used to keep a private slicer for this one declaration, over RAW source.
        let body = try declarationBody(of: "private func aimOrganize(lens: OrganizeLens?, scope: String?) {",
                                       in: host)
        let lensWrite = try #require(body.range(of: "paletteRailLens = lens"),
                                     "aimOrganize no longer writes the rail selection")
        let scopeGuard = try #require(body.range(of: "guard let scope else { return }"),
                                      "aimOrganize no longer returns early for a scope-less route")
        #expect(lensWrite.lowerBound < scopeGuard.lowerBound,
                "the scope guard runs before the rail is written — “Organize ▸ Duplicates”, which carries no scope, leaves the rail wherever it was")
        #expect(body.contains("paletteRailLens = lens?.resolvedForPresentation"),
                "the lens is stored unresolved — a folded lens leaves the rail with nothing selected")
    }
}
