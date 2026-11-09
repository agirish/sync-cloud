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
        #expect(set.contains("if on, isLeft, organizePinFoldHoldsInfo { askClaudeReleasePinFold() }"))
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
