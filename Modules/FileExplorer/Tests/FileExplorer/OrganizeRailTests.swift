import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's header, in pixels: the rail on row 1, the readout on row 2, and the controls between
/// them. The first claim is that a capsule is a control: the clickable row must look clickable and
/// the prose row must not.
///
/// Pixels, because the rail items are labels inside `Button`s that `fittingSize` can't see (the
/// lens fills a fixed frame), and a caption assertion passes vacuously with no assistive client.
@MainActor
// Machine-pinned per test: only the tests that read painted pixels carry
// `.machinePinned(.pixelSampling)`; the arithmetic, glyph table and labels run everywhere.
@Suite(.serialized) struct OrganizeRailTests {

    /// 1400, not 900: at 900 the rail sheds its labels (see ``OrganizeRailMetrics``), so the suite
    /// would measure only the glyph-only state and leave the spelled-out rail a real window shows
    /// untested. The shedding is pinned separately, on both sides of the threshold.
    private static let canvas = CGSize(width: 1400, height: 620)

    /// Row 1, the rail. Measured off the rendered header: row 1's content at y 12–42, a blank
    /// gutter at 42–52, then row 2 at 52–70. The zone stops at x 588 so the trailing controls,
    /// which are also capsules, can't be mistaken for rail items.
    private static let railZone = CGRect(x: 8, y: 12, width: 580, height: 30)
    /// Row 2, the readout. Same left edge, so the two densities compare over the same width.
    private static let readoutZone = CGRect(x: 8, y: 50, width: 580, height: 22)
    /// The lens's trailing controls on row 2. Excludes the search toggle, which sits on row 1 and
    /// draws in every state, so a band containing it would never be empty.
    private static let actionsZone = CGRect(x: 1000, y: 48, width: 330, height: 26)
/// Row 2's trailing controls, anchored to the right edge so they track at any width. 170pt: they
/// share the side with the folder-memory caption, and a wider band reads the caption coming and
/// going as truncation. Inside the narrowest trailing set measured (Duplicates, 354pt).
    private static func trailingZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 170, y: 48, width: 170, height: 26)
    }
    /// The content card beneath the header: everything below the two-row ladder and its gutter.
    /// Used only to ask whether a lens's page carries anything, never what it says.
    private static let contentZone = CGRect(x: 20, y: 110, width: 1360, height: 420)

    // MARK: Fixtures

    private static func suggestion(_ name: String, confident: Bool = true) -> FilingSuggestion {
        FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
                         modificationDate: Date(timeIntervalSince1970: 0),
                         candidates: [FilingDestination(path: "/root/Documents/Family",
                                                        confidence: confident ? .high : .low,
                                                        reasons: ["t"], newSegments: [])],
                         providerRoot: "/root")
    }

    private static func risky(_ n: String) -> RiskyName {
        RiskyName(id: "/root/\(n)", relativePath: n, currentName: n,
                  sanitizedName: n.replacingOccurrences(of: ":", with: "-"),
                  reason: "colon", isDirectory: false)
    }

    /// Two eras of two, the minimum `StructureDivergence` reports on: the shape of the real
    /// `Income Tax` family cut to size.
    private static var divergentProfile: FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        func add(_ path: String) {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: true, fileCount: 1,
                                               subfolderCount: 0, axes: [:])
        }
        for year in ["2013", "2014"] {
            add("Tax/\(year)"); add("Tax/\(year)/Federal"); add("Tax/\(year)/State")
        }
        for year in ["2016", "2017"] {
            add("Tax/\(year)"); add("Tax/\(year)/Forms"); add("Tax/\(year)/Refund")
        }
        return FolderProfile(profileId: "t", root: "/root", folders: folders, personTokens: [])
    }

    /// The badge accessor ``OrganizeRailMetrics`` takes, from the counts that matter to a case.
    /// Anything unlisted reports nothing, which is what `badge(count:)` turns into "no badge".
    private static func badges(_ counts: [OrganizeLens: Int]) -> (OrganizeLens) -> Int? {
        { $0.badge(count: counts[$0] ?? 0) }
    }

    /// The rail states the width model takes, from the counts that matter to a case. Anything
    /// unlisted is `clean` (scanned and empty, not unscanned), which costs the model nothing; a
    /// fixture wanting the dot must ask for it, so an item's width can't grow by accident.
    private static func states(_ counts: [OrganizeLens: Int],
                               unscanned: Set<OrganizeLens> = []) -> (OrganizeLens) -> RailItemState {
        { item in
            guard item.carriesBadge else { return .configuration }
            if let n = counts[item], n > 0 { return .reporting(n) }
            return unscanned.contains(item) ? .notScanned : .clean
        }
    }

    /// Duplicates with real groups: the lens with Organize's widest trailing set (`All ⌄`,
    /// `Rescan`, `Apply N recommended`, search), measured at 353.5pt against the filing queue's
    /// 281.
    private static func duplicatesManager(groups: Int, names: Int) -> FileSyncManager {
        let m = manager(queue: 24, names: names)
        m.duplicateGroups = (0..<groups).map { i in
            DuplicateGroup(
                matchType: .identical, name: "dup\(i).pdf", isDirectory: false,
                copies: [
                    DuplicateCopy(id: "/root/A/dup\(i).pdf", name: "dup\(i).pdf",
                                  isDirectory: false, size: 4_096, itemCount: 1,
                                  modificationDate: Date(timeIntervalSince1970: 0),
                                  uniqueItemCount: 0, depth: 2, isRecommendedKeeper: true),
                    DuplicateCopy(id: "/root/B/dup\(i).pdf", name: "dup\(i).pdf",
                                  isDirectory: false, size: 4_096, itemCount: 1,
                                  modificationDate: Date(timeIntervalSince1970: 0),
                                  uniqueItemCount: 0, depth: 2, isRecommendedKeeper: false)],
                reclaimableBytes: 4_096)
        }
        m.hasFoundDuplicates = true
        return m
    }

    /// A real survey's worst case: every clause the summary can carry, with the counts his own tree
    /// produces. 485pt of caption.
    private static let longSurvey = FileSyncManager.FilingSurveyReport(
        foldersChanged: 12, documentsRead: 340, documentsRelocated: 8, documentsDropped: 3,
        documentsUnavailable: 5, foldersLearned: 96, changed: true)

/// - Parameters:
///   - survey: the last folder-memory re-survey's report, or nil (none run this session).
///   - refine: whether the refine offer shows. `canRefineFilingSuggestions` also wants the cached
///     taxonomy and provider root; without them no button draws and the row "fits".
///   - scanFolder: the root the filing list was walked from, or nil for a manager that never
///     scanned. `hasScanned: false` alone leaves a scanned root, which draws a different button.
    private static func manager(queue: Int, names: Int, hasScanned: Bool = true,
                                scanFolder: String? = "/root/Downloads",
                                survey: FileSyncManager.FilingSurveyReport? = nil,
                                refine: Bool = false,
                                heavyReadout: Bool = false) -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions((0..<queue).map { suggestion("f\($0).pdf", confident: $0 % 3 != 0) })
        m.hasSuggestedFiling = hasScanned
        m.filingScanFolder = scanFolder
        m.filingLastProviderRoot = "/root"
        m.riskyNames = (0..<names).map { risky("bad:name\($0).pdf") }
        m.nameScanRoot = URL(fileURLWithPath: "/root")
        m.hasScannedNames = names > 0
        m.filingSurveyReport = survey
        if heavyReadout {
            // Two more pills on row 2's leading side (`reused`, `refined`), which makes the row
            // tight enough for its trailing side to have to give.
            m.filingLastCacheReuse = FileSyncManager.FilingCacheReuse(reused: 340, classified: 12)
            m.filingLastRefine = FileSyncManager.FilingRefineSummary(asked: 40, reused: 8,
                                                                     classified: 32, changed: 12)
        }
        if refine {
            m.filingClassifier = { _, _, _ in [:] }
            m.filingLastTaxonomyFolders = ["Documents", "Documents/Family"]
            m.filingLastExistingFolders = ["Documents", "Documents/Family"]
        }
        return m
    }

/// Mounts Organize with a named rail selection, through the defaults `LensWorkspaceView` reads.
/// With the key unset the rail resolves to the overview, where no lens's actions draw, so every
/// action-band comparison would measure nothing. `scale` is the app's text-size multiplier.
/// `providerRoot` and `scanTarget` decide whether the pane has wandered off what Organize answers
/// about (``OrganizeAim``); the defaults keep them equal, so no fixture draws the moved button.
    private func mount(_ manager: FileSyncManager, lens: OrganizeLens?,
                       width: CGFloat? = nil, scale: CGFloat = 1,
                       providerRoot: String? = nil,
                       scanTarget: String = "/root/Downloads") -> NSHostingView<AnyView> {
        let canvas = CGSize(width: width ?? Self.canvas.width, height: Self.canvas.height)
        let defaults = ScratchDefaults("OrganizeRailTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let lens {
            defaults.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            defaults.removeObject(forKey: OrganizeLens.defaultsKey)
        }
// Both callbacks gate a control this suite measures: "Refresh what’s learned", and "Refine with
// Claude…", which is withheld when there is no Settings to open.
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: scanTarget, onFindDuplicates: {},
                               onUpdateFolderMemory: {}, onConfigureCloudRefine: {},
                               providerRoot: providerRoot)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        // Twice: `.onGeometryChange` writes `railStyle` after a pass.
        return ReviewLensHost.mount(subject, size: canvas, passes: 2).host
    }

/// Pixels split by how far they are from the band's background corner. A capsule covers its area
/// in a low-opacity fill (`wash`); text is a small area of near-black `ink`. Not a brightness
/// filter: that counts the dark text inside a capsule and none of the wash behind it.
    private func counts(_ rep: NSBitmapImageRep) -> (wash: Int, ink: Int) {
        guard let background = rep.colorAt(x: 2, y: 2) else { return (0, 0) }
        var wash = 0, ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = PixelProbe.distance(c, background)
                if delta > 0.35 { ink += 1 } else if delta > 0.03 { wash += 1 }
            }
        }
        return (wash, ink)
    }

    /// `wash` per point of band width, so bands of different widths compare directly.
    private func washDensity(_ rep: NSBitmapImageRep, width: CGFloat) -> Double {
        Double(counts(rep).wash) / Double(width)
    }

/// Accent-tinted wash pixels: the capsule fill rather than its ring. A reporting item is washed in
/// the accent and a clean one in a neutral, so blue must lead red at a small delta.
    private func accentWash(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        return PixelProbe.count(in: rep) {
            PixelProbe.distance($0, background) > 0.02 && ($0.blueComponent - $0.redComponent) > 0.05
        }
    }

/// Strong, blue-dominant pixels: the selection ring, told apart from the 22% fill behind it (which
/// sits below the 0.30 floor) and from near-neutral text.
    private func accentEdge(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        return PixelProbe.count(in: rep) {
            PixelProbe.distance($0, background) > 0.30 && ($0.blueComponent - $0.redComponent) > 0.18
        }
    }

/// The x-extent of row 1's leading cluster (rail plus intro button), read off the render so the
/// width model is held to something other than itself. A 30pt run of background ends it. The band
/// starts at x 8: the card's 1pt border at x≈2.5 would merge into the cluster and count as rail.
    private func leadingExtent(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = PixelProbe.render(host, CGRect(x: origin, y: 12, width: width - origin, height: 30)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin)
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = PixelProbe.distance(c, background)
                if delta > 0.03 { n += 1 }
            }
            inked.append(n >= 2)
        }
        var runs: [(CGFloat, CGFloat)] = []
        var start: Int?
        var blank = 0
        let gap = Int(30 * scale)
        for (i, on) in inked.enumerated() {
            if on {
                if start == nil { start = i }
                blank = 0
            } else if let s = start {
                blank += 1
                if blank >= gap {
                    runs.append((CGFloat(s) / scale, CGFloat(i - blank) / scale))
                    start = nil
                }
            }
        }
        if let s = start { runs.append((CGFloat(s) / scale, CGFloat(inked.count - 1) / scale)) }
        guard let cluster = runs.first(where: { $0.1 - $0.0 > 3 }) else { return nil }
        return cluster.1 - cluster.0
    }

/// The width from the first inked run to the last in a band. The 0.10 threshold and the run split
/// are because the card's glass carries a gradient; first-to-last because the last run is always
/// the search toggle.
    private func trailingSpan(_ rep: NSBitmapImageRep, bandWidth: CGFloat) -> CGFloat? {
        guard let background = rep.colorAt(x: rep.pixelsWide - 3, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / bandWidth
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = PixelProbe.distance(c, background)
                if delta > 0.10 { n += 1 }
            }
            inked.append(n >= 2)
        }
        var runs: [(Int, Int)] = []
        var start: Int?
        var blank = 0
        let gap = Int(10 * scale)
        for (i, on) in inked.enumerated() {
            if on {
                if start == nil { start = i }
                blank = 0
            } else if let s = start {
                blank += 1
                if blank >= gap { runs.append((s, i - blank)); start = nil }
            }
        }
        if let s = start { runs.append((s, inked.count - 1)) }
        let real = runs.filter { $0.1 - $0.0 > 2 }
        guard let first = real.first, let last = real.last else { return nil }
        return CGFloat(last.1 - first.0) / scale
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { n += 1 }
        }
        return n
    }

    // MARK: The rule, ported across the row break — a capsule is a control

    @Test("The rail row wears capsules and the readout row does not", .machinePinned(.pixelSampling))
    func onlyTheControlRowWearsCapsules() throws {
        let host = mount(Self.manager(queue: 24, names: 17), lens: .toFile)
        let rail = try #require(PixelProbe.render(host, Self.railZone))
        let readout = try #require(PixelProbe.render(host, Self.readoutZone))

// Staleness guard: a band drifted off its row paints nothing and satisfies "no capsule"
// trivially, so the readout must be full of text while empty of wash.
        let readoutInk = counts(readout).ink
        #expect(readoutInk > 200,
                "the readout band drew only \(readoutInk) inked pixels — it has drifted off row 2, and every wash assertion here is vacuous")

        let railDensity = washDensity(rail, width: Self.railZone.width)
        let readoutDensity = washDensity(readout, width: Self.readoutZone.width)
        #expect(railDensity > 20,
                "the rail painted \(Int(railDensity)) wash px/pt — its items have lost their capsules, and with them the only thing saying the row is clickable")
        #expect(readoutDensity < 8,
                "the readout painted \(Int(readoutDensity)) wash px/pt — it is wearing capsules, so a number that does nothing when clicked looks exactly as pressable as the rail above it")
    }

    @Test("The readout still says its numbers", .machinePinned(.pixelSampling))
    func theReadoutIsNotSimplyGone() throws {
        // The cheapest way to pass the test above is to draw no readout at all, so pin that it
        // still tracks the scan: same queue length, different confidence mix, which moves `ready`
        // and `unsure` without changing any rail badge.
        let allConfident = Self.manager(queue: 0, names: 17)
        allConfident.publishFilingSuggestions((0..<24).map { Self.suggestion("f\($0).pdf", confident: true) })
        allConfident.hasSuggestedFiling = true

        let mixed = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                   Self.readoutZone))
        let clean = try #require(PixelProbe.render(mount(allConfident, lens: .toFile), Self.readoutZone))
        #expect(counts(mixed).ink != counts(clean).ink,
                "the readout painted the same thing for 24 ready and for 16 ready with 8 unsure — it is not reading the scan")
    }

    // MARK: The rail is on screen, and it is the rail

    @Test("The rail draws on a lens whose apparatus is not the filing one", .machinePinned(.pixelSampling))
    func theRailSurvivesTheApparatusSwitch() throws {
        // The rail must sit outside the summary arm only the filing apparatus reaches, or standing
        // on Duplicates or Rules would draw that lens's own pills and no rail. Rules borrows
        // `.automations`' apparatus, the furthest from filing's, so it is the strongest case.
        let onFiling = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                      Self.railZone))
        let onRules = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .rules),
                                                     Self.railZone))
        #expect(counts(onRules).ink > 600,
                "row 1 is empty on the Rules lens — the rail is drawn inside one apparatus's arm again")
        // The same items either way; only the ring moves, so the renders differ but neither is
        // blank. Asserting they differ stops a cached or identical render passing both.
        #expect(differingPixels(onFiling, onRules) > 0,
                "the rail rendered identically on two different selections — the ring is not tracking the lens")
    }

    @Test("The selected item is ringed", .machinePinned(.pixelSampling))
    func theSelectedItemIsRinged() throws {
// Measured as the ring, not a diff: deleting the stroke leaves the deepened fill, which still
// moves a whole-band diff. `accentEdge` separates them.
        let ringed = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                    Self.railZone))
        let edge = accentEdge(ringed)
        #expect(edge > 1500,
                "the selected item painted \(edge) full-strength accent pixels — the ring is not drawing, and only the fill is left to say which lens you are on")
    }

    @Test("Moving the selection moves the ring", .machinePinned(.pixelSampling))
    func theRingFollowsTheSelection() throws {
        // A ring drawn on a fixed item would satisfy the test above forever. Both states are
        // ringed, so here the pixel diff is the right instrument: the question is whether the ring
        // moved.
        let onToFile = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                      Self.railZone))
        let onRenames = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .renames),
                                                       Self.railZone))
        #expect(accentEdge(onRenames) > 1500, "the Renames selection drew no ring")
        #expect(differingPixels(onToFile, onRenames) > 200,
                "selecting a different rail item changed almost nothing — the ring is pinned to one item")
    }

    @Test("The overview rings its own item, and no lens", .machinePinned(.pixelSampling))
    func theOverviewRingsAll() throws {
// The overview's place is "All" at the head of the rail, ringed when `railLens` is nil.
        let overview = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: nil),
                                                      Self.railZone))
        let selected = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                      Self.railZone))
        #expect(counts(overview).ink > 600, "the overview drew no rail — it is not the unselected state")

        // Something is ringed: about 400 accent-edge pixels when nothing is, against 2,500 for a
        // ringed lens. A pixel diff can't ask this, since it passes with the ring deleted.
        let edge = accentEdge(overview)
        #expect(edge > 900,
                "the overview painted \(edge) full-strength accent pixels — nothing is ringed, so All is not showing as the current place")

        // …and it is All that is ringed, not a lens: the ring sits in the rail's first item,
        // measured over the leading 120pt, which at this canvas holds All and nothing else.
        let allItem = CGRect(x: 8, y: 12, width: 120, height: 30)
        let overviewAll = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: nil), allItem))
        let toFileAll = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile), allItem))
        #expect(accentEdge(overviewAll) > accentEdge(toFileAll) + 200,
                "All painted \(accentEdge(overviewAll)) accent-edge pixels on the overview and \(accentEdge(toFileAll)) with a lens selected — the ring is not moving to All")

        #expect(differingPixels(overview, selected) > 200,
                "the overview and a selected lens rendered the same rail")
    }

    // MARK: Badges — absent at zero, present with a finding

    @Test("A badge appears only when its lens has something to report", .machinePinned(.pixelSampling))
    func aBadgeIsAbsentAtZero() throws {
        // The item is unconditional, which is what pointed invocation lands on, so this compares
        // two renders of the same items and asserts the badge is what changed.
        let none = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 0), lens: .toFile),
                                                  Self.railZone))
        let some = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                  Self.railZone))
        #expect(differingPixels(none, some) > 100,
                "17 risky names painted the same rail as none — the Names badge is not drawing")
        // And the item itself is there either way: a place is not a badge.
        #expect(counts(none).ink > 600, "the rail lost an item at zero — a place is not a badge")
    }

    @Test("The badge carries the count, not just a dot", .machinePinned(.pixelSampling))
    func theCountReachesTheBadge() throws {
        // Two non-zero counts of different digit widths. A presence indicator rather than a number
        // would render these identically.
        let three = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 3), lens: .toFile),
                                                   Self.railZone))
        let seventeen = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                       Self.railZone))
        #expect(differingPixels(three, seventeen) > 50,
                "3 and 17 risky names painted the same badge — it is not carrying the count")
    }

    @Test("The Restructure badge reports the findings the overview reports", .machinePinned(.pixelSampling))
    func theRestructureBadgeTracksTheDetector() throws {
        // `railCount` must read the restructure detector, not return a literal 0; otherwise the
        // overview says "1 finding" while the rail item beside it stays bare, and the lens can't
        // announce itself, which is the whole job of a badge.
        let withFindings = Self.manager(queue: 24, names: 17)
        withFindings.filingFolderProfile = Self.divergentProfile
        let none = Self.manager(queue: 24, names: 17)   // no profile ⇒ nothing to detect

        // A band wide enough for the whole rail. `railZone` stops at x 588 to keep the trailing
        // controls out, and a third badge pushes the rail past that edge, so the crop would lose
        // more of "Rules" than the badge adds and invert the ink comparison.
        let whole = CGRect(x: 8, y: 12, width: 700, height: 30)
        let a = try #require(PixelProbe.render(mount(withFindings, lens: .toFile), whole))
        let b = try #require(PixelProbe.render(mount(none, lens: .toFile), whole))
        #expect(differingPixels(a, b) > 50,
                "a tree with a divergent family painted the same rail as one with none — the badge is not reading the detector")
        #expect(counts(a).ink > counts(b).ink,
                "the badge added no ink — restructure is still reporting a hard-coded zero")
    }

    // MARK: Shedding — the rail yields width to the controls

    @Test("At 900pt the rail spells itself out, and the controls are on row 2", .machinePinned(.pixelSampling))
    func theRailKeepsItsNamesAtNineHundred() throws {
// Row 1 reserves only the search toggle, so 900 is above the shed threshold. A shed 900pt
// render inks less than half the 1400pt one.
        let wide = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                  Self.railZone))
        let atNineHundred = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17),
                                                                 lens: .toFile, width: 900),
                                                           Self.railZone))
        #expect(counts(atNineHundred).ink > counts(wide).ink * 3 / 4,
                "at 900pt the rail inked \(counts(atNineHundred).ink) against \(counts(wide).ink) at 1400 — it is shedding its labels again, so row 1 has picked up a tenant the reserve does not know about")

        // And row 1's trailing half is empty, bar the search toggle `LensHeaderCard` appends
        // itself. Measured to the left of that toggle, which draws in every state and would make
        // this band non-empty whatever the actions did.
        let host = mount(Self.manager(queue: 24, names: 17, refine: true), lens: .toFile, width: 1400)
        let rowOneTrailing = try #require(PixelProbe.render(host, CGRect(x: 1000, y: 12, width: 330, height: 30)))
        #expect(counts(rowOneTrailing).ink < 200,
                "row 1's trailing band inked \(counts(rowOneTrailing).ink) — a control is still drawing up there, and the reserve is sized for none")
        // …and they are drawing on row 2, or the assertion above passes by the actions having
        // vanished.
        let rowTwoTrailing = try #require(PixelProbe.render(host, Self.trailingZone(1400)))
        #expect(counts(rowTwoTrailing).ink > 400,
                "row 2's trailing band inked \(counts(rowTwoTrailing).ink) — the controls did not arrive where they were moved to")
    }

    // MARK: The three states — reporting, clean, never looked

    @Test("A lens with findings is tinted; one that ran and found nothing is not", .machinePinned(.pixelSampling))
    func theTintSaysHasWorkNotIsClickable() throws {
// The wash means "this has work", not "this is a control": colour goes only to lenses with
// findings. Same scan either way, over Duplicates' own item.
        let reporting = Self.duplicatesManager(groups: 12, names: 0)
        let clean = Self.duplicatesManager(groups: 0, names: 0)
        // The rail runs All | To File · Duplicates · …, so Duplicates' item sits second among the
        // lenses. A 150pt band from x 150 holds it at this canvas and neither neighbour.
        let band = CGRect(x: 150, y: 12, width: 150, height: 30)
        let hot = try #require(PixelProbe.render(mount(reporting, lens: .toFile), band))
        let cold = try #require(PixelProbe.render(mount(clean, lens: .toFile), band))
        #expect(accentWash(hot) > accentWash(cold) + 300,
                "a reporting lens washed \(accentWash(hot)) accent pixels and a clean one \(accentWash(cold)) — the tint is not carrying the finding, so the row is six identical capsules again")
        // …and the clean one is still a capsule, or the control claim is gone with the colour.
        #expect(counts(cold).ink > 200,
                "the clean lens inked \(counts(cold).ink) — it has lost its capsule along with its tint, so a live button now reads as prose")
    }

    @Test("Never-scanned is not the same as clean, on the rail as in the overview")
    func theRailKeepsCleanAndUnscannedApart() {
        // The distinction `OrganizeOverviewState` draws: never scanned and clean must not both read
        // as "an item with no badge". Asserted on the state the width model and the label both
        // read, so the two can't drift.
        var counts = LensWorkspaceView.RailCounts(toFile: 0, duplicates: 0, names: 0, renames: 0,
                                         restructure: 0, rules: 3)
        counts.scanned = [.duplicates]
        #expect(counts.state(.duplicates) == .clean)
        #expect(counts.state(.toFile) == .notScanned)
        #expect(counts.state(.rules) == .configuration,
                "Rules answered a scan state — it is configuration, and neither clean nor unscanned describes it")
        counts.toFile = 4
        #expect(counts.state(.toFile) == .reporting(4))
        // And the two quiet states cost different widths, or the model can't tell them apart and
        // the dot is drawn uncharged.
        #expect(OrganizeRailMetrics.stateWidth(.notScanned, scale: 1)
                > OrganizeRailMetrics.stateWidth(.clean, scale: 1))
    }

    @Test("The rail says its state in words, not only in colour")
    func theRailStateIsSpokenNotOnlyTinted() {
        // A reporting item is told from a quiet one by its wash, and an unscanned one from a clean
        // one by a 4pt dot; neither reaches VoiceOver, so the state must also be in the spoken
        // label. Colour must never be the only carrier.
        #expect(RailItemLabel.accessibilityLabel(title: "Duplicates", state: .reporting(722))
                == "Duplicates, 722")
        #expect(RailItemLabel.accessibilityLabel(title: "Names", state: .clean)
                == "Names, nothing found")
        #expect(RailItemLabel.accessibilityLabel(title: "Restructure", state: .notScanned)
                == "Restructure, not scanned")
        // Rules and "All" report nothing and have no state to announce: "Rules, nothing found"
        // would be the claim the badge refuses to make by never drawing a zero there.
        #expect(RailItemLabel.accessibilityLabel(title: "Rules", state: .configuration) == "Rules")

        // The three states must be told apart from each other, which is the whole claim.
        let spoken = Set([RailItemState.reporting(1), .clean, .notScanned]
            .map { RailItemLabel.accessibilityLabel(title: "X", state: $0) })
        #expect(spoken.count == 3, "two states announce identically — the row is still colour-only")

        // Spoken in full where the badge abbreviates: `1.2k` is a width compromise for capsules
        // sharing a row, which a spoken label doesn't need.
        #expect(RailItemLabel.accessibilityLabel(title: "Renames", state: .reporting(1_192))
                == "Renames, 1,192")
        #expect(RailItemLabel.badgeText(1_192) == "1.1k")
    }

    @Test("The rail item actually wears the label it composes")
    func theRailAppliesItsSpokenLabel() throws {
// Pins that the view calls `accessibilityLabel(title:state:)`. A source scan, because SwiftUI
// publishes no accessibility tree to an `NSHostingView` with no assistive client attached, so a
// live check would pass with the modifier deleted.
        let source = try SourceText.fileExplorer("OrganizeOverview.swift", atLeast: 5000)

        // Fed by the function, not restated: an inlined "\(title), \(count)" would satisfy a bare
        // "is there a label" scan while free to drift from what the tests above pin.
        #expect(source.contains(".accessibilityLabel(Self.accessibilityLabel(title: title, state: state))"),
                "RailItemLabel no longer speaks its state — the row announces six identical titles and the tint is the only carrier again")
    }

    @Test("A lens that has never scanned does not claim a scan found nothing")
    func theHelpDoesNotInventAScan() {
        // `badge ?? 0` would read a nil (no number to show) as zero, and a never-scanned queue's
        // tooltip would claim "0 loose files this scan found" for a scan that never ran, the
        // conflation the rail's three states exist to remove.
        let unscanned = OrganizeLens.toFile.help(state: .notScanned)
        #expect(unscanned.hasPrefix("Not scanned here yet."),
                "a never-scanned lens says: \(unscanned)")
        #expect(!unscanned.contains("0 "), "the help is still quoting a zero for a scan that never ran")

        #expect(OrganizeLens.toFile.help(state: .clean).hasPrefix("Nothing here."))
        #expect(OrganizeLens.toFile.help(state: .reporting(24)).hasPrefix("24 here."))
        // The description is the same sentence in every state; only the count clause changes.
        for state in [RailItemState.reporting(24), .clean, .notScanned] {
            #expect(OrganizeLens.toFile.help(state: state).contains("Loose files and where they belong."))
        }
    }

    @Test("A four-digit badge abbreviates, and the model measures what it draws")
    func theBadgeAbbreviatesPastThreeDigits() {
        #expect(RailItemLabel.badgeText(999) == "999")
        #expect(RailItemLabel.badgeText(1_192) == "1.1k")
        #expect(RailItemLabel.badgeText(12_400) == "12k")
        // Abbreviating matters because the rail is widest on the day every finding reports.
        #expect(OrganizeRailMetrics.badgeWidth(1_192, scale: 1)
                < OrganizeRailMetrics.badgeWidth(999, scale: 1) + 8,
                "the four-digit badge costs as much as it did unabbreviated — the model is measuring `1,192` while the row paints `1.1k`")
        // `410` is not `24`: a flat two-digit figure per badge would under-charge a three-digit
        // count by about 8pt a badge and let the row truncate while the arithmetic reports room.
        #expect(OrganizeRailMetrics.badgeWidth(410, scale: 1)
                > OrganizeRailMetrics.badgeWidth(24, scale: 1))
        #expect(OrganizeRailMetrics.leadingWidth(scale: 1,
                                                 state: Self.states([.duplicates: 410]))
                > OrganizeRailMetrics.leadingWidth(scale: 1,
                                                   state: Self.states([.duplicates: 24])))
    }

    @Test("Shedding is arithmetic, and it answers both ways")
    func theShedRuleIsComputed() {
        let twoBadges = Self.states([.toFile: 24, .renames: 17])
        let lead = { (b: @escaping (OrganizeLens) -> RailItemState) in
            OrganizeRailMetrics.leadingWidth(scale: 1, state: b)
        }
        // The real header widths this app produces, either side of the threshold. With the controls
        // on row 2 the reserve is the search toggle alone and the threshold is ~668, so 900 is
        // `.full`. 600 is below it and answers the other way, which keeps this about arithmetic
        // rather than a constant.
        #expect(OrganizeRailMetrics.style(contentWidth: 1400, leadingWidth: lead(twoBadges)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 900, leadingWidth: lead(twoBadges)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 600, leadingWidth: lead(twoBadges)) == .iconOnly)
        // The shed rung must actually solve it, or shedding buys nothing.
        let shed = OrganizeRailMetrics.shedLeadingWidth(scale: 1, state: twoBadges)
        #expect(shed <= 600 - OrganizeRailMetrics.searchToggleWidth)
        // Badges widen the rail, so the day every finding reports is the tightest; a rule measured
        // without them would shed too late. Every lens badged sheds soonest, and answers the same
        // way at the same widths.
        #expect(lead(twoBadges) > lead(Self.states([:])))
        let everyBadge: (OrganizeLens) -> RailItemState = { $0.carriesBadge ? .reporting(7) : .configuration }
        #expect(OrganizeRailMetrics.style(contentWidth: 1400, leadingWidth: lead(everyBadge)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 900, leadingWidth: lead(everyBadge)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 600, leadingWidth: lead(everyBadge)) == .iconOnly)
        // Row 1 reserves only the rail and the search toggle; the scope chip lives on row 2,
        // outside this budget (`OrganizeScopeCallSiteTests` pins its draw site).
        #expect(OrganizeRailMetrics.searchToggleWidth == 36)
    }

/// The width the rail gets is the column's, not the window's: Organize's card sits beside a source
/// pane draggable from 220pt up, so a 900pt window hands this row about 500. At the default size
/// with two findings, labels need a 623pt column, which an 810pt window can't give (590).
    @Test("The column, not the window, is what the rail has to fit")
    func theShedRuleIsAskedInColumnWidths() {
        let twoBadges = Self.states([.toFile: 24, .renames: 17])
        let leading = OrganizeRailMetrics.leadingWidth(scale: 1, state: twoBadges)

// The card's own inset and padding are charged, asserted as a consequence rather than by
// restating the body: a column holding exactly the rail and toggle is still too narrow.
        #expect(OrganizeRailMetrics.cardChrome == 29)
        #expect(OrganizeRailMetrics.style(columnWidth: leading + OrganizeRailMetrics.searchToggleWidth,
                                          leadingWidth: leading) == .iconOnly,
                "the card's own inset and padding have stopped being charged — the rail will draw 29pt past the room it has")

        // The boundary from both sides, so a chrome constant cannot move it unnoticed.
        let threshold = leading + OrganizeRailMetrics.searchToggleWidth + OrganizeRailMetrics.cardChrome
        #expect(OrganizeRailMetrics.style(columnWidth: threshold, leadingWidth: leading) == .full)
        #expect(OrganizeRailMetrics.style(columnWidth: threshold - 1, leadingWidth: leading) == .iconOnly)

        // What the window's own floor produces: 810 content, less the source pane's 220pt minimum.
        #expect(OrganizeRailMetrics.style(columnWidth: 810 - 220, leadingWidth: leading) == .iconOnly,
                """
                the rail spells itself out in a 590pt column — if that is now true the threshold has \
                moved and the window floor's consequence recorded here is out of date
                """)
        // And a comfortable window still spells it out, or the shed has swallowed the normal case.
        #expect(OrganizeRailMetrics.style(columnWidth: 1000, leadingWidth: leading) == .full)
    }

/// A rail item has to fit the row, because the row's horizontal `ScrollView` in `lensTitle` clips
/// it top and bottom. The margin at the largest text size is one point.
    @MainActor
    @Test("Every rail item fits the row the scroll clips it to", .machinePinned(.layoutMetrics))
    func theRailItemFitsTheRowItIsClippedTo() {
        for size in FontSize.allCases {
            let host = NSHostingView(rootView:
                RailItemLabel(title: "Duplicates", systemImage: "doc.on.doc", state: .reporting(410),
                              isSelected: true, accent: .blue)
                    .environment(\.appFontScale, size.scale))
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height

            #expect(height > 0, "the rail item laid out at 0pt at \(size.displayName) — this measurement is fiction")
            #expect(height <= LensHeaderMetrics.tabRow,
                    """
                    a rail item is \(height)pt at \(size.displayName), taller than the \
                    \(LensHeaderMetrics.tabRow)pt row — the scroll view in `lensTitle` clips it now, \
                    so this shows as a badge cut off top and bottom
                    """)
        }
    }

    /// Shedding can't always solve it, which is why the row also scrolls. At the workspace
    /// column's 340pt floor (`singleSourceLayout`'s `minWorkspace`), four three-digit badges at the
    /// largest text size overrun the usable row even with the labels gone, and an `HStack` out of
    /// room draws over its neighbour rather than clipping. This keeps the horizontal scroll in
    /// `LensWorkspaceView.lensTitle` from reading as belt-and-braces someone can tidy away.
    @Test("The glyph rung can still overrun the narrowest column")
    func theGlyphRungCanStillOverrunTheNarrowestColumn() {
        let busy = Self.states([.toFile: 410, .duplicates: 410,
                                .renames: 410, .restructure: 410])
        let shed = OrganizeRailMetrics.shedLeadingWidth(scale: FontSize.extraLarge.scale, state: busy)
        let usable = 340 - OrganizeRailMetrics.cardChrome - OrganizeRailMetrics.searchToggleWidth

        #expect(shed > usable,
                """
                the glyph rail now fits the 340pt workspace floor at \(shed)pt against \(usable) — \
                the scroll in `lensTitle` has stopped being reachable and this test has lost its subject
                """)
    }

    @Test("The leading model matches what row 1 draws at every text size the app ships", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theLeadingModelMatchesWhatTheRowDraws(size: FontSize) throws {
// Measured off the render: comparing the model with itself would stay self-consistent while short
// of the row, and only this catches a control added beside the rail and left out of the model.
// Every text size, because a `glyphWidth` that ignores `scale` fails only at `.extraLarge`.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        let host = mount(manager, lens: .duplicates, width: 1400, scale: size.scale)
        let drawn = try #require(leadingExtent(host, width: 1400),
                                 "row 1 drew no leading cluster at \(size.scale)× — the rail is not on screen at all")
        // The risky names ride the Renames badge (Names is folded into Renames), so the model is
        // fed what the rail draws.
        let model = OrganizeRailMetrics.leadingWidth(
            scale: size.scale,
            state: Self.states([.toFile: 24, .duplicates: 410, .renames: 17]))

// Over, never under: a model that under-states the leading side lets the row overrun.
        #expect(model >= drawn,
                "at \(size.scale)× the rail draws \(drawn)pt but the model budgets \(model)pt — it is \(drawn - model)pt short, so the row will overrun before it sheds")
// And not wildly over, or the rail sheds its labels on headers that would have seated them.
        #expect(model - drawn < 12,
                "at \(size.scale)× the model budgets \(model)pt for a leading side that draws \(drawn)pt — \(model - drawn)pt of slack sheds the labels early")
    }

    @Test("The divider never draws against nothing", .machinePinned(.pixelSampling))
    func theRowTwoDividerIsPairedWithItsControls() throws {
// `hasRowTwoActions` hand-copies `lensActions`'s gates (a `@ViewBuilder` can't be asked whether
// it produced anything); if they disagree a hairline floats against an empty band. A narrow band,
// so a 1pt rule is a large share of it.
        let edge = { (w: CGFloat) in CGRect(x: w - 60, y: 48, width: 52, height: 26) }
        let width: CGFloat = 1400

        // Before any scan: no controls, and therefore no rule.
        let never = try #require(PixelProbe.render(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                                         lens: .toFile, width: width), edge(width)))
        // Wash, not ink: the divider is a 1pt `.quaternary` rule that registers about 56 wash
        // pixels and zero ink, so only the faint-fill measure can see it.
        #expect(counts(never).wash < 20,
                "row 2's trailing edge washed \(counts(never).wash) before any scan — the divider is drawing with no controls beside it")

        // After one: controls, and the rule that separates them from the prose.
        let scanned = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17),
                                                           lens: .toFile, width: width), edge(width)))
        #expect(counts(scanned).ink > 100,
                "row 2's trailing edge inked \(counts(scanned).ink) with a finished scan — the controls are not drawing where the divider says they are")
    }

    @Test("A stale readout leaves the row empty — it does not borrow the overview's", .machinePinned(.pixelSampling))
    func aStaleLensDoesNotBorrowTheOverviewsReadout() throws {
// `if let organizeLens, !stale { … } else { overviewSummary }` would draw the overview's readout
// under a selected lens mid-scan. A stale readout must leave the row empty.
        let scanning = Self.manager(queue: 24, names: 17)
        scanning.isSuggestingFiles = true
        let onToFile = try #require(PixelProbe.render(mount(scanning, lens: .toFile), Self.readoutZone))

        // The overview at the same moment does draw its readout: the non-vacuity half. Without it,
        // "the band is empty" would pass just as well with `overviewSummary` deleted.
        let onOverview = try #require(PixelProbe.render(mount(scanning, lens: nil), Self.readoutZone))
        #expect(counts(onOverview).ink > 200,
                "the overview drew no readout while a scan was running — this comparison proves nothing")
        #expect(counts(onToFile).ink < counts(onOverview).ink / 2,
                "a selected lens inked \(counts(onToFile).ink) against the overview's \(counts(onOverview).ink) while its own scan was running — it is drawing the overview's readout instead of leaving the row empty")
    }

    @Test("Row 1's reserve seats what row 1 actually draws, at every text size", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theRowOneReserveSeatsWhatRowOneDraws(size: FontSize) throws {
// Holds `searchToggleWidth` to everything row 1 draws right of the rail, in the state with the
// most to draw (refine offer and a survey report).
        let manager = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        let width: CGFloat = 1400
        let host = mount(manager, lens: .toFile, width: width, scale: size.scale)

// From the rail's end, read off the render, to the card's right edge.
        let railEnd = try #require(leadingExtent(host, width: width),
                                   "row 1 drew no leading cluster at \(size.scale)× — nothing to measure from")
        let band = CGRect(x: railEnd + 8, y: 12, width: width - railEnd - 16, height: 30)
        let rep = try #require(PixelProbe.render(host, band))

        // Measured as the inked extent, not an ink count: the question is how much width the
        // trailing side consumes, and a wide sparse control inks like a narrow dense one.
        let drawn = try #require(trailingSpan(rep, bandWidth: band.width),
                                 "row 1's trailing side drew nothing at \(size.scale)× — the search toggle is gone, and this reserve is protecting a control that no longer exists")
        #expect(drawn <= OrganizeRailMetrics.searchToggleWidth,
                "row 1's trailing side draws \(drawn)pt at \(size.scale)× against a reserve of \(OrganizeRailMetrics.searchToggleWidth) — a control has been put back up here and the rail is not being charged for it")
    }

    @Test("The glyph table still matches the renderer", .machinePinned(.layoutMetrics))
    func theGlyphTableMatchesTheRenderer() throws {
// ``OrganizeRailMetrics/glyphWidth(_:scale:)`` is tabulated because measuring is too slow per
// `body`; this stops the table rotting. A glyph is not its point size.
        for lens in OrganizeLens.allCases {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            let live = try #require(
                NSImage(systemSymbolName: lens.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)?.size.width,
                "\(lens.symbol) did not resolve — the rail's glyph is missing, not just mis-sized")
            #expect(abs(OrganizeRailMetrics.glyphWidth(lens, scale: 1) - live) < 0.5,
                    "\(lens.symbol) renders \(live)pt but the table says \(OrganizeRailMetrics.glyphWidth(lens, scale: 1)) — the rail is mis-measured by \(live - OrganizeRailMetrics.glyphWidth(lens, scale: 1))pt on this item")
        }
    }

    // MARK: The moment the labels appear, the actions must still have their words

    @Test("At the width the rail first spells itself out, the actions are not truncated", .machinePinned(.pixelSampling))
    func theShedThresholdIsNotOneCharacterTooLate() throws {
// Once the rail is spelled out, the actions must still be seated untruncated, or a threshold
// band draws `Apply 410 recomme…` while the arithmetic passes.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
// From 900, the narrowest card an ordinary window produces: row 2 needs ~800 for this lens, so
// sweeping from the rail's own flip point would ask what row 2 can't deliver.
        let threshold: CGFloat = 900

// Right-anchored and narrow (see `trailingZone`): the trailing set is fixed-size, so at every
// width that seats it these bands are pixel-identical.
        let roomy = mount(manager, lens: .duplicates, width: 2400)
        let reference = try #require(PixelProbe.render(roomy, Self.trailingZone(2400)))

        // A band of widths, not one point: a reserve a few points short puts the truncation just
        // above the flip, and a single probe would step over it.
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .duplicates, width: width)
            // The rail is spelled out here; otherwise "not truncated" is satisfied by the shed
            // state, which fits trivially.
            #expect(counts(try #require(PixelProbe.render(host, Self.railZone))).ink > 600,
                    "at \(width)pt the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(PixelProbe.render(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt — \(offset)pt above the width the model starts spelling the rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    @Test("To File seats its own actions at the width it starts spelling the rail out, at every text size", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theToFileThresholdSeatsItsOwnActions(size: FontSize) throws {
// The same on To File, whose trailing set is wider once the refine offer shows. Every text size:
// the controls are AppKit's and don't follow `appFontScale`, but nothing enforces that.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        // From 900 for the reason the test above gives: rows 1 and 2 shed at different widths, and
        // 900 is where real windows start.
        let threshold: CGFloat = 900

// The reference at the same scale, or it answers a different question at every other size.
        let reference = try #require(PixelProbe.render(mount(manager, lens: .toFile, width: 2400, scale: size.scale),
                                                       Self.trailingZone(2400)))
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .toFile, width: width, scale: size.scale)
            // Scaled with the text, because the rail's ink is: the flat 600 that suits 1.0 is a
            // near-miss at 0.9, where the same spelled-out items paint less of everything.
            let floor = 600 * size.scale * size.scale
            #expect(Double(counts(try #require(PixelProbe.render(host, Self.railZone))).ink) > floor,
                    "at \(width)pt and \(size.scale)× the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(PixelProbe.render(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt and \(size.scale)× — \(offset)pt above the width the model starts spelling To File's rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    // MARK: The folder-memory report is prose, and prose is not on row 1

/// The survey sentence's band on row 2, clear of the readout and the controls (the rightmost
/// ~455pt), so it is about the sentence alone: x 740–930 on the 1400pt canvas.
    private static func statusZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 660, y: 48, width: 190, height: 26)
    }
/// A rename backlog whose header form and folder-row form differ as much as they can. The totals
/// keep the monospaced headline the same width in both fixtures, so the renders differ only in the
/// breakdown.
    private static func renamePlan(named: Int = 0, reshuffled: Int = 0, padded: Int = 0,
                                   skips: Int = 0) -> RenamePlan {
        var steps: [RenameStep] = []
        func step(_ i: Int, _ kind: RenameStep.Kind) -> RenameStep {
            RenameStep(currentPath: "/T/\(kind.rawValue)\(i).pdf",
                       currentName: "\(kind.rawValue)\(i).pdf", proposedName: "0\(i). Jan 2021.pdf",
                       kind: kind, cohort: kind == .renumbered ? 1 : 0, reason: "")
        }
        for i in 0..<named { steps.append(step(i, .placed)) }
        for i in 0..<reshuffled { steps.append(step(i, .renumbered)) }
        for i in 0..<padded { steps.append(step(i, .tidied)) }
        return RenamePlan(folderPath: "/T", relativePath: "/T", scheme: .position, steps: steps,
                          skips: (0..<skips).map {
                              RenameSkip(path: "/T/s\($0)", fileName: "s\($0)", reason: "")
                          })
    }

    /// The right edge of row 2's leading run: the headline plus the breakdown after it. Runs break
    /// on 20pt of background, wider than the 8pt gap between headline and breakdown and narrower
    /// than the reach to the trailing side, so the first run is exactly the readout.
    private func leadingRunEndOnRowTwo(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = PixelProbe.render(host, CGRect(x: origin, y: 50, width: width - origin - 8, height: 22)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin - 8)
        var lastInk = -1, gapRun = 0
        let gap = Int(20 * scale)
        for x in 0..<rep.pixelsWide {
            var on = false
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = PixelProbe.distance(c, background)
                if delta > 0.03 { on = true; break }
            }
            if on { lastInk = x; gapRun = 0 } else if lastInk >= 0 {
                gapRun += 1
                if gapRun >= gap { break }
            }
        }
        return lastInk < 0 ? nil : CGFloat(lastInk) / scale + origin
    }

    @Test("The rename header draws its own short breakdown, not the folder rows' census",
          .machinePinned(.pixelSampling))
    func theRenameHeaderDrawsTheShortBreakdown() throws {
// The call site the pure tally tests can't reach: reverting `renameBacklogSummary` to
// `tally.breakdown` must fail here. Differential, so the headline cancels.
        let width: CGFloat = 1400
        let mixed = Self.manager(queue: 24, names: 17)
        mixed.renamePlans = [Self.renamePlan(named: 7, reshuffled: 6, padded: 628, skips: 2)]
        let padOnly = Self.manager(queue: 24, names: 17)
        padOnly.renamePlans = [Self.renamePlan(padded: 628)]

        let a = RenameBacklogTally(mixed.renamePlans), b = RenameBacklogTally(padOnly.renamePlans)
        #expect(a.headerBreakdown != a.breakdown,
                "the fixture's two forms are identical, so this test cannot tell which one is drawn")
        #expect(b.headerBreakdown == b.breakdown,
                "the control fixture differs between forms too, so it cannot serve as a baseline")

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let ifShort = w(a.headerBreakdown) - w(b.headerBreakdown)
        let ifCensus = w(a.breakdown) - w(b.breakdown)
        #expect(ifCensus - ifShort > 50,
                "the two candidate strings differ by only \(ifCensus - ifShort)pt — too little for the render to distinguish them, so this test would pass either way")

        let endMixed = try #require(leadingRunEndOnRowTwo(mount(mixed, lens: .renames, width: width),
                                                          width: width))
        let endPadOnly = try #require(leadingRunEndOnRowTwo(mount(padOnly, lens: .renames, width: width),
                                                            width: width))
        let drawn = endMixed - endPadOnly
        #expect(abs(drawn - ifShort) < abs(drawn - ifCensus),
                "row 2's readout grew by \(drawn)pt between the two backlogs — \(ifShort) is what the header's own short form predicts and \(ifCensus) is what the folder rows' census predicts, so the header is drawing the census")
    }

    @Test("A finished survey report leaves row 2 alone entirely", .machinePinned(.pixelSampling))
    func theFinishedSurveyReportIsNotOnRowTwo() throws {
// The finished report sits above its menu item (``FolderSurveyNote``), not on row 2, where it
// would shorten to a stub and clip the readout. So the row is identical with and without one.
        let width: CGFloat = 800
        let reported = Self.manager(queue: 24, names: 17, survey: Self.longSurvey,
                                    refine: true, heavyReadout: true)
        let quiet = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        let wholeRow = CGRect(x: 8, y: 48, width: width - 16, height: 26)

        #expect(reported.filingSurveyReport?.summary.isEmpty == false,
                "the fixture is not carrying a survey report at all, so the comparison below would pass on an empty premise")
        #expect(differingPixels(try #require(PixelProbe.render(mount(reported, lens: .toFile, width: width), wholeRow)),
                                try #require(PixelProbe.render(mount(quiet, lens: .toFile, width: width), wholeRow))) == 0,
                "row 2 renders differently once a finished survey report exists — the report is still being drawn there, so it is still renting the row and still the thing that gets truncated")

// The positive control: a running survey stays on row 2, so the same comparison is non-zero.
        let running = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        _ = running.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        #expect(differingPixels(try #require(PixelProbe.render(mount(running, lens: .toFile, width: width), wholeRow)),
                                try #require(PixelProbe.render(mount(quiet, lens: .toFile, width: width), wholeRow))) > 0,
                "a running survey changes nothing on row 2 either — the band is not looking at the row, so the zero above proves nothing about the finished report")
    }

    @Test("The survey note says what the survey found")
    func theSurveyNoteSaysItsNumbers() {
// "Refresh what’s learned" usually changes nothing and would look dead without these numbers.
// Pure, because a `Menu`'s content isn't rendered until opened.
        let note = FolderSurveyNote.text(for: Self.longSurvey)
        #expect(note.contains("12 folders changed"))
        #expect(note.contains("340 documents read"))
        // The standing count of folders with learned content.
        #expect(note.contains("96 folders have learned content"))

        // Two surveys differing only in their first clause must read differently: the stub check,
        // on the string rather than pixels.
        let other = FileSyncManager.FilingSurveyReport(
            foldersChanged: 7, documentsRead: 91, documentsRelocated: 8, documentsDropped: 3,
            documentsUnavailable: 5, foldersLearned: 96, changed: true)
        #expect(FolderSurveyNote.text(for: other) != note)

        // The quiet outcome is the common one and the reason the line exists.
        #expect(FolderSurveyNote.text(for: .none).contains("Everything learned here is up to date."))
        // Singular, because a note that says "1 folders" is a note nobody proof-read.
        let one = FileSyncManager.FilingSurveyReport(
            foldersChanged: 1, documentsRead: 1, documentsRelocated: 0, documentsDropped: 0,
            documentsUnavailable: 0, foldersLearned: 1, changed: true)
        #expect(FolderSurveyNote.text(for: one).contains("1 folder has learned content"))
    }

    @Test("The survey says it is working, on the same row it reports from", .machinePinned(.pixelSampling))
    func theRunningSurveyShowsItsProgressOnRowTwo() throws {
// The in-flight branch of `folderMemoryStatus`: without visible progress the menu item looks
// broken, and the state is transient, so a careless edit could drop it unseen.
        let running = Self.manager(queue: 24, names: 17, refine: true)
        _ = running.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        let idle = Self.manager(queue: 24, names: 17, refine: true)

        let width: CGFloat = 1400
        let busy = try #require(PixelProbe.render(mount(running, lens: .toFile, width: width),
                                                  Self.statusZone(width)))
        let quiet = try #require(PixelProbe.render(mount(idle, lens: .toFile, width: width),
                                                   Self.statusZone(width)))
        #expect(counts(busy).ink > counts(quiet).ink + 200,
                "row 2's status zone painted \(counts(busy).ink) inked pixels while a survey was running and \(counts(quiet).ink) with nothing to say — the in-flight branch is not drawing, so the menu item goes back to looking like it did nothing")

        // And the actions are untouched by a survey in flight; they share this row with it.
        #expect(differingPixels(try #require(PixelProbe.render(mount(running, lens: .toFile, width: width),
                                                               Self.trailingZone(width))),
                                try #require(PixelProbe.render(mount(idle, lens: .toFile, width: width),
                                                               Self.trailingZone(width)))) == 0,
                "the actions render differently while the folder-memory survey is running — the progress line is taking their words")
    }

    @Test("The survey's progress stays inside the filing apparatus", .machinePinned(.pixelSampling))
    func theRunningSurveyDoesNotFollowYouToTheOtherLenses() throws {
// Folder memory belongs to Filing: the line has nothing to say on Duplicates, and would sit where
// its "N of M" goes. Duplicates, not the overview, which reaches it as `.filing` and should show it.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        _ = manager.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        manager.duplicateGroups = Self.duplicatesManager(groups: 3, names: 17).duplicateGroups
        manager.hasFoundDuplicates = true
        let width: CGFloat = 1400

        let onDuplicates = counts(try #require(PixelProbe.render(mount(manager, lens: .duplicates, width: width),
                                                                 Self.statusZone(width)))).ink
        let onToFile = counts(try #require(PixelProbe.render(mount(manager, lens: .toFile, width: width),
                                                             Self.statusZone(width)))).ink
        #expect(onToFile > 200,
                "the progress line painted \(onToFile) inked pixels on To File — the fixture is not producing it, so the comparison below proves nothing")
        #expect(onDuplicates < 20,
                "the folder-memory progress painted \(onDuplicates) inked pixels on Duplicates — it has escaped the filing apparatus and is describing a survey this lens never ran")
    }

    @Test("The survey's progress grows with the app's text size", .machinePinned(.pixelSampling))
    func theRunningSurveyProgressTakesTheAppsTextSize() throws {
// Pins `scaledFont` on the running branch: a plain `.font(.caption)` is identical at 1.0.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        _ = manager.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders in Documents…")
        let width: CGFloat = 1400
        let plain = counts(try #require(PixelProbe.render(mount(manager, lens: .toFile, width: width),
                                                          Self.statusZone(width)))).ink
        let large = counts(try #require(PixelProbe.render(mount(manager, lens: .toFile, width: width,
                                                                scale: FontSize.extraLarge.scale),
                                                          Self.statusZone(width)))).ink
        #expect(plain > 200,
                "the progress line painted \(plain) inked pixels at 1.0× — it is not drawing, so the comparison below is between two blanks")
        #expect(large > plain,
                "the progress line painted \(plain) inked pixels at 1.0× and \(large) at 1.3× — it is not taking the app's text size, so it will sit at 11pt beside a readout that grew")
    }

    @Test("The readout stops giving way to the survey", .machinePinned(.pixelSampling))
    func theReadoutNoLongerCompetesWithTheSurvey() throws {
        // The finished report is gone from the row (`theFinishedSurveyReportIsNotOnRowTwo`), so
        // what is left to ask is whether the one branch still here, a running survey, pushes the
        // numbers beside it.
        let width: CGFloat = 800
        let busy = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        _ = busy.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        let quiet = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        // The readout occupies x 15–324 either way.
        let readout = CGRect(x: 8, y: 50, width: 330, height: 22)

        // Renames is settled at 800.
        #expect(differingPixels(try #require(PixelProbe.render(mount(busy, lens: .renames, width: width), readout)),
                                try #require(PixelProbe.render(mount(quiet, lens: .renames, width: width), readout))) == 0,
                "the Renames readout still moves when a survey runs — R1 did not settle the lens it was reported against")

// To File is settled too, from 1000 up; it has Organize's widest actions with the refine offer.
        #expect(differingPixels(try #require(PixelProbe.render(mount(busy, lens: .toFile, width: 1000), readout)),
                                try #require(PixelProbe.render(mount(quiet, lens: .toFile, width: 1000), readout))) == 0,
                "To File's readout moves when a survey runs even at 1000pt, where the row has room")

// Not settled: To File at 800 with refine and a heavy readout is over-subscribed before the
// survey counts, and `ShrinkableRun` takes the spinner's ~19pt off the readout's tail. Only a
// row-2 width model can remove it, so asserted as a bound.
        let residue = differingPixels(
            try #require(PixelProbe.render(mount(busy, lens: .toFile, width: width), readout)),
            try #require(PixelProbe.render(mount(quiet, lens: .toFile, width: width), readout)))
        #expect(residue < 150,
                "To File's readout gave up \(residue) pixels to a running survey at 800pt, against 66 when this was measured — row 2 is over-subscribed by more than the spinner now, so something has been added to it without a width model to seat it")

// The half that must hold at every width: a destructive button keeps its words. Two bands, because
// ``trailingZone`` over Renames' single Rescan would catch the status text across the divider.
        #expect(differingPixels(try #require(PixelProbe.render(mount(busy, lens: .toFile, width: width),
                                                               Self.trailingZone(width))),
                                try #require(PixelProbe.render(mount(quiet, lens: .toFile, width: width),
                                                               Self.trailingZone(width)))) == 0,
                "To File renders its actions differently while a survey is running — the progress line is taking their words")
// Renames' actions are Rescan alone, beyond everything a survey changes on this lens.
        let renamesActions = CGRect(x: width - 118, y: 48, width: 108, height: 26)
        #expect(differingPixels(try #require(PixelProbe.render(mount(busy, lens: .renames, width: width),
                                                               renamesActions)),
                                try #require(PixelProbe.render(mount(quiet, lens: .renames, width: width),
                                                               renamesActions))) == 0,
                "Renames renders its actions differently while a survey is running — the progress line is taking their words")
        // The band must be over something, or the zero above is about blank card.
        #expect(counts(try #require(PixelProbe.render(mount(quiet, lens: .renames, width: width),
                                                      renamesActions))).ink > 100,
                "the Renames actions band painted almost nothing — it is not over the Rescan button, so the comparison above proves nothing")
    }

    @Test("The shed rung is narrower than the rail it replaces, by enough to be worth having")
    func theShedRungIsAFallbackWorthFallingBackTo() {
        // Asserted in the arithmetic, not a render: row 1 reserves only the search toggle, so the
        // rail sheds below ~668pt of card, and the harness can't get there. `LensWorkspaceView`
        // lays its header out at about 750pt however narrow the canvas, and below that the leading
        // cluster is clipped, not shed, so a render would measure clipping and call it shedding.
        //
        // The claim that matters: the fallback must be much narrower than what it replaces (315pt
        // against 632 measured), or shedding buys nothing. `theShedRuleIsComputed` covers the rule
        // choosing between them.
        let badge = Self.states([.toFile: 24, .duplicates: 410, .renames: 17])
        let shedModel = OrganizeRailMetrics.shedLeadingWidth(scale: 1, state: badge)
        let spelledOut = OrganizeRailMetrics.leadingWidth(scale: 1, state: badge)
        #expect(shedModel < spelledOut - 100,
                "the shed rung models \(shedModel)pt against \(spelledOut)pt spelled out — falling back to it saves too little to be a fallback")
        // And it keeps the badges, which are the reason to look at a shed rail at all.
        let unbadged = OrganizeRailMetrics.shedLeadingWidth(scale: 1, state: Self.states([:]))
        #expect(shedModel > unbadged,
                "the shed rung costs the same with badges as without — it is dropping the counts along with the labels")
    }

    // MARK: The control — Rescan outlives the queue

    @Test("…and is absent before the first scan, where there is nothing to re-scan", .machinePinned(.pixelSampling))
    func rescanIsAbsentBeforeAnyScan() throws {
// The other direction, so Rescan's check in `theActionsBandIsWhereTheActionsAre` can't pass on an
// always-drawn button. On Renames: To File withholds it before a scan for its own reason
// (`theMovedButtonYieldsToTheIntroCard`), so only Renames isolates Rescan's gate.
        let never = try #require(PixelProbe.render(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                                         lens: .renames), Self.actionsZone))
        #expect(counts(never).ink < 20,
                "the action band is inked before any scan has completed — Rescan is ungated")
    }

    // MARK: The control — pointing Organize somewhere new

    @Test("Organize “<folder>” draws before the first scan, on the overview", .machinePinned(.pixelSampling))
    func theMovedButtonDrawsBeforeAnyScan() throws {
// Nothing scanned, the pane in a subfolder, standing on "All", where no intro card carries the
// invitation: the band must not be empty, or Organize can't be aimed from its own header.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root/Family/Daughter")
        let band = try #require(PixelProbe.render(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "the overview's trailing band painted nothing with the pane in a subfolder — there is no way to point Organize at what you are browsing")
    }

    @Test("…and stands down on To File, where the setup card is already asking", .machinePinned(.pixelSampling))
    func theMovedButtonYieldsToTheIntroCard() throws {
// Ungated, the moved branch would put `Organize "Daughter"` beside To File's pre-scan card naming
// the same folder: two invitations, one of which moves the scope.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Daughter")
        let band = try #require(PixelProbe.render(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink < 20,
                "To File drew a header control before its first scan — the setup card below it is already the invitation, naming the same folder")
    }

    @Test("…but still draws on a lens that has no intro card of its own", .machinePinned(.pixelSampling))
    func theMovedButtonSurvivesOnRenames() throws {
        // Stops `filingIntroOwnsInvitation` being written as a bare `!hasSuggestedFiling`. Renames
        // shares To File's apparatus but has no intro card offering to aim Organize at this folder,
        // so standing down here would leave it with no way to aim at all.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: .renames, providerRoot: "/root", scanTarget: "/root/Family/Daughter")
        let band = try #require(PixelProbe.render(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "Renames lost the moved button — the stand-down is keyed on the scan flag rather than on To File")
    }

    @Test("The stand-down has something to stand down for", .machinePinned(.pixelSampling))
    func theToFileIntroIsActuallyOnScreen() throws {
// The premise of `theMovedButtonYieldsToTheIntroCard`: an empty band is also what a vanished
// setup card gives. Compared against the same lens after a clean scan.
        let toFile = try #require(PixelProbe.render(
            mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                  lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Daughter"),
            Self.contentZone))
        let scanned = try #require(PixelProbe.render(
            mount(Self.manager(queue: 0, names: 0, hasScanned: true, scanFolder: nil),
                  lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Daughter"),
            Self.contentZone))
        let (intro, blank) = (counts(toFile).ink, counts(scanned).ink)
        #expect(intro > blank + 500, """
                To File's pre-scan content inked \(intro) against \(blank) once scanned — the \
                setup card the header stands down for is not on screen.
                """)
    }

    @Test("…and does not, when the pane is at the top of the tree", .machinePinned(.pixelSampling))
    func theMovedButtonIsAbsentAtTheProviderRoot() throws {
// A pane at the provider root has moved off nothing, so "Organize everything" would change
// nothing.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root")
        let band = try #require(PixelProbe.render(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink < 20,
                "the overview drew a control with the pane at the provider root — Organize is offering to re-aim at what it is already aimed at")
    }

    @Test("The actions band is over the actions", .machinePinned(.pixelSampling))
    func theActionsBandIsWhereTheActionsAre() throws {
// `actionsZone` is a hard-coded rectangle; off the buttons, `rescanIsAbsentBeforeAnyScan` passes
// for the wrong reason. Pinned against the state with the most controls.
        let full = try #require(PixelProbe.render(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                                  Self.actionsZone))
        let rescanOnly = try #require(PixelProbe.render(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                                        Self.actionsZone))
        #expect(counts(full).ink > counts(rescanOnly).ink + 200,
                "three controls and one control inked this band almost identically — it is not over the actions")
        // Rescan outlives the queue: everything filed, findings still standing, and Rescan must not
        // sit inside the gate that draws "File all".
        #expect(counts(rescanOnly).ink > 100,
                "the action band painted nothing with an empty queue beside 17 risky names — Rescan is gated on the queue again")
    }
}
