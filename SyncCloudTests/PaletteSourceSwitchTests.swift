import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **RD7 — ⌘K switches to the source a typed path is in.**
///
/// The row that used to read "In Dropbox — switch source first" is a destination now, and the
/// reason it was deferred for two releases is the only interesting thing about it: a provider
/// change runs its own navigation reset on the *next* view update, so an `aimProvider` followed by
/// a `focusOn` lands the pane at the source root with the typed folder silently dropped.
///
/// Two halves, because they fail in two different ways:
///
/// 1. **The decision** — `ContentView.sourceSwitchOutcome`, a pure rule with three refusals and one
///    destination, extracted for the reason `RevealOutcome` is: the caller is a method on a SwiftUI
///    `View` with `@State`, which nothing can construct.
/// 2. **The ordering** — three statements whose order is the whole of the fix, and which no test in
///    this repo can execute. `MacApp/` is in no SPM package, and the writes are `@AppStorage` and
///    `@State` on a view a test cannot build, so this is a source scan of positions, exactly as
///    `theOrganizeRouteResolvesItsScopeAgainstThePaneItCameFrom` scans the sibling hazard one
///    function up. **Stated plainly: nothing here proves the pane really lands on the folder in a
///    running app** — it proves the three statements are in the order that makes it, and that the
///    provider write goes through the helper whose contract is the suppression.
@Suite struct PaletteSourceSwitchTests {

    private static let dropbox = "/Users/x/Dropbox"

    /// A probe that records whether it was asked at all — the laziness below is a claim about the
    /// disk not being touched, and a `PathKind` passed by value could not express it.
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

    /// The source's own root is the pane's top, which `focusOn("")` is how you say — the same
    /// answer `revealOutcome` gives for the root it is handed.
    @Test func theNamedSourcesRootIsTheEmptyRelativePath() {
        #expect(ContentView.sourceSwitchOutcome(path: Self.dropbox, namedRoot: Self.dropbox,
                                                kind: .directory)
                == .switchAndFocus(relativePath: ""))
    }

    /// **A pasted path is usually a file's**, and the enclosing folder is the destination — the
    /// rule `PaletteRouter.pathRow` applies inside the aimed source, applied here for the source
    /// the pane is not on. It has to live here rather than in the router, because the router
    /// deliberately does not `stat` a path outside the aimed source and so cannot tell a file from
    /// a folder at the moment the row is built.
    @Test func aFilePathLandsOnItsEnclosingFolder() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Clients/invoice.pdf",
                                                namedRoot: Self.dropbox, kind: .file)
                == .switchAndFocus(relativePath: "Clients"))
    }

    /// A file sitting at the source root leaves nothing above it — and `""` is exactly right, not
    /// a degenerate case: it is the pane's own top.
    @Test func aFileAtTheSourceRootLandsOnTheRoot() {
        #expect(ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/invoice.pdf",
                                                namedRoot: Self.dropbox, kind: .file)
                == .switchAndFocus(relativePath: ""))
    }

    /// **Nothing there is refused rather than delivered half.** The router could not ask — probing
    /// a source the pane is not showing is the stall `PalettePath`'s ordering forbids — so ↩ is the
    /// first moment anything can, and switching the source to land at the parent of a folder that
    /// is gone is the silent drop this whole feature is arranged against.
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

    /// **An empty root must never claim a path.** An empty base prefixes every absolute path —
    /// the hazard `PathBoundary.relativize` guards by name — so a source configured with no path
    /// would otherwise answer "yes, and it is at Users/x/Dropbox/Legal" for anything at all, and
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

    /// A sibling whose name merely *starts* with the root is not inside it — the prefix trap
    /// `PathBoundary` exists to close, asserted here because getting it wrong would switch the pane
    /// to Dropbox and hand it a garbage relative path.
    @Test func aSiblingSharingThePrefixIsNotInside() {
        #expect(ContentView.sourceSwitchOutcome(path: "/Users/x/DropboxOld/Legal",
                                                namedRoot: Self.dropbox, kind: .directory)
                == .outsideNamedSource(root: Self.dropbox))
    }

    // MARK: The disk is asked once, and only when the answer can matter

    /// **`kind` is `@autoclosure` so the two index questions are answered without a `stat`.**
    ///
    /// This is the same stall guard `PalettePath` states for the keystroke path, kept at the one
    /// place a `stat` is still made. It is a real risk rather than a tidiness: the sources whose
    /// rows can reach here are, by construction, ones the pane is NOT showing — a network mount or
    /// an external drive that answered when the palette opened and need not still.
    @Test func theDiskIsNotAskedWhenTheSourceCannotTakeThePathAnyway() {
        let gone = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal", namedRoot: nil,
                                            kind: gone.kind())
        #expect(gone.calls == 0, "a source that is gone was stat'ed anyway")

        let outside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "/Users/x/Documents/Legal",
                                            namedRoot: Self.dropbox, kind: outside.kind())
        #expect(outside.calls == 0, "a path outside the named source was stat'ed anyway")

        // …and the case that IS asked, so the two assertions above are not passing because the
        // closure is never called at all.
        let inside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal",
                                            namedRoot: Self.dropbox, kind: inside.kind())
        #expect(inside.calls == 1,
                "the one path that must be checked was asked \(inside.calls) times")
    }

    // MARK: The ordering — the whole of the deferral

    /// **Three statements, one order, and each position is load-bearing.**
    ///
    /// - `focusOn` **before** the provider write, matching `tabAction`, where the verb applies the
    ///   tab's navigation before the source is adopted. Both land in one synchronous turn, so by
    ///   the time SwiftUI evaluates either `onChange` the pane already names the folder and the
    ///   source.
    /// - the provider write **through `adoptProviderForTab`**, never `aimProvider` and never a
    ///   bare id assignment. That helper is what arms `pendingTabProviderChanges`; without it
    ///   `onChange(of: leftProviderId)` takes the `.userSwitch` arm and calls `retargetPane()`,
    ///   which re-homes the pane at its new source's landing folder — the typed folder dropped,
    ///   with nothing logged and nothing failing.
    /// - `refreshForTabSwitch` **last**, because it resolves both providers out of
    ///   `enabledProviders` by the ids as they now are.
    @Test func theSwitchNavigatesFirstThenAdoptsUnderSuppressionThenReloads() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String) {",
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

        // **The writers that must NOT be here.** `aimProvider` is the `.provider` route's writer
        // and arms nothing — it is *meant* to run the full reset — so reaching for it here is the
        // exact defect the deferral was about, spelled with the obvious call. A bare id assignment
        // is the same defect one step cruder; `theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper`
        // counts those in the tabs file and cannot see this one.
        for wrong in ["aimProvider(", "leftProviderId =", "rightProviderId =",
                      "$leftProviderId", "$rightProviderId", "retargetPane("] {
            #expect(!Self.codeOnly(body).contains(wrong),
                    "the source switch writes the pane's provider with `\(wrong)`, which does not suppress the navigation reset")
        }
    }

    /// **Every refusal says something.** Three of the four outcomes deliver nothing, and an
    /// accepted ⌘K route that does nothing without a trace is the failure this whole surface's
    /// logging exists for — `revealInSourcePane` shipped two silent `return`s of exactly this shape.
    @Test func everyRefusalIsLoggedRatherThanReturningSilently() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String) {",
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

    /// **The pane it switches is the one ⌘K was aimed at, read once.**
    ///
    /// `aimedAtRight` is computed over the layout, so re-reading it per statement is how
    /// `aimOrganize` came to reveal a right-pane scope into the left pane. Both writes have to name
    /// the same side, and the side has to be a binding rather than the expression twice.
    /// `@MainActor` for one reason and one only: `PaneTabWiringTests.argumentTokens` is a member of
    /// a `@MainActor` suite. Written on the test rather than on this suite so nothing else here
    /// silently inherits an isolation it does not need.
    @MainActor
    @Test func bothWritesNameTheSameCapturedPane() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String) {",
            in: try Self.source("CommandPaletteHost.swift"))
        let code = Self.codeOnly(body)
        #expect(code.contains("let isLeft = !aimedAtRight"),
                "the aimed pane is no longer captured once at the top")
        // Counted, not merely present: a second live read of `aimedAtRight` in here is the shape
        // that made the Organize route reveal into the wrong pane.
        #expect(code.components(separatedBy: "aimedAtRight").count - 1 == 1,
                "the aim is read more than once in the switch — the two writes can name different panes")
        let sides = PaneTabWiringTests.argumentTokens(labelled: "isLeft", in: code)
        #expect(sides.count >= 2 && sides.allSatisfy { $0 == "isLeft" },
                "a side argument in the switch names something other than the captured pane: \(sides)")
    }

    /// **The link toggle deliberately does not apply**, and the absence is asserted because it is
    /// the kind of thing a later session adds "for consistency".
    ///
    /// The source switch is per-pane — the sibling's provider is untouched — so a linked follow
    /// would move it to a folder path relativized against a source it is not showing. That is
    /// verbatim the defect `revealInSourcePane`'s doc records and the one
    /// `FileActionHandler.focusFolder`'s `suppressLinkedNavigation` exists for.
    /// `focusOn(relativePath:isLeft:)` is the single-pane door, which is also what the `.folder`
    /// route has always used, so this introduces no asymmetry between the two path rows.
    @Test func theSwitchMovesOnePaneAndNeverFollowsTheLink() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String) {",
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
