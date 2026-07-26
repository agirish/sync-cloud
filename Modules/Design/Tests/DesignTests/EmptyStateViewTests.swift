import Testing
import SwiftUI
@testable import Design

/// Pins the public shape of `EmptyStateView` (H3): the unified blank-panel template every tab
/// renders through. These are API/behavior pins, not pixel tests — the component is pure
/// layout, so what matters is that the parameterized slots exist, stay public, and carry the
/// caller's copy and handlers through unchanged.
@Suite struct EmptyStateViewTests {

    @Test func actionCarriesTitleImageAndHandler() {
        var fired = false
        let action = EmptyStateView.Action("Find Duplicates", systemImage: "wand.and.stars") {
            fired = true
        }
        #expect(action.title == "Find Duplicates")
        #expect(action.systemImage == "wand.and.stars")
        action.handler()
        #expect(fired)
    }

    @Test func actionImageIsOptional() {
        let action = EmptyStateView.Action("Scan again") {}
        #expect(action.systemImage == nil)
    }

    /// Every caller shape constructs — one compile-and-run pin per variant, in one test
    /// (the view stores everything privately and renders pure layout, so there is nothing
    /// further to assert here; the VISUAL contract, including the `path:` slot's middle
    /// truncation, is pinned by `DesignSnapshotTests`).
    @Test func everyCallerShapeConstructs() {
        // The full L4 template: provider-named title, job explanation, safety-contract
        // caption, one primary action plus a quieter secondary.
        _ = EmptyStateView(
            icon: "wand.and.stars",
            tint: .green,
            title: "Find duplicates in iCloud",
            message: "Scan this provider for folders and files that repeat.",
            caption: "Nothing is removed without your confirmation, and everything is undoable.",
            primary: .init("Find Duplicates", systemImage: "wand.and.stars") {},
            secondary: .init("Scan again", systemImage: "arrow.clockwise") {}
        )
        // The Log's shape: icon + title + message, no caption, no actions.
        _ = EmptyStateView(icon: "doc.text", title: "No log entries yet",
                           message: "Activity shows up here.")
        // The narrow-host shape (Details sidebar, pane placeholders): same slots,
        // tighter layout.
        _ = EmptyStateView(icon: "info.circle", title: "No item selected",
                           message: "Select a file or folder in either pane.",
                           layout: .compact)
        // The missing-root shape: the `path:` slot (monospaced, middle-truncated file-system
        // detail) — previously the one initializer slot no test ever exercised.
        _ = EmptyStateView(
            icon: "externaldrive.badge.questionmark",
            title: "Folder not found",
            message: "The scanned folder is no longer at its recorded location.",
            path: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Projects",
            primary: .init("Choose Folder…") {}
        )
    }

    /// BOTH action buttons must carry `chromeHover` — the one hover choke point in this codebase.
    ///
    /// The secondary used to have none, so an empty state offering two side-by-side actions had a
    /// primary that lit up under the pointer and a companion that stayed completely inert: not
    /// "loud and quiet" but "live and dead". `HoverAffordanceMetrics` is by design `.none` at rest
    /// for every variant, and `chromeHover` drives itself from its own `onHover` state, so there
    /// is nothing to render or drive from a test — what IS checkable is that the modifier is on
    /// both buttons, which the body's static type spells out once per application site.
    @MainActor
    @Test func bothActionButtonsCarryTheHoverChokePoint() {
        let view = EmptyStateView(
            icon: "wand.and.stars",
            title: "Find duplicates in iCloud",
            primary: .init("Find Duplicates") {},
            secondary: .init("Scan again") {}
        )
        let bodyType = String(describing: type(of: view.body))
        let applications = bodyType.components(separatedBy: "ChromeHoverModifier").count - 1
        #expect(applications == 2,
                "expected chromeHover on both the primary and secondary buttons, found \(applications)")
    }
}
