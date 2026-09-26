import Design
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
@Suite(.machinePinned(.layoutMetrics)) struct SetupSheetFitTests {

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
        let defaults = ScratchDefaults("setup-fit")
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
    static let realisticRoster = ["Father", "Mother", "Daughter", "Son", "Granny", "Elder", "Uncle"]

    /// Household names the fixture walk does **not** propose, for the growth control below.
    static let rosterOnlyNames = ["Ada", "Bruno", "Cosima", "Devendra", "Eun-ji", "Farhan",
                                  "Giulia"]

    private func roster() throws -> PeopleStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "fit", profile: nil)
        for name in Self.realisticRoster {
            store.add(displayName: name, relationship: name == "Father" ? "me" : "family")
        }
        return store
    }

    private func sheet(_ settings: SettingsManager, people: PeopleStore? = nil,
                       hasFilingProfile: Bool = false,
                       walk: SetupWalk? = Self.realisticWalk) -> SetupSheet {
        SetupSheet(
            settings: settings,
            peopleStore: people,
            glassHue: .blue,
            glassLevel: .frosted,
            surfaceTint: 0,
            availableSize: Self.smallDisplayHost,
            hasFilingProfile: hasFilingProfile,
            walk: walk,
            onOpenSettings: { _ in },
            onFinish: {},
            onDismiss: {}
        )
    }

    /// A tree with the shapes the screens after Learn actually draw: enough people to fill the
    /// chip row, the five country candidates the reference tree proposes, four levels of nesting
    /// for Structure to open along, and loose files at the top for the routing view.
    ///
    /// **Without it every one of those screens measures its empty state.** The retired form
    /// carried `placeCandidates:`/`peopleCandidates:` injection for exactly this reason, and the
    /// note on it said so: "a fixture built with no engine proposes none — which is measuring the
    /// empty state, the way the Organize tab's fit guard passed for a release while real users
    /// scrolled."
    static let realisticWalk: SetupWalk = {
        var folders: [String] = ["Finance/TODO", "Finance/Archive", "Home/Utilities/Water",
                                 "Home/Insurance", "School/Transcripts", "Photos/2019"]
        for country in ["US", "IN", "EMP", "IT", "PRD"] {
            for parent in ["Finance", "Legal", "School", "Work", "Immigration"] {
                folders.append("\(parent)/\(country)/Income Tax/2024")
            }
        }
        for person in ["Granny", "Mother", "Daughter", "Son", "Uncle", "Elder"] {
            folders.append("Family/\(person)")
        }
        var files = ["bank statement march.pdf", "insurance renewal.pdf", "water bill feb.pdf",
                     "transcript 2019.pdf", "passport scan.pdf", "zzqx.pdf"]
        files += ["Finance/US/Income Tax/2024/return.pdf", "Family/Mother/passport.pdf"]
        return SetupWalk.summarising(tree: fixtureTree(folders: folders, files: files),
                                     root: URL(fileURLWithPath: "/tmp/Documents"),
                                     recordedRoot: "~/Documents", known: [])
    }()

    /// A `FileNode` tree from `"a/b/c"` paths. The `Sync` package has one of these for its own
    /// suites; it is in that package's test target, which this one cannot see.
    static func fixtureTree(folders: [String], files: [String]) -> [FileNode] {
        final class Box {
            var children: [String: Box] = [:]
            var files: Set<String> = []
            func child(_ name: String) -> Box {
                if let existing = children[name] { return existing }
                let made = Box(); children[name] = made; return made
            }
        }
        let top = Box()
        for path in folders {
            var here = top
            for part in path.split(separator: "/") { here = here.child(String(part)) }
        }
        for path in files {
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            var here = top
            for part in parts.dropLast() { here = here.child(part) }
            here.files.insert(name)
        }
        func nodes(_ box: Box, prefix: String) -> [FileNode] {
            box.children.keys.sorted().map { name in
                FileNode(id: prefix + "/" + name, name: name, isDirectory: true,
                         children: nodes(box.children[name]!, prefix: prefix + "/" + name))
            } + box.files.sorted().map { name in
                FileNode(id: prefix + "/" + name, name: name, isDirectory: false,
                         modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         fileSize: 1_024)
            }
        }
        return nodes(top, prefix: "/tmp/Documents")
    }

    /// The laid-out height of a screen's content at the width the card gives it.
    /// The width the card gives this screen — the narrow column only where a Why panel takes the
    /// rest.
    private func width(for screen: SetupFlow.Screen, scale: CGFloat = 1) -> CGFloat {
        SetupSheetMetrics.contentWidth(availableSize: Self.smallDisplayHost, scale: scale,
                                       screen: screen)
    }

    private func height(of screen: SetupFlow.Screen, in sheet: SetupSheet,
                        width: CGFloat, scale: CGFloat = 1,
                        outlineRows: [SetupFlow.OutlineRow] = SetupFlow.outline) -> CGFloat {
        let host = NSHostingView(
            rootView: sheet.screenBody(screen, outlineRows: outlineRows)
                .environment(\.appFontScale, scale)
                // The sheet publishes this; a screen measured without it lays its one
                // point-sized box out at the default size and understates every other size.
                .environment(\.setupCardScale, SetupSheetMetrics.cardScale(
                    availableSize: Self.smallDisplayHost, scale: scale))
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
        _ = sheet
        // The fullest footer there is: Back, the lock line, a Skip and a long primary title.
        for skip in [nil, "Skip"] as [String?] {
            let host = NSHostingView(
                rootView: SetupFooter(onBack: {}, skipTitle: skip, onSkip: skip == nil ? nil : {},
                                      primaryTitle: "Save and start reading", onPrimary: {})
                    .environment(\.appFontScale, 1)
                    .frame(width: contentWidth)
            )
            host.layoutSubtreeIfNeeded()
            let measured = host.fittingSize.height
            #expect(measured > 0, "the footer measured nothing at all")
            #expect(measured <= SetupSheetMetrics.footerHeight,
                    "the footer is \(Int(measured))pt against a \(Int(SetupSheetMetrics.footerHeight))pt budget — every height this sheet computes is optimistic by the difference")
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
    static let boundedScreens: [SetupFlow.Screen] = [
        .welcome, .learn, .you, .people, .countries, .structure, .workspaces, .appearance, .summary,
    ]

    /// Places enough to make the Folders step the tallest it honestly gets.
    ///
    /// **Five, because that is what the reference tree proposes**: `US`, `IN`, `EMP`, `IT` and
    /// `PRD` — two real and three inventions, which is the whole reason the step exists. A fixture
    /// with none measures a step with no chips in it.
    /// Household names enough to make the People step the tallest it honestly gets.
    ///
    /// Six, because the reference tree proposes 28 and the step shows the first twelve — and a
    /// fixture with none measures a step with no chips in it, which is the trap the roster taught
    /// me once already.
    static let realisticPeople: [PersonCandidate] = [
        PersonCandidate(name: "Granny", parents: ["Family"], folderCount: 5, householdParents: 2),
        PersonCandidate(name: "Mother", parents: ["Family"], folderCount: 28, householdParents: 1),
        PersonCandidate(name: "Daughter", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Son", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Uncle", parents: ["Family"], folderCount: 5, householdParents: 1),
        PersonCandidate(name: "Elder", parents: ["Family"], folderCount: 5, householdParents: 1),
    ]

    static let realisticPlaces: [JurisdictionCandidate] = [
        JurisdictionCandidate(value: "US", parents: ["Finance", "Legal", "School"], folderCount: 214),
        JurisdictionCandidate(value: "IN", parents: ["Finance", "Immigration"], folderCount: 168),
        JurisdictionCandidate(value: "EMP", parents: ["Work"], folderCount: 61),
        JurisdictionCandidate(value: "IT", parents: ["Work/Payslips"], folderCount: 12),
        JurisdictionCandidate(value: "PRD", parents: ["Work/Releases"], folderCount: 9),
    ]

    @Test func everyBoundedScreenFitsTheCardTheyShare() async throws {
        // The fixture has to be feeding the screens that grow, or this measures nothing.
        #expect(Self.realisticWalk.people.count >= 5,
                "the fixture proposes \(Self.realisticWalk.people.count) people — People would be measured empty")
        #expect(Self.realisticWalk.places.count >= 5,
                "the fixture proposes \(Self.realisticWalk.places.count) places — Countries would be measured empty")
        #expect(Self.realisticWalk.folderCount > 40,
                "the fixture tree is thin — Structure would be measured on a stub")
        #expect(Self.realisticWalk.looseFileNames.count >= 5)
        let settings = await manager(providerCount: Self.realisticProviderCount)
        #expect(settings.availableProviders.count >= Self.realisticProviderCount,
                "the fixture discovered no providers — this would measure the empty state")
        let store = try roster()
        #expect(store.people.count == Self.realisticRoster.count,
                "the fixture roster is empty — the People step would be measured with nothing in it")

        let sheet = sheet(settings, people: store, hasFilingProfile: true)
        // **Every text size, not just the default.** The card's width follows the type and its
        // height stops at the window, so the opening changes shape as the size rises — at 135% on
        // this display it is *smaller* than at 125%, because the chrome went on growing after the
        // card could not. A screen measured only at 100% cannot see the size that overflows, and
        // Structure did: 552pt into a 516pt opening, with the Read documents switch below the fold.
        for size in FontSize.allCases {
            let scale = size.scale
            let ceiling = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost,
                                                          scale: scale)
            for screen in Self.boundedScreens {
                let measured = height(of: screen, in: sheet,
                                      width: width(for: screen, scale: scale), scale: scale)
                #expect(measured <= ceiling,
                        "at \(size.percent)% \(screen.displayName) lays out at \(Int(measured))pt against a \(Int(ceiling))pt opening — it will scroll on a 1280×800 display")
            }
        }
    }

    /// **The welcome card fits too, and nothing measured it before.**
    ///
    /// Welcome is deliberately not a `Step` — it precedes the rail — so `everyBoundedStepFitsThe
    /// CardTheyShare` above cannot reach it, and it is simultaneously the one screen in this app
    /// that only ever renders on a machine nobody working on it is using. That combination is how
    /// its "setting up asks for" list came to be dropped by a redraw with three tests still green
    /// over the data behind it.
    ///
    /// Measured at three text sizes, because this is the screen with the most words on it and the
    /// one nobody working on the app ever sees.
    @Test func theWelcomeScreenFitsTheCardItIsDrawnIn() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let sheet = sheet(settings)
        for scale in [1.0, 1.25, 1.35] as [CGFloat] {
            let measured = height(of: .welcome, in: sheet,
                                  width: SetupSheetMetrics.resolvedWidth(
                                    availableSize: Self.smallDisplayHost, scale: scale),
                                  scale: scale)
            let opening = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost,
                                                          scale: scale)
            #expect(measured > 0, "the welcome card measured nothing at all")
            #expect(measured <= opening,
                    "the welcome card lays out at \(Int(measured))pt at \(Int(scale * 100))% against a \(Int(opening))pt card — it will overflow on a 1280×800 display")
        }
    }

    /// The welcome card really **draws** the outline, not just the data behind it.
    ///
    /// **Measured twice, because the failure this catches is a render one.** `SetupFlow.outline`
    /// and its three tests in `SetupFlowTests` survived `89373824`, which stopped drawing the list
    /// while redrawing the card, and `e52076eb`, which brought the step it announces back and did
    /// not bring the row with it. Those tests assert the TABLE, and a table nobody reads is exactly
    /// as consistent as one somebody does. SwiftUI draws its own text — an `NSTextField` sweep of
    /// the laid-out tree comes back empty, measured — so the only thing an offscreen host can
    /// honestly report is the height, and the height is enough: a card that renders the rows is
    /// taller than one handed none.
    @Test func theWelcomeCardGrowsByTheOutlineItDraws() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let width = SetupSheetMetrics.resolvedWidth(availableSize: Self.smallDisplayHost, scale: 1)
        let card = sheet(settings)
        func measure(_ rows: [SetupFlow.OutlineRow]) -> CGFloat {
            height(of: .welcome, in: card, width: width, outlineRows: rows)
        }
        #expect(SetupFlow.outline.count >= 4, "the outline table is thin — this would barely measure")
        let withRows = measure(SetupFlow.outline)
        let without = measure([])
        #expect(without > 0, "the control card measured nothing — both numbers are meaningless")
        // One row is a line of caption text plus its spacing; four rows and a heading cannot come to
        // less than this without something having been dropped or clipped.
        #expect(withRows - without >= CGFloat(SetupFlow.outline.count) * 14,
                "drawing the outline added only \(Int(withRows - without))pt for \(SetupFlow.outline.count) rows — the card is not rendering the list it declares")
    }

    /// Every screen is either measured against the shared height or explicitly exempt.
    ///
    /// Derived from `allCases`, so a screen added later joins the fit list or earns a line in
    /// `boundedScreens` — it cannot skip the guard by not being named.
    @Test func everyScreenIsEitherFitTestedOrExempt() {
        let exempt: Set<SetupFlow.Screen> = [.locations]
        #expect(Set(Self.boundedScreens).union(exempt) == Set(SetupFlow.Screen.allCases),
                "a screen is neither fit-tested nor exempt")
        #expect(Set(Self.boundedScreens).isDisjoint(with: exempt))
    }

    /// The shared height is not much taller than the tallest step it is measured against.
    ///
    /// The other side of that bound, and the reason the old 648pt card was wrong: a height chosen
    /// above what any bounded step asks for is dead space on every one of them. Loose enough for a
    /// copy edit, tight enough that a stale number fails rather than lingering.
    @Test func theSharedHeightIsNotMuchTallerThanItNeedsToBe() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let sheet = sheet(settings, people: try roster(), hasFilingProfile: true)
        let tallest = try #require(Self.boundedScreens
            .map { height(of: $0, in: sheet, width: width(for: $0)) }.max())
        #expect(tallest > 0, "a screen measured nothing at all")
        // The card's whole budget, not the card minus its footer: the sheet also spends a top bar,
        // two hairlines and the padding around the content before a screen sees a point of it.
        let slack = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost, scale: 1)
            - tallest
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
            let measured = height(of: .locations, in: sheet(settings), width: opening.width)
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

        // **One name first, and the reason is the disclosure.** The screen leads with the list and
        // keeps the proposals behind `SetupMoreOptions`, which opens itself while the list is empty
        // — that being the run where the proposals are the only thing to act on. So an empty roster
        // draws *more* than a roster of one, and comparing empty against full asks whether the
        // disclosure closed rather than whether the roster grew. Both measurements here are taken
        // with it closed, so the only thing that moves is the rows.
        store.add(displayName: Self.rosterOnlyNames[0])
        let one = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                         width: opening.width)
        // **Names the walk did not propose.** Adding a proposed name moves it from the chip row to
        // the roster row rather than adding a row — the two lists trade off by design — so
        // measuring with the proposals would ask this control whether the screen shrinks, which is
        // a different question and a true one.
        for name in Self.rosterOnlyNames.dropFirst() { store.add(displayName: name) }
        let full = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                          width: opening.width)

        #expect(one > 0, "the fixture measured nothing at all")
        #expect(Set(Self.rosterOnlyNames)
                    .isDisjoint(with: Set(Self.realisticWalk.people.map(\.name))),
                "these names are proposals, so adding them removes a chip as it adds a row")
        #expect(full > one,
                "\(Self.rosterOnlyNames.count - 1) more people did not make the People screen taller (\(Int(one))pt vs \(Int(full))pt) — this measurement is not seeing the roster")
    }

    /// The empty roster is not the smallest thing this screen can be.
    ///
    /// **Which is the other half of the control above.** People opens its proposals while the list
    /// is empty, so the first-run screen carries the longest chip row it will ever draw. A fit
    /// assertion taken against the roster alone would miss it entirely — this is the state a real
    /// first run is in.
    @Test func theEmptyRosterDrawsTheProposalsAndStillFits() async throws {
        let settings = await manager(providerCount: 2)
        let opening = (width: contentWidth, height: contentCeiling)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "empty", profile: nil)

        let empty = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                           width: opening.width)
        store.add(displayName: Self.rosterOnlyNames[0])
        let one = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                         width: opening.width)

        #expect(empty > one,
                "an empty roster measured \(Int(empty))pt against \(Int(one))pt with one name — the proposals are not being drawn on the first run")
        #expect(empty <= opening.height,
                "the first-run People screen wants \(Int(empty))pt of \(Int(opening.height))")
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
        // Higher than the old bound, because the roster is a wrapping chip row now rather than a
        // list: four names to a line, so it takes four times as many to fill the same height.
        for count in 1...200 {
            store.add(displayName: "Person \(count)")
            let measured = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                                  width: opening.width)
            if measured > opening.height { firstOverflow = count; break }
        }

        let overflow = try #require(firstOverflow,
                                    "People fits 200 members — either the card grew a great deal or this measurement stopped seeing the roster")
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
