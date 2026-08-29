import AppKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// §11's two deferred verbs, landed (proposal O10). The menu is where a keyboard user finds a
/// plan at all, and until now `Plan…` was reachable only by locating the card and clicking it.
@MainActor
@Suite struct RestructureMenuVerbTests {

    /// **Both items exist in the Organize menu**, which is the whole claim — a verb with a
    /// handler and no menu route cannot be found without already knowing where to look.
    @Test func theOrganizeMenuCarriesBothVerbs() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        let titles = organize.items.map(\.title)
        #expect(titles.contains("Plan This Folder’s Shape…"))
        #expect(titles.contains("Set Up Like Its Siblings"))
    }

    /// **Above the Undo divider.** These are things to do with a folder; Undo is about a landing
    /// that already happened, and §11's one hard constraint is that it not be mistaken for ⌘Z.
    @Test func theyPrecedeTheLedgerUndo() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        let titles = organize.items.map(\.title)
        let plan = try #require(titles.firstIndex(of: "Plan This Folder’s Shape…"))
        let setUp = try #require(titles.firstIndex(of: "Set Up Like Its Siblings"))
        let undo = try #require(titles.firstIndex(of: "Undo This Reorganisation"))
        #expect(plan < undo)
        #expect(setUp < undo)
        #expect(plan < setUp, "plan then set up — the order the roadmap lists them in")
    }

    /// **No chords.** This menu's own rule, and the palette law: a verb reaches ⌘K only after it
    /// has a menu item, never the other way round.
    @Test func neitherVerbTakesAChord() throws {
        let organize = try #require(NSApp.mainMenu?.items
            .first { $0.title == "Organize" }?.submenu)
        for title in ["Plan This Folder’s Shape…", "Set Up Like Its Siblings"] {
            let item = try #require(organize.items.first { $0.title == title })
            #expect(item.keyEquivalent.isEmpty, "\(title) took a chord")
        }
    }

    /// The Edit menu stays clean of them — the constraint that keeps the ledger undo out of it
    /// applies to its neighbours too.
    @Test func theEditMenuCarriesNoneOfThem() throws {
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let titles = edit.items.map(\.title)
        for title in ["Plan This Folder’s Shape…", "Set Up Like Its Siblings",
                      "Undo This Reorganisation"] {
            #expect(!titles.contains(title), "\(title) must not sit beside ⌘Z's Undo")
        }
    }

    /// A request is a VALUE the workspace carries out — a sheet presented from the menu bar
    /// would sit outside the anchor that keeps it alive across a lens switch.
    @Test func aRequestReFiresWhenTheSameVerbIsPressedTwice() {
        let first = RestructureVerbRequest(verb: .plan, folder: "/x/Finance")
        let second = RestructureVerbRequest(verb: .plan, folder: "/x/Finance")
        #expect(first != second,
                "two presses of one item must not be swallowed as 'no change'")
        #expect(first.verb == second.verb)
        #expect(first.folder == second.folder)
    }
}
