import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The last step between an accepted ⌘K route and nothing happening. The palette's index is a
/// snapshot from when it opened while the root read at ↩ is live, so a provider changing under an
/// open palette reaches `revealInSourcePane`'s refusals, and each must log, never return silently.
/// Extracted because the caller is a method on a SwiftUI `View` with `@State`.
@Suite struct PaletteRevealOutcomeTests {
    private static let root = "/Users/x/Documents"

    @Test func aPathInsideTheRootBecomesTheRelativeFocus() {
        #expect(ContentView.revealOutcome(for: "\(Self.root)/Clients/Legal", under: Self.root)
                == .focus(relativePath: "Clients/Legal"))
    }

    /// The root itself is the empty relative path, which is how `focusOn("")` names it.
    @Test func theRootItselfIsTheEmptyRelativePath() {
        #expect(ContentView.revealOutcome(for: Self.root, under: Self.root) == .focus(relativePath: ""))
    }

    /// An empty root never claims a path: an empty base prefixes every absolute path.
    /// `PathBoundary.relativize` guards this.
    @Test func noSourceIsRefusedRatherThanMatchingEverything() {
        #expect(ContentView.revealOutcome(for: "/anywhere", under: "") == .noSource)
    }

    /// The reachable refusal: the pane moved to another source while the palette was up, so the row
    /// names a path the new root doesn't contain.
    @Test func aPathOutsideTheRootNamesTheRootItIsNotIn() {
        #expect(ContentView.revealOutcome(for: "/Users/x/Dropbox/Legal", under: Self.root)
                == .outsideSource(root: Self.root))
    }

    /// A sibling whose name merely starts with the root isn't inside it (the prefix trap
    /// `PathBoundary` closes), or the pane would get a garbage relative path.
    @Test func aSiblingSharingThePrefixIsNotInside() {
        #expect(ContentView.revealOutcome(for: "/Users/x/DocumentsOld/Legal", under: Self.root)
                == .outsideSource(root: Self.root))
    }

    /// The call site goes through the rule and logs on both refusals, read as text since `MacApp/` is
    /// in no SPM package.
    @Test func theRevealGoesThroughTheRuleAndSaysSoOnBothRefusals() throws {
        let text = try macAppFile("CommandPaletteHost.swift")
        #expect(text.contains("switch Self.revealOutcome(for: absolutePath, under: root ?? lensProviderRootExpanded)"),
                "the reveal carries its own copy of the rule again — the branches this suite pins are not the ones that run")
        let reveal = try declarationBody(of: "private func revealInSourcePane(", in: text)
        for branch in ["case .noSource:", "case .outsideSource(let root):"] {
            let start = try #require(reveal.range(of: branch), "\(branch) is gone from the reveal")
            // The arm alone, up to the next `case .`: a fixed window reads into the next arm's log.
            let rest = reveal[start.upperBound...]
            let arm = rest[..<(rest.range(of: "case .")?.lowerBound ?? rest.endIndex)]
            #expect(arm.contains("Logger.shared.warning("),
                    "\(branch) returns without a word — an accepted route delivering nothing, with no trace")
        }
        // The person route's exit must log too: the log call that says it, not any earlier one.
        let code = sourceCodeOnly(text)
        let person = try #require(code.range(of: "is no longer in the registry"),
                                  "↩ on a person the registry has dropped goes back to doing nothing silently")
        #expect(code[..<person.lowerBound].suffix(80).contains("Logger.shared.warning("),
                "the dropped-person exit no longer logs a warning")
    }
}
