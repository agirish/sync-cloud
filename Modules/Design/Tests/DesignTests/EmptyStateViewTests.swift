import Testing
import SwiftUI
@testable import Design

/// Pins the public shape of `EmptyStateView`, the blank-panel template every tab renders through.
/// API pins, not pixel tests: the component is pure layout, so what matters is that its slots
/// exist, stay public, and carry the caller's copy and handlers through unchanged.
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

    /// Both action buttons carry `chromeHover`. Hover is `.none` at rest and driven by the
    /// modifier's own `onHover`, so a test can't render it; this counts the modifier in the body's
    /// static type instead.
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
