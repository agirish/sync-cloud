import AppKit
import Foundation
import Settings
import SwiftUI
import Testing
@testable import SyncCloud

/// Does each step fit the opening the card can actually offer it?
///
/// **Written against the CLAMPED opening, which is the whole reason this file exists.** The
/// settings sheet learned this the expensive way: it was raised to 758pt, every fit test passed,
/// and it still scrolled on a 1280×800-class display — because `resolvedSize` clamps the card to
/// the host window and every one of those tests measured the *unclamped* number. The fixture below
/// is a window on a small display, not a number taken from `SetupSheetMetrics.baseSize`.
///
/// It also measures `stepContent(_:)` rather than the card. A `ScrollView` accepts any height it is
/// offered, so `fittingSize` taken on the card answers the card's own height however tall the step
/// inside it is — a guard written that way passes with a step twice the size of its opening.
@MainActor
@Suite struct SetupSheetFitTests {

    /// A window on a 1280×800-class display, after the app's own chrome.
    ///
    /// The same reasoning as the settings sheet's small-display fixture: the display is 800pt tall,
    /// the window is smaller than the screen, and `hostMargin` comes off that again. This is the
    /// tightest opening a real user has.
    static let smallDisplayHost = CGSize(width: 1200, height: 740)

    /// Providers enough to make Sources the tallest step it can honestly be.
    ///
    /// **Seven, because that is what a real Mac has**: iCloud plus the six accounts under
    /// `~/Library/CloudStorage` on the machine this was designed against. A fixture with two would
    /// measure a step that nobody has.
    static let realisticProviderCount = 7

    private func manager(providerCount: Int) async -> SettingsManager {
        let folders = (0..<providerCount).map {
            URL(fileURLWithPath: "/private/tmp/setup-fit/CloudStorage/GoogleDrive-fixture\($0)@example.com")
        }
        let defaults = UserDefaults(suiteName: "setup-fit-\(UUID().uuidString)")!
        let manager = SettingsManager(
            autoDiscover: false,
            userDefaults: defaults,
            cloudStorageLister: { CloudStorageAccounts(folders: folders, rootWasReadable: true) },
            pathValidator: { _ in true }
        )
        await manager.discoverProviders()
        return manager
    }

    private func sheet(_ settings: SettingsManager, hasFilingProfile: Bool = false) -> SetupSheet {
        SetupSheet(
            settings: settings,
            peopleStore: nil,
            glassHue: .blue,
            glassLevel: .frosted,
            surfaceTint: 0,
            availableSize: Self.smallDisplayHost,
            hasFilingProfile: hasFilingProfile,
            onOpenSettings: { _ in },
            onFinish: {},
            onDismiss: {}
        )
    }

    /// The laid-out height of a step's content at the width the card gives it.
    private func height(of step: SetupFlow.Step, in sheet: SetupSheet,
                        width: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let host = NSHostingView(
            rootView: sheet.stepContent(step)
                .environment(\.appFontScale, scale)
                .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The metrics themselves

    /// The card never exceeds the window it is centred in.
    ///
    /// This is the property the settings sheet's tests were all missing, so it is asserted directly
    /// rather than only through the step measurements below.
    @Test func theCardClampsToTheWindowItIsShownIn() {
        let tight = CGSize(width: 900, height: 600)
        let resolved = SetupSheetMetrics.resolvedSize(availableSize: tight, scale: 1)
        #expect(resolved.height <= tight.height - SetupSheetMetrics.hostMargin)
        #expect(resolved.width <= tight.width - SetupSheetMetrics.hostMargin)
    }

    /// On a large display it takes its base size and no more — a card that grew to fill a 6K screen
    /// would be a form with a metre of dead air in it.
    @Test func theCardStopsGrowingAtItsBaseSize() {
        let huge = CGSize(width: 3000, height: 2000)
        let resolved = SetupSheetMetrics.resolvedSize(availableSize: huge, scale: 1)
        #expect(resolved == SetupSheetMetrics.baseSize)
    }

    /// Below the floor it stops shrinking and the step scrolls instead: overflowing a tiny window
    /// is better than a card too small to use.
    @Test func theCardStopsShrinkingAtItsFloor() {
        let tiny = CGSize(width: 300, height: 200)
        let resolved = SetupSheetMetrics.resolvedSize(availableSize: tiny, scale: 1)
        #expect(resolved == SetupSheetMetrics.floorSize)
    }

    // MARK: - The steps

    /// Every step fits the opening on the smallest display anyone runs this on.
    @Test func everyStepFitsTheClampedOpening() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        // The fixture has to be able to fail. A Sources step measured with no providers is the
        // empty state, and measuring the empty state is exactly how the Organize tab's fit guard
        // passed for a release while real users scrolled.
        #expect(settings.availableProviders.count >= Self.realisticProviderCount,
                "the fixture discovered no providers — this would measure the empty state")

        let sheet = sheet(settings)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        for step in SetupFlow.Step.allCases {
            let measured = height(of: step, in: sheet, width: opening.width)
            #expect(measured <= opening.height,
                    "\(step.displayName) lays out at \(Int(measured))pt inside a \(Int(opening.height))pt opening — it will scroll on a 1280×800 display")
        }
    }

    /// Sources is the step the card is sized against, and it is the one that grows with the user's
    /// data.
    ///
    /// Pinned so a step that quietly overtakes it gets noticed: the card's height was chosen against
    /// this one, and a taller neighbour means the number was chosen against the wrong thing.
    @Test func sourcesIsTheTallestStep() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let sheet = sheet(settings)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        let heights = SetupFlow.Step.allCases.map {
            ($0, height(of: $0, in: sheet, width: opening.width))
        }
        let tallest = try #require(heights.max { $0.1 < $1.1 })
        #expect(tallest.0 == .sources,
                "\(tallest.0.displayName) is now the tallest step at \(Int(tallest.1))pt — the card's height was measured against Sources")
    }

    /// The measurement can see a step growing.
    ///
    /// **The positive control.** Every assertion above is an upper bound, which a measurement stuck
    /// at zero — a `fittingSize` that never resolved, a view that rendered nothing — would satisfy
    /// perfectly. Adding four more sources has to make Sources taller.
    @Test func theMeasurementSeesAStepGrow() async throws {
        let small = await manager(providerCount: 3)
        let large = await manager(providerCount: 7)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        let shortRun = height(of: .sources, in: sheet(small), width: opening.width)
        let longRun = height(of: .sources, in: sheet(large), width: opening.width)

        #expect(shortRun > 0, "the fixture measured nothing at all")
        #expect(longRun > shortRun,
                "four more sources did not make the step taller (\(Int(shortRun))pt vs \(Int(longRun))pt) — this measurement is not seeing the list")
    }

    /// Where Sources stops fitting.
    ///
    /// **The card's height cannot promise to hold this step, and this is the honest form of saying
    /// so.** Sources draws a row per source, and a user may add any number of folders, so the
    /// question is not *whether* it outgrows the opening but *when* — the settings sheet keeps its
    /// Providers tab out of its fit guard for the same reason, and the exemption sat there for a
    /// release as a label with no measurement under it.
    ///
    /// The bound is two-sided on purpose. A realistic Mac has to fit, and the count where it stops
    /// has to be far enough past that to be a real answer rather than a coincidence — but it must
    /// also stay *findable*, so a step that silently stopped growing (a list that clipped rather
    /// than scrolled, a measurement that flatlined) fails here rather than passing as "fits at
    /// every count".
    @Test func sourcesOutgrowsTheOpeningEventually() async throws {
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        var firstOverflow: Int?
        for count in 1...24 {
            let settings = await manager(providerCount: count)
            let measured = height(of: .sources, in: sheet(settings), width: opening.width)
            if measured > opening.height { firstOverflow = count; break }
        }

        let overflow = try #require(firstOverflow,
                                    "Sources fits at 24 sources — either the card grew a great deal or this measurement stopped seeing the list")
        #expect(overflow > Self.realisticProviderCount,
                "Sources scrolls at \(overflow) sources, and this Mac has \(Self.realisticProviderCount) — the card is sized under what a real machine holds")
    }

    /// At the largest text size the card grows too, so the steps still have somewhere to go.
    ///
    /// Not a fit assertion — on a small display the card is already clamped, so the largest text
    /// size legitimately scrolls. What must hold is that the opening did not get *smaller*.
    @Test func theOpeningDoesNotShrinkWhenTextGrows() {
        let roomy = CGSize(width: 2000, height: 1400)
        let base = SetupSheetMetrics.resolvedSize(availableSize: roomy, scale: 1)
        let large = SetupSheetMetrics.resolvedSize(availableSize: roomy, scale: 1.35)
        #expect(large.height >= base.height)
        #expect(large.width >= base.width)
    }
}
