import AppKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// Restructure's two folder verbs in the Organize menu, which is where a keyboard user finds a
/// plan at all; otherwise `Plan…` is reachable only by finding the card and clicking it.
@MainActor
@Suite struct RestructureMenuVerbTests {

    /// Both items exist in the Organize menu: a verb with a handler and no menu route can't be
    /// found without already knowing where to look.
    @Test func theOrganizeMenuCarriesBothVerbs() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        let titles = organize.items.map(\.title)
        #expect(titles.contains("Plan This Folder’s Shape…"))
        #expect(titles.contains("Set Up Like Its Siblings"))
    }

    /// Above the Undo divider. These act on a folder; Undo reverses a landing that already
    /// happened, and must not be mistaken for ⌘Z.
    @Test func theyPrecedeTheLedgerUndo() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        let titles = organize.items.map(\.title)
        let plan = try #require(titles.firstIndex(of: "Plan This Folder’s Shape…"))
        let setUp = try #require(titles.firstIndex(of: "Set Up Like Its Siblings"))
        let undo = try #require(titles.firstIndex(of: "Undo This Reorganization…"))
        #expect(plan < undo)
        #expect(setUp < undo)
        #expect(plan < setUp, "plan then set up — the order the roadmap lists them in")
    }

    /// No chords, by this menu's own rule. (A verb reaches ⌘K only after it has a menu item, never
    /// the other way round.)
    @Test func neitherVerbTakesAChord() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        for title in ["Plan This Folder’s Shape…", "Set Up Like Its Siblings"] {
            let item = try #require(organize.items.first { $0.title == title })
            #expect(item.keyEquivalent.isEmpty, "\(title) took a chord")
        }
    }

    /// The Edit menu stays clean of them: what keeps the ledger undo away from ⌘Z keeps its
    /// neighbours away too.
    @Test func theEditMenuCarriesNoneOfThem() throws {
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
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

    /// Menu availability and the handler read one answer. `RestructureVerbResolver.resolve` owns
    /// and tests the decision, but no test can call both sites (`ContentView` can't be built here,
    /// and `carryOut` is private to another package's view). So this checks both pass the store
    /// gate and the scaffolded set. It can't see a wrong value, only a site that skips one, which
    /// would offer `Plan…` on a store the card withholds it for, or keep `Set Up Like Its Siblings`
    /// enabled after its scaffold landed.
    @Test func bothCallSitesAskTheResolverTheSameQuestion() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let menu = try String(contentsOf: repo.appendingPathComponent("MacApp/ShortcutCommands.swift"),
                              encoding: .utf8)
        let workspace = try String(
            contentsOf: repo.appendingPathComponent(
                "Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift"),
            encoding: .utf8)

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
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let artifacts = try String(
            contentsOf: repo.appendingPathComponent("MacApp/FilingArtifacts.swift"),
            encoding: .utf8)
        #expect(artifacts.contains("recordingTrend: Bool = false"),
                "the default must be the safe one — the test host takes the default")
        #expect(artifacts.contains("if recordingTrend { manager.stampStructureTrend() }"),
                "the stamp is gated, not unconditional")

        let app = try String(contentsOf: repo.appendingPathComponent("MacApp/SyncCloudApp.swift"),
                             encoding: .utf8)
        #expect(app.contains("recordingTrend: !isRunningTests"),
                "the launch site is the one that opts in, and it excludes the test host")

        // Positive control: `isRunningTests` is a real flag here, not a name that evaluates to
        // nothing.
        #expect(app.contains("XCTestConfigurationFilePath"))
    }
}
