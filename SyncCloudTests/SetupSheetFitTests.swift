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
            placeCandidates: Self.realisticPlaces,
            peopleCandidates: Self.realisticPeople,
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

    private var contentCeiling: CGFloat {
        SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost, scale: 1)
    }

    private var contentWidth: CGFloat {
        SetupSheetMetrics.contentWidth(availableSize: Self.smallDisplayHost, scale: 1)
    }

    /// The card never exceeds the window it is centred in.
    ///
    /// This is the property the settings sheet's tests were all missing — it was raised to 758pt,
    /// every fit test passed, and it still hung off a 1280×800-class display, because they all
    /// measured the unclamped number.
    @Test func theCardClampsToTheWindowItIsShownIn() {
        let tight = CGSize(width: 900, height: 560)
        #expect(SetupSheetMetrics.resolvedWidth(availableSize: tight, scale: 1)
                <= tight.width - SetupSheetMetrics.hostMargin)
        #expect(SetupSheetMetrics.resolvedHeight(availableSize: tight, scale: 1)
                <= tight.height - SetupSheetMetrics.hostMargin)
    }

    /// On a roomy display it takes its own size and no more.
    @Test func theCardTakesItsOwnSizeWhenThereIsRoom() {
        let huge = CGSize(width: 3000, height: 2000)
        #expect(SetupSheetMetrics.resolvedWidth(availableSize: huge, scale: 1) == SetupSheetMetrics.cardWidth)
        #expect(SetupSheetMetrics.resolvedHeight(availableSize: huge, scale: 1) == SetupSheetMetrics.cardHeight)
    }

    /// The footer really is no taller than the height the content budget is computed from.
    ///
    /// **An unverified constant inside a sizing rule makes every height that uses it unverified.**
    /// `contentHeight` subtracts `footerHeight` from the card, so a real footer taller than the
    /// number means every measurement here is optimistic by the difference.
    @Test func theFooterFitsTheHeightTheOpeningIsComputedFrom() async throws {
        let settings = await manager(providerCount: 2)
        let sheet = sheet(settings)
        for step in SetupFlow.Step.allCases {
            let host = NSHostingView(
                rootView: sheet.footer(step)
                    .environment(\.appFontScale, 1)
                    .frame(width: contentWidth)
            )
            host.layoutSubtreeIfNeeded()
            let measured = host.fittingSize.height
            #expect(measured > 0, "the footer measured nothing at all")
            #expect(measured <= SetupSheetMetrics.footerHeight,
                    "\(step.displayName)'s footer is \(Int(measured))pt against a \(Int(SetupSheetMetrics.footerHeight))pt budget — every height this form computes is optimistic by the difference")
        }
    }

    // MARK: - The steps

    /// The steps that can be measured fit the one card they all share.
    ///
    /// **Sources is exempt, and the exemption is a measurement rather than a label.** It draws a row
    /// per source and a user may add any number of folders, so no card height promises to hold it —
    /// at seven sources it wants ~600pt, more than a 1280×800 display can give *any* card. The
    /// settings sheet keeps its Providers tab out of its fit guard for the same property, and that
    /// exemption sat there for a release with nothing under it;
    /// `sourcesOutgrowsTheOpeningEventually` is what stops this one going the same way.
    ///
    /// Measured against the CLAMPED height, not `SetupSheetMetrics.cardHeight`: the settings sheet
    /// passed every fit test it had while scrolling on a small display, because all of them measured
    /// the unclamped number.
    static let boundedSteps: [SetupFlow.Step] = [.you, .people, .survey, .done]

    /// Places enough to make the Folders step the tallest it honestly gets.
    ///
    /// **Five, because that is what the reference tree proposes**: `US`, `IN`, `HPE`, `IT` and
    /// `PRD` — two real and three inventions, which is the whole reason the step exists. A fixture
    /// with none measures a step with no chips in it.
    /// Household names enough to make the People step the tallest it honestly gets.
    ///
    /// Six, because the reference tree proposes 28 and the step shows the first twelve — and a
    /// fixture with none measures a step with no chips in it, which is the trap the roster taught
    /// me once already.
    static let realisticPeople: [PersonCandidate] = [
        PersonCandidate(name: "Muktha", parents: ["Family"], folderCount: 5, householdParents: 2),
        PersonCandidate(name: "Shweta", parents: ["Family"], folderCount: 28, householdParents: 1),
        PersonCandidate(name: "Aditi", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Divit", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Anuraag", parents: ["Family"], folderCount: 5, householdParents: 1),
        PersonCandidate(name: "Girish", parents: ["Family"], folderCount: 5, householdParents: 1),
    ]

    static let realisticPlaces: [JurisdictionCandidate] = [
        JurisdictionCandidate(value: "US", parents: ["Finance", "Legal", "School"], folderCount: 214),
        JurisdictionCandidate(value: "IN", parents: ["Finance", "Immigration"], folderCount: 168),
        JurisdictionCandidate(value: "HPE", parents: ["Work"], folderCount: 61),
        JurisdictionCandidate(value: "IT", parents: ["Work/Payslips"], folderCount: 12),
        JurisdictionCandidate(value: "PRD", parents: ["Work/Releases"], folderCount: 9),
    ]

    @Test func everyBoundedStepFitsTheCardTheyShare() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        #expect(settings.availableProviders.count >= Self.realisticProviderCount,
                "the fixture discovered no providers — this would measure the empty state")
        let store = try roster()
        #expect(store.people.count == Self.realisticRoster.count,
                "the fixture roster is empty — the People step would be measured with nothing in it")

        let sheet = sheet(settings, people: store, hasFilingProfile: true)
        for step in Self.boundedSteps {
            let measured = height(of: step, in: sheet, width: contentWidth)
            #expect(measured <= contentCeiling,
                    "\(step.displayName) lays out at \(Int(measured))pt against a \(Int(contentCeiling))pt opening — it will scroll on a 1280×800 display")
        }
    }

    /// Every step is either measured against the shared height or explicitly exempt.
    ///
    /// Derived from `allCases`, so a step added later joins the fit list or earns a line in
    /// `boundedSteps` — it cannot skip the guard by not being named.
    @Test func everyStepIsEitherFitTestedOrExempt() {
        let exempt: Set<SetupFlow.Step> = [.sources]
        #expect(Set(Self.boundedSteps).union(exempt) == Set(SetupFlow.Step.allCases),
                "a step is neither fit-tested nor exempt")
        #expect(Set(Self.boundedSteps).isDisjoint(with: exempt))
    }

    /// The shared height is not much taller than the tallest step it is measured against.
    ///
    /// The other side of that bound, and the reason the old 648pt card was wrong: a height chosen
    /// above what any bounded step asks for is dead space on every one of them. Loose enough for a
    /// copy edit, tight enough that a stale number fails rather than lingering.
    @Test func theSharedHeightIsNotMuchTallerThanItNeedsToBe() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let sheet = sheet(settings, people: try roster(), hasFilingProfile: true)
        let tallest = try #require(Self.boundedSteps
            .map { height(of: $0, in: sheet, width: contentWidth) }.max())
        #expect(tallest > 0, "a step measured nothing at all")
        let slack = SetupSheetMetrics.cardHeight - SetupSheetMetrics.footerHeight - tallest
        #expect(slack >= 0, "the tallest bounded step does not fit the card at its unclamped size")
        #expect(slack <= 60,
                "the card carries \(Int(slack))pt more than any bounded step needs — every one of them inherits that as dead space")
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
        let opening = (width: contentWidth, height: contentCeiling)

        var firstOverflow: Int?
        for count in 1...24 {
            let settings = await manager(providerCount: count)
            let measured = height(of: .sources, in: sheet(settings), width: opening.width)
            if measured > opening.height { firstOverflow = count; break }
        }

        let overflow = try #require(firstOverflow,
                                    "Sources fits at 24 sources — either the card grew a great deal or this measurement stopped seeing the list")
        // **Where it starts scrolling, recorded rather than promised.** The card is one height for
        // every step and Sources is the step that cannot promise to fit it, so the useful claim is
        // not "it always fits" — it is that the count is known and has not collapsed. A regression
        // that made it scroll at one or two sources is a broken row, not a long list.
        #expect(overflow >= 4,
                "Sources scrolls at \(overflow) source(s) — that is not a long list, it is a row that got too tall")
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
        let opening = (width: contentWidth, height: contentCeiling)

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
        let opening = (width: contentWidth, height: contentCeiling)

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
        #expect(SetupSheetMetrics.resolvedHeight(availableSize: roomy, scale: 1.35)
                >= SetupSheetMetrics.resolvedHeight(availableSize: roomy, scale: 1))
        #expect(SetupSheetMetrics.resolvedWidth(availableSize: roomy, scale: 1.35)
                >= SetupSheetMetrics.resolvedWidth(availableSize: roomy, scale: 1))
    }
}
