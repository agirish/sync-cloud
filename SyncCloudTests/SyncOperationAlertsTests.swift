import AppKit
import Foundation
import Testing
import Sync
@testable import SyncCloud

/// Pins the pure string builders behind the invalid-destination-name alert and the cloud-Filing
/// spend pre-flight (the collision and transfer-confirmation builders are pinned in
/// SyncCloudTests.swift). The NSAlert plumbing itself stays untested — these builders are extracted
/// `nonisolated` precisely so the wording is checkable headlessly.
@Suite struct SyncOperationAlertsTests {

    // MARK: Invalid-destination-name alert

    private static func violation(isMove: Bool = false) -> NameViolationPrompt {
        NameViolationPrompt(
            itemName: "report .pdf",
            sanitizedName: "report.pdf",
            providerName: "OneDrive",
            reason: "OneDrive doesn't allow names ending with a space.",
            destinationPath: NSHomeDirectory() + "/Library/CloudStorage/OneDrive/Documents/report .pdf",
            isMove: isMove)
    }

    @Test func invalidNameMessageNamesTheItemProviderAndVerb() {
        #expect(SyncOperationAlerts.invalidNameMessage(Self.violation())
                == "\"report .pdf\" can't be copied to OneDrive under this name.")
        #expect(SyncOperationAlerts.invalidNameMessage(Self.violation(isMove: true))
                == "\"report .pdf\" can't be moved to OneDrive under this name.")
    }

    @Test func invalidNameBodyExplainsTheLocalOnlyHazardAndShowsTheDestination() {
        let body = SyncOperationAlerts.invalidNameInformativeText(Self.violation())
        #expect(body.hasPrefix("OneDrive doesn't allow names ending with a space."))
        #expect(body.contains("an item OneDrive never uploads"))
        #expect(body.contains("look identical to \"report.pdf\""))
        // The destination is home-abbreviated for readability.
        #expect(body.contains("Destination: ~/Library/CloudStorage/OneDrive/Documents/report .pdf"))
        #expect(!body.contains("Destination: /Users"))
    }

    @Test func displayPathAbbreviatesTheHomeDirectory() {
        #expect(SyncOperationAlerts.displayPath(NSHomeDirectory() + "/Documents/a.txt") == "~/Documents/a.txt")
        #expect(SyncOperationAlerts.displayPath("/Volumes/External/a.txt") == "/Volumes/External/a.txt")
    }

    // MARK: Cloud-Filing spend pre-flight

    private static func preflight(fileCount: Int = 12,
                                  model: String = "claude-haiku-4-5",
                                  estCostUSD: Double = 0.02,
                                  monthlySpentUSD: Double = 0, monthlyCapUSD: Double = 0,
                                  totalSpentUSD: Double = 0, totalCapUSD: Double = 0) -> FilingSpendPreflight {
        FilingSpendPreflight(fileCount: fileCount, model: model,
                             estInputTokens: 8_000, estOutputTokens: 1_500,
                             estCostUSD: estCostUSD,
                             monthlySpentUSD: monthlySpentUSD, monthlyCapUSD: monthlyCapUSD,
                             totalSpentUSD: totalSpentUSD, totalCapUSD: totalCapUSD)
    }

    @Test func spendMessageNamesCountAndModelWithSingularPlural() {
        #expect(SyncOperationAlerts.filingSpendMessage(Self.preflight(fileCount: 12))
                == "Classify 12 files with Haiku?")
        #expect(SyncOperationAlerts.filingSpendMessage(Self.preflight(fileCount: 1, model: "claude-sonnet-4-5"))
                == "Classify 1 file with Sonnet?")
    }

    @Test func spendMessageLeadsWithTheBlockWhenOverACap() {
        // Monthly cap would be breached.
        let monthly = Self.preflight(estCostUSD: 0.50, monthlySpentUSD: 0.80, monthlyCapUSD: 1.00)
        #expect(SyncOperationAlerts.filingSpendMessage(monthly) == "This would exceed your monthly cloud budget")

        // Only the total (lifetime) cap would be breached.
        let total = Self.preflight(estCostUSD: 0.50, totalSpentUSD: 4.80, totalCapUSD: 5.00)
        #expect(SyncOperationAlerts.filingSpendMessage(total) == "This would exceed your total cloud budget")

        // Both breached: the monthly wording wins.
        let both = Self.preflight(estCostUSD: 0.50, monthlySpentUSD: 0.80, monthlyCapUSD: 1.00,
                                  totalSpentUSD: 4.80, totalCapUSD: 5.00)
        #expect(SyncOperationAlerts.filingSpendMessage(both) == "This would exceed your monthly cloud budget")
    }

    @Test func spendBodyAlwaysStatesTheEstimateAndBillingCaveat() {
        let body = SyncOperationAlerts.filingSpendInformativeText(Self.preflight())
        #expect(body.contains("Estimated cost: ~$0.02 (8.0k tok in / 1.5k tok out)."))
        #expect(body.contains("billed to your Anthropic API key"))
        // No caps set → neither budget section appears.
        #expect(!body.contains("This month:"))
        #expect(!body.contains("Lifetime:"))
    }

    @Test func spendBodyShowsTheMonthlyBudgetOnlyWhenACapIsSet() {
        let body = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(monthlySpentUSD: 0.25, monthlyCapUSD: 1.00))
        #expect(body.contains("This month: ~$0.25 of ~$1.00 monthly cap."))
        #expect(!body.contains("Lifetime:"))
    }

    @Test func spendBodyShowsTheLifetimeBudgetOnlyWhenATotalCapIsSet() {
        let totalOnly = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(totalSpentUSD: 1.50, totalCapUSD: 5.00))
        #expect(totalOnly.contains("\n\nLifetime: ~$1.50 of ~$5.00 total cap."))
        #expect(!totalOnly.contains("This month:"))

        // With BOTH caps the lifetime line joins the monthly section with a single newline.
        let both = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(monthlySpentUSD: 0.25, monthlyCapUSD: 1.00, totalSpentUSD: 1.50, totalCapUSD: 5.00))
        #expect(both.contains("monthly cap.\nLifetime: ~$1.50 of ~$5.00 total cap."))
    }

    @Test func spendBodySaysTheCallIsBlockedWhenItWouldExceedACap() {
        let monthly = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(estCostUSD: 0.50, monthlySpentUSD: 0.80, monthlyCapUSD: 1.00))
        #expect(monthly.contains("Running this would exceed the monthly cap, so it's blocked"))
        #expect(monthly.contains("free on-device suggestions instead"))
        #expect(monthly.contains("Settings → Organize"))

        let total = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(estCostUSD: 0.50, totalSpentUSD: 4.80, totalCapUSD: 5.00))
        #expect(total.contains("Running this would exceed the total cap, so it's blocked"))
    }

    @Test func spendBodyStaysUnblockedUnderTheCaps() {
        let body = SyncOperationAlerts.filingSpendInformativeText(
            Self.preflight(estCostUSD: 0.02, monthlySpentUSD: 0.10, monthlyCapUSD: 1.00))
        #expect(!body.contains("blocked"))
    }

    // MARK: Button → decision mapping
    //
    // The alerts themselves can't be driven headlessly, but the half that turns a click into a
    // destructive decision now can: each test resolves a button BY TITLE to the response NSAlert
    // would send for it, then asserts what that response means. A swapped title or a swapped
    // switch arm turns a "Skip" click into a replace — silent, and only discovered once the
    // user's file is gone.

    /// The response `NSAlert` reports when the user clicks the button titled `title`.
    private func response(for title: String, in titles: [String]) throws -> NSApplication.ModalResponse {
        let index = try #require(titles.firstIndex(of: title), "no button titled \(title)")
        return SyncOperationAlerts.modalResponse(forButtonAt: index)
    }

    @Test func collisionButtonsMapToTheResolutionTheyName() throws {
        let titles = SyncOperationAlerts.collisionButtonTitles
        #expect(SyncOperationAlerts.collisionResolution(for: try response(for: "Skip", in: titles)) == .skip)
        #expect(SyncOperationAlerts.collisionResolution(for: try response(for: "Replace", in: titles)) == .replace)
        #expect(SyncOperationAlerts.collisionResolution(for: try response(for: "Keep Both", in: titles)) == .keepBoth)
    }

    @Test func collisionAlertOffersExactlyTheThreeChoicesWithKeepBothAsTheDefault() {
        // Order is load-bearing twice over: it is the response mapping, and the FIRST button is
        // the Return-key default — which must never be the destructive Replace.
        #expect(SyncOperationAlerts.collisionButtonTitles == ["Keep Both", "Skip", "Replace"])
        #expect(SyncOperationAlerts.collisionResolution(for: .alertFirstButtonReturn) != .replace)
    }

    @Test func anUnexpectedCollisionResponseFailsSafeToSkip() {
        // A programmatic dismissal (no button clicked) must never be read as consent to replace.
        #expect(SyncOperationAlerts.collisionResolution(for: .cancel) == .skip)
        #expect(SyncOperationAlerts.collisionResolution(for: .stop) == .skip)
    }

    @Test func invalidNameButtonsMapToTheResolutionTheyName() throws {
        let titles = SyncOperationAlerts.invalidNameButtonTitles(Self.violation())
        #expect(titles.first == "Use \"report.pdf\"")   // Return-key default: the safe, sanitized name
        #expect(SyncOperationAlerts.invalidNameResolution(for: try response(for: "Use \"report.pdf\"", in: titles))
                == .useSanitizedName)
        #expect(SyncOperationAlerts.invalidNameResolution(for: try response(for: "Skip", in: titles)) == .skip)
        #expect(SyncOperationAlerts.invalidNameResolution(for: try response(for: "Keep Invalid Name", in: titles))
                == .keepOriginalName)
        // And an unexpected response skips rather than writing an unsyncable name.
        #expect(SyncOperationAlerts.invalidNameResolution(for: .cancel) == .skip)
    }

    @Test func onlyTheFirstButtonConfirmsAYesNoPrompt() {
        // Every Bool prompt (transfer, undo-last-run, permanent delete, cloud spend) puts its
        // affirmative action first and Cancel second; reading the second button as consent would
        // permanently delete on a Cancel click.
        #expect(SyncOperationAlerts.isConfirmed(.alertFirstButtonReturn))
        #expect(!SyncOperationAlerts.isConfirmed(.alertSecondButtonReturn))
        #expect(!SyncOperationAlerts.isConfirmed(.alertThirdButtonReturn))
        #expect(!SyncOperationAlerts.isConfirmed(.cancel))
    }

    @MainActor
    @Test func permanentDeleteOfNothingIsRefusedWithoutAnAlert() {
        // The empty-list guard runs before any AppKit call, so this is reachable headlessly —
        // and it is the guard that keeps a no-selection delete from presenting a modal.
        #expect(!SyncOperationAlerts.confirmPermanentDelete(itemNames: []))
    }
}
