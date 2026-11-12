import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's header, in pixels: the rail on row 1, the readout on row 2, and the controls between
/// them.
///
/// The first claim is that a capsule is a control: the clickable row must still look clickable and
/// the prose row must not, measured across the two rows.
///
/// Pixels, because nothing else here is open: the rail items are labels inside `Button`s inside the
/// header card, `fittingSize` can't see them (the lens fills a fixed frame), and a caption
/// assertion passes vacuously with no assistive client attached to the test process. Defects here,
/// such as the rail not drawing on some lenses, pass any suite that doesn't look.
@MainActor
// Machine-pinned per test rather than per suite: the tests that read painted pixels (directly or
// through the ink helpers) carry `.machinePinned(.pixelSampling)`, since only the recording Mac
// gives them a trustworthy verdict; the shedding arithmetic, glyph table, label composition and
// width models are ordinary tests that run everywhere.
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
    /// Row 2's trailing controls, anchored to the right edge so they track at any width.
    ///
    /// 170pt, because on row 2 the controls share the trailing side with the folder-memory caption:
    /// a wider band (300pt reported a flat 222-pixel difference below the caption's floor) catches
    /// the caption appearing and disappearing and reads it as truncation. 170 is inside the
    /// narrowest trailing set this suite measures (Duplicates, 354pt).
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
    ///   - survey: what the last folder-memory re-survey reported, or nil for the ordinary state
    ///     where none has run this session.
    ///   - refine: whether the refine offer is showing. It needs more than the classifier:
    ///     `canRefineFilingSuggestions` also wants the cached taxonomy and the provider root, and a
    ///     fixture without them draws no button and would report that the row fits.
    ///   - scanFolder: the root the filing list was walked from, or nil for a manager that has
    ///     never scanned. `hasScanned: false` alone does not give that state: it clears the
    ///     completion flag but leaves a scanned root, a pane on its own subject rather than an
    ///     Organize with no subject. The two differ in exactly the button this suite measures.
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

    /// Mounts Organize with a named rail selection.
    ///
    /// The selection goes through the defaults the view reads, where `LensWorkspaceView` keeps it.
    /// With the key unset the rail resolves to `nil`, the overview, where no lens's actions are
    /// drawn, so every action-band comparison would measure nothing. The innermost
    /// `defaultAppStorage` wins.
    ///
    /// `scale` is the app's text-size multiplier (`FontSize.scale`), defaulting to 1; it is a real
    /// parameter because the width model claims to be right at every size while only some of its
    /// parts scale.
    ///
    /// `providerRoot` and `scanTarget` decide whether the pane has wandered off what Organize is
    /// answering about (``OrganizeAim``). The defaults keep the target equal to the scanned root,
    /// so no fixture draws the moved button by accident; the two tests about that button set them
    /// apart.
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
        // Both callbacks are supplied because both gate a control this suite measures: the Rescan
        // menu’s "Refresh what’s learned" item, and the "Refine with Claude…" invitation, which is
        // withheld outright when there is no Settings to open.
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: scanTarget, onFindDuplicates: {},
                               onUpdateFolderMemory: {}, onConfigureCloudRefine: {},
                               providerRoot: providerRoot)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        // Twice: `.onGeometryChange` writes `railStyle` after a pass.
        return ReviewLensHost.mount(subject, size: canvas, passes: 2).host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels split by how far they are from the band's own background corner.
    ///
    /// The largest per-channel departure of `c` from `background`.
    private static func delta(_ c: NSColor, _ background: NSColor) -> CGFloat {
        max(abs(c.redComponent - background.redComponent),
            max(abs(c.greenComponent - background.greenComponent),
                abs(c.blueComponent - background.blueComponent)))
    }

    /// `wash` separates a capsule from a run of text: a tinted capsule covers its whole area in a
    /// low-opacity fill, a large soft departure from the background, while text is a small area of
    /// near-black `ink` with a thin antialiased fringe. A row of capsules reads dense in `wash`;
    /// the same words without them read nearly empty of it.
    ///
    /// Not a brightness filter: `brightness < 0.90` counts the dark text inside a capsule and none
    /// of the pale wash behind it, which is backwards for this question.
    private func counts(_ rep: NSBitmapImageRep) -> (wash: Int, ink: Int) {
        guard let background = rep.colorAt(x: 2, y: 2) else { return (0, 0) }
        var wash = 0, ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
                if delta > 0.35 { ink += 1 } else if delta > 0.03 { wash += 1 }
            }
        }
        return (wash, ink)
    }

    /// `wash` per point of band width, so bands of different widths compare directly.
    private func washDensity(_ rep: NSBitmapImageRep, width: CGFloat) -> Double {
        Double(counts(rep).wash) / Double(width)
    }

    /// Accent-tinted wash pixels: the capsule fill rather than its ring.
    ///
    /// `accentEdge` excludes the wash (its 0.30 floor sits above a 22% fill) because it asks about
    /// the ring; this asks the opposite. A reporting item is washed in the accent and a clean one
    /// in a neutral, so the difference is a hue at low delta: blue must lead red, and the delta
    /// must be small enough to be a wash and large enough not to be the background.
    private func accentWash(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
                if delta > 0.02 && (c.blueComponent - c.redComponent) > 0.05 { n += 1 }
            }
        }
        return n
    }

    /// Strong, blue-dominant pixels: the ring, told apart from the fill behind it.
    ///
    /// The selected item encodes selection twice: a 2pt full-opacity `accent` stroke, and a fill
    /// deepened from 14% to 22%. A diff between two selections moves whether or not the ring draws,
    /// so it measures the fill. A 22% wash sits at delta ≈ 0.22, below the 0.30 floor; text is
    /// near-neutral, so requiring blue to lead red by 0.18 excludes it too. Measured: 2,476 such
    /// pixels with the ring, 632 without it, 402 on an unringed rail.
    private func accentEdge(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
                if delta > 0.30 && (c.blueComponent - c.redComponent) > 0.18 { n += 1 }
            }
        }
        return n
    }

    /// The x-extent of row 1's leading cluster (the rail plus the intro button), read off the
    /// render so the width model can be held to something other than itself.
    ///
    /// A 30pt run of background ends the cluster: inside it the widest gap is the 9.5pt before the
    /// intro button, while the reach across to the trailing controls is hundreds of points.
    ///
    /// The band starts at x 8, not 0, like `railZone`: the card's 1pt border at x≈2.5 is only 11pt
    /// clear of the first rail item, so a band including it merges the border into the cluster and
    /// reports the card's padding as rail width. Dropping short runs can't help once it has merged.
    private func leadingExtent(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = strip(host, CGRect(x: origin, y: 12, width: width - origin, height: 30)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin)
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
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

    /// The width from the first inked run to the last in a band: the span every control on this
    /// side of the row occupies together.
    ///
    /// The 0.10 threshold and the split into runs are because the card's glass carries a gradient:
    /// at 0.03 the far end of a wide band differs from the near end and the whole band reads as
    /// inked. First-to-last, not the last run alone: the rightmost run is the search toggle either
    /// way, so the last run would miss lens actions moved back onto row 1.
    private func trailingSpan(_ rep: NSBitmapImageRep, bandWidth: CGFloat) -> CGFloat? {
        guard let background = rep.colorAt(x: rep.pixelsWide - 3, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / bandWidth
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
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
        let rail = try #require(strip(host, Self.railZone))
        let readout = try #require(strip(host, Self.readoutZone))

        // Staleness guard first, which makes the claim mean anything: a band that drifted off its
        // row paints nothing, and nothing satisfies "no capsule" trivially. The readout must be
        // full of text while empty of wash, which is true only of words drawn without a capsule
        // behind them.
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

        let mixed = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                       Self.readoutZone))
        let clean = try #require(strip(mount(allConfident, lens: .toFile), Self.readoutZone))
        #expect(counts(mixed).ink != counts(clean).ink,
                "the readout painted the same thing for 24 ready and for 16 ready with 8 unsure — it is not reading the scan")
    }

    // MARK: The rail is on screen, and it is the rail

    @Test("Every rail item reaches the screen", .machinePinned(.pixelSampling))
    func theRailPaints() throws {
        let rail = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        // The rail's capsules and labels. A bare threshold would pass on one item, so this is
        // paired with the per-item probe below.
        #expect(counts(rail).ink > 600, "row 1 is nearly empty — the rail is not drawing")
    }

    @Test("The rail draws on a lens whose apparatus is not the filing one", .machinePinned(.pixelSampling))
    func theRailSurvivesTheApparatusSwitch() throws {
        // The rail must sit outside the summary arm only the filing apparatus reaches, or standing
        // on Duplicates or Rules would draw that lens's own pills and no rail. Rules borrows
        // `.automations`' apparatus, the furthest from filing's, so it is the strongest case.
        let onFiling = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onRules = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .rules),
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
        // An `.overlay` that never draws is invisible to every geometry assertion, so the ring must
        // be measured in pixels, and as the ring: deleting the stroke leaves the deepened fill,
        // which still moves a whole-band diff. `accentEdge` separates them (about 2,500 with the
        // ring, 630 without).
        let ringed = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
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
        let onToFile = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onRenames = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .renames),
                                           Self.railZone))
        #expect(accentEdge(onRenames) > 1500, "the Renames selection drew no ring")
        #expect(differingPixels(onToFile, onRenames) > 200,
                "selecting a different rail item changed almost nothing — the ring is pinned to one item")
    }

    @Test("The overview rings its own item, and no lens", .machinePinned(.pixelSampling))
    func theOverviewRingsAll() throws {
        // The overview has a place of its own, "All" at the head of the rail, and it is ringed when
        // `railLens` is nil: the overview renders, and clicking the selected lens again comes back
        // here.
        let overview = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil),
                                          Self.railZone))
        let selected = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
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
        let overviewAll = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil), allItem))
        let toFileAll = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile), allItem))
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
        let none = try #require(strip(mount(Self.manager(queue: 24, names: 0), lens: .toFile),
                                      Self.railZone))
        let some = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
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
        let three = try #require(strip(mount(Self.manager(queue: 24, names: 3), lens: .toFile),
                                       Self.railZone))
        let seventeen = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
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
        let a = try #require(strip(mount(withFindings, lens: .toFile), whole))
        let b = try #require(strip(mount(none, lens: .toFile), whole))
        #expect(differingPixels(a, b) > 50,
                "a tree with a divergent family painted the same rail as one with none — the badge is not reading the detector")
        #expect(counts(a).ink > counts(b).ink,
                "the badge added no ink — restructure is still reporting a hard-coded zero")
    }

    // MARK: Shedding — the rail yields width to the controls

    @Test("At 900pt the rail spells itself out, and the controls are on row 2", .machinePinned(.pixelSampling))
    func theRailKeepsItsNamesAtNineHundred() throws {
        // With the controls on row 2, row 1 reserves only the search toggle, so 900 is comfortably
        // above the shed threshold and the rail spells its names out. At both widths the ink is
        // within a few per cent; a shed 900pt render inks less than half the 1400pt one, which the
        // assertion catches if row 1 picks up a tenant again.
        let wide = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        let atNineHundred = try #require(strip(mount(Self.manager(queue: 24, names: 17),
                                                     lens: .toFile, width: 900),
                                               Self.railZone))
        #expect(counts(atNineHundred).ink > counts(wide).ink * 3 / 4,
                "at 900pt the rail inked \(counts(atNineHundred).ink) against \(counts(wide).ink) at 1400 — it is shedding its labels again, so row 1 has picked up a tenant the reserve does not know about")

        // And row 1's trailing half is empty, bar the search toggle `LensHeaderCard` appends
        // itself. Measured to the left of that toggle, which draws in every state and would make
        // this band non-empty whatever the actions did.
        let host = mount(Self.manager(queue: 24, names: 17, refine: true), lens: .toFile, width: 1400)
        let rowOneTrailing = try #require(strip(host, CGRect(x: 1000, y: 12, width: 330, height: 30)))
        #expect(counts(rowOneTrailing).ink < 200,
                "row 1's trailing band inked \(counts(rowOneTrailing).ink) — a control is still drawing up there, and the reserve is sized for none")
        // …and they are drawing on row 2, or the assertion above passes by the actions having
        // vanished.
        let rowTwoTrailing = try #require(strip(host, Self.trailingZone(1400)))
        #expect(counts(rowTwoTrailing).ink > 400,
                "row 2's trailing band inked \(counts(rowTwoTrailing).ink) — the controls did not arrive where they were moved to")
    }

    // MARK: The three states — reporting, clean, never looked

    @Test("A lens with findings is tinted; one that ran and found nothing is not", .machinePinned(.pixelSampling))
    func theTintSaysHasWorkNotIsClickable() throws {
        // The wash means "this has work", not "this is a control": a capsule still says clickable,
        // but the colour goes only to lenses with findings, or the row reads as identical capsules
        // with a small badge as the only signal. Measured over Duplicates' own item, with the same
        // scan having run either way; the only difference is whether it found anything.
        let reporting = Self.duplicatesManager(groups: 12, names: 0)
        let clean = Self.duplicatesManager(groups: 0, names: 0)
        // The rail runs All | To File · Duplicates · …, so Duplicates' item sits second among the
        // lenses. A 150pt band from x 150 holds it at this canvas and neither neighbour.
        let band = CGRect(x: 150, y: 12, width: 150, height: 30)
        let hot = try #require(strip(mount(reporting, lens: .toFile), band))
        let cold = try #require(strip(mount(clean, lens: .toFile), band))
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
        // The test above asserts what `accessibilityLabel(title:state:)` returns; this pins that
        // the view calls it. Removing the `.accessibilityLabel(…)` from `RailItemLabel`'s body must
        // fail here.
        //
        // A source scan, because a live one isn't available: SwiftUI publishes no accessibility
        // tree to an `NSHostingView` with no assistive client attached (`accessibilityChildren()`
        // returns an empty `AXGroup`), so an assertion against it would pass with the modifier
        // deleted. A scan pins a spelling, not a behaviour, but it fails on the one edit that
        // matters.
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

    /// The width the rail gets is the column's, not the window's.
    ///
    /// `theShedRuleIsComputed` feeds `style(contentWidth:)` window-sized numbers. Organize's header
    /// card lives in the workspace half of `singleSourceLayout`, beside a source pane draggable
    /// from 220pt up, so a 900pt window hands this row somewhere near 500, below the threshold.
    ///
    /// So this asks the same rule in the units a caller can supply. At the default text size with
    /// two findings reporting, labels need a 623pt column, which an 810pt window can't give while
    /// the source pane holds its 220pt floor (590). Organize is a glyph rail at the narrowest
    /// window, like the workspace bar, and its tooltips are why that rung exists.
    @Test("The column, not the window, is what the rail has to fit")
    func theShedRuleIsAskedInColumnWidths() {
        let twoBadges = Self.states([.toFile: 24, .renames: 17])
        let leading = OrganizeRailMetrics.leadingWidth(scale: 1, state: twoBadges)

        // The card's own inset and padding are charged: the difference between the two entry
        // points. Asserted as a consequence, not as
        // `style(columnWidth: w) == style(contentWidth: w - cardChrome)`, which restates the body
        // and agrees with itself whatever either side does.
        // What can fail: a column holding exactly the rail and the toggle is still too narrow,
        // because the card spends 29 of it before the row starts.
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

    /// A rail item has to fit the row, because the row's horizontal `ScrollView` in `lensTitle`
    /// clips it: an over-tall item would have a badge or the selected capsule cut off top and
    /// bottom.
    ///
    /// Measured 20 / 22 / 25 / 26pt against `LensHeaderMetrics.tabRow`'s 27, so the margin at the
    /// largest text size is one point. Anything that adds vertical padding to `RailItemLabel` fails
    /// here first.
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

    @Test("A wider badge costs more than a narrower one")
    func theBadgeIsMeasuredByItsDigits() {
        // `410` is not `24`: a flat two-digit figure per badge would under-charge a three-digit
        // count by about 8pt a badge and let the row truncate while the arithmetic reports room.
        #expect(OrganizeRailMetrics.badgeWidth(410, scale: 1)
                > OrganizeRailMetrics.badgeWidth(24, scale: 1))
        #expect(OrganizeRailMetrics.leadingWidth(scale: 1,
                                                 state: Self.states([.duplicates: 410]))
                > OrganizeRailMetrics.leadingWidth(scale: 1,
                                                   state: Self.states([.duplicates: 24])))
    }

    @Test("The leading model matches what row 1 draws at every text size the app ships", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theLeadingModelMatchesWhatTheRowDraws(size: FontSize) throws {
        // Measures the leading cluster off the render and holds the model to it: comparing the
        // model with itself would let an estimate fall short of the row and stay self-consistent.
        // It is also the only assertion that catches a control added beside the rail and left out
        // of the model.
        //
        // Every text size, because the model is a mixture: labels and badges measured at
        // `11.5 * scale`, glyphs a linearly scaled table, paddings and gaps flat. A `glyphWidth`
        // that ignores `scale` passes at 0.9, 1.0 and 1.15 and fails only at `.extraLarge`, so a
        // single-scale test misses it.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        let host = mount(manager, lens: .duplicates, width: 1400, scale: size.scale)
        let drawn = try #require(leadingExtent(host, width: 1400),
                                 "row 1 drew no leading cluster at \(size.scale)× — the rail is not on screen at all")
        // The risky names ride the Renames badge (Names is folded into Renames), so the model is
        // fed what the rail draws.
        let model = OrganizeRailMetrics.leadingWidth(
            scale: size.scale,
            state: Self.states([.toFile: 24, .duplicates: 410, .renames: 17]))

        // Over, never under: a model that under-states the leading side lets the row overrun, this
        // type's failure mode. Measured model against drawn, with labels on `LabelMetrics` (which
        // applies SwiftUI's half-point ceiling to a text run): slack 6.8 / 5.0 / 10.25 / 8.95pt at
        // 0.9 / 1.0 / 1.15 / 1.3, with `overviewMargin` at 6.
        #expect(model >= drawn,
                "at \(size.scale)× the rail draws \(drawn)pt but the model budgets \(model)pt — it is \(drawn - model)pt short, so the row will overrun before it sheds")
        // And not wildly over, or the rail sheds its labels on headers that would have seated them.
        // The widest measured slack is at the large sizes, where the glyph table's linear scaling
        // is furthest from the renderer.
        #expect(model - drawn < 12,
                "at \(size.scale)× the model budgets \(model)pt for a leading side that draws \(drawn)pt — \(model - drawn)pt of slack sheds the labels early")
    }

    @Test("The divider never draws against nothing", .machinePinned(.pixelSampling))
    func theRowTwoDividerIsPairedWithItsControls() throws {
        // `hasRowTwoActions` is a hand-written copy of `lensActions`'s gates (a `@ViewBuilder`
        // can't be asked whether it produced anything), and if the two disagree a hairline floats
        // against an empty band. Asserted at the two states that differ, on a band narrow enough
        // that a 1pt rule is a large share of it; a wide band would drown the divider in the
        // readout beside it.
        let edge = { (w: CGFloat) in CGRect(x: w - 60, y: 48, width: 52, height: 26) }
        let width: CGFloat = 1400

        // Before any scan: no controls, and therefore no rule.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .toFile, width: width), edge(width)))
        // Wash, not ink: the divider is a 1pt `.quaternary` rule that registers about 56 wash
        // pixels and zero ink, so only the faint-fill measure can see it.
        #expect(counts(never).wash < 20,
                "row 2's trailing edge washed \(counts(never).wash) before any scan — the divider is drawing with no controls beside it")

        // After one: controls, and the rule that separates them from the prose.
        let scanned = try #require(strip(mount(Self.manager(queue: 24, names: 17),
                                               lens: .toFile, width: width), edge(width)))
        #expect(counts(scanned).ink > 100,
                "row 2's trailing edge inked \(counts(scanned).ink) with a finished scan — the controls are not drawing where the divider says they are")
    }

    @Test("A stale readout leaves the row empty — it does not borrow the overview's", .machinePinned(.pixelSampling))
    func aStaleLensDoesNotBorrowTheOverviewsReadout() throws {
        // The `else` of a compound condition catches both arms:
        // `if let organizeLens, !stale { … } else { overviewSummary }` would draw the overview's
        // readout ("1 reporting · 2 clean") under a selected lens whose list the filing scan
        // republishes, mid-scan. Suppressing a stale readout must leave the row empty; a different
        // answer is worse than the staleness.
        let scanning = Self.manager(queue: 24, names: 17)
        scanning.isSuggestingFiles = true
        let onToFile = try #require(strip(mount(scanning, lens: .toFile), Self.readoutZone))

        // The overview at the same moment does draw its readout: the non-vacuity half. Without it,
        // "the band is empty" would pass just as well with `overviewSummary` deleted.
        let onOverview = try #require(strip(mount(scanning, lens: nil), Self.readoutZone))
        #expect(counts(onOverview).ink > 200,
                "the overview drew no readout while a scan was running — this comparison proves nothing")
        #expect(counts(onToFile).ink < counts(onOverview).ink / 2,
                "a selected lens inked \(counts(onToFile).ink) against the overview's \(counts(onOverview).ink) while its own scan was running — it is drawing the overview's readout instead of leaving the row empty")
    }

    @Test("Row 1's reserve seats what row 1 actually draws, at every text size", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theRowOneReserveSeatsWhatRowOneDraws(size: FontSize) throws {
        // Holds `searchToggleWidth` to the render. It measures everything row 1 draws to the right
        // of the rail, which should be only the search toggle `LensHeaderCard` appends, and the
        // reserve must cover it with the refine offer showing and a survey report in hand, the
        // state with the most to draw.
        let manager = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        let width: CGFloat = 1400
        let host = mount(manager, lens: .toFile, width: width, scale: size.scale)

        // The band runs from the rail's end to the card's right edge, with the rail's extent read
        // off the render, so the trailing side is measured relative to what is drawn rather than a
        // hard-coded x.
        let railEnd = try #require(leadingExtent(host, width: width),
                                   "row 1 drew no leading cluster at \(size.scale)× — nothing to measure from")
        let band = CGRect(x: railEnd + 8, y: 12, width: width - railEnd - 16, height: 30)
        let rep = try #require(strip(host, band))

        // Measured as the inked extent, not an ink count: the question is how much width the
        // trailing side consumes, and a wide sparse control inks like a narrow dense one.
        let drawn = try #require(trailingSpan(rep, bandWidth: band.width),
                                 "row 1's trailing side drew nothing at \(size.scale)× — the search toggle is gone, and this reserve is protecting a control that no longer exists")
        #expect(drawn <= OrganizeRailMetrics.searchToggleWidth,
                "row 1's trailing side draws \(drawn)pt at \(size.scale)× against a reserve of \(OrganizeRailMetrics.searchToggleWidth) — a control has been put back up here and the rail is not being charged for it")
    }

    @Test("The glyph table still matches the renderer", .machinePinned(.layoutMetrics))
    func theGlyphTableMatchesTheRenderer() throws {
        // ``OrganizeRailMetrics/glyphWidth(_:scale:)`` is tabulated because measuring costs ~812µs
        // for the six and the caller runs per `body`; this stops the table rotting silently. A
        // glyph is not its point size: `folder.badge.gearshape` is 17pt wide at 10.5pt.
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
        // The invariant: once the rail is spelled out, the actions must still be seated,
        // untruncated. A threshold band where the model says the labels fit and the row disagrees
        // would draw `Apply 410 recomme…` while the arithmetic tests pass.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        // Swept from 900, not from the rail's own flip point: row 1 spells the rail out from
        // ~633pt, while row 2 needs ~800 for this lens, so sweeping from the rail's threshold would
        // assert something row 2 can't deliver. 900 is the narrowest card an ordinary window
        // produces.
        let threshold: CGFloat = 900

        // Right-anchored: the trailing set is right-aligned and fixed-size, so at every width that
        // seats it these bands are pixel-identical. Narrow (see `trailingZone`), because a band
        // reaching back past the actions catches other row-2 content and reads its motion as
        // truncation.
        let roomy = mount(manager, lens: .duplicates, width: 2400)
        let reference = try #require(strip(roomy, Self.trailingZone(2400)))

        // A band of widths, not one point: a reserve a few points short puts the truncation just
        // above the flip, and a single probe would step over it.
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .duplicates, width: width)
            // The rail is spelled out here; otherwise "not truncated" is satisfied by the shed
            // state, which fits trivially.
            #expect(counts(try #require(strip(host, Self.railZone))).ink > 600,
                    "at \(width)pt the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(strip(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt — \(offset)pt above the width the model starts spelling the rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    @Test("To File seats its own actions at the width it starts spelling the rail out, at every text size", .machinePinned(.pixelSampling),
          arguments: FontSize.allCases)
    func theToFileThresholdSeatsItsOwnActions(size: FontSize) throws {
        // The same invariant on To File, whose trailing set is wider than Duplicates' once the
        // refine offer is showing (Rescan, `Refine with Claude…`, `File all N confident`, search).
        // `survey` is nil here, so the folder-memory caption is not involved.
        //
        // Every text size: the trailing controls are AppKit's and don't follow `appFontScale`
        // (measured 435.5 to 441.5pt across the four sizes), but nothing enforces that; give one
        // `scaledFont` and the row would start truncating at 1.3 alone, the scale this sweep adds.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        // From 900 for the reason the test above gives: rows 1 and 2 shed at different widths, and
        // 900 is where real windows start.
        let threshold: CGFloat = 900

        // The reference is taken at the same scale: the question is whether a header at this width
        // renders its actions like a roomy one, and a 1× reference would answer a different
        // question at every other size.
        let reference = try #require(strip(mount(manager, lens: .toFile, width: 2400, scale: size.scale),
                                           Self.trailingZone(2400)))
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .toFile, width: width, scale: size.scale)
            // Scaled with the text, because the rail's ink is: the flat 600 that suits 1.0 is a
            // near-miss at 0.9, where the same spelled-out items paint less of everything.
            let floor = 600 * size.scale * size.scale
            #expect(Double(counts(try #require(strip(host, Self.railZone))).ink) > floor,
                    "at \(width)pt and \(size.scale)× the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(strip(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt and \(size.scale)× — \(offset)pt above the width the model starts spelling To File's rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    // MARK: The folder-memory report is prose, and prose is not on row 1

    /// The survey sentence's band on row 2, kept clear of the readout on one side and the controls
    /// on the other, so it is about the sentence and nothing else.
    ///
    /// The lens's controls occupy the rightmost ~455pt of this row (To File's set with the refine
    /// offer, plus "N of M" and the divider), so a band anchored near the right edge reports the
    /// actions' ink. This band is 190pt wide and ends 470pt short of the edge, a slice of the
    /// sentence (worst case 485pt) where nothing else reaches. On the 1400pt canvas that is x
    /// 740–930, clear of the controls and of the leading summary, which on Duplicates runs to
    /// x≈720.
    private static func statusZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 660, y: 48, width: 190, height: 26)
    }
    /// A rename backlog whose header form and folder-row form differ as much as they can.
    ///
    /// `named` and `reshuffled` both non-zero so the header collects them; `skips` non-zero so the
    /// header drops them. Totals chosen to keep the headline the same width in both fixtures below:
    /// 641 and 628 are both three digits, and the headline is `.monospacedDigit()`, so the
    /// difference between the two renders is the breakdown and nothing else.
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
        guard let rep = strip(host, CGRect(x: origin, y: 50, width: width - origin - 8, height: 22)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin - 8)
        var lastInk = -1, gapRun = 0
        let gap = Int(20 * scale)
        for x in 0..<rep.pixelsWide {
            var on = false
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = Self.delta(c, background)
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
        // The call site, which the pure tally tests can't reach: `headerBreakdown` is asserted in
        // `RenameBacklogTallyTests`, and those pass with `renameBacklogSummary` reverted to
        // `tally.breakdown`. Reverting the call site must fail this test.
        //
        // Differential, so the headline cancels: two fixtures whose only difference is the
        // breakdown are rendered, and the difference between the renders is compared against the
        // difference between the two candidate strings. The headline is three monospaced digits in
        // both.
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
        // The finished survey report sits above the menu item it reports on (``FolderSurveyNote``),
        // not on row 2, where as the row's widest and only compressible tenant it would shorten to
        // a stub and then clip the readout beside a destructive button. So every pixel of the row
        // must be identical with and without one, at 800pt with a heavy readout, where the row is
        // tight.
        let width: CGFloat = 800
        let reported = Self.manager(queue: 24, names: 17, survey: Self.longSurvey,
                                    refine: true, heavyReadout: true)
        let quiet = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        let wholeRow = CGRect(x: 8, y: 48, width: width - 16, height: 26)

        #expect(reported.filingSurveyReport?.summary.isEmpty == false,
                "the fixture is not carrying a survey report at all, so the comparison below would pass on an empty premise")
        #expect(differingPixels(try #require(strip(mount(reported, lens: .toFile, width: width), wholeRow)),
                                try #require(strip(mount(quiet, lens: .toFile, width: width), wholeRow))) == 0,
                "row 2 renders differently once a finished survey report exists — the report is still being drawn there, so it is still renting the row and still the thing that gets truncated")

        // The positive control: "no difference" is also what a misplaced band or a blank row
        // reports. A running survey stays on row 2, so the same comparison against it must come
        // back non-zero.
        let running = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)
        _ = running.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        #expect(differingPixels(try #require(strip(mount(running, lens: .toFile, width: width), wholeRow)),
                                try #require(strip(mount(quiet, lens: .toFile, width: width), wholeRow))) > 0,
                "a running survey changes nothing on row 2 either — the band is not looking at the row, so the zero above proves nothing about the finished report")
    }

    @Test("The survey note says what the survey found")
    func theSurveyNoteSaysItsNumbers() {
        // The meaning moved with the pixels: "Refresh what’s learned" usually changes nothing and
        // would look like a dead menu item without this sentence's numbers. Pure, because a
        // `Menu`'s content isn't rendered until opened, and a mounted-header test could only read
        // source text.
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
        // `folderMemoryStatus` has two branches; this is the in-flight one. The menu item reads a
        // few folder mtimes and usually writes nothing, so without visible progress it looks
        // broken, and the state is transient, so a careless edit could drop it unseen.
        let running = Self.manager(queue: 24, names: 17, refine: true)
        _ = running.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        let idle = Self.manager(queue: 24, names: 17, refine: true)

        let width: CGFloat = 1400
        let busy = try #require(strip(mount(running, lens: .toFile, width: width),
                                      Self.statusZone(width)))
        let quiet = try #require(strip(mount(idle, lens: .toFile, width: width),
                                       Self.statusZone(width)))
        #expect(counts(busy).ink > counts(quiet).ink + 200,
                "row 2's status zone painted \(counts(busy).ink) inked pixels while a survey was running and \(counts(quiet).ink) with nothing to say — the in-flight branch is not drawing, so the menu item goes back to looking like it did nothing")

        // And the actions are untouched by a survey in flight; they share this row with it.
        #expect(differingPixels(try #require(strip(mount(running, lens: .toFile, width: width),
                                                   Self.trailingZone(width))),
                                try #require(strip(mount(idle, lens: .toFile, width: width),
                                                   Self.trailingZone(width)))) == 0,
                "the actions render differently while the folder-memory survey is running — the progress line is taking their words")
    }

    @Test("The survey's progress stays inside the filing apparatus", .machinePinned(.pixelSampling))
    func theRunningSurveyDoesNotFollowYouToTheOtherLenses() throws {
        // The gate is hand-written on row 2, the kind of condition that gets "simplified" later.
        // Folder memory belongs to Filing: a line about documents read has nothing to say on
        // Duplicates, and it would sit where that lens's own "N of M" goes. The finished report
        // can't escape to another lens because it is on no lens's row
        // (`theFinishedSurveyReportIsNotOnRowTwo`).
        //
        // Duplicates rather than the overview: the overview reaches `lensTrailing` with
        // `effectiveLens == .filing` and should show it.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        _ = manager.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        manager.duplicateGroups = Self.duplicatesManager(groups: 3, names: 17).duplicateGroups
        manager.hasFoundDuplicates = true
        let width: CGFloat = 1400

        let onDuplicates = counts(try #require(strip(mount(manager, lens: .duplicates, width: width),
                                                     Self.statusZone(width)))).ink
        let onToFile = counts(try #require(strip(mount(manager, lens: .toFile, width: width),
                                                 Self.statusZone(width)))).ink
        #expect(onToFile > 200,
                "the progress line painted \(onToFile) inked pixels on To File — the fixture is not producing it, so the comparison below proves nothing")
        #expect(onDuplicates < 20,
                "the folder-memory progress painted \(onDuplicates) inked pixels on Duplicates — it has escaped the filing apparatus and is describing a survey this lens never ran")
    }

    @Test("The survey's progress grows with the app's text size", .machinePinned(.pixelSampling))
    func theRunningSurveyProgressTakesTheAppsTextSize() throws {
        // Pins `scaledFont` on the running branch: a plain `.font(.caption)` changes no pixel any
        // other test here looks at, since they render at 1.0, where the two are identical. At the
        // top of the range it shows as the readout and "N of M" growing while the sentence beside
        // them stays put.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        _ = manager.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders in Documents…")
        let width: CGFloat = 1400
        let plain = counts(try #require(strip(mount(manager, lens: .toFile, width: width),
                                              Self.statusZone(width)))).ink
        let large = counts(try #require(strip(mount(manager, lens: .toFile, width: width,
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
        #expect(differingPixels(try #require(strip(mount(busy, lens: .renames, width: width), readout)),
                                try #require(strip(mount(quiet, lens: .renames, width: width), readout))) == 0,
                "the Renames readout still moves when a survey runs — R1 did not settle the lens it was reported against")

        // To File is settled too, from 1000 up. Its actions are Organize's widest set with the
        // refine offer showing (436.5–468pt against Renames' 240), so it has the least room left on
        // this row.
        #expect(differingPixels(try #require(strip(mount(busy, lens: .toFile, width: 1000), readout)),
                                try #require(strip(mount(quiet, lens: .toFile, width: 1000), readout))) == 0,
                "To File's readout moves when a survey runs even at 1000pt, where the row has room")

        // The one case not settled, recorded rather than hidden: To File at 800 with the refine
        // offer and a heavy readout is over-subscribed on row 2 before the survey counts (309pt of
        // pills plus ~468 of actions plus gaps exceed the card's 776pt). A running survey adds the
        // ~19pt the spinner can't yield, and `ShrinkableRun` takes it off the readout's tail (66
        // pixels when measured). Only a measured row-2 width model can remove it. Asserted as a
        // bound, not zero: pinning the number would freeze a defect, and asserting nothing would
        // let it grow back to a clipped sentence.
        let residue = differingPixels(
            try #require(strip(mount(busy, lens: .toFile, width: width), readout)),
            try #require(strip(mount(quiet, lens: .toFile, width: width), readout)))
        #expect(residue < 150,
                "To File's readout gave up \(residue) pixels to a running survey at 800pt, against 66 when this was measured — row 2 is over-subscribed by more than the spinner now, so something has been added to it without a width model to seat it")

        // The half that must hold at every width: a destructive button keeps its words.
        //
        // Two bands, because one doesn't fit both lenses. ``trailingZone`` is 170pt, which covers
        // To File's actions (refine + file-all) but is wider than Renames' single Rescan, where it
        // would also catch the tail of the status text across the divider and report a correct
        // layout as changed.
        #expect(differingPixels(try #require(strip(mount(busy, lens: .toFile, width: width),
                                                   Self.trailingZone(width))),
                                try #require(strip(mount(quiet, lens: .toFile, width: width),
                                                   Self.trailingZone(width)))) == 0,
                "To File renders its actions differently while a survey is running — the progress line is taking their words")
        // Renames' actions are Rescan alone, 109pt against the card's trailing edge, so the band is
        // 108 at x = width − 118, measured: what a survey changes on this lens spans x 534…672 (the
        // status), and Rescan sits entirely beyond it. The button does not move, which is the
        // claim.
        let renamesActions = CGRect(x: width - 118, y: 48, width: 108, height: 26)
        #expect(differingPixels(try #require(strip(mount(busy, lens: .renames, width: width),
                                                   renamesActions)),
                                try #require(strip(mount(quiet, lens: .renames, width: width),
                                                   renamesActions))) == 0,
                "Renames renders its actions differently while a survey is running — the progress line is taking their words")
        // The band must be over something, or the zero above is about blank card.
        #expect(counts(try #require(strip(mount(quiet, lens: .renames, width: width),
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
        // The other direction, which stops Rescan's check in `theActionsBandIsWhereTheActionsAre`
        // being satisfied by a button that is always drawn. The pane is on its subject (`scanFolder` and `scanTarget` are the same
        // folder), so this measures Rescan rather than the moved branch.
        //
        // On Renames, not To File: To File also withholds this control before its first scan
        // because its setup card owns the invitation (`theMovedButtonYieldsToTheIntroCard`), so a
        // `.toFile` fixture would pass whether or not Rescan's own gate survived. Renames reaches
        // the same gate with no intro to stand down for, so an empty band there is Rescan's gate
        // and nothing else.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .renames), Self.actionsZone))
        #expect(counts(never).ink < 20,
                "the action band is inked before any scan has completed — Rescan is ungated")
    }

    // MARK: The control — pointing Organize somewhere new

    @Test("Organize “<folder>” draws before the first scan, on the overview", .machinePinned(.pixelSampling))
    func theMovedButtonDrawsBeforeAnyScan() throws {
        // Nothing scanned, no scope, the pane browsed into a subfolder, standing on "All", where
        // the app lands and no lens's intro card carries the invitation. The band must not be
        // empty, or there is no way to aim Organize from its own header without having aimed it
        // first. On the overview because `hasRowTwoActions` gates the whole trailing group, and its
        // `.none` arm is the case.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root/Family/Daughter")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "the overview's trailing band painted nothing with the pane in a subfolder — there is no way to point Organize at what you are browsing")
    }

    @Test("…and stands down on To File, where the setup card is already asking", .machinePinned(.pixelSampling))
    func theMovedButtonYieldsToTheIntroCard() throws {
        // Ungated everywhere, the moved branch would put `Organize "Daughter"` in the header while
        // To File's pre-scan card says "File loose files in Daughter" with its own Start button:
        // two invitations naming one folder, only one of which moves the scope. Same manager and
        // pane as `theMovedButtonDrawsBeforeAnyScan`; only the rail selection differs.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Daughter")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
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
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "Renames lost the moved button — the stand-down is keyed on the scan flag rather than on To File")
    }

    @Test("The stand-down has something to stand down for", .machinePinned(.pixelSampling))
    func theToFileIntroIsActuallyOnScreen() throws {
        // The premise `theMovedButtonYieldsToTheIntroCard` rests on and can't check: an empty
        // header band is also what you get if To File's setup card stopped rendering, and the
        // stand-down would then defer to nothing.
        //
        // The control is To File after a clean scan, not another lens: every lens's pre-scan state
        // is a setup card, so a lens picked for drawing less would stop being a control. Comparing
        // the one lens's two states isolates the claim: before a scan the full invitation, after a
        // clean one a plain empty state.
        let toFile = try #require(strip(
            mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                  lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Daughter"),
            Self.contentZone))
        let scanned = try #require(strip(
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
        // Unscoped Organize already answers about everything, so a pane at the provider root has
        // not moved off anything, and "Organize everything" there would be a button that changes
        // nothing. Same fixture as above but for the pane's folder, so this can only be reading
        // `OrganizeAim`'s answer.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink < 20,
                "the overview drew a control with the pane at the provider root — Organize is offering to re-aim at what it is already aimed at")
    }

    @Test("The actions band is over the actions", .machinePinned(.pixelSampling))
    func theActionsBandIsWhereTheActionsAre() throws {
        // `actionsZone` is a hard-coded rectangle over a laid-out row, the kind of constant that
        // goes stale silently, and a band off the buttons makes `rescanIsAbsentBeforeAnyScan` pass
        // for the wrong reason. Pinned against the state with the most controls: a full queue draws
        // Rescan, Refine and File all, so this band must ink well beyond the one drawing Rescan
        // alone.
        let full = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.actionsZone))
        let rescanOnly = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                            Self.actionsZone))
        #expect(counts(full).ink > counts(rescanOnly).ink + 200,
                "three controls and one control inked this band almost identically — it is not over the actions")
        // Rescan outlives the queue: everything filed, findings still standing, and Rescan must not
        // sit inside the gate that draws "File all".
        #expect(counts(rescanOnly).ink > 100,
                "the action band painted nothing with an empty queue beside 17 risky names — Rescan is gated on the queue again")
    }
}
