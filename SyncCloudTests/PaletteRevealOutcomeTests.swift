import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **The last thing between an accepted ⌘K route and nothing at all happening.**
///
/// `revealInSourcePane` had two silent `return`s until 2026-08-20. Neither is supposed to be
/// reachable — a folder row is built from the survey under this very root, and Go to Folder refuses
/// a typed path outside `PaletteIndex.providerRoot` before offering it — but "not supposed to be
/// reachable" is exactly the claim a log line exists for. The palette's index is a **snapshot**
/// taken when it opened while the root read at ↩ time is live, so a provider that changes underneath
/// an open palette arrives here holding a row the user watched do nothing.
///
/// The rule is extracted because the caller is a method on a SwiftUI `View` with `@State`, which no
/// test can construct. `theRevealGoesThroughTheRuleAndSaysSoOnBothRefusals` is the call-site half —
/// without it this is a rule one revert from being unused.
@Suite struct PaletteRevealOutcomeTests {

    private static let root = "/Users/x/Documents"

    @Test func aPathInsideTheRootBecomesTheRelativeFocus() {
        #expect(ContentView.revealOutcome(for: "\(Self.root)/Clients/Legal", under: Self.root)
                == .focus(relativePath: "Clients/Legal"))
    }

    /// The root itself is the pane's own top, which `focusOn("")` is how you say.
    @Test func theRootItselfIsTheEmptyRelativePath() {
        #expect(ContentView.revealOutcome(for: Self.root, under: Self.root) == .focus(relativePath: ""))
    }

    /// **An empty root must never claim a path.** `PathBoundary.relativize` guards this by name —
    /// an empty base prefixes every absolute path, so without it a pane with no source would answer
    /// "yes, and it is at Users/x/Documents/…" for anything at all.
    @Test func noSourceIsRefusedRatherThanMatchingEverything() {
        #expect(ContentView.revealOutcome(for: "/anywhere", under: "") == .noSource)
    }

    /// The reachable one: the pane moved to another source while the palette was up, so a row built
    /// against the old root arrives naming a path the new one does not contain.
    @Test func aPathOutsideTheRootNamesTheRootItIsNotIn() {
        #expect(ContentView.revealOutcome(for: "/Users/x/Dropbox/Legal", under: Self.root)
                == .outsideSource(root: Self.root))
    }

    /// A sibling whose name merely *starts* with the root is not inside it — the prefix trap
    /// `PathBoundary` exists to close, asserted here because this is the caller that would hand the
    /// pane a garbage relative path if it reopened.
    @Test func aSiblingSharingThePrefixIsNotInside() {
        #expect(ContentView.revealOutcome(for: "/Users/x/DocumentsOld/Legal", under: Self.root)
                == .outsideSource(root: Self.root))
    }

    /// **The call site really goes through it, and really says something on both refusals.**
    /// `MacApp/` is in no SPM package, so this half can only be read as text.
    @Test func theRevealGoesThroughTheRuleAndSaysSoOnBothRefusals() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/CommandPaletteHost.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read CommandPaletteHost.swift — the checks below would be vacuous")
        #expect(text.contains("switch Self.revealOutcome(for: absolutePath, under: root ?? lensProviderRootExpanded)"),
                "the reveal carries its own copy of the rule again — the branches this suite pins are not the ones that run")
        for branch in ["case .noSource:", "case .outsideSource(let root):"] {
            let start = try #require(text.range(of: branch), "\(branch) is gone from the reveal")
            let body = String(text[start.upperBound...].prefix(220))
            #expect(body.contains("Logger.shared.warning"),
                    "\(branch) returns without a word — an accepted route delivering nothing, with no trace")
        }
        // The person route's own silent exit, which is the same defect one case up.
        let person = try #require(text.range(of: "is no longer in the registry"),
                                  "↩ on a person the registry has dropped goes back to doing nothing silently")
        #expect(text[..<person.lowerBound].contains("Logger.shared.warning"))
    }
}
