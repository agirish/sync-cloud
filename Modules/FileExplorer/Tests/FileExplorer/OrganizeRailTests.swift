import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's header, in pixels: the rail on row 1, the readout on row 2, and the controls that
/// used to go missing between them.
///
/// **This replaces `OrganizeFocusChipTests` and `OrganizeSummaryZoneTests`, whose shared premise
/// the layout retired.** Both were built on one row carrying navigation *and* prose side by side:
/// the chips and the readout were told apart by wash density measured in two zones of the *same*
/// band, and `SummaryZoneDivider` marked the boundary between them. The rail owns row 1 now and
/// the readout owns row 2, so that boundary is a row break and the divider is gone.
///
/// The claim those suites protected has not gone anywhere, and it is the first test below: **a
/// capsule is a control.** It is simply structural now — the question is no longer "which half of
/// this row is clickable" but "does the clickable row still look clickable and the prose row
/// still not". Measured across the two rows rather than across two zones of one.
///
/// **Pixels, because nothing else here is open.** The rail items are labels inside `Button`s inside
/// the header card: `fittingSize` cannot see them (the lens fills a fixed frame), and a caption
/// assertion passes vacuously with no assistive client attached to the test process. Three defects
/// in this feature shipped past a green suite and were caught by installing the app and looking —
/// the rail not drawing on two of six lenses among them.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels back out of a live renderer, the repo-wide
/// marker for a suite that only produces a trustworthy verdict on the recording Mac.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeRailTests {

    /// **1400, not 900.** At 900 the rail sheds its labels (see ``OrganizeRailMetrics``), so a
    /// suite on that canvas would measure the glyph-only state throughout and leave the spelled-out
    /// rail — what a real window shows — untested. The shedding itself is pinned separately below,
    /// on both sides of the threshold.
    private static let canvas = CGSize(width: 1400, height: 620)

    /// Row 1 — the rail. **Measured, not guessed**: a horizontal sweep of the rendered header in
    /// 6pt slices puts the card's first row of content at y 12–42 (wash peaking 16.4k at y 18–24),
    /// then a blank gutter at y 42–52, then row 2 at y 52–70. The zone stops at x 588 so the
    /// trailing controls, which are also capsules, cannot be mistaken for rail items.
    private static let railZone = CGRect(x: 8, y: 12, width: 580, height: 30)
    /// Row 2 — the readout. Same left edge, so the two densities compare over the same width.
    private static let readoutZone = CGRect(x: 8, y: 50, width: 580, height: 22)
    /// Row 1's trailing controls, **excluding the search toggle** at x≈860–890, which is drawn in
    /// every state and would make this band non-empty no matter what the actions did.
    private static let actionsZone = CGRect(x: 1000, y: 12, width: 330, height: 30)
    /// Row 1's trailing set, **anchored to the right edge** so it tracks the controls at any width.
    /// 300pt: wide enough to hold the whole `Apply N recommended` label, narrow enough that the
    /// rail's own tail cannot wander into it on a header near the shed threshold.
    private static func trailingZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 300, y: 12, width: 300, height: 30)
    }

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

    /// Two eras of two, which is the minimum `StructureDivergence` reports on — the shape of the
    /// real `Income Tax` family cut to size.
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

    /// Duplicates with real groups — the lens whose trailing set is the widest in Organize
    /// (`All ⌄`, `Rescan`, `Apply N recommended`, search), measured at 353.5pt against the filing
    /// queue's 281.
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

    private static func manager(queue: Int, names: Int, hasScanned: Bool = true) -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions((0..<queue).map { suggestion("f\($0).pdf", confident: $0 % 3 != 0) })
        m.hasSuggestedFiling = hasScanned
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.riskyNames = (0..<names).map { risky("bad:name\($0).pdf") }
        m.nameScanRoot = URL(fileURLWithPath: "/root")
        m.hasScannedNames = names > 0
        return m
    }

    /// Mounts Organize with a **named rail selection**.
    ///
    /// The selection has to go through the defaults the view itself reads, because that is where
    /// `TidyView` keeps it — and it is not optional for a fixture: with the key unset the rail
    /// resolves to `nil`, which is the *overview*, where no lens's actions are drawn at all. A
    /// suite that forgot this measured the overview and reported that a full queue and an empty
    /// one inked the action band identically. The innermost `defaultAppStorage` wins.
    private func mount(_ manager: FileSyncManager, lens: OrganizeLens?,
                       width: CGFloat? = nil) -> NSHostingView<AnyView> {
        let canvas = CGSize(width: width ?? Self.canvas.width, height: Self.canvas.height)
        let defaults = ScratchDefaults("OrganizeRailTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let lens {
            defaults.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            defaults.removeObject(forKey: OrganizeLens.defaultsKey)
        }
        let subject = TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: "/root/Downloads", onFindDuplicates: {})
            .defaultAppStorage(defaults)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison reads as zero difference.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels split by how far they are from the band's own background corner.
    ///
    /// **`wash` is what separates a capsule from a run of text.** A tinted capsule covers its whole
    /// area in a low-opacity fill — a large, soft, uniform departure from the background. Glyphs
    /// and text are the opposite: a small area of near-black `ink` with a thin antialiased fringe.
    /// So a row of capsules reads dense in `wash`, and the same words drawn without them read
    /// nearly empty of it however much text is in there.
    ///
    /// Deliberately not a brightness filter: `brightness < 0.90` counts the dark text *inside* a
    /// capsule and none of the pale wash behind it, which is exactly backwards for this question.
    private func counts(_ rep: NSBitmapImageRep) -> (wash: Int, ink: Int) {
        guard let background = rep.colorAt(x: 2, y: 2) else { return (0, 0) }
        var wash = 0, ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.35 { ink += 1 } else if delta > 0.03 { wash += 1 }
            }
        }
        return (wash, ink)
    }

    /// `wash` per point of band width, so bands of different widths compare directly.
    private func washDensity(_ rep: NSBitmapImageRep, width: CGFloat) -> Double {
        Double(counts(rep).wash) / Double(width)
    }

    /// Strong, blue-dominant pixels — **the ring, told apart from the fill behind it.**
    ///
    /// The selected item encodes selection twice: a 2pt full-opacity `accent` stroke, and a fill
    /// deepened from 14% to 22%. `differingPixels` between two selections therefore moves whether
    /// or not the ring draws at all, which is how the first version of these two tests passed with
    /// the ring deleted — they measured the fill, one property adjacent to the claim.
    ///
    /// A 22% wash sits at delta ≈ 0.22 from the background, so the 0.30 floor excludes it; text is
    /// near-neutral, so requiring blue to lead red by 0.18 excludes that too. Measured: **2,476**
    /// such pixels with the ring, **632** with the ring deleted (the accent glyph and badges of the
    /// selected item), and **402** on the overview, which rings nothing.
    private func accentEdge(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.30 && (c.blueComponent - c.redComponent) > 0.18 { n += 1 }
            }
        }
        return n
    }

    /// The x-extent of row 1's **leading cluster** — the rail plus the intro button — read off the
    /// render, so the width model can be held to something other than itself.
    ///
    /// A 30pt run of background ends the cluster: inside it the widest gap is the 9.5pt before the
    /// intro button, while the reach across to the trailing controls is hundreds of points.
    ///
    /// **The band starts at x 8, not 0** — the same reason `railZone` does. The card paints a 1pt
    /// border at x≈2.5, and it is only 11pt clear of the first rail item, so a band that includes
    /// it merges the border into the cluster and reports the card's own padding as rail width
    /// (660 against a true 648). Dropping short runs does not help: the border is not a separate
    /// run once it has merged.
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
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
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

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { n += 1 }
        }
        return n
    }

    // MARK: The rule, ported across the row break — a capsule is a control

    @Test("The rail row wears capsules and the readout row does not")
    func onlyTheControlRowWearsCapsules() throws {
        let host = mount(Self.manager(queue: 24, names: 17), lens: .toFile)
        let rail = try #require(strip(host, Self.railZone))
        let readout = try #require(strip(host, Self.readoutZone))

        // Staleness guard first, and it is the half that makes the claim mean anything: a band that
        // has drifted off its row paints nothing, and "nothing" satisfies "no capsule" trivially.
        // The readout must be full of TEXT while being empty of WASH — a pairing that is only true
        // of words drawn without a capsule behind them.
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

    @Test("The readout still says its numbers")
    func theReadoutIsNotSimplyGone() throws {
        // The cheapest way to pass the test above is to draw no readout at all. So pin that it
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

    @Test("Every rail item reaches the screen")
    func theRailPaints() throws {
        let rail = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        // Six capsules and their labels. A bare threshold would pass on one item, so this is
        // paired with the per-item probe below.
        #expect(counts(rail).ink > 600, "row 1 is nearly empty — the rail is not drawing")
    }

    @Test("The rail draws on a lens whose apparatus is not the filing one")
    func theRailSurvivesTheApparatusSwitch() throws {
        // **The defect that shipped.** The rail was built inside the summary arm that only the
        // filing apparatus reaches, so standing on Duplicates or Rules drew that lens's own pills
        // and no rail at all. Rules borrows `.automations`' apparatus, which is the furthest from
        // filing's, so it is the strongest case to pin.
        let onFiling = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onRules = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .rules),
                                         Self.railZone))
        #expect(counts(onRules).ink > 600,
                "row 1 is empty on the Rules lens — the rail is drawn inside one apparatus's arm again")
        // Same six items either way; only the ring moves, so the two renders differ but neither is
        // blank. Asserting they DIFFER is what stops a cached or identical render passing both.
        #expect(differingPixels(onFiling, onRules) > 0,
                "the rail rendered identically on two different selections — the ring is not tracking the lens")
    }

    @Test("The selected item is ringed")
    func theSelectedItemIsRinged() throws {
        // An `.overlay` that never draws is invisible to every geometry assertion, so the ring is
        // pixels or it is nothing — and it has to be measured as the RING. Deleting the stroke
        // leaves the deepened fill behind, which still moves a whole-band pixel diff, so a diff is
        // not evidence the ring exists. `accentEdge` is: 2,476 with it, 632 without.
        let ringed = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                        Self.railZone))
        let edge = accentEdge(ringed)
        #expect(edge > 1500,
                "the selected item painted \(edge) full-strength accent pixels — the ring is not drawing, and only the fill is left to say which lens you are on")
    }

    @Test("Moving the selection moves the ring")
    func theRingFollowsTheSelection() throws {
        // A ring that drew on a fixed item would satisfy the test above forever. Both states are
        // ringed, so this is the pixel diff — here it IS the right instrument, because the
        // question is whether the ring MOVED, not whether it exists.
        let onToFile = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onNames = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .names),
                                         Self.railZone))
        #expect(accentEdge(onNames) > 1500, "the Names selection drew no ring")
        #expect(differingPixels(onToFile, onNames) > 200,
                "selecting a different rail item changed almost nothing — the ring is pinned to one item")
    }

    @Test("The overview rings nothing")
    func theOverviewIsTheUnselectedState() throws {
        // The overview is the rail's unselected state rather than a seventh item, so it must draw
        // the same six items with no ring — fewer inked pixels than any selected state, but not
        // zero.
        let overview = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil),
                                          Self.railZone))
        let selected = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        #expect(counts(overview).ink > 600, "the overview drew no rail — it is not the unselected state")
        // Measured at 402 against 2,476 for a ringed render: the overview rings nothing. A pixel
        // diff would pass here even with the ring deleted, so this asks the ring question directly.
        let edge = accentEdge(overview)
        #expect(edge < 900,
                "the overview painted \(edge) full-strength accent pixels — something is ringed, so the unselected state is quietly selecting a lens")
        #expect(differingPixels(overview, selected) > 200,
                "the overview and a selected lens rendered the same rail")
    }

    // MARK: Badges — absent at zero, present with a finding

    @Test("A badge appears only when its lens has something to report")
    func aBadgeIsAbsentAtZero() throws {
        // The surviving half of the chips' argument. The ITEM is unconditional — that is what
        // pointed invocation lands on — so this compares two renders of the same six items and
        // asserts the *badge* is what changed.
        let none = try #require(strip(mount(Self.manager(queue: 24, names: 0), lens: .toFile),
                                      Self.railZone))
        let some = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        #expect(differingPixels(none, some) > 100,
                "17 risky names painted the same rail as none — the Names badge is not drawing")
        // And the item itself is there either way: the rail must not shrink to five places.
        #expect(counts(none).ink > 600, "the rail lost an item at zero — a place is not a badge")
    }

    @Test("The badge carries the count, not just a dot")
    func theCountReachesTheBadge() throws {
        // Two non-zero counts of different digit widths. If the badge were a presence indicator
        // rather than a number these would render identically.
        let three = try #require(strip(mount(Self.manager(queue: 24, names: 3), lens: .toFile),
                                       Self.railZone))
        let seventeen = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                           Self.railZone))
        #expect(differingPixels(three, seventeen) > 50,
                "3 and 17 risky names painted the same badge — it is not carrying the count")
    }

    @Test("The Restructure badge reports the findings the overview reports")
    func theRestructureBadgeTracksTheDetector() throws {
        // **The defect this pins.** `railCount` returned a literal `0` for restructure, under a
        // comment saying there were no detectors — written before the detector landed in the same
        // change and never revisited. The overview said "1 finding" while the rail item beside it
        // stayed bare, so the one lens built that session could not announce itself, which is the
        // whole job of a badge.
        let withFindings = Self.manager(queue: 24, names: 17)
        withFindings.filingFolderProfile = Self.divergentProfile
        let none = Self.manager(queue: 24, names: 17)   // no profile ⇒ nothing to detect

        // **A band wide enough for the WHOLE rail.** `railZone` stops at x 588 so the trailing
        // controls cannot be mistaken for rail items, and a third badge pushes the rail past that
        // edge — so the crop lost more of "Rules" than the badge added, and the render WITH a
        // finding measured *fewer* inked pixels than the one without. The difference was real; the
        // direction was an artefact of the crop.
        let whole = CGRect(x: 8, y: 12, width: 700, height: 30)
        let a = try #require(strip(mount(withFindings, lens: .toFile), whole))
        let b = try #require(strip(mount(none, lens: .toFile), whole))
        #expect(differingPixels(a, b) > 50,
                "a tree with a divergent family painted the same rail as one with none — the badge is not reading the detector")
        #expect(counts(a).ink > counts(b).ink,
                "the badge added no ink — restructure is still reporting a hard-coded zero")
    }

    // MARK: Shedding — the rail yields width to the controls

    @Test("The rail spells its items out when the header is wide enough")
    func theRailKeepsItsLabelsWhenThereIsRoom() throws {
        let wide = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        // Six labels plus six glyphs. The glyph-only rail inks far less, which is what the
        // narrow-canvas comparison below turns into an assertion.
        #expect(counts(wide).ink > 600, "the rail is not drawing its labels at 1400pt")
    }

    @Test("The rail sheds its labels rather than truncating the controls")
    func theRailShedsWhenTheRowIsTight() throws {
        // **The defect this rule exists for.** At 900pt the spelled-out rail and the filing
        // queue's three controls overran row 1, and SwiftUI truncated the flexible side: `Refine
        // with Opus` and `Refine with Haiku` both rendered as `Refin…`, so four tests comparing
        // those renders saw identical pixels and nothing anywhere reported a problem.
        let wide = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        let narrowHost = mount(Self.manager(queue: 24, names: 17), lens: .toFile, width: 900)
        let narrow = try #require(strip(narrowHost, Self.railZone))

        // The labels are gone…
        #expect(counts(narrow).ink < counts(wide).ink / 2,
                "the narrow rail inked \(counts(narrow).ink) against \(counts(wide).ink) wide — it is not shedding, so the controls beside it are being truncated instead")
        // …and the six places are not. A rail that shed items rather than words would strand
        // pointed invocation, which is the one thing the permanent item exists for.
        #expect(counts(narrow).ink > 120, "the narrow rail drew nothing — it shed its items, not its labels")
    }

    @Test("Shedding is arithmetic, and it answers both ways")
    func theShedRuleIsComputed() {
        let twoBadges = Self.badges([.toFile: 24, .names: 17])
        let lead = { (b: @escaping (OrganizeLens) -> Int?) in
            OrganizeRailMetrics.leadingWidth(scale: 1, hasIntro: true, badge: b)
        }
        // The real header widths this app produces, either side of the threshold.
        #expect(OrganizeRailMetrics.style(contentWidth: 1400, leadingWidth: lead(twoBadges)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 900, leadingWidth: lead(twoBadges)) == .iconOnly)
        // The shed rung has to actually solve it, or shedding buys nothing.
        let shed = OrganizeRailMetrics.shedLeadingWidth(scale: 1, hasIntro: true, badge: twoBadges)
        #expect(shed <= 900 - OrganizeRailMetrics.reservedTrailing)
        // Badges widen the rail, so the day every finding reports is the day it is tightest —
        // a rule measured without them would shed too late.
        #expect(lead(twoBadges) > lead(Self.badges([:])))
    }

    @Test("A wider badge costs more than a narrower one")
    func theBadgeIsMeasuredByItsDigits() {
        // **`410` is not `24`.** The model charged a flat two-digit figure per badge, and the
        // ~8pt-per-badge shortfall that opened up on a three-digit count is part of why the
        // Duplicates row truncated while the arithmetic reported room.
        #expect(OrganizeRailMetrics.badgeWidth(410, scale: 1)
                > OrganizeRailMetrics.badgeWidth(24, scale: 1))
        #expect(OrganizeRailMetrics.leadingWidth(scale: 1, hasIntro: true,
                                                 badge: Self.badges([.duplicates: 410]))
                > OrganizeRailMetrics.leadingWidth(scale: 1, hasIntro: true,
                                                   badge: Self.badges([.duplicates: 24])))
    }

    @Test("The leading model matches what row 1 actually draws")
    func theLeadingModelMatchesWhatTheRowDraws() throws {
        // **The test the arithmetic was missing, and the reason the truncation shipped.** Every
        // other assertion about the width model compared it against itself, so an estimate could be
        // 63pt short of the row it claimed to describe and still be perfectly self-consistent.
        // This one measures the leading cluster OFF THE RENDER and holds the model to it.
        //
        // It is also what makes ``OrganizeRailMetrics/introCompanion`` load-bearing. Zeroing that
        // constant leaves every *behavioural* assertion here passing — the glyph and badge
        // corrections alone happen to keep the row honest, with 4pt to spare instead of 25 — so
        // only a claim about the model's own accuracy can catch it.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        let host = mount(manager, lens: .duplicates, width: 1400)
        let drawn = try #require(leadingExtent(host, width: 1400),
                                 "row 1 drew no leading cluster — the rail is not on screen at all")
        let model = OrganizeRailMetrics.leadingWidth(
            scale: 1, hasIntro: true,
            badge: Self.badges([.toFile: 24, .duplicates: 410, .names: 17]))

        // Measured: 653.2 modelled against 648.0 drawn. Over, never under — a model that
        // under-states the leading side is one that lets the row overrun, which is this whole
        // type's failure mode.
        #expect(model >= drawn,
                "the rail and the intro button draw \(drawn)pt but the model budgets \(model)pt — it is \(drawn - model)pt short, so the row will overrun before it sheds")
        // And not wildly over, or the rail sheds its labels on headers that would have seated them.
        #expect(model - drawn < 12,
                "the model budgets \(model)pt for a leading side that draws \(drawn)pt — \(model - drawn)pt of slack sheds the labels early")
    }

    @Test("The glyph table still matches the renderer")
    func theGlyphTableMatchesTheRenderer() throws {
        // ``OrganizeRailMetrics/glyphWidth(_:scale:)`` is tabulated because measuring costs ~812µs
        // for the six and the caller runs per `body`. Tabulated numbers rot; this is what stops
        // them rotting silently. A glyph is NOT its point size — the estimate this replaced charged
        // 10.5 for all six, and `folder.badge.gearshape` is 17.
        for lens in OrganizeLens.allCases {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            let live = try #require(
                NSImage(systemSymbolName: lens.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)?.size.width,
                "\(lens.symbol) did not resolve — the rail's glyph is missing, not just mis-sized")
            #expect(abs(OrganizeRailMetrics.glyphWidth(lens) - live) < 0.5,
                    "\(lens.symbol) renders \(live)pt but the table says \(OrganizeRailMetrics.glyphWidth(lens)) — the rail is mis-measured by \(live - OrganizeRailMetrics.glyphWidth(lens))pt on this item")
        }
    }

    // MARK: The moment the labels appear, the actions must still have their words

    @Test("At the width the rail first spells itself out, the actions are not truncated")
    func theShedThresholdIsNotOneCharacterTooLate() throws {
        // **The defect this pins, and the one the suite above could not see.** Every render here
        // was at 900 (shed) or 1400 (roomy); nothing rendered at the threshold itself. Between
        // them lay a ~29pt band where the model said the labels fitted and the row disagreed —
        // Duplicates drew `Apply 410 recomme…` while `theShedRuleIsComputed` passed, because that
        // test only ever compared the arithmetic against itself.
        //
        // The invariant, stated where it can fail: **the first width at which the model spells the
        // rail out must already seat the actions.** Asserted at the model's own flip point, so it
        // re-derives if the constants move.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        let badge = Self.badges([.toFile: 24, .duplicates: 410, .names: 17])
        let threshold = OrganizeRailMetrics.leadingWidth(scale: 1, hasIntro: true, badge: badge)
            + OrganizeRailMetrics.reservedTrailing

        // Right-anchored: the trailing set is right-aligned and fixed-size, so at every width that
        // seats it these bands are pixel-identical. 300pt, because a band wide enough to reach back
        // past the actions catches the RAIL's tail on a narrow canvas and reads that motion as
        // truncation.
        let roomy = mount(manager, lens: .duplicates, width: 2400)
        let reference = try #require(strip(roomy, Self.trailingZone(2400)))

        // A **band**, not the single threshold point: a reserve that is short by a few points puts
        // the truncation just above the flip rather than at it, and one probe would step straight
        // over it. Measured pre-fix, the bad band ran 29pt.
        for offset in stride(from: 0.0, through: 30.0, by: 6.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .duplicates, width: width)
            // The rail really is spelled out here — otherwise "not truncated" is satisfied by the
            // shed state, which fits trivially and is not what this is asking about.
            #expect(counts(try #require(strip(host, Self.railZone))).ink > 600,
                    "at \(width)pt the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(strip(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt — \(offset)pt above the width the model starts spelling the rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    // MARK: The control — Rescan outlives the queue

    @Test("Rescan is there once a scan has run, even with nothing left to file")
    func rescanSurvivesAnEmptyQueue() throws {
        // The reported state: everything filed, findings still standing. Row 1's trailing half used
        // to be empty here, because Rescan sat inside the gate that draws "File all".
        let filed = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                       Self.actionsZone))
        #expect(counts(filed).ink > 100,
                "row 1 painted no controls with an empty queue beside 17 risky names — Rescan is gated on the queue again")
    }

    @Test("…and is absent before the first scan, where the intro owns the invitation")
    func rescanIsAbsentBeforeAnyScan() throws {
        // The other direction, and what stops the test above from being satisfied by a button that
        // is simply always drawn.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .toFile), Self.actionsZone))
        #expect(counts(never).ink < 20,
                "row 1's action band is inked before any scan has completed — Rescan is ungated")
    }

    @Test("The actions band is over the actions")
    func theActionsBandIsWhereTheActionsAre() throws {
        // `actionsZone` is a hard-coded rectangle over a laid-out row, the kind of constant that
        // goes stale silently — and a band that has slid off the buttons makes
        // `rescanIsAbsentBeforeAnyScan` pass for the wrong reason forever. Pinned against the state
        // with the MOST controls: a full queue draws Rescan, Refine and File all, so this band has
        // to be substantially more inked than the one that draws Rescan alone.
        let full = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.actionsZone))
        let rescanOnly = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                            Self.actionsZone))
        #expect(counts(full).ink > counts(rescanOnly).ink + 200,
                "three controls and one control inked this band almost identically — it is not over the actions")
    }
}
