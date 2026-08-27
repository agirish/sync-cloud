import Testing
import Foundation
import Events
@testable import Dashboard

/// What a pane-bar edit leaves behind in `~/sync-cloud.log`.
///
/// The bar wrote **nothing at all** before this: `PaneBarArrangement`, the 700-line customize sheet
/// and the bar half of `DashboardViews` held zero `Logger` calls between them, in a module that logs
/// from five other files. That was survivable while a removal cost a pill and never an ability —
/// whatever left the bar was still in ⋯ — and `9db37173` ended that. A control taken off the bar is
/// gone now, and "my Delete button disappeared" had no trace anywhere to read.
///
/// **What makes the log assertions here safe**, since the note that stood in this spot credited
/// `.serialized` and that is not the mechanism: `.serialized` orders the tests *within this suite*,
/// while `Logger.shared.entries` is a process-wide buffer every other suite in the run is writing
/// into at the same time. Two things do the work. Every read below — presence and absence alike —
/// writes a UUID marker first and looks only at what follows it, because the buffer is capped at
/// 1000 entries and a read without a window passes for free once a sibling suite has rolled past
/// what this test wrote (`docs/flaky-tests.md`, mechanism 12). And the predicate is
/// `[panebar] User …`, which nothing outside this file writes, so no other suite can land a line
/// inside one of these windows. `.serialized` sits on top of both and keeps the windows short.
@MainActor
@Suite(.serialized) struct PaneBarEditLogTests {

    /// Awaits a fresh log task, so everything enqueued before it is visible in `entries`.
    private func flushLog() async {
        await Logger.shared.debug("panebar-edit-log flush marker").value
    }

    private static let defaultEncoded =
        "viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,preview,delete,search"

    /// The bar as it stands after someone drags Delete off it — the state the reported complaint is
    /// about, and the one with no record of how it got there.
    private static let withoutDelete = PaneBarArrangement(
        PaneBarArrangement.default.items.filter { $0 != .delete })

    /// Guards the fixture rather than assuming it: every message below is quoted as a literal, so a
    /// default arrangement that changed would make them wrong in a way nothing else would catch.
    @Test func testTheFixturesMatchTheShippedDefault() {
        #expect(PaneBarArrangement.default.encoded == Self.defaultEncoded)
        #expect(Self.withoutDelete.encoded ==
                "viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,preview,search")
    }

    /// Removing a control says what went and what is left. The second half is the point: a line
    /// naming only the control would not answer "what does my bar look like now", which is the
    /// question someone asks after finding a button missing.
    @Test func testRemovingAControlNamesItAndTheBarItLeftBehind() {
        #expect(PaneBarEditLog.message(from: .default, to: Self.withoutDelete)
                == "[panebar] User removed Delete from the pane bar — it is now "
                + "viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,preview,search")
    }

    /// The reverse, and the one line that has to name the default: a Restore is described by what
    /// it did plus the fact that the result *is* the shipped set. Nothing takes the sheet's word
    /// for which gesture ran — the tail is read off the result, so an edit that happens to land on
    /// the default arrangement is labelled the same way, truthfully.
    @Test func testRestoringTheDefaultSaysSo() {
        #expect(PaneBarEditLog.message(from: Self.withoutDelete, to: .default)
                == "[panebar] User added Delete to the pane bar — it is now "
                + "\(Self.defaultEncoded) (the default arrangement)")
        // …and an edit that lands anywhere else does not claim it.
        let elsewhere = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        let plusSearch = PaneBarArrangement(encoded: "flexibleSpace,scan,sort,search")
        #expect(PaneBarEditLog.message(from: elsewhere, to: plusSearch)
                == "[panebar] User added Search to the pane bar — it is now flexibleSpace,scan,sort,search")
    }

    /// A pure reorder adds and removes nothing, so it needs its own verb — without one it would be
    /// described as an edit that changed no items, which reads as a no-op and is not one.
    @Test func testAReorderIsNamedAsAReorder() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        let after = PaneBarArrangement(encoded: "flexibleSpace,sort,scan")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User reordered the pane bar — it is now flexibleSpace,sort,scan")
    }

    /// A drag from the palette onto an occupied slot both adds and removes; the line has to carry
    /// both, or half of what happened is invisible.
    @Test func testAnEditThatBothAddsAndRemovesSaysBoth() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        let after = PaneBarArrangement(encoded: "flexibleSpace,scan,search")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User added Search to the pane bar and removed Sort"
                + " — it is now flexibleSpace,scan,search")
    }

    /// Spacers repeat, so the difference has to count rather than compare sets. A set difference
    /// answers "nothing changed" for a bar that gained its second Space, and the line would then
    /// call a genuine add a reorder.
    @Test func testGainingASecondSpacerCountsAsAnAdd() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,space")
        let after = PaneBarArrangement(encoded: "flexibleSpace,scan,space,space")
        #expect(before.items.count == 3 && after.items.count == 4, "the fixture must really repeat")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User added Space to the pane bar — it is now flexibleSpace,scan,space,space")
    }

    /// **A no-op writes no line.** The sheet reaches this on every Move Left at index 0, every
    /// Remove on Scan, and every drag abandoned onto the pill it started from — the most ordinary
    /// gestures in the surface, and exactly the shape of the strip defect that logged a click on
    /// the already-active chip.
    @Test func testAnEditThatChangesNothingIsNotLogged() async {
        let marker = "panebar-edit-noop-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let bar = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        #expect(PaneBarEditLog.message(from: bar, to: bar) == nil)
        #expect(!PaneBarEditLog.record(from: bar, to: bar), "record claimed it wrote a line")
        // A remove that the arrangement refuses (Scan is pinned) reaches the same place from the
        // direction the sheet actually takes.
        var refused = bar
        refused.remove(at: 1)
        #expect(refused == bar, "the fixture must actually be refused, or this proves nothing")
        #expect(!PaneBarEditLog.record(from: bar, to: refused))
        await flushLog()

        let entries = Logger.shared.entries
        #expect(entries.contains { $0.message == marker },
                "the log window rolled past the marker — this absence proves nothing")
        let since = entries.drop(while: { $0.message != marker })
        #expect(!since.contains { $0.message.hasPrefix("[panebar] User ") },
                "an edit that changed nothing was written to the log anyway")
    }

    /// And the other half: a real edit does reach the log, at `info`, through `record` — the pure
    /// message function being right is worth nothing if nothing calls it.
    @Test func testARealEditReachesTheLog() async {
        let marker = "panebar-edit-real-\(UUID().uuidString)"
        Logger.shared.info(marker)

        #expect(PaneBarEditLog.record(from: .default, to: Self.withoutDelete))
        await flushLog()

        let entries = Logger.shared.entries
        #expect(entries.contains { $0.message == marker },
                "the log window rolled past the marker — read the entries sooner")
        // Inside the marker window, not across the whole buffer: an identical line left by an
        // earlier run of this same test would otherwise stand in for the one this run wrote.
        let written = entries.drop(while: { $0.message != marker })
            .last { $0.message.hasPrefix("[panebar] User removed Delete") }
        #expect(written?.message == "[panebar] User removed Delete from the pane bar — it is now "
                + "viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,preview,search")
        #expect(written?.level == .info, "a user rearranging their own bar is not a warning")
    }
}
