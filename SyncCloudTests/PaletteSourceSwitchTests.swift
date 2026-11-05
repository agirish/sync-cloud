import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// ⌘K switches to the source a typed path is in. The trap: a provider change runs its own
/// navigation reset on the next view update, so an `aimProvider` followed by a `focusOn` would land
/// the pane at the source root with the typed folder silently dropped.
///
/// 1. The decision: `ContentView.sourceSwitchOutcome`, a pure rule with three refusals and one
///    destination, extracted as `RevealOutcome` is, since the caller is a `View` method.
/// 2. The ordering: three statements whose order is the fix, which no test can execute, so this is
///    a source scan of positions, as `theOrganizeRouteResolvesItsScopeAgainstThePaneItCameFrom`
///    does. It proves the order and that the provider write goes through the suppressing helper,
///    not that the pane lands on the folder in a running app.
@Suite struct PaletteSourceSwitchTests {

    private static let dropbox = "/Users/x/Dropbox"

    /// A probe that records whether it was asked: the laziness below is a claim that the disk is
    /// not touched, which a `PathKind` passed by value can't express.
    private final class Probe: @unchecked Sendable {
        let answer: PathKind
        private(set) var calls = 0
        init(_ answer: PathKind) { self.answer = answer }
        func kind() -> PathKind { calls += 1; return answer }
    }

    // MARK: The decision

    @Test func aFolderInsideTheNamedSourceBecomesTheRelativeFocus() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Clients/Legal",
                                                namedRoot: Self.dropbox, kind: .directory)
                == .switchAndFocus(relativePath: "Clients/Legal"))
    }

    /// The source's own root is the pane's top, `focusOn("")`, as `revealOutcome` answers for its
    /// root.
    @Test func theNamedSourcesRootIsTheEmptyRelativePath() {
        #expect(ContentView.sourceSwitchOutcome(path: Self.dropbox, namedRoot: Self.dropbox,
                                                kind: .directory)
                == .switchAndFocus(relativePath: ""))
    }

    /// A pasted path is usually a file's, so the enclosing folder is the destination, as
    /// `PaletteRouter.pathRow` does inside the aimed source. It lives here because the router
    /// doesn't `stat` a path outside the aimed source, so it can't tell a file from a folder.
    @Test func aFilePathLandsOnItsEnclosingFolder() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Clients/invoice.pdf",
                                                namedRoot: Self.dropbox, kind: .file)
                == .switchAndFocus(relativePath: "Clients"))
    }

    /// A file at the source root lands on `""`, the pane's own top.
    @Test func aFileAtTheSourceRootLandsOnTheRoot() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/invoice.pdf",
                                                namedRoot: Self.dropbox, kind: .file)
                == .switchAndFocus(relativePath: ""))
    }

    /// Nothing there is refused rather than half delivered. The router can't probe a source the
    /// pane isn't showing (the stall `PalettePath`'s ordering forbids), so ↩ is the first moment to
    /// ask, and switching to the parent of a folder that is gone would be a silent drop.
    @Test func aPathWithNothingAtItSwitchesNothing() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Gone",
                                                namedRoot: Self.dropbox, kind: .missing)
                == .nothingAtThatPath)
    }

    /// The `.person` hazard, one route over: the index is a snapshot taken when the palette opened
    /// and the sources are live, so an id that no longer names an enabled source arrives here.
    @Test func aSourceThatIsGoneIsRefusedRatherThanSwitchedTo() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal", namedRoot: nil,
                                                kind: .directory)
                == .noSuchSource)
    }

    /// An empty root must never claim a path: an empty base prefixes every absolute path (the
    /// hazard `PathBoundary.relativize` guards), so a source with no path would claim anything and
    /// the pane would be switched onto it.
    @Test func aSourceWithNoPathClaimsNothing() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal", namedRoot: "",
                                                kind: .directory)
                == .noSuchSource)
    }

    /// The source moved under an open palette: the row was built against the root it had then.
    @Test func aPathOutsideTheNamedSourceNamesTheRootItIsNotIn() {
        #expect(ContentView.sourceSwitchOutcome(path: "/Users/x/Documents/Legal",
                                                namedRoot: Self.dropbox, kind: .directory)
                == .outsideNamedSource(root: Self.dropbox))
    }

    /// A sibling whose name merely starts with the root isn't inside it: the prefix trap
    /// `PathBoundary` closes. Wrong, it would switch the pane to Dropbox with a garbage relative
    /// path.
    @Test func aSiblingSharingThePrefixIsNotInside() {
        #expect(ContentView.sourceSwitchOutcome(path: "/Users/x/DropboxOld/Legal",
                                                namedRoot: Self.dropbox, kind: .directory)
                == .outsideNamedSource(root: Self.dropbox))
    }

    // MARK: The disk is asked once, and only when the answer can matter

    /// `kind` is `@autoclosure` so the two index questions are answered without a `stat`: the
    /// stall guard `PalettePath` states for keystrokes. The sources that reach here are ones the
    /// pane isn't showing, such as a network mount or external drive that may no longer answer.
    @Test func theDiskIsNotAskedWhenTheSourceCannotTakeThePathAnyway() {
        let gone = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal", namedRoot: nil,
                                            kind: gone.kind())
        #expect(gone.calls == 0, "a source that is gone was stat'ed anyway")

        let outside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "/Users/x/Documents/Legal",
                                            namedRoot: Self.dropbox, kind: outside.kind())
        #expect(outside.calls == 0, "a path outside the named source was stat'ed anyway")

        // The case that is asked, so the assertions above can't pass because the closure is never
        // called.
        let inside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal",
                                            namedRoot: Self.dropbox, kind: inside.kind())
        #expect(inside.calls == 1,
                "the one path that must be checked was asked \(inside.calls) times")
    }

    // MARK: The ordering — the whole of the deferral

    /// Three statements, one order, each position load-bearing:
    ///
    /// - `focusOn` before the provider write, as in `tabAction`. Both land in one synchronous turn,
    ///   so when SwiftUI evaluates either `onChange` the pane already names folder and source.
    /// - The provider write through `adoptProviderForTab`, never `aimProvider` or a bare id
    ///   assignment. The helper arms `pendingTabProviderChanges`; without it
    ///   `onChange(of: leftProviderId)` takes the `.userSwitch` arm and `retargetPane()` re-homes
    ///   the pane at the new source's landing folder, silently dropping the typed folder.
    /// - `refreshForTabSwitch` last, because it resolves both providers by the ids as they now are.
    @Test func theSwitchNavigatesFirstThenAdoptsUnderSuppressionThenReloads() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try Self.source("CommandPaletteHost.swift"))
        let focus = try #require(body.range(of: "syncManager.focusOn(relativePath: relative"),
                                 "the switch no longer focuses the pane on the typed folder at all")
        let adopt = try #require(body.range(of: "adoptProviderForTab(providerId, isLeft: isLeft"),
                                 "the provider write no longer goes through the helper that arms the suppression counter")
        let reload = try #require(body.range(of: "refreshForTabSwitch(movedPane: isLeft)"),
                                  "nothing drives the reload — the suppressed handler was the only thing that would have")
        #expect(focus.lowerBound < adopt.lowerBound,
                "the source is adopted before the pane is told where to go, so the handler's next update finds a pane that has not moved")
        #expect(adopt.lowerBound < reload.lowerBound,
                "the reload runs before the provider write, so it resolves the source being left rather than the one being adopted")

        // The writers that must not be here. `aimProvider` is the `.provider` route's writer and
        // is meant to run the full reset; a bare id assignment does the same.
        // `theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper` covers only the tabs file.
        for wrong in ["aimProvider(", "leftProviderId =", "rightProviderId =",
                      "$leftProviderId", "$rightProviderId", "retargetPane("] {
            #expect(!Self.codeOnly(body).contains(wrong),
                    "the source switch writes the pane's provider with `\(wrong)`, which does not suppress the navigation reset")
        }
    }

    /// Every refusal logs. Three of the four outcomes deliver nothing, and an accepted ⌘K route
    /// must never do nothing without a trace.
    @Test func everyRefusalIsLoggedRatherThanReturningSilently() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try Self.source("CommandPaletteHost.swift"))
        for branch in ["case .noSuchSource:", "case .outsideNamedSource(let root):",
                       "case .nothingAtThatPath:"] {
            let start = try #require(body.range(of: branch),
                                     "\(branch) is gone from the switch — the rule has an answer nothing acts on")
            let arm = String(body[start.upperBound...].prefix(400))
            #expect(arm.contains("Logger.shared.warning"),
                    "\(branch) returns without a word — an accepted route delivering nothing, with no trace")
        }
    }

    /// The pane it switches is the one ⌘K was aimed at, read once. `aimedAtRight` is computed over
    /// the layout, so re-reading it per statement can reveal into the wrong pane. Both writes name
    /// the same side, through a binding, not the expression twice.
    @Test func bothWritesNameTheSameCapturedPane() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try Self.source("CommandPaletteHost.swift"))
        let code = Self.codeOnly(body)
        // A caller may name its pane (Ask Claude setting one side of Compare); otherwise the aim.
        #expect(code.contains("let isLeft = paneIsLeft ?? !aimedAtRight"),
                "the aimed pane is no longer captured once at the top")
        // Counted, not merely present: a second live read of `aimedAtRight` could name the other
        // pane.
        #expect(code.components(separatedBy: "aimedAtRight").count - 1 == 1,
                "the aim is read more than once in the switch — the two writes can name different panes")
        let sides = PaneTabWiringTests.argumentTokens(labelled: "isLeft", in: code)
        #expect(sides.count >= 2 && sides.allSatisfy { $0 == "isLeft" },
                "a side argument in the switch names something other than the captured pane: \(sides)")
    }

    /// The link toggle deliberately doesn't apply, asserted because it is the kind of thing added
    /// later "for consistency". The switch is per-pane, so a linked follow would move the sibling
    /// to a path relativized against a source it isn't showing, which is what
    /// `FileActionHandler.focusFolder`'s `suppressLinkedNavigation` exists for.
    /// `focusOn(relativePath:isLeft:)` is the single-pane call the `.folder` route uses too.
    @Test func theSwitchMovesOnePaneAndNeverFollowsTheLink() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try Self.source("CommandPaletteHost.swift"))
        let code = Self.codeOnly(body)
        for both in ["focusBoth", "PaneLinkPreference", "isLinked", "PaneSideChoice.sibling"] {
            #expect(!code.contains(both),
                    "the cross-source switch reaches for the sibling pane (`\(both)`) — it is on another source and would be handed a path from this one's tree")
        }
    }

    private static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check here would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scans would be near-vacuous")
        return text
    }
}
