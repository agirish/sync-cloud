import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// ⌘K switches to the source a typed path is in. The trap: a provider change runs its own
/// navigation reset on the next view update, so `aimProvider` then `focusOn` would land the pane at
/// the source root with the typed folder silently dropped.
///
/// The decision is the pure `ContentView.sourceSwitchOutcome`; the ordering is a source scan of
/// positions, which proves the order, not that the pane lands on the folder in a running app.
@Suite struct PaletteSourceSwitchTests {
    static let dropbox = "/Users/x/Dropbox"

    /// A probe that records whether it was asked: the laziness below is a claim that the disk is
    /// not touched, which a `PathKind` passed by value can't express.
    private final class Probe: @unchecked Sendable {
        let answer: PathKind
        private(set) var calls = 0
        init(_ answer: PathKind) { self.answer = answer }
        func kind() -> PathKind { calls += 1; return answer }
    }

    // MARK: The decision

    /// `(path, namedRoot, kind, outcome)`, one row per case.
    @Test(arguments: [
        ("\(PaletteSourceSwitchTests.dropbox)/Clients/Legal", PaletteSourceSwitchTests.dropbox, PathKind.directory,
         ContentView.SourceSwitchOutcome.switchAndFocus(relativePath: "Clients/Legal")),
        // The source's own root is the pane's top, `focusOn("")`, as in `revealOutcome`.
        (PaletteSourceSwitchTests.dropbox, PaletteSourceSwitchTests.dropbox, .directory, .switchAndFocus(relativePath: "")),
        // A pasted file's path goes to its folder. Decided here, since the router doesn't `stat`
        // outside the aimed source and can't tell a file from a folder.
        ("\(PaletteSourceSwitchTests.dropbox)/Clients/invoice.pdf", PaletteSourceSwitchTests.dropbox, .file, .switchAndFocus(relativePath: "Clients")),
        // A file at the source root lands on `""`, the pane's own top.
        ("\(PaletteSourceSwitchTests.dropbox)/invoice.pdf", PaletteSourceSwitchTests.dropbox, .file, .switchAndFocus(relativePath: "")),
        // Nothing there is refused, not half delivered. ↩ is the first moment the disk may be asked
        // (`PalettePath` forbids the stall earlier), and landing on the parent is a silent drop.
        ("\(PaletteSourceSwitchTests.dropbox)/Gone", PaletteSourceSwitchTests.dropbox, .missing, .nothingAtThatPath),
        // The index is a snapshot from when the palette opened, so an id may no longer name an
        // enabled source.
        ("\(PaletteSourceSwitchTests.dropbox)/Legal", nil, .directory, .noSuchSource),
        // An empty root must never claim a path: an empty base prefixes every absolute path (as
        // `PathBoundary.relativize` guards).
        ("\(PaletteSourceSwitchTests.dropbox)/Legal", "", .directory, .noSuchSource),
        // The source moved under an open palette: the row was built against the root it had then.
        ("/Users/x/Documents/Legal", PaletteSourceSwitchTests.dropbox, .directory, .outsideNamedSource(root: PaletteSourceSwitchTests.dropbox)),
        // A sibling whose name merely starts with the root isn't inside it (`PathBoundary`'s
        // prefix rule); otherwise the pane would switch to Dropbox with a garbage path.
        ("/Users/x/DropboxOld/Legal", PaletteSourceSwitchTests.dropbox, .directory, .outsideNamedSource(root: PaletteSourceSwitchTests.dropbox)),
    ] as [(String, String?, PathKind, ContentView.SourceSwitchOutcome)])
    func theOutcomeFollowsWhereThePathIs(path: String, namedRoot: String?, kind: PathKind,
                                         expected: ContentView.SourceSwitchOutcome) {
        #expect(ContentView.sourceSwitchOutcome(path: path, namedRoot: namedRoot, kind: kind) == expected)
    }

    // MARK: The disk is asked once, and only when the answer can matter

    /// `kind` is `@autoclosure`, so the index questions are answered without a `stat`. These sources
    /// aren't on screen, and may be a network mount or external drive that no longer answers.
    @Test func theDiskIsNotAskedWhenTheSourceCannotTakeThePathAnyway() {
        let gone = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal", namedRoot: nil,
                                            kind: gone.kind())
        #expect(gone.calls == 0, "a source that is gone was stat'ed anyway")

        let outside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "/Users/x/Documents/Legal",
                                            namedRoot: Self.dropbox, kind: outside.kind())
        #expect(outside.calls == 0, "a path outside the named source was stat'ed anyway")

        // Positive control: the closure is called when it matters.
        let inside = Probe(.directory)
        _ = ContentView.sourceSwitchOutcome(path: "\(Self.dropbox)/Legal",
                                            namedRoot: Self.dropbox, kind: inside.kind())
        #expect(inside.calls == 1,
                "the one path that must be checked was asked \(inside.calls) times")
    }

    // MARK: The ordering — the whole of the deferral

    /// Three statements, one order, each position load-bearing:
    /// - `focusOn` first, so when SwiftUI evaluates either `onChange` the pane names both.
    /// - The provider write through `adoptProviderForTab`, which arms `pendingTabProviderChanges`;
    ///   otherwise `onChange(of: leftProviderId)` re-homes the pane and drops the typed folder.
    /// - `refreshForTabSwitch` last, since it resolves both providers by the ids as they now are.
    @Test func theSwitchNavigatesFirstThenAdoptsUnderSuppressionThenReloads() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try macAppFile("CommandPaletteHost.swift"))
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

        // Writers that run the full reset: `aimProvider` and a bare id assignment.
        // `theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper` covers only the tabs file.
        for wrong in ["aimProvider(", "leftProviderId =", "rightProviderId =",
                      "$leftProviderId", "$rightProviderId", "retargetPane("] {
            #expect(!body.contains(wrong),
                    "the source switch writes the pane's provider with `\(wrong)`, which does not suppress the navigation reset")
        }
    }

    /// Every refusal logs. Three of the four outcomes deliver nothing, and an accepted ⌘K route
    /// must never do nothing without a trace.
    @Test func everyRefusalIsLoggedRatherThanReturningSilently() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try macAppFile("CommandPaletteHost.swift"))
        for branch in ["case .noSuchSource:", "case .outsideNamedSource(let root):",
                       "case .nothingAtThatPath:"] {
            let start = try #require(body.range(of: branch),
                                     "\(branch) is gone from the switch — the rule has an answer nothing acts on")
            // The arm alone, up to the next `case .`: a fixed window reads into the next arm's log.
            let rest = body[start.upperBound...]
            let arm = rest[..<(rest.range(of: "case .")?.lowerBound ?? rest.endIndex)]
            #expect(arm.contains("Logger.shared.warning("),
                    "\(branch) returns without a word — an accepted route delivering nothing, with no trace")
        }
    }

    /// The pane it switches is the one ⌘K was aimed at, read once. `aimedAtRight` is computed over
    /// the layout, so re-reading it per statement can reveal into the wrong pane. Both writes name
    /// the same side, through a binding, not the expression twice.
    @Test func bothWritesNameTheSameCapturedPane() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try macAppFile("CommandPaletteHost.swift"))
        let code = body
        // A caller may name its pane (Ask Claude setting one side of Compare); otherwise the aim.
        #expect(code.contains("let isLeft = paneIsLeft ?? !aimedAtRight"),
                "the aimed pane is no longer captured once at the top")
        // Counted: a second live read of `aimedAtRight` could name the other pane.
        #expect(code.components(separatedBy: "aimedAtRight").count - 1 == 1,
                "the aim is read more than once in the switch — the two writes can name different panes")
        let sides = PaneTabWiringTests.argumentTokens(labelled: "isLeft", in: code)
        #expect(sides.count >= 2 && sides.allSatisfy { $0 == "isLeft" },
                "a side argument in the switch names something other than the captured pane: \(sides)")
    }

    /// The link toggle deliberately doesn't apply: a linked follow would move the sibling to a
    /// path relativized against a source it isn't showing (what `suppressLinkedNavigation` exists
    /// for). `focusOn(relativePath:isLeft:)` is the single-pane call the `.folder` route uses too.
    @Test func theSwitchMovesOnePaneAndNeverFollowsTheLink() throws {
        let body = try declarationBody(
            of: "private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {",
            in: try macAppFile("CommandPaletteHost.swift"))
        let code = body
        for both in ["focusBoth", "PaneLinkPreference", "isLinked", "PaneSideChoice.sibling"] {
            #expect(!code.contains(both),
                    "the cross-source switch reaches for the sibling pane (`\(both)`) — it is on another source and would be handed a path from this one's tree")
        }
    }
}
