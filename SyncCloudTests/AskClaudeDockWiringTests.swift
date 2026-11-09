import Testing
import Foundation
@testable import SyncCloud

/// How the window wires the dock's rules: what makes it busy, the room rule's first answer, and
/// what Info does around the dock's fold. Each a call-site check, paired with the pure rule's own
/// tests (`PinRoomTests`, `AskClaudeAppTests`).
@Suite struct AskClaudeDockWiringTests {

    private static func askClaude() throws -> String { try macAppFile("ContentView+AskClaude.swift") }
    private static func paneInfo() throws -> String { try macAppFile("ContentView+PaneInfo.swift") }

    /// A comparison overlay makes the window busy whether the column is open or not, so ◨ and ⌘J
    /// (both off while busy) never open the column beneath one.
    @Test func aComparisonOverlayIsBusyWithTheColumnClosedToo() throws {
        let body = CodeText(try declarationBody(of: "var askClaudeStateBusy: String? {", in: Self.askClaude()))
        #expect(body.contains("if compareDifferencePair != nil || compareFilePair != nil { return \"a comparison is open\" }"))
        #expect(!body.contains("askClaudeOpen"), "the comparison counts as busy only with the column open again")
    }

    /// The first measured answer has no previous one: the 40 pt margin is for a line the window
    /// crossed, and at launch it crossed none. `PinRoomTests` holds the rule with and without one.
    @Test func theFirstMeasuredAnswerKeepsNoMargin() throws {
        let body = CodeText(try declarationBody(of: "func askClaudePinInputChanged(_ input: PaneLogic.PinRoomInput) {",
                                                in: Self.askClaude()))
        #expect(body.contains("PaneLogic.pinRoom(input, previous: askClaudePinDecided ? askClaudePinState : nil)"))
        #expect(body.contains("if input.rowWidth > 0 { askClaudePinDecided = true }"))
        // The rule itself: no previous answer docks at exactly what it needs; the overlay's needs 40 more.
        let input = PaneLogic.PinRoomInput(workspace: .browse, rowWidth: 774, columnWidth: 373, gutter: 0,
                                           sidebarShown: true, sidebarStored: 180)
        #expect(PaneLogic.pinRoom(input, previous: nil).fits)
        #expect(!PaneLogic.pinRoom(input, previous: .overlay).fits)
    }

    /// Organize's spine drawer is for a fold made by hand. The dock's fold is computed, and a drawer
    /// then would cover To File, the room the fold was made for: asking for Info opens the pane.
    @Test func organizesSpineDrawerIsForAHandFoldOnly() throws {
        let source = try Self.paneInfo()
        let spine = CodeText(try declarationBody(of: "var organizeSpineHoldsInfo: Bool {", in: source))
        #expect(spine.contains("panesStoredHiddenForCurrentTab"))
        #expect(!spine.contains("panesHiddenForCurrentTab"), "the drawn fold, the dock's included, again")
        let set = CodeText(try declarationBody(of: "func setPaneInfo(isLeft: Bool, _ on: Bool) {", in: source))
        #expect(set.contains("if on, isLeft, pinFoldHoldsInfo { askClaudeReleasePinFold() }"))
    }

    /// Under the dock's fold, Edit's file pane is drawn folded though the person left it open: ⌘I
    /// and Get Info open it, as Organize's do, rather than call it hidden. A pane the person folded
    /// stays folded, and Info unavailable, as without the column.
    @Test func infoUnderTheDocksFoldOpensEditsPaneToo() throws {
        #expect(ContentView.pinFoldHoldsInfo(workspace: .editor, drawnHidden: true, storedHidden: false),
                "Edit's pane under the dock's fold has no way to Info")
        #expect(ContentView.pinFoldHoldsInfo(workspace: .filing, drawnHidden: true, storedHidden: false))
        #expect(!ContentView.pinFoldHoldsInfo(workspace: .editor, drawnHidden: true, storedHidden: true), "a hand fold")
        #expect(!ContentView.pinFoldHoldsInfo(workspace: .editor, drawnHidden: false, storedHidden: false), "nothing folded")
        #expect(!ContentView.pinFoldHoldsInfo(workspace: .browse, drawnHidden: true, storedHidden: false))
        #expect(!ContentView.pinFoldHoldsInfo(workspace: .compare, drawnHidden: true, storedHidden: false))
        // The window: ⌘I's availability and Info's drawing read it.
        let source = try Self.paneInfo()
        let rule = CodeText(try declarationBody(of: "var pinFoldHoldsInfo: Bool {", in: source))
        #expect(rule.contains("Self.pinFoldHoldsInfo(workspace: selectedWorkspace, drawnHidden: panesHiddenForCurrentTab, storedHidden: panesStoredHiddenForCurrentTab)"))
        let available = CodeText(try declarationBody(of: "func paneInfoAvailable(isLeft: Bool) -> Bool {", in: source))
        #expect(available.contains("organizeSpineHoldsInfo || pinFoldHoldsInfo"))
    }

    /// Docked, the column has no tuck: one made over a narrow window ends when it docks, so ◨, the
    /// header's ✕ and ⌘J close it at the first press, and narrowing again draws it over the
    /// workspace rather than hiding it.
    @MainActor @Test func aTuckEndsWhenTheColumnDocks() throws {
        let visibility = AskClaudeVisibility(restoredOpen: true)
        visibility.tucked = true
        visibility.toggle()
        #expect(visibility.isOpen && !visibility.tucked, "over the workspace, the first press brings it back")
        visibility.tucked = true
        visibility.columnDocked()
        #expect(!visibility.tucked, "docked, the column kept its tuck")
        visibility.toggle()
        #expect(!visibility.isOpen, "◨ on a docked column did not close it")
        // The window: the room rule's handler ends the tuck on a docked answer, and ◨ runs the rule.
        let source = try Self.askClaude()
        let handler = CodeText(try declarationBody(of: "func askClaudePinInputChanged(_ input: PaneLogic.PinRoomInput) {", in: source))
        #expect(handler.contains("if verdict.fits, input.rowWidth > 0 { askClaudeHolder.visibility.columnDocked() }"))
        let toggle = CodeText(try declarationBody(of: "func toggleAskClaude() {", in: source))
        #expect(toggle.contains("visibility.toggle()"))
    }

    /// A pane opened by hand under the dock's fold is released until the rule stops wanting the
    /// fold, not until the column stops being docked: the release sends the column over the
    /// workspace when the opened pane leaves no room, and ending it there would fold the pane again
    /// at once. A workspace switch ends it too, so Edit's list folds after Organize's was opened.
    @Test func theReleaseLastsUntilTheFoldIsOverOrTheWorkspaceChanges() throws {
        let source = try Self.askClaude()
        let held = CodeText(try declarationBody(of: "var askClaudePinFoldHeld: Bool {", in: source))
        #expect(held.contains("askClaudePinState.folds"))
        #expect(!held.contains("askClaudePinnedShown") && !held.contains("askClaudePinFoldWanted") && !held.contains(".fits"),
                "the release ends again whenever the column is drawn over the workspace")
        #expect(try CallArguments(of: "AskClaudeHost(", in: normalizedCode(source)).passes("foldHeld", "askClaudePinFoldHeld"))
        let host = CodeText(try declarationBody(of: "struct AskClaudeHost: ViewModifier {", in: source))
        #expect(host.contains(".onChange(of: foldHeld) { _, held in if !held { onFoldEnded() } }"))
        let window = try macAppFile("ContentView.swift")
        let switched = CodeText(try declarationBody(of: ".onChange(of: selectedWorkspace) { _, workspace in", in: window))
        #expect(switched.contains("askClaudePinFoldEnded()"), "a release outlives its workspace")
    }

    /// `show_in_app info` where no pane can show Info says why, rather than that there is no place
    /// called info.
    @Test func infoWithNoPaneToShowItSaysWhy() throws {
        let source = try Self.askClaude()
        #expect(CodeText(source).contains(
            "guard paneInfoAvailable(isLeft: isLeft) else { return .unavailable(paneInfoUnavailableSentence) }"))
        // The raw source: `CodeText` reads code, and blanks what a string literal says.
        #expect(try Self.paneInfo().contains("? \"Info isn’t available here: Edit’s file pane is hidden.\""))
    }
}
