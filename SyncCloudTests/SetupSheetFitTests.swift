import AppKit
import Foundation
import Settings
import Sync
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

    /// A household the size of a real one.
    ///
    /// **Seven, from this machine's `people.json`.** The People step draws a row per person, so a
    /// fixture with an empty roster measures the empty state — which is exactly how the Organize
    /// tab's fit guard passed for a release while real users scrolled, and it got there the same
    /// way: by handing the view a nil dependency.
    static let realisticRoster = ["Abhishek", "Shweta", "Aditi", "Divit", "Muktha", "Girish", "Anuraag"]

    private func roster() throws -> PeopleStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "fit", profile: nil)
        for name in Self.realisticRoster {
            store.add(displayName: name, relationship: name == "Abhishek" ? "me" : "family")
        }
        return store
    }

    private func sheet(_ settings: SettingsManager, people: PeopleStore? = nil,
                       hasFilingProfile: Bool = false) -> SetupSheet {
        SetupSheet(
            settings: settings,
            peopleStore: people,
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

    /// The footer really is no taller than the height the opening is computed from.
    ///
    /// **An unverified constant inside a fit guard makes every assertion that uses it unverified.**
    /// `contentOpening` subtracts `footerHeight` from the card, so a real footer taller than the
    /// number means every step measurement in this file is optimistic by the difference — the guard
    /// would keep passing while a step overflowed on screen.
    @Test func theFooterFitsTheHeightTheOpeningIsComputedFrom() async throws {
        let settings = await manager(providerCount: 2)
        let sheet = sheet(settings)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)

        for step in SetupFlow.Step.allCases {
            let host = NSHostingView(
                rootView: sheet.footer(step)
                    .environment(\.appFontScale, 1)
                    .frame(width: card.width - SetupSheetMetrics.railWidth)
            )
            host.layoutSubtreeIfNeeded()
            let measured = host.fittingSize.height
            #expect(measured > 0, "the footer measured nothing at all")
            #expect(measured <= SetupSheetMetrics.footerHeight,
                    "\(step.displayName)'s footer is \(Int(measured))pt against a \(Int(SetupSheetMetrics.footerHeight))pt budget — every step fit assertion here is optimistic by the difference")
        }
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

        let store = try roster()
        // The People step draws a row per person, so an empty roster measures the empty state.
        #expect(store.people.count == Self.realisticRoster.count,
                "the fixture roster is empty — the People step would be measured with nothing in it")

        let sheet = sheet(settings, people: store, hasFilingProfile: true)
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
        let sheet = sheet(settings, people: try roster(), hasFilingProfile: true)
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

    /// The People step grows with the household, and the measurement sees it.
    ///
    /// **The second positive control, and it is the one the first draft of this file was missing.**
    /// Every fit assertion is an upper bound, and a step measured with an empty roster satisfies
    /// one trivially — so "People fits" means nothing until it is shown that People *can* stop
    /// fitting. This is the same claim `theMeasurementSeesAStepGrow` makes for Sources, on the
    /// other list in this form that grows with the user's data.
    @Test func theMeasurementSeesTheRosterGrow() async throws {
        let settings = await manager(providerCount: 2)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-grow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "grow", profile: nil)

        let empty = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                           width: opening.width)
        for name in Self.realisticRoster { store.add(displayName: name) }
        let full = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                          width: opening.width)

        #expect(empty > 0, "the fixture measured nothing at all")
        #expect(full > empty,
                "seven people did not make the People step taller (\(Int(empty))pt vs \(Int(full))pt) — this measurement is not seeing the roster")
    }

    /// Where People stops fitting.
    ///
    /// Same shape as `sourcesOutgrowsTheOpeningEventually`, and needed for the same reason: the
    /// roster is the user's data and no card height can promise to hold it. What can be promised is
    /// that a real household fits, and that the number where it stops is known.
    @Test func peopleOutgrowsTheOpeningEventually() async throws {
        let settings = await manager(providerCount: 2)
        let card = SetupSheetMetrics.resolvedSize(availableSize: Self.smallDisplayHost, scale: 1)
        let opening = SetupSheetMetrics.contentOpening(cardSize: card)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-people-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "many", profile: nil)

        var firstOverflow: Int?
        for count in 1...40 {
            store.add(displayName: "Person \(count)")
            let measured = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                                  width: opening.width)
            if measured > opening.height { firstOverflow = count; break }
        }

        let overflow = try #require(firstOverflow,
                                    "People fits 40 members — either the card grew a great deal or this measurement stopped seeing the roster")
        #expect(overflow > Self.realisticRoster.count,
                "People scrolls at \(overflow) members, and this household has \(Self.realisticRoster.count) — the card is sized under a real roster")
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
