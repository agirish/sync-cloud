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
/// Written against the clamped opening: `resolvedSize` clamps the card to the host window, so a
/// test of the unclamped size passes while the card scrolls on a 1280×800-class display. The
/// fixture is a window on a small display, not `SetupSheetMetrics.baseSize`.
///
/// It measures `screenBody(_:)`, not the card: a `ScrollView` accepts any height, so the card's
/// `fittingSize` is its own height however tall the screen inside it is.
@MainActor
@Suite(.machinePinned(.layoutMetrics)) struct SetupSheetFitTests {

    /// A window on a 1280×800-class display, after the app's own chrome: the window is smaller than
    /// the 800pt screen, and `hostMargin` comes off that again. The tightest opening a real user
    /// has.
    static let smallDisplayHost = CGSize(width: 1200, height: 740)

    /// Providers enough to make Locations as tall as it honestly gets: seven, as on a real Mac
    /// (iCloud plus six accounts under `~/Library/CloudStorage`).
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

    /// A household the size of a real one: seven people. The People step draws a row per person,
    /// so an empty roster, or a nil dependency, would measure only the empty state.
    static let realisticRoster = ["Father", "Mother", "Daughter", "Son", "Granny", "Elder", "Uncle"]

    /// Household names the fixture walk does not propose, for the growth control below.
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
            // No draft: a mounted sheet commits the open screen when it is taken down.
            draftURL: nil,
            onOpenSettings: { _ in },
            onFinish: {},
            onDismiss: {}
        )
    }

    /// A tree with the shapes the screens after Learn actually draw: enough people to fill the
    /// chip row, the five country candidates the reference tree proposes, four levels of nesting
    /// for Structure, and loose files at the top for the routing view. Without it every one of
    /// those screens measures its empty state.
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

    /// The width the card gives this screen: the narrow column only where a Why panel takes the
    /// rest.
    private func width(for screen: SetupFlow.Screen, scale: CGFloat = 1) -> CGFloat {
        SetupSheetMetrics.contentWidth(availableSize: Self.smallDisplayHost, scale: scale,
                                       screen: screen)
    }

    /// The laid-out height of a screen's content at the width the card gives it.
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

    /// The card never exceeds the window it is centred in, so every fit test here measures the
    /// size a user actually gets.
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

    /// The footer is no taller than the height the content budget is computed from:
    /// `contentHeight` subtracts `footerHeight`, so a taller real footer makes every measurement
    /// here optimistic by the difference.
    @Test func theFooterFitsTheHeightTheOpeningIsComputedFrom() async throws {
        let settings = await manager(providerCount: 2)
        let sheet = sheet(settings)
        _ = sheet
        // The fullest footer there is: Back, the lock line, a Skip and a long primary title.
        for skip in [nil, "Skip"] as [String?] {
            let host = NSHostingView(
                rootView: SetupFooter(onBack: {}, skipTitle: skip, onSkip: skip == nil ? nil : {},
                                      primaryTitle: "Save and Start Reading", onPrimary: {})
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

    /// The screens that can be measured fit the one card they all share, at the clamped height,
    /// not `SetupSheetMetrics.cardHeight`.
    ///
    /// Locations is exempt: it draws a row per location and a user may add any number of folders,
    /// so no card height can promise to hold it. `sourcesOutgrowsTheOpeningEventually` measures
    /// where it stops fitting, so the exemption isn't just a label.
    static let boundedScreens: [SetupFlow.Screen] = [
        .welcome, .learn, .you, .people, .countries, .structure, .workspaces, .appearance, .summary,
    ]

    /// Household names enough to make the People step as tall as it honestly gets. A fixture with
    /// none measures a step with no chips in it.
    static let realisticPeople: [PersonCandidate] = [
        PersonCandidate(name: "Granny", parents: ["Family"], folderCount: 5, householdParents: 2),
        PersonCandidate(name: "Mother", parents: ["Family"], folderCount: 28, householdParents: 1),
        PersonCandidate(name: "Daughter", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Son", parents: ["Family"], folderCount: 12, householdParents: 1),
        PersonCandidate(name: "Uncle", parents: ["Family"], folderCount: 5, householdParents: 1),
        PersonCandidate(name: "Elder", parents: ["Family"], folderCount: 5, householdParents: 1),
    ]

    /// Places enough to make the Countries step as tall as it honestly gets: the five the reference
    /// tree proposes, `US`, `IN`, `EMP`, `IT` and `PRD`, two real and three not, which is why the
    /// step exists.
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
        // Every text size: the card's width follows the type and its height stops at the window,
        // so the opening changes shape as the size rises, and can shrink at the largest sizes as
        // the chrome keeps growing.
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

    /// Structure fits with a failed Save on it, the tallest that screen gets. The failure's
    /// heading, reason and two ways on replace the line about grey words, on the screen with the
    /// least room; the test above measures it with no failure.
    @Test func structureFitsWithAFailedSaveOnIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)
        let engine = FileSyncManager.scratch()
        engine.filingProfilesDirectory = blocker.appendingPathComponent("profiles")
        let settings = await manager(providerCount: Self.realisticProviderCount)
        func model() -> SetupModel {
            SetupModel(settings: settings, peopleStore: nil, syncManager: engine,
                       hasFilingProfile: false, defaults: ScratchDefaults("setup-fit-d"),
                       walk: Self.realisticWalk, startScreen: .structure, draftURL: nil)
        }
        let failed = model()
        await failed.save()
        #expect(failed.saveFailure != nil, "premise: the Save failed")
        let clean = model()

        func height(_ model: SetupModel, scale: CGFloat) -> CGFloat {
            let host = NSHostingView(
                rootView: StructureScreen(model: model, hue: .blue)
                    .environment(\.appFontScale, scale)
                    .environment(\.setupCardScale, SetupSheetMetrics.cardScale(
                        availableSize: Self.smallDisplayHost, scale: scale))
                    .frame(width: width(for: .structure, scale: scale)))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        for size in FontSize.allCases {
            let scale = size.scale
            let ceiling = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost,
                                                          scale: scale)
            let measured = height(failed, scale: scale)
            #expect(measured != height(clean, scale: scale),
                    "at \(size.percent)% the failure changed nothing — this measures the clean screen")
            #expect(measured <= ceiling,
                    "at \(size.percent)% Structure with a failed Save lays out at \(Int(measured))pt against a \(Int(ceiling))pt opening")
        }
    }

    /// Structure fits while the reading still runs: the reading's line stands in the tree's box,
    /// and the heading's blurb says it is still reading.
    @Test func structureFitsWhileTheReadingRuns() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        func model() -> SetupModel {
            SetupModel(settings: settings, peopleStore: nil, syncManager: nil,
                       hasFilingProfile: false, defaults: ScratchDefaults("setup-fit-d"),
                       walk: Self.realisticWalk, startScreen: .structure, draftURL: nil)
        }
        let reading = model()
        reading.walkState = .running
        #expect(reading.structureAwaitsReading, "premise: Structure is waiting on the reading")
        let landed = model()

        for scale in [1.0, 1.35] as [CGFloat] {
            let ceiling = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost,
                                                          scale: scale)
            let running = renderStructure(reading, scale: scale)
            let other = renderStructure(landed, scale: scale)
            #expect(!running.pixels.isEmpty, "at \(Int(scale * 100))% Structure drew nothing")
            #expect(running.pixels != other.pixels,
                    "at \(Int(scale * 100))% the running reading changed nothing — this measures the landed screen")
            #expect(running.height <= ceiling,
                    "at \(Int(scale * 100))% Structure over a running reading lays out at \(Int(running.height))pt against a \(Int(ceiling))pt opening")
            // No lens, grey words or legend while it runs: they explain a tree there isn't yet.
            // The tree's box is a fixed height either way, so the screen is shorter by those three.
            #expect(other.height - running.height >= 40,
                    "at \(Int(scale * 100))% Structure over a running reading is \(Int(running.height))pt against \(Int(other.height))pt landed — it still draws the tree's lens and legend")
        }
    }

    /// Structure fits over a reading that failed, and says so: the failure's line, its reason and
    /// Try Another Folder… stand in the tree's box, where the last reading's tree stood.
    @Test func structureFitsOverAFailedReading() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        func model() -> SetupModel {
            SetupModel(settings: settings, peopleStore: nil, syncManager: nil,
                       hasFilingProfile: false, defaults: ScratchDefaults("setup-fit-d"),
                       walk: Self.realisticWalk, startScreen: .structure, draftURL: nil)
        }
        // Learn Again over a reading, and the new one failed: the preview still holds the old tree.
        let failed = model()
        failed.walkState = .failed("The folder “Documents” couldn’t be opened because you don’t "
                                   + "have permission to see its contents.")
        #expect(failed.structureProfile != nil, "premise: the last reading's tree is still built")
        let running = model()
        running.walkState = .running

        for scale in [1.0, 1.35] as [CGFloat] {
            let ceiling = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost,
                                                          scale: scale)
            let drawn = renderStructure(failed, scale: scale)
            let landed = renderStructure(model(), scale: scale)
            #expect(!drawn.pixels.isEmpty, "at \(Int(scale * 100))% Structure drew nothing")
            #expect(drawn.pixels != landed.pixels,
                    "at \(Int(scale * 100))% the failed reading is drawn as the last reading's tree")
            // The pixels alone are satisfied by the blurb, which names the failure whatever the box
            // draws. The lens and legend go with the tree, so the height tells them apart.
            #expect(landed.height - drawn.height >= 40,
                    "at \(Int(scale * 100))% Structure over a failed reading is \(Int(drawn.height))pt against \(Int(landed.height))pt landed — it still draws the old tree's lens and legend")
            #expect(drawn.pixels != renderStructure(running, scale: scale).pixels,
                    "at \(Int(scale * 100))% the failed reading is drawn as one still running")
            #expect(drawn.height <= ceiling,
                    "at \(Int(scale * 100))% Structure over a failed reading lays out at \(Int(drawn.height))pt against a \(Int(ceiling))pt opening")
        }
    }

    /// Structure alone, laid out at its fitting height and photographed.
    private func renderStructure(_ model: SetupModel, scale: CGFloat) -> (height: CGFloat, pixels: Data) {
        let host = NSHostingView(
            rootView: StructureScreen(model: model, hue: .blue)
                .environment(\.appFontScale, scale)
                .environment(\.setupCardScale, SetupSheetMetrics.cardScale(
                    availableSize: Self.smallDisplayHost, scale: scale))
                .frame(width: width(for: .structure, scale: scale)))
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return (host.fittingSize.height, Data())
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let bytes = rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) }
        return (host.fittingSize.height, bytes ?? Data())
    }

    /// The welcome card fits at the card's full width, at three text sizes: it has the most words
    /// of any screen, and it only ever renders on a fresh machine, so nobody working on the app
    /// sees it.
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

    /// The welcome card really draws the outline, not just the data behind it.
    ///
    /// `SetupFlowTests` checks the `SetupFlow.outline` table, which stays consistent whether or not
    /// the card draws it. SwiftUI draws its own text, so an `NSTextField` sweep finds nothing; the
    /// height is what an offscreen host can report, and a card that draws the rows is taller than
    /// one handed none.
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

    /// Every screen is either measured against the shared height or explicitly exempt. Derived from
    /// `allCases`, so a new screen can't skip the guard by not being named.
    @Test func everyScreenIsEitherFitTestedOrExempt() {
        let exempt: Set<SetupFlow.Screen> = [.locations]
        #expect(Set(Self.boundedScreens).union(exempt) == Set(SetupFlow.Screen.allCases),
                "a screen is neither fit-tested nor exempt")
        #expect(Set(Self.boundedScreens).isDisjoint(with: exempt))
    }

    /// The shared height is not much taller than the tallest step it is measured against: height
    /// above what any bounded step asks for is dead space on all of them. Loose enough for a copy
    /// edit, tight enough that a stale number fails.
    @Test func theSharedHeightIsNotMuchTallerThanItNeedsToBe() async throws {
        let settings = await manager(providerCount: Self.realisticProviderCount)
        let sheet = sheet(settings, people: try roster(), hasFilingProfile: true)
        let tallest = try #require(Self.boundedScreens
            .map { height(of: $0, in: sheet, width: width(for: $0)) }.max())
        #expect(tallest > 0, "a screen measured nothing at all")
        // The content budget, not the card minus its footer: the sheet also spends a top bar, two
        // hairlines and the padding around the content.
        let slack = SetupSheetMetrics.contentHeight(availableSize: Self.smallDisplayHost, scale: 1)
            - tallest
        #expect(slack >= 0, "the tallest bounded step does not fit the card at its unclamped size")
        #expect(slack <= 60,
                "the card carries \(Int(slack))pt more than any bounded step needs — every one of them inherits that as dead space")
    }


    /// Where Locations stops fitting. It draws a row per location and a user may add any number of
    /// folders, so the question is when it outgrows the opening, not whether.
    ///
    /// Two-sided on purpose: a realistic Mac must fit, and the overflow count must stay findable,
    /// so a list that clipped or a measurement that flatlined fails rather than passing as "fits at
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
        // Where it starts scrolling, recorded rather than promised: the claim is that the count is
        // known and hasn't collapsed. Scrolling at one or two locations is a broken row, not a
        // long list.
        #expect(overflow >= 4,
                "Sources scrolls at \(overflow) source(s) — that is not a long list, it is a row that got too tall")
    }

    /// The People step grows with the household, and the measurement sees it.
    ///
    /// Every fit assertion is an upper bound, which an empty roster satisfies trivially, so "People
    /// fits" means nothing until People is shown to grow. The same claim
    /// `sourcesOutgrowsTheOpeningEventually` makes for Locations, the other list that grows with the
    /// user's data.
    @Test func theMeasurementSeesTheRosterGrow() async throws {
        let settings = await manager(providerCount: 2)
        let opening = (width: contentWidth, height: contentCeiling)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-grow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "grow", profile: nil)

        // One name first: the proposals sit behind `SetupMoreOptions`, which opens itself while the
        // list is empty, so an empty roster draws more than a roster of one. Both measurements are
        // taken with it closed, so only the rows move.
        store.add(displayName: Self.rosterOnlyNames[0])
        let one = height(of: .people, in: sheet(settings, people: store, hasFilingProfile: true),
                         width: opening.width)
        // Names the walk did not propose: adding a proposed one moves it from the chip row to the
        // roster rather than adding a row.
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

    /// The empty roster is not the smallest this screen can be, the other half of the control
    /// above. People opens its proposals while the list is empty, so a real first run draws the
    /// longest chip row the screen ever shows, and it must still fit.
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

    /// Where People stops fitting. Same shape as `sourcesOutgrowsTheOpeningEventually`: no card
    /// height can hold any roster, but a real household must fit and the overflow count be known.
    @Test func peopleOutgrowsTheOpeningEventually() async throws {
        let settings = await manager(providerCount: 2)
        let opening = (width: contentWidth, height: contentCeiling)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fit-people-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "many", profile: nil)

        var firstOverflow: Int?
        // A high bound, because the roster is a wrapping chip row of about four names to a line.
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

    /// At the largest text size the card grows too, so the steps still have somewhere to go. Not a
    /// fit assertion: on a small display the card is already clamped and may scroll; what must hold
    /// is that the opening doesn't shrink.
    @Test func theOpeningDoesNotShrinkWhenTextGrows() {
        let roomy = CGSize(width: 2000, height: 1400)
        #expect(SetupSheetMetrics.resolvedHeight(availableSize: roomy, scale: 1.35)
                >= SetupSheetMetrics.resolvedHeight(availableSize: roomy, scale: 1))
        #expect(SetupSheetMetrics.resolvedWidth(availableSize: roomy, scale: 1.35)
                >= SetupSheetMetrics.resolvedWidth(availableSize: roomy, scale: 1))
    }
}
