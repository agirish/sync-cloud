import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Dashboard

/// What a pane-bar edit leaves in `~/sync-cloud.log`: a control taken off the bar is gone, not
/// moved to ⋯, so "my Delete button disappeared" needs a line to read. `.serialized` orders only
/// this suite, while `Logger.shared.entries` is a process-wide buffer capped at 1000 entries, so
/// every read, presence and absence alike, comes from a `LogCapture` opened before the edit ("A log
/// assertion reading a window that has already rolled" in `docs/flaky-tests.md`), and nothing
/// outside this file writes the `[panebar] User …` predicate.
@MainActor
@Suite(.serialized) struct PaneBarEditLogTests {

    private static let defaultEncoded =
        "viewMode,collapse,backForward,scan,info,newFolder,sort,hiddenFiles,delete,typeFilter,search"

    /// The bar after someone drags Delete off it.
    private static let withoutDelete = PaneBarArrangement(
        PaneBarArrangement.default.items.filter { $0 != .delete })

    /// Removing a control says what went and what is left, which answers "what does my bar look
    /// like now" for someone who finds a button missing.
    @Test func testRemovingAControlNamesItAndTheBarItLeftBehind() {
        #expect(PaneBarEditLog.message(from: .default, to: Self.withoutDelete)
                == "[panebar] User removed Delete from the pane bar — it is now "
                + "viewMode,collapse,backForward,scan,info,newFolder,sort,hiddenFiles,typeFilter,search")
    }

    /// A result that is the shipped set says so. The tail is read off the result, not the gesture,
    /// so any edit that lands on the default is labelled the same way.
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

    /// A pure reorder adds and removes nothing, so it needs its own verb, or it would read as a
    /// no-op.
    @Test func testAReorderIsNamedAsAReorder() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        let after = PaneBarArrangement(encoded: "flexibleSpace,sort,scan")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User reordered the pane bar — it is now flexibleSpace,sort,scan")
    }

    /// An edit that both adds and removes says both.
    @Test func testAnEditThatBothAddsAndRemovesSaysBoth() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        let after = PaneBarArrangement(encoded: "flexibleSpace,scan,search")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User added Search to the pane bar and removed Sort"
                + " — it is now flexibleSpace,scan,search")
    }

    /// Spacers repeat, so the difference must count, not compare sets: a set difference would call
    /// a second Space a reorder.
    @Test func testGainingASecondSpacerCountsAsAnAdd() {
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,space")
        let after = PaneBarArrangement(encoded: "flexibleSpace,scan,space,space")
        #expect(before.items.count == 3 && after.items.count == 4, "the fixture must really repeat")
        #expect(PaneBarEditLog.message(from: before, to: after)
                == "[panebar] User added Space to the pane bar — it is now flexibleSpace,scan,space,space")
    }

    /// A no-op writes no line. The sheet reaches one on every Move Left at index 0, every Remove on
    /// Scan, and every drag dropped back where it started.
    @Test func testAnEditThatChangesNothingIsNotLogged() async {
        let log = LogCapture()

        let bar = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        #expect(PaneBarEditLog.message(from: bar, to: bar) == nil)
        #expect(!PaneBarEditLog.record(from: bar, to: bar), "record claimed it wrote a line")
        // A remove the arrangement refuses (Scan is pinned), the way the sheet reaches a no-op.
        var refused = bar
        refused.remove(at: 1)
        #expect(refused == bar, "the fixture must actually be refused, or this proves nothing")
        #expect(!PaneBarEditLog.record(from: bar, to: refused))
        // After both calls, so a capture that holds it was listening across them.
        let marker = "panebar-edit-noop-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let entries = await log.entries
        #expect(entries.contains { $0.message == marker },
                "the capture never saw this test's own line — this absence proves nothing")
        #expect(!entries.contains { $0.message.hasPrefix("[panebar] User ") },
                "an edit that changed nothing was written to the log anyway")
    }

    /// A real edit reaches the log at `info` through `record`, not just the pure message function.
    @Test func testARealEditReachesTheLog() async {
        let log = LogCapture()

        #expect(PaneBarEditLog.record(from: .default, to: Self.withoutDelete))

        // From the capture, not the whole buffer, where an earlier run's identical line could
        // stand in for this one.
        let written = await log.entries.last { $0.message.hasPrefix("[panebar] User removed Delete") }
        #expect(written?.message == "[panebar] User removed Delete from the pane bar — it is now "
                + "viewMode,collapse,backForward,scan,info,newFolder,sort,hiddenFiles,typeFilter,search")
        #expect(written?.level == .info, "a user rearranging their own bar is not a warning")
    }
}
