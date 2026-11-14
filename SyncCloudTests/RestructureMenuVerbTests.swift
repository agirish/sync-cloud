import AppKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// Restructure's two folder verbs in the Organize menu, which is where a keyboard user finds a
/// plan at all; otherwise `Plan…` is reachable only by finding the card and clicking it.
@MainActor
@Suite struct RestructureMenuVerbTests {

    /// The Edit menu stays clean of them: what keeps the ledger undo away from ⌘Z keeps its
    /// neighbours away too.
    @Test func theEditMenuCarriesNoneOfThem() throws {
        let edit = try appMenu("Edit")
        let titles = edit.items.map(\.title)
        for title in ["Plan This Folder’s Shape…", "Set Up Like Its Siblings",
                      "Undo This Reorganization…"] {
            #expect(!titles.contains(title), "\(title) must not sit beside ⌘Z's Undo")
        }
    }

    /// A request is a value the workspace carries out, since a sheet presented from the menu bar
    /// would sit outside the anchor that keeps it alive across a lens switch. Two presses must
    /// differ, or the second is swallowed as no change.
    @Test func aRequestReFiresWhenTheSameVerbIsPressedTwice() {
        let first = RestructureVerbRequest(verb: .plan, folder: "/x/Finance")
        let second = RestructureVerbRequest(verb: .plan, folder: "/x/Finance")
        #expect(first != second,
                "two presses of one item must not be swallowed as 'no change'")
        #expect(first.verb == second.verb)
        #expect(first.folder == second.folder)
    }

    /// Menu availability and the handler read one answer from `RestructureVerbResolver.resolve`.
    /// Neither site can be called here, so this checks both pass the store gate and the scaffolded
    /// set: it can't see a wrong value, only a site that skips one.
    @Test func bothCallSitesAskTheResolverTheSameQuestion() throws {
        let menu = try macAppFile("ShortcutCommands.swift")
        let workspace = try repoFile("Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift")

        for (name, text) in [("the menu", menu), ("the workspace", workspace)] {
            #expect(text.contains("RestructureVerbResolver.resolve("),
                    "\(name) must read the shared resolution, not re-derive one")
            #expect(text.contains("storeIsReadable:"),
                    "\(name) drops the store gate")
            #expect(text.contains("alreadyScaffolded:"),
                    "\(name) drops the landed-scaffold check")
        }
        // Neither reaches past it to the finding lookup, the seam that would let the two drift.
        #expect(!menu.contains("RestructureVerbResolver.finding("),
                "the menu asks for a resolution, not a finding")
        #expect(!workspace.contains("RestructureVerbResolver.finding("),
                "and so does the workspace")
    }

    /// The app's own binary is the test host, so `SyncCloudApp`'s launch path runs under
    /// `xcodebuild test`, and an unconditional trend stamp would write into the developer's real
    /// `restructure.json` on every test run. `attach` defaults to not stamping and the launch site
    /// passes `!isRunningTests`. A source scan: it can't run the launch path, but it forbids an
    /// unconditional stamp in a function the test host calls.
    @Test func attachDoesNotWriteUnlessARealLaunchAsksItTo() throws {
        let artifacts = try macAppFile("FilingArtifacts.swift")
        #expect(artifacts.contains("recordingTrend: Bool = false"),
                "the default must be the safe one — the test host takes the default")
        #expect(artifacts.contains("if recordingTrend { manager.stampStructureTrend() }"),
                "the stamp is gated, not unconditional")

        let app = try macAppFile("SyncCloudApp.swift")
        #expect(app.contains("recordingTrend: !isRunningTests"),
                "the launch site is the one that opts in, and it excludes the test host")

        // Positive control: `isRunningTests` is a real flag here, not a name that evaluates to
        // nothing.
        #expect(app.contains("XCTestConfigurationFilePath"))
    }
}
