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
    /// The lens's trailing controls — **row 2 now**, which is where they moved. Excludes the search
    /// toggle: that one stayed on row 1, and it draws in every state, so a band containing it would
    /// be non-empty no matter what the actions did.
    private static let actionsZone = CGRect(x: 1000, y: 48, width: 330, height: 26)
    /// Row 1's trailing set, **anchored to the right edge** so it tracks the controls at any width.
    /// 300pt: wide enough to hold the whole `Apply N recommended` label, narrow enough that the
    /// rail's own tail cannot wander into it on a header near the shed threshold.
    /// Row **2**'s trailing controls, anchored to the right edge so they track at any width.
    ///
    /// **170pt, where row 1's band was 300.** The controls moved to row 2, and on that row they
    /// share the trailing side with the folder-memory caption — a band wide enough to reach back
    /// past the buttons catches the caption appearing and disappearing and reads that as
    /// truncation. Measured: a 300pt band reported a flat 222-pixel difference at every width below
    /// the caption's floor, which is the caption's own absence and not a clipped label. 170 is
    /// inside the narrowest trailing set this suite measures (Duplicates, 354pt).
    private static func trailingZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 170, y: 48, width: 170, height: 26)
    }
    /// The content card beneath the header — everything below the two-row ladder and its gutter.
    /// Used only to ask whether a lens's page is carrying anything, never what it says.
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

    /// The rail states the width model takes, from the counts that matter to a case.
    ///
    /// Anything unlisted is `clean` — **scanned and empty, not unscanned**, which is the state that
    /// costs the model nothing. A fixture wanting the dot has to ask for it, so an item's width can
    /// never grow by accident here.
    private static func states(_ counts: [OrganizeLens: Int],
                               unscanned: Set<OrganizeLens> = []) -> (OrganizeLens) -> RailItemState {
        { item in
            guard item.carriesBadge else { return .configuration }
            if let n = counts[item], n > 0 { return .reporting(n) }
            return unscanned.contains(item) ? .notScanned : .clean
        }
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

    /// A real survey's worst case: every clause the summary can carry, with the counts his own tree
    /// produces. 485pt of caption — the string the row 1 defect was made of.
    private static let longSurvey = FileSyncManager.FilingSurveyReport(
        foldersChanged: 12, documentsRead: 340, documentsRelocated: 8, documentsDropped: 3,
        documentsUnavailable: 5, foldersLearned: 96, changed: true)

    /// - Parameters:
    ///   - survey: what the last folder-memory re-survey reported, or nil for the ordinary state
    ///     where none has run this session.
    ///   - refine: whether the refine offer is showing. **It needs four things, not one**, and a
    ///     fixture that sets only the classifier draws no button at all —
    ///     `canRefineFilingSuggestions` also wants the cached taxonomy and the provider root, so a
    ///     suite that forgot them would measure the state without the widest control in it and
    ///     report that the row fits.
    ///   - scanFolder: the root the filing list was walked from, or nil for a manager that has
    ///     genuinely never scanned. **`hasScanned: false` alone does not give you that state** — it
    ///     clears the completion flag while leaving a scanned root behind, which is a pane sitting
    ///     on its own subject rather than an Organize with no subject at all. The two states differ
    ///     in exactly the button this suite measures.
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
            // Two more pills on row 2's leading side (`reused`, `refined`), which is how the row
            // gets tight enough for anything on its trailing side to have to give.
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

    /// Mounts Organize with a **named rail selection**.
    ///
    /// The selection has to go through the defaults the view itself reads, because that is where
    /// `LensWorkspaceView` keeps it — and it is not optional for a fixture: with the key unset the rail
    /// resolves to `nil`, which is the *overview*, where no lens's actions are drawn at all. A
    /// suite that forgot this measured the overview and reported that a full queue and an empty
    /// one inked the action band identically. The innermost `defaultAppStorage` wins.
    ///
    /// `scale` is the app's own text-size multiplier (`FontSize.scale`). It defaults to 1 so the
    /// behavioural tests read as before, but it is a real parameter because the width model claims
    /// to be right at *every* size while only some of its parts actually scale.
    ///
    /// `providerRoot` and `scanTarget` are what decide whether the pane has wandered off what
    /// Organize is answering about (``OrganizeAim``). They default to the pair the rest of this
    /// suite wants — a target equal to the scanned root, so no fixture draws the moved button by
    /// accident — and the two tests about that button set them apart on purpose.
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
        // menu's "Update folder memory" item, and the "Refine with Claude…" invitation, which is
        // withheld outright when there is no Settings to open.
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: scanTarget, onFindDuplicates: {},
                               onUpdateFolderMemory: {}, onConfigureCloudRefine: {},
                               providerRoot: providerRoot)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
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
        // **Twice.** `.onGeometryChange` writes `railStyle` *after* a pass, so a single
        // `layoutSubtreeIfNeeded` renders the initial `.full` and never the width-dependent answer.
        // This was invisible while the threshold sat above every width the suite used — the initial
        // value and the resolved one agreed — and became visible the moment a probe asked for a
        // width on the shed side of it.
        host.layoutSubtreeIfNeeded()
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
    /// Accent-tinted **wash** pixels — the capsule fill rather than its ring.
    ///
    /// `accentEdge` deliberately excludes the wash (its 0.30 floor sits above a 22% fill), because
    /// it exists to ask about the ring. This asks the opposite question, which is the one change B
    /// turned into a signal: a reporting item is washed in the accent and a clean one in a neutral,
    /// so the difference is a *hue* at low delta. Blue must lead red, and the delta must be small
    /// enough to be a wash and large enough not to be the background.
    private func accentWash(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.02 && (c.blueComponent - c.redComponent) > 0.05 { n += 1 }
            }
        }
        return n
    }

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

    /// The width **from the first inked run to the last** in a band — the span every control on
    /// this side of the row occupies together.
    ///
    /// **Two wrong measures were tried first, and both are worth recording.**
    ///
    /// *Raw first-to-last inked column* reported 738pt of "control" beside a 22pt button: the
    /// card's glass carries a gradient, so at a 0.03 threshold the far end of a 700pt band differs
    /// from the near end and the whole band reads as inked. Hence the 0.10 threshold and the
    /// gap-splitting into runs.
    ///
    /// *The last run alone* passed a mutation that put the lens actions back on row 1 — the
    /// rightmost run is the search toggle either way, so it answered 22pt while three buttons sat
    /// beside it. A reserve covers everything after the rail, so the span has to run from the first
    /// control to the last.
    private func trailingSpan(_ rep: NSBitmapImageRep, bandWidth: CGFloat) -> CGFloat? {
        guard let background = rep.colorAt(x: rep.pixelsWide - 3, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / bandWidth
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
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
        let onRenames = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .renames),
                                           Self.railZone))
        #expect(accentEdge(onRenames) > 1500, "the Renames selection drew no ring")
        #expect(differingPixels(onToFile, onRenames) > 200,
                "selecting a different rail item changed almost nothing — the ring is pinned to one item")
    }

    @Test("The overview rings its own item, and no lens")
    func theOverviewRingsAll() throws {
        // **This assertion is inverted from what it used to be, and the inversion is change B.**
        // The overview was the rail's unselected state with no control of its own, so this test
        // asked that *nothing* be ringed. It has a place now — "All", at the head of the rail —
        // and the state it names has not changed: `railLens` is still nil, the overview still
        // renders, clicking the selected lens a second time still comes back here. What changed is
        // that you can point at it.
        let overview = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil),
                                          Self.railZone))
        let selected = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        #expect(counts(overview).ink > 600, "the overview drew no rail — it is not the unselected state")

        // Something IS ringed now — measured 402 accent-edge pixels when nothing was, against
        // 2,476 for a ringed lens. A pixel diff cannot ask this question: it passes with the ring
        // deleted, which is how a ring mutation escaped this suite once before.
        let edge = accentEdge(overview)
        #expect(edge > 900,
                "the overview painted \(edge) full-strength accent pixels — nothing is ringed, so All is not showing as the current place")

        // …and it is All that is ringed, not a lens: the ring sits in the rail's first item.
        // Measured over the leading 120pt, which at this canvas holds All and nothing else.
        let allItem = CGRect(x: 8, y: 12, width: 120, height: 30)
        let overviewAll = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil), allItem))
        let toFileAll = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile), allItem))
        #expect(accentEdge(overviewAll) > accentEdge(toFileAll) + 200,
                "All painted \(accentEdge(overviewAll)) accent-edge pixels on the overview and \(accentEdge(toFileAll)) with a lens selected — the ring is not moving to All")

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

    @Test("At 900pt the rail spells itself out, and the controls are on row 2")
    func theRailKeepsItsNamesAtNineHundred() throws {
        // **This is change A, stated where it can fail.** The controls used to share row 1 with the
        // rail, so the reserve was 490 for To File and the rail wanted 1,183pt of card before it
        // would spell six names — at 900 it drew six anonymous glyphs. They are on row 2 now and
        // row 1 reserves only the search toggle, so 900 is comfortably above the threshold.
        //
        // Run against this suite's own 1400pt reference: at both widths the rail is spelled out, so
        // the ink is within a few per cent. Before A the 900pt render inked less than half of the
        // 1400pt one, which is what the assertion below would catch if the reserve ever went back.
        let wide = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        let atNineHundred = try #require(strip(mount(Self.manager(queue: 24, names: 17),
                                                     lens: .toFile, width: 900),
                                               Self.railZone))
        #expect(counts(atNineHundred).ink > counts(wide).ink * 3 / 4,
                "at 900pt the rail inked \(counts(atNineHundred).ink) against \(counts(wide).ink) at 1400 — it is shedding its labels again, so row 1 has picked up a tenant the reserve does not know about")

        // And row 1's trailing half really is empty now, bar the search toggle `LensHeaderCard`
        // appends itself. Measured to the LEFT of that toggle, which draws in every state and would
        // make this band non-empty no matter what the actions did.
        let host = mount(Self.manager(queue: 24, names: 17, refine: true), lens: .toFile, width: 1400)
        let rowOneTrailing = try #require(strip(host, CGRect(x: 1000, y: 12, width: 330, height: 30)))
        #expect(counts(rowOneTrailing).ink < 200,
                "row 1's trailing band inked \(counts(rowOneTrailing).ink) — a control is still drawing up there, and the reserve is sized for none")
        // …and they are drawing on row 2, or the assertion above passes by the actions having
        // vanished entirely.
        let rowTwoTrailing = try #require(strip(host, Self.trailingZone(1400)))
        #expect(counts(rowTwoTrailing).ink > 400,
                "row 2's trailing band inked \(counts(rowTwoTrailing).ink) — the controls did not arrive where they were moved to")
    }

    // MARK: The three states — reporting, clean, never looked

    @Test("A lens with findings is tinted; one that ran and found nothing is not")
    func theTintSaysHasWorkNotIsClickable() throws {
        // **The wash used to mean "this is a control" and now means "this has work".** Every item
        // wore `accent.opacity(0.14)` whether it had found 722 things or nothing, so the only
        // signal was a small badge at the item's tail and six identical capsules is what the row
        // read as. The capsule stays — it is still what says "clickable" — but the colour is spent
        // on the lenses that want you.
        //
        // Measured over Duplicates' own item, with the same scan having run either way: the only
        // difference between the two fixtures is whether it found anything.
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
        // The distinction `OrganizeOverviewState` is careful about and the rail used to throw away:
        // both drew as "an item with no badge". Asserted on the state the width model and the label
        // both read, so the two cannot drift.
        var counts = LensWorkspaceView.RailCounts(toFile: 0, duplicates: 0, names: 0, renames: 0,
                                         restructure: 0, rules: 3)
        counts.scanned = [.duplicates]
        #expect(counts.state(.duplicates) == .clean)
        #expect(counts.state(.toFile) == .notScanned)
        #expect(counts.state(.rules) == .configuration,
                "Rules answered a scan state — it is configuration, and neither clean nor unscanned describes it")
        counts.toFile = 4
        #expect(counts.state(.toFile) == .reporting(4))
        // And the two quiet states really do cost different widths, or the model cannot tell them
        // apart either and the dot is drawn uncharged.
        #expect(OrganizeRailMetrics.stateWidth(.notScanned, scale: 1)
                > OrganizeRailMetrics.stateWidth(.clean, scale: 1))
    }

    @Test("The rail says its state in words, not only in colour")
    func theRailStateIsSpokenNotOnlyTinted() {
        // **The gap this closes was opened by making the tint mean something.** A reporting item is
        // told from a quiet one by its wash and an unscanned one from a clean one by a 4pt dot;
        // neither reaches VoiceOver, so before this every item on the row announced as its bare
        // title and the whole encoding was invisible. Colour must never be the only carrier.
        #expect(RailItemLabel.accessibilityLabel(title: "Duplicates", state: .reporting(722))
                == "Duplicates, 722")
        #expect(RailItemLabel.accessibilityLabel(title: "Names", state: .clean)
                == "Names, nothing found")
        #expect(RailItemLabel.accessibilityLabel(title: "Restructure", state: .notScanned)
                == "Restructure, not scanned")
        // Rules and "All" report nothing and have no state to announce — "Rules, nothing found"
        // would be the same claim the badge refuses to make by never drawing a zero there.
        #expect(RailItemLabel.accessibilityLabel(title: "Rules", state: .configuration) == "Rules")

        // The three states must be told apart from each other, which is the whole claim.
        let spoken = Set([RailItemState.reporting(1), .clean, .notScanned]
            .map { RailItemLabel.accessibilityLabel(title: "X", state: $0) })
        #expect(spoken.count == 3, "two states announce identically — the row is still colour-only")

        // Spoken in full where the badge abbreviates: `1.2k` is a width compromise six capsules
        // sharing a row have to make, and a spoken label does not.
        #expect(RailItemLabel.accessibilityLabel(title: "Renames", state: .reporting(1_192))
                == "Renames, 1,192")
        #expect(RailItemLabel.badgeText(1_192) == "1.1k")
    }

    @Test("The rail item actually wears the label it composes")
    func theRailAppliesItsSpokenLabel() throws {
        // The suite above asserts what `accessibilityLabel(title:state:)` *returns*. Nothing
        // asserted that the view ever calls it — delete the `.accessibilityLabel(…)` from
        // `RailItemLabel`'s body and every expectation here still passes while the row goes back to
        // announcing nothing, which is precisely the regression the function was written for.
        //
        // **A source scan, because a live one is not available.** SwiftUI publishes no accessibility
        // tree to an `NSHostingView` with no assistive client attached: walking this view's
        // `accessibilityChildren()` in this harness returns an empty `AXGroup`, measured, so an
        // assertion made against it would be green with the modifier deleted. Scanning the file is
        // weaker — it pins a spelling, not a behaviour — but it fails on the one edit that matters,
        // and it names the file rather than reading nothing and passing.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/Tests/FileExplorer
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer/OrganizeOverview.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        try #require(source.count > 5000, "OrganizeOverview.swift could not be read — the scan below would be vacuous")

        // Fed by the function, not restated: an inlined "\(title), \(count)" here would satisfy a
        // bare "is there a label" scan while free to drift from what the tests above pin.
        #expect(source.contains(".accessibilityLabel(Self.accessibilityLabel(title: title, state: state))"),
                "RailItemLabel no longer speaks its state — the row announces six identical titles and the tint is the only carrier again")
    }

    @Test("A lens that has never scanned does not claim a scan found nothing")
    func theHelpDoesNotInventAScan() {
        // `railHelp` took the badge, and `badge ?? 0` reads a nil — which means *no number to show*
        // — as zero. So a never-scanned queue's tooltip said "0 loose files **this scan found**",
        // asserting a scan that had not run: precisely the conflation the rail's three states exist
        // to remove, still being made by the words beside them.
        let unscanned = OrganizeLens.toFile.help(state: .notScanned)
        #expect(unscanned.hasPrefix("Not scanned here yet."),
                "a never-scanned lens says: \(unscanned)")
        #expect(!unscanned.contains("0 "), "the help is still quoting a zero for a scan that never ran")

        #expect(OrganizeLens.toFile.help(state: .clean).hasPrefix("Nothing here."))
        #expect(OrganizeLens.toFile.help(state: .reporting(24)).hasPrefix("24 here."))
        // The description is the same sentence in every state — only the count clause changes.
        for state in [RailItemState.reporting(24), .clean, .notScanned] {
            #expect(OrganizeLens.toFile.help(state: state).contains("Loose files and where they belong."))
        }
    }

    @Test("A four-digit badge abbreviates, and the model measures what it draws")
    func theBadgeAbbreviatesPastThreeDigits() {
        #expect(RailItemLabel.badgeText(999) == "999")
        #expect(RailItemLabel.badgeText(1_192) == "1.1k")
        #expect(RailItemLabel.badgeText(12_400) == "12k")
        // The point of abbreviating is that the rail is widest on the day every finding reports.
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
        // The real header widths this app produces, either side of the threshold.
        //
        // **900 is now `.full`, and that is the whole of change A.** It used to be `.iconOnly`:
        // the reserve was 490 for To File, so the rail wanted 1,183pt before it would spell six
        // names and every ordinary window got glyphs. With the controls on row 2 the reserve is the
        // search toggle alone and the threshold is ~668, so the shed belongs to widths a window
        // does not reach. 640 is below it and still answers the other way, which is what keeps this
        // an assertion about arithmetic rather than a restatement of a constant.
        #expect(OrganizeRailMetrics.style(contentWidth: 1400, leadingWidth: lead(twoBadges)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 900, leadingWidth: lead(twoBadges)) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 600, leadingWidth: lead(twoBadges)) == .iconOnly)
        // The shed rung has to actually solve it, or shedding buys nothing.
        let shed = OrganizeRailMetrics.shedLeadingWidth(scale: 1, state: twoBadges)
        #expect(shed <= 600 - OrganizeRailMetrics.searchToggleWidth)
        // Badges widen the rail, so the day every finding reports is the day it is tightest —
        // a rule measured without them would shed too late.
        #expect(lead(twoBadges) > lead(Self.states([:])))
    }

    /// **The width the rail gets is the COLUMN's, not the window's** — and that difference is why
    /// the rung above sat unreached for so long while the row overlapped the pane beside it.
    ///
    /// `theShedRuleIsComputed` feeds `style(contentWidth:)` numbers like 900 and 1400 and calls
    /// them "the real header widths this app produces". They are window-sized. Organize's header
    /// card lives in the workspace half of `singleSourceLayout`, beside a source pane that is
    /// draggable from 220pt up, so a 900pt window hands this row somewhere near 500 — below the
    /// threshold, every time. The arithmetic was right and the number it was given was a different
    /// quantity.
    ///
    /// So this is the same rule asked in the units a caller can actually supply. Measured at the
    /// default text size with two findings reporting: labels need a **623pt column**, which a
    /// 760pt window cannot give while the source pane holds its own 220pt floor (540). Organize is
    /// therefore a glyph rail at the narrowest window, exactly as the workspace bar is — and the
    /// tooltips it sheds into are why that rung exists.
    @Test("The column, not the window, is what the rail has to fit")
    func theShedRuleIsAskedInColumnWidths() {
        let twoBadges = Self.states([.toFile: 24, .renames: 17])
        let leading = OrganizeRailMetrics.leadingWidth(scale: 1, state: twoBadges)

        // The card's own inset and padding are charged — the difference between the two entry
        // points, and the 29pt the old measurement silently spent.
        //
        // Asserted as a CONSEQUENCE rather than as `style(columnWidth: w) == style(contentWidth: w
        // - cardChrome)`, which was this test's first draft and is the function body restated: a
        // model compared to itself agrees no matter what either side is doing. What can actually
        // fail is this — a column holding exactly the rail and the toggle is still too narrow,
        // because the card spends 29 of it before the row starts.
        #expect(OrganizeRailMetrics.cardChrome == 29)
        #expect(OrganizeRailMetrics.style(columnWidth: leading + OrganizeRailMetrics.searchToggleWidth,
                                          leadingWidth: leading) == .iconOnly,
                "the card's own inset and padding have stopped being charged — the rail will draw 29pt past the room it has")

        // The boundary from both sides, so a chrome constant cannot move it unnoticed.
        let threshold = leading + OrganizeRailMetrics.searchToggleWidth + OrganizeRailMetrics.cardChrome
        #expect(OrganizeRailMetrics.style(columnWidth: threshold, leadingWidth: leading) == .full)
        #expect(OrganizeRailMetrics.style(columnWidth: threshold - 1, leadingWidth: leading) == .iconOnly)

        // What the window's own floor produces: 760 content, less the source pane's 220pt minimum.
        #expect(OrganizeRailMetrics.style(columnWidth: 760 - 220, leadingWidth: leading) == .iconOnly,
                """
                the rail spells itself out in a 540pt column — if that is now true the threshold has \
                moved and the window floor's consequence recorded here is out of date
                """)
        // And a comfortable window still spells it out, or the shed has swallowed the normal case.
        #expect(OrganizeRailMetrics.style(columnWidth: 1000, leadingWidth: leading) == .full)
    }

    /// **Shedding cannot always solve it, which is why the row also scrolls.**
    ///
    /// Every other assertion here ends at "and the glyph rung fits". At the workspace column's own
    /// 340pt floor (`singleSourceLayout`'s `minWorkspace`) it does not: six three-digit badges at
    /// the largest text size measure 474.7 with the labels already gone, against 275pt of usable
    /// row. There is nothing left to shed, and an `HStack` that runs out of room draws over its
    /// neighbour rather than clipping — which is the defect the screenshots showed.
    ///
    /// Recorded as a measurement so the horizontal scroll in `LensWorkspaceView.lensTitle` reads as the
    /// answer to a case that exists rather than as belt-and-braces someone can tidy away.
    /// **A rail item has to fit the row, now that the row clips.**
    ///
    /// Before the horizontal `ScrollView` in `lensTitle` an over-tall item simply drew outside the
    /// 27pt row — untidy, and nobody's bug. A scroll view clips its content, so the same overflow
    /// would now cut a badge or a selected item's capsule off at the top and bottom instead. That
    /// is the cost of the fix, and this is what keeps it paid.
    ///
    /// **Measured: 20 / 22 / 25 / 26pt against `LensHeaderMetrics.tabRow`'s 27**, so the margin at
    /// the largest text size is a single point. It is not slack to spend — anything that adds
    /// vertical padding to `RailItemLabel` fails here first.
    @MainActor
    @Test("Every rail item fits the row the scroll clips it to")
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
        // **`410` is not `24`.** The model charged a flat two-digit figure per badge, and the
        // ~8pt-per-badge shortfall that opened up on a three-digit count is part of why the
        // Duplicates row truncated while the arithmetic reported room.
        #expect(OrganizeRailMetrics.badgeWidth(410, scale: 1)
                > OrganizeRailMetrics.badgeWidth(24, scale: 1))
        #expect(OrganizeRailMetrics.leadingWidth(scale: 1,
                                                 state: Self.states([.duplicates: 410]))
                > OrganizeRailMetrics.leadingWidth(scale: 1,
                                                   state: Self.states([.duplicates: 24])))
    }

    @Test("The leading model matches what row 1 draws at every text size the app ships",
          arguments: FontSize.allCases)
    func theLeadingModelMatchesWhatTheRowDraws(size: FontSize) throws {
        // **The test the arithmetic was missing, and the reason the truncation shipped.** Every
        // other assertion about the width model compared it against itself, so an estimate could be
        // 63pt short of the row it claimed to describe and still be perfectly self-consistent.
        // This one measures the leading cluster OFF THE RENDER and holds the model to it.
        //
        // It is also the only assertion that would catch a control added beside the rail and left
        // out of the model — the failure that put a 21pt intro button on this side of the row and
        // never charged for it. Every *behavioural* assertion here kept passing through that,
        // because each compared the arithmetic against itself.
        //
        // **Every text size, not just the default**, because the model is a mixture: labels and
        // badges are measured at `11.5 * scale`, glyphs are a table scaled linearly, and the
        // paddings and gaps are flat. Whether that mixture stays honest at 1.3 is a question no
        // arithmetic here can answer. Mutation-checked and worth knowing: a `glyphWidth` that
        // ignores `scale` entirely passes at 0.9, 1.0 and 1.15 and fails **only** at
        // `.extraLarge`, so a single-scale version of this test misses it outright.
        let manager = Self.duplicatesManager(groups: 410, names: 17)
        let host = mount(manager, lens: .duplicates, width: 1400, scale: size.scale)
        let drawn = try #require(leadingExtent(host, width: 1400),
                                 "row 1 drew no leading cluster at \(size.scale)× — the rail is not on screen at all")
        // Post-fold, the 17 risky names ride the RENAMES badge (Names is folded into
        // Renames and off the rail), so the model must be fed what the rail actually draws.
        let model = OrganizeRailMetrics.leadingWidth(
            scale: size.scale,
            state: Self.states([.toFile: 24, .duplicates: 410, .renames: 17]))

        // Measured, model against drawn: 593.6/586.0 at 0.9, 632.2/627.0 at 1.0, 688.5/682.0 at
        // 1.15, 744.2/733.5 at 1.3. Both numbers fell by exactly 21pt at 1.0 when the intro button
        // came off the row, which is the check that the model dropped it along with the render
        // rather than keeping a phantom control in the budget. Over, never under — a model that
        // under-states the leading side is one that lets the row overrun, which is this whole
        // type's failure mode.
        #expect(model >= drawn,
                "at \(size.scale)× the rail draws \(drawn)pt but the model budgets \(model)pt — it is \(drawn - model)pt short, so the row will overrun before it sheds")
        // And not wildly over, or the rail sheds its labels on headers that would have seated them.
        // The widest measured slack is 10.7pt, at 1.3, where the glyph table's linear scaling is
        // furthest from the renderer.
        #expect(model - drawn < 12,
                "at \(size.scale)× the model budgets \(model)pt for a leading side that draws \(drawn)pt — \(model - drawn)pt of slack sheds the labels early")
    }

    @Test("The divider never draws against nothing")
    func theRowTwoDividerIsPairedWithItsControls() throws {
        // `hasRowTwoActions` is a hand-written copy of `lensActions`'s own gates — a `@ViewBuilder`
        // cannot be asked whether it produced anything, so the divider's condition had to be
        // restated. **A restated condition is one edit away from disagreeing with the original**,
        // and the visible cost of disagreement is a hairline floating against an empty band: the
        // exact "rule separating prose from the card edge" this file rejected once already.
        //
        // Asserted at the two states that differ, on a band narrow enough that a 1pt rule is a
        // large share of it — a wide band would drown the divider in the readout beside it.
        let edge = { (w: CGFloat) in CGRect(x: w - 60, y: 48, width: 52, height: 26) }
        let width: CGFloat = 1400

        // Before any scan: no controls, and therefore no rule.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .toFile, width: width), edge(width)))
        // **Wash, not ink, and that distinction is the test.** The divider is a 1pt `.quaternary`
        // rule: measured, it registers 56 wash pixels and *zero* ink ones, so an ink assertion here
        // passed the mutation that ungated it — 0 against 0. The faint-fill measure is the only one
        // that can see a hairline at all.
        #expect(counts(never).wash < 20,
                "row 2's trailing edge washed \(counts(never).wash) before any scan — the divider is drawing with no controls beside it")

        // After one: controls, and the rule that separates them from the prose.
        let scanned = try #require(strip(mount(Self.manager(queue: 24, names: 17),
                                               lens: .toFile, width: width), edge(width)))
        #expect(counts(scanned).ink > 100,
                "row 2's trailing edge inked \(counts(scanned).ink) with a finished scan — the controls are not drawing where the divider says they are")
    }

    @Test("A stale readout leaves the row empty — it does not borrow the overview's")
    func aStaleLensDoesNotBorrowTheOverviewsReadout() throws {
        // **The `else` of a compound condition catches both its arms, and that is the bug.**
        // `organizeSummary` read `if let organizeLens, !stale { … } else { overviewSummary }`, so a
        // lens whose list the filing scan republishes — To File, Names, Renames, the three the
        // guard exists for — fell through mid-scan and drew the OVERVIEW's readout ("1 reporting ·
        // 2 clean") underneath a selected lens. Suppressing a stale readout has to leave the row
        // empty; substituting a different answer is worse than the staleness it was avoiding.
        let scanning = Self.manager(queue: 24, names: 17)
        scanning.isSuggestingFiles = true
        let onToFile = try #require(strip(mount(scanning, lens: .toFile), Self.readoutZone))

        // The overview at the same moment DOES draw its readout — that is the non-vacuity half.
        // Without it, "the band is empty" would pass just as well if `overviewSummary` had been
        // deleted outright.
        let onOverview = try #require(strip(mount(scanning, lens: nil), Self.readoutZone))
        #expect(counts(onOverview).ink > 200,
                "the overview drew no readout while a scan was running — this comparison proves nothing")
        #expect(counts(onToFile).ink < counts(onOverview).ink / 2,
                "a selected lens inked \(counts(onToFile).ink) against the overview's \(counts(onOverview).ink) while its own scan was running — it is drawing the overview's readout instead of leaving the row empty")
    }

    @Test("Row 1's reserve seats what row 1 actually draws, at every text size",
          arguments: FontSize.allCases)
    func theRowOneReserveSeatsWhatRowOneDraws(size: FontSize) throws {
        // **The test `searchToggleWidth`'s doc claimed existed, and did not.** The doc named this
        // function as the thing holding the constant to the render; nothing of the sort was ever
        // written, so from the moment the lens controls moved to row 2 the only number row 1
        // reserves has been an unchecked assertion. A citation is not a test, and this suite has
        // the harness to make it one.
        //
        // What it measures: everything row 1 draws to the RIGHT of the rail. Today that is the
        // search toggle `LensHeaderCard` appends itself and nothing else, and the reserve must
        // cover it — with the refine offer showing and a survey report in hand, i.e. the state that
        // used to put three buttons and a sentence up here.
        let manager = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        let width: CGFloat = 1400
        let host = mount(manager, lens: .toFile, width: width, scale: size.scale)

        // The band runs from the rail's end to the card's right edge. `leadingExtent` gives the
        // rail's own extent off the render, so the trailing side is measured relative to what is
        // actually drawn rather than to a hard-coded x — the mistake that let a 300pt band report
        // the caption's absence as truncation.
        let railEnd = try #require(leadingExtent(host, width: width),
                                   "row 1 drew no leading cluster at \(size.scale)× — nothing to measure from")
        let band = CGRect(x: railEnd + 8, y: 12, width: width - railEnd - 16, height: 30)
        let rep = try #require(strip(host, band))

        // Measured as the inked EXTENT, not an ink count: the question is how much width row 1's
        // trailing side consumes, and a count answers a different one (a wide sparse control and a
        // narrow dense one ink alike).
        let drawn = try #require(trailingSpan(rep, bandWidth: band.width),
                                 "row 1's trailing side drew nothing at \(size.scale)× — the search toggle is gone, and this reserve is protecting a control that no longer exists")
        #expect(drawn <= OrganizeRailMetrics.searchToggleWidth,
                "row 1's trailing side draws \(drawn)pt at \(size.scale)× against a reserve of \(OrganizeRailMetrics.searchToggleWidth) — a control has been put back up here and the rail is not being charged for it")
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
            #expect(abs(OrganizeRailMetrics.glyphWidth(lens, scale: 1) - live) < 0.5,
                    "\(lens.symbol) renders \(live)pt but the table says \(OrganizeRailMetrics.glyphWidth(lens, scale: 1)) — the rail is mis-measured by \(live - OrganizeRailMetrics.glyphWidth(lens, scale: 1))pt on this item")
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
        let badge = Self.states([.toFile: 24, .duplicates: 410, .renames: 17])
        // **Swept from 900, not from the rail's own flip point, and the reason is change A.**
        // The two constraints used to be one: the controls shared row 1 with the rail, so the width
        // that first spelled the rail out was exactly the width that had to seat them, and this
        // swept upward from it. They are on row 2 now and the constraints have come apart — row 1
        // spells the rail out from ~633pt, while row 2 needs ~800 for this lens. Sweeping from the
        // rail's threshold would assert something row 2 cannot deliver and never claimed to.
        //
        // 900 is the narrowest card an ordinary window produces, and the truncation this test was
        // written for ran 600–925 and 1050–1225 — squarely inside the band swept here.
        let threshold: CGFloat = 900

        // Right-anchored: the trailing set is right-aligned and fixed-size, so at every width that
        // seats it these bands are pixel-identical. 300pt, because a band wide enough to reach back
        // past the actions catches the RAIL's tail on a narrow canvas and reads that motion as
        // truncation.
        let roomy = mount(manager, lens: .duplicates, width: 2400)
        let reference = try #require(strip(roomy, Self.trailingZone(2400)))

        // A **band**, not the single threshold point: a reserve that is short by a few points puts
        // the truncation just above the flip rather than at it, and one probe would step straight
        // over it. Measured pre-fix, the bad band ran 29pt.
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
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

    @Test("To File seats its own actions at the width it starts spelling the rail out, at every text size",
          arguments: FontSize.allCases)
    func theToFileThresholdSeatsItsOwnActions(size: FontSize) throws {
        // **The same invariant, on the lens the test above does not reach — and it was failing.**
        // `theShedThresholdIsNotOneCharacterTooLate` sweeps Duplicates, whose trailing set is
        // 354pt, and passed. To File's is 436.5–468 once the refine offer is showing (Rescan,
        // `Refine with Claude…`, `File all N confident`, search), against a reserve that was 420
        // for all six lenses — so from its flip point upward the row bought the rail's labels with
        // the buttons' words, and kept doing it for a further 48pt. Nothing about the folder-memory
        // caption was involved: `survey` is nil here.
        //
        // That is what the per-lens trailing reserve was for, before the controls moved to row 2 and it
        // collapsed to ``OrganizeRailMetrics/searchToggleWidth``.
        //
        // **Every text size, and the neighbour above says why a single-scale version is not
        // enough**: a `glyphWidth` that ignored `scale` passed at 0.9, 1.0 and 1.15 and failed only
        // at `.extraLarge`. The reserve carries the same hazard from the other side.
        // The trailing reserve was a flat number *because* the trailing
        // controls are AppKit's and do not follow `appFontScale` — measured at 435.5/436.5/438.5/
        // 441.5 across the four sizes — but nothing about that is enforced by the buttons
        // themselves. Give one of them `scaledFont` and the reserve starts under-counting at 1.3
        // alone, which is precisely the scale this sweep adds.
        let manager = Self.manager(queue: 24, names: 17, refine: true)
        _ = Self.states([.toFile: 24, .renames: 17])
        // From 900 for the reason the neighbour above gives: row 1 and row 2 no longer shed
        // against the same width, and 900 is where real windows start.
        let threshold: CGFloat = 900

        // The reference is taken at the SAME scale: the question is whether a header at the flip
        // point renders its actions like a roomy one, and a 1× reference would answer a different
        // one at every other size.
        let reference = try #require(strip(mount(manager, lens: .toFile, width: 2400, scale: size.scale),
                                           Self.trailingZone(2400)))
        for offset in stride(from: 0.0, through: 480.0, by: 60.0) {
            let width = (threshold + offset).rounded(.up)
            let host = mount(manager, lens: .toFile, width: width, scale: size.scale)
            // Scaled with the text, because the rail's ink is: the flat 600 that suited 1.0 is a
            // near-miss at 0.9, where the same six spelled-out items paint less of everything.
            let floor = 600 * size.scale * size.scale
            #expect(Double(counts(try #require(strip(host, Self.railZone))).ink) > floor,
                    "at \(width)pt and \(size.scale)× the rail is not spelled out — this probe is measuring the shed state, where nothing has to fit")
            let tight = try #require(strip(host, Self.trailingZone(width)))
            #expect(differingPixels(tight, reference) == 0,
                    "at \(width)pt and \(size.scale)× — \(offset)pt above the width the model starts spelling To File's rail out — the actions render differently from a roomy header, i.e. they are being truncated to buy the labels room")
        }
    }

    // MARK: The folder-memory report is prose, and prose is not on row 1

    /// The survey sentence's band on row 2 — **kept clear of the readout on one side and of the
    /// controls on the other**, which is what makes it about the sentence and nothing else.
    ///
    /// It used to run to the row's right edge, because the right edge was where the sentence ended.
    /// The lens's controls are on this row now and occupy the rightmost ~455pt (To File's set with
    /// the refine offer, plus "N of M" and the divider), so a band anchored at `width - 452` is
    /// almost entirely buttons: measured, it reported the actions' ink and moved with them, which
    /// is how three tests here started answering a question about controls while claiming to be
    /// about prose. This band stops 470pt short of the edge and is 470 wide — the sentence's own
    /// worst case is 485 — so it is a slice of the sentence rather than the whole of it, taken
    /// where nothing else can reach: 190pt ending 470 short of the row's right edge. At the 1400pt
    /// canvas this suite pins these tests to, that is x 740–930 — clear of the controls on one side
    /// and of the leading summary on the other, which on Duplicates runs out to x≈720 and was what
    /// a wider band picked up and reported as the sentence.
    private static func statusZone(_ width: CGFloat) -> CGRect {
        CGRect(x: width - 660, y: 48, width: 190, height: 26)
    }
    /// The width of the **last inked run** on row 2 — the survey sentence, measured rather than
    /// inferred from how much ink a fixed band happens to contain.
    ///
    /// Ink counts cannot answer "was this truncated": a band that catches part of the readout
    /// reports more ink on the narrow canvas than on the wide one, which is the opposite of the
    /// truth. A run's extent is the sentence's own painted width, and a truncated sentence is
    /// simply shorter. Runs break on 20pt of background — wider than any inter-word gap at caption
    /// size, narrower than the reach from the readout across to the trailing edge.
    private func trailingRunOnRowTwo(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = strip(host, CGRect(x: origin, y: 50, width: width - origin - 8, height: 22)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin - 8)
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
            inked.append(n >= 1)
        }
        var runs: [(Int, Int)] = []
        var start: Int?
        var blank = 0
        let gap = Int(20 * scale)
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
        guard let last = runs.filter({ CGFloat($0.1 - $0.0) / scale > 3 }).last else { return nil }
        return CGFloat(last.1 - last.0) / scale
    }

    @Test("A long survey report leaves the actions untouched")
    func theSurveyReportDoesNotTakeTheActionsWords() throws {
        // The reported defect. `FilingSurveyReport.summary` is prose whose length is a property of
        // the last survey — "12 folders changed, 340 documents read, 8 followed a move, 3 left the
        // tree, 5 not downloaded yet." — and drawn on row 1 it took the trailing set from 436.5pt
        // to **921**, so at a 1200pt card the row read `Refine with…` and `File all 24 co…`.
        //
        // Stated as: the report changes nothing about row 1. Same width, same everything else.
        let withReport = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        let without = Self.manager(queue: 24, names: 17, refine: true)
        let width: CGFloat = 1400

        let reported = mount(withReport, lens: .toFile, width: width)
        let quiet = mount(without, lens: .toFile, width: width)

        // **Non-vacuity first, and it is the half that matters here.** The cheapest way to pass
        // this test is to stop drawing the report at all, which would be a worse bug than the one
        // being fixed: the menu item that produced it would go back to looking like it did nothing.
        // So the report has to be ON SCREEN, on row 2, and it has to be the reason that band is
        // inked — hence the comparison against the same header without it.
        let reportedRow2 = counts(try #require(strip(reported, Self.statusZone(width)))).ink
        let quietRow2 = counts(try #require(strip(quiet, Self.statusZone(width)))).ink
        #expect(reportedRow2 > quietRow2 + 500,
                "row 2's trailing zone painted \(reportedRow2) inked pixels with a survey report and \(quietRow2) without — the report is not being drawn there, so every claim below is about a sentence nobody can read")

        #expect(differingPixels(try #require(strip(reported, Self.trailingZone(width))),
                                try #require(strip(quiet, Self.trailingZone(width)))) == 0,
                "the actions render differently with a folder-memory report present — the caption is taking the buttons' words to make room for itself, which is the defect that moved it off row 1 in the first place")
    }

    @Test("The report still says what the survey found, and is not a stub")
    func theSurveyReportSaysItsNumbers() throws {
        // **The move has to carry the meaning, not just the pixels.** The whole reason this line
        // exists is that "Update folder memory" usually changes nothing and would otherwise look
        // like a menu item that does nothing, so a report reduced to an unreadable stub on row 2
        // would be the original complaint back again by a different route — and this suite's
        // founding failure is exactly that: two different labels clipped to identical images while
        // four tests compared them and passed.
        //
        // At 1000, where the sentence is under pressure and truncating: two surveys that differ in
        // their FIRST clause must still render differently.
        //
        // **1000 rather than 800, because the controls moved onto this row.** At 800 the trailing
        // half is the heaviest readout (out to x≈324) and this lens's own controls (455pt back from
        // the edge), which between them leave the sentence nothing — it is squeezed out entirely
        // rather than truncated, and a test asking whether a truncated sentence stays legible has
        // no sentence to ask about. At 1000 it gets ~209pt of the 485 it wants: compressed, drawn,
        // and still carrying its first clause, which is the state this is about.
        let width: CGFloat = 1000
        let other = FileSyncManager.FilingSurveyReport(
            foldersChanged: 7, documentsRead: 91, documentsRelocated: 8, documentsDropped: 3,
            documentsUnavailable: 5, foldersLearned: 96, changed: true)

        let a = try #require(strip(mount(Self.manager(queue: 24, names: 17, survey: Self.longSurvey,
                                                      refine: true, heavyReadout: true),
                                         lens: .toFile, width: width), Self.statusZone(width)))
        let b = try #require(strip(mount(Self.manager(queue: 24, names: 17, survey: other,
                                                      refine: true, heavyReadout: true),
                                         lens: .toFile, width: width), Self.statusZone(width)))
        #expect(counts(a).ink > 500,
                "row 2's status zone painted \(counts(a).ink) inked pixels — the report is not being drawn there at all")
        #expect(differingPixels(a, b) > 0,
                "12 folders changed and 7 folders changed rendered identically — the report is a stub, so moving it here bought nothing")
    }

    @Test("The survey says it is working, on the same row it reports from")
    func theRunningSurveyShowsItsProgressOnRowTwo() throws {
        // **`folderMemoryStatus` has two branches and the move carried both; only one was tested.**
        // The in-flight one is the whole reason the line exists — the menu item reads a few folder
        // mtimes and usually writes nothing, so without visible evidence it ran it looks broken —
        // and it is the branch a careless edit would drop, because the state is transient and
        // nobody sees it while working on the other one.
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

        // And the actions are untouched by a survey being in flight, which is the same claim the
        // finished report has to satisfy — they share this row with it now.
        #expect(differingPixels(try #require(strip(mount(running, lens: .toFile, width: width),
                                                   Self.trailingZone(width))),
                                try #require(strip(mount(idle, lens: .toFile, width: width),
                                                   Self.trailingZone(width)))) == 0,
                "the actions render differently while the folder-memory survey is running — the progress line is taking their words")
    }

    @Test("The report stays inside the filing apparatus it describes")
    func theSurveyReportDoesNotFollowYouToTheOtherLenses() throws {
        // **The gate is the whole of what the move had to preserve, and nothing else pinned it.**
        // On row 1 the status inherited its visibility from `lensActions`' `.rename, .filing` arm;
        // on row 2 that condition had to be written out by hand, and a hand-written copy of an
        // inherited condition is exactly the kind that gets "simplified" later. Folder memory
        // belongs to Filing — a sentence about documents read has nothing to say on Duplicates, and
        // it would be sitting where that lens's own "N of M" goes.
        //
        // Duplicates rather than the overview, deliberately: the overview reaches `lensTrailing`
        // with `effectiveLens == .filing` and SHOULD show it, exactly as it did from row 1.
        let manager = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        manager.duplicateGroups = Self.duplicatesManager(groups: 3, names: 17).duplicateGroups
        manager.hasFoundDuplicates = true
        let width: CGFloat = 1400

        let onDuplicates = counts(try #require(strip(mount(manager, lens: .duplicates, width: width),
                                                     Self.statusZone(width)))).ink
        let onToFile = counts(try #require(strip(mount(manager, lens: .toFile, width: width),
                                                 Self.statusZone(width)))).ink
        #expect(onToFile > 500,
                "the report painted \(onToFile) inked pixels on To File — the fixture is not producing it, so the comparison below proves nothing")
        #expect(onDuplicates < 20,
                "the folder-memory report painted \(onDuplicates) inked pixels on Duplicates — it has escaped the filing apparatus and is describing a scan this lens never ran")
    }

    @Test("The report grows with the app's text size, like everything beside it")
    func theSurveyReportTakesTheAppsTextSize() throws {
        // **Pins `scaledFont`, which a mutation showed nothing else did.** Reverting the report to a
        // plain `.font(.caption)` changed no pixel any other test in this suite looks at, because
        // every one of them renders at 1.0 where the two are identical. It only shows at the top of
        // the range — and it shows as the readout and the "N of M" beside it growing while the
        // sentence explaining them stays put, which is the sort of thing that reads as a rendering
        // bug rather than as a missing modifier.
        //
        // 1400pt so neither render is truncated: a compressed sentence would be measuring the
        // canvas, not the font. Measured 490pt at 1.0 against 630 at 1.3.
        let manager = Self.manager(queue: 24, names: 17, survey: Self.longSurvey, refine: true)
        let plain = try #require(trailingRunOnRowTwo(mount(manager, lens: .toFile, width: 1400),
                                                     width: 1400))
        let large = try #require(trailingRunOnRowTwo(mount(manager, lens: .toFile, width: 1400,
                                                           scale: FontSize.extraLarge.scale),
                                                     width: 1400))
        // A tenth of the 30% the scale asks for — enough that only a genuinely scaling font clears
        // it, loose enough not to pin the exact metrics of a caption.
        #expect(large > plain * 1.03,
                "the survey report painted \(plain)pt wide at 1.0× and \(large)pt at 1.3× — it is not taking the app's text size, so it will sit at 11pt beside a readout that grew")
    }

    @Test("The report is the thing that shortens when row 2 runs out of room")
    func theSurveyReportIsWhatGivesWay() throws {
        // Row 2's leading readout says what the scan found and its trailing "N of M" says how much
        // of it is showing; both describe the list on screen, while this describes a menu action.
        // So when the row is over-subscribed — 309pt of pills against a 490pt sentence at 800 —
        // the sentence is what shortens.
        //
        // **Over-determined, and worth saying so rather than claiming more than it pins.** Deleting
        // `folderMemoryStatus`'s `layoutPriority(-1)` does not break this: `SummaryRun` is
        // `.fixedSize()` and so is `ofMLabel`, which leaves the sentence the only compressible
        // thing on the row whatever the priorities say. This asserts the rendered outcome, which is
        // what the user gets; the modifier is insurance against either sibling ever becoming
        // flexible, and no test here can hold it while they are not.
        let width: CGFloat = 800
        let heavy = Self.manager(queue: 24, names: 17, survey: Self.longSurvey,
                                 refine: true, heavyReadout: true)
        let heavyQuiet = Self.manager(queue: 24, names: 17, refine: true, heavyReadout: true)

        // The readout occupies x 15–324 either way. A band over it must be pixel-identical with
        // and without a sentence competing for the row.
        let readout = CGRect(x: 8, y: 50, width: 330, height: 22)
        #expect(differingPixels(try #require(strip(mount(heavy, lens: .toFile, width: width), readout)),
                                try #require(strip(mount(heavyQuiet, lens: .toFile, width: width), readout))) == 0,
                "row 2's readout renders differently once a survey report shares the row — the report is outranking the numbers it sits beside, which is backwards")

        // …and it really was tight: the sentence is painted narrower here than where it has room,
        // so the assertion above is about a row that had to give something up rather than a roomy
        // one. Measured 447pt against 490, and the render shows the ellipsis.
        let tight = try #require(trailingRunOnRowTwo(mount(heavy, lens: .toFile, width: width),
                                                     width: width))
        let roomy = try #require(trailingRunOnRowTwo(mount(heavy, lens: .toFile, width: 1400),
                                                     width: 1400))
        #expect(tight < roomy - 20,
                "the report painted \(tight)pt wide at 800 and \(roomy)pt at 1400 — it is not being compressed at all, so nothing here is under pressure and the claim above is untested")
    }

    @Test("The shed rung is narrower than the rail it replaces, by enough to be worth having")
    func theShedRungIsAFallbackWorthFallingBackTo() {
        // **This test used to render the shed rail. It cannot any more, and the reason is worth
        // recording rather than quietly dropping.**
        //
        // Row 1 reserves only the search toggle now, so the rail sheds below ~668pt of card. The
        // harness cannot get there: `LensWorkspaceView` lays its header out at roughly 750pt however narrow
        // the canvas, and below that the leading cluster is *clipped* rather than shed. Measured by
        // sweeping `leadingExtent` down the canvas — 627pt drawn at every width from 1100 to 750,
        // then 685 / 642 / 592 / 542 / 492 at 700 / 650 / 600 / 550 / 500, which is a fixed cluster
        // running off the edge and not a rail that has swapped rungs. A render assertion here would
        // measure clipping and call it shedding.
        //
        // So the rung is asserted where it is still observable — in the arithmetic — and the claim
        // is the one that matters: **the fallback has to be dramatically narrower than what it
        // replaces, or shedding buys nothing.** 315pt against 632 measured. `theShedRuleIsComputed`
        // covers the rule that chooses between them, at 900 and at 600.
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

    @Test("Rescan is there once a scan has run, even with nothing left to file")
    func rescanSurvivesAnEmptyQueue() throws {
        // The reported state: everything filed, findings still standing. The trailing half used to be
        // empty here, because Rescan sat inside the gate that draws "File all".
        let filed = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                       Self.actionsZone))
        #expect(counts(filed).ink > 100,
                "the action band painted nothing with an empty queue beside 17 risky names — Rescan is gated on the queue again")
    }

    @Test("…and is absent before the first scan, where there is nothing to re-scan")
    func rescanIsAbsentBeforeAnyScan() throws {
        // The other direction, and what stops the test above from being satisfied by a button that
        // is simply always drawn.
        //
        // **The pane is on its subject here** — `scanFolder` and `scanTarget` are the same folder —
        // which is what leaves this measuring *Rescan* rather than the moved branch.
        //
        // **On Renames, not To File, and the move matters.** To File now withholds this control
        // before its first scan for a second, independent reason — its setup card owns the
        // invitation, see `theMovedButtonYieldsToTheIntroCard` — so a `.toFile` fixture would pass
        // here whether or not Rescan's own gate survived, which is a test that has quietly stopped
        // testing its own claim. Renames reaches the same gate and has no intro to stand down for,
        // so an empty band there is Rescan's gate and nothing else.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .renames), Self.actionsZone))
        #expect(counts(never).ink < 20,
                "the action band is inked before any scan has completed — Rescan is ungated")
    }

    // MARK: The control — pointing Organize somewhere new

    @Test("Organize “<folder>” draws before the first scan, on the overview")
    func theMovedButtonDrawsBeforeAnyScan() throws {
        // The reported defect, rendered. Nothing scanned, no scope, the pane browsed into a
        // subfolder, standing on "All" — which is where the app now lands, and where no lens's
        // intro card is there to carry the invitation instead. The band was empty: there was no way
        // to aim Organize from its own header without first having aimed it.
        //
        // On the overview, and not on a lens, deliberately: `hasRowTwoActions` gates the whole
        // trailing group and its `.none` arm is the one that returned false for every state.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root/Family/Aditi")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "the overview's trailing band painted nothing with the pane in a subfolder — there is no way to point Organize at what you are browsing")
    }

    @Test("…and stands down on To File, where the setup card is already asking")
    func theMovedButtonYieldsToTheIntroCard() throws {
        // The over-reach in the first cut of this fix. Ungating the moved branch everywhere put
        // `Organize "Aditi"` in the header while To File's pre-scan card underneath it said "File
        // loose files in Aditi" with its own Start button — two invitations naming one folder, and
        // only one of them moves the scope.
        //
        // Same manager and same pane as `theMovedButtonDrawsBeforeAnyScan`; the *only* difference
        // is which rail item is selected, so a band that inks here is the duplicate CTA and nothing
        // else.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Aditi")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink < 20,
                "To File drew a header control before its first scan — the setup card below it is already the invitation, naming the same folder")
    }

    @Test("…but still draws on a lens that has no intro card of its own")
    func theMovedButtonSurvivesOnRenames() throws {
        // The direction that stops `filingIntroOwnsInvitation` from being written as a bare
        // `!hasSuggestedFiling`. Renames shares To File's apparatus but renders an empty
        // `RenamePassLens`, not an invitation — so standing down here would take the button away
        // from a lens with nothing else offering to aim Organize, which is the original bug in a
        // narrower room.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: .renames, providerRoot: "/root", scanTarget: "/root/Family/Aditi")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink > 100,
                "Renames lost the moved button — the stand-down is keyed on the scan flag rather than on To File")
    }

    @Test("The stand-down has something to stand down for")
    func theToFileIntroIsActuallyOnScreen() throws {
        // **The premise `theMovedButtonYieldsToTheIntroCard` rests on, which that test cannot
        // check.** An empty header band is equally what you get if To File's setup card stopped
        // rendering — the stand-down would then be deferring to nothing, and the reported bug would
        // be back on the one lens most likely to be browsed to.
        //
        // **The control is To File AFTER a clean scan, not another lens.** Renames was the
        // original control and lost the job when its pre-scan state became a setup card (P12);
        // Restructure took over and has now lost it the same way, because *every* lens's
        // pre-scan state is that card. A lens picked for drawing less is a control with a
        // shelf life — so this compares the two states of the one lens under test instead, and
        // the difference is exactly the thing being asserted: before a scan To File draws the
        // full invitation, after a clean one it draws a plain empty state.
        let toFile = try #require(strip(
            mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                  lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Aditi"),
            Self.contentZone))
        let scanned = try #require(strip(
            mount(Self.manager(queue: 0, names: 0, hasScanned: true, scanFolder: nil),
                  lens: .toFile, providerRoot: "/root", scanTarget: "/root/Family/Aditi"),
            Self.contentZone))
        let (intro, blank) = (counts(toFile).ink, counts(scanned).ink)
        #expect(intro > blank + 500, """
                To File's pre-scan content inked \\(intro) against \\(blank) once scanned — the \\
                setup card the header stands down for is not on screen.
                """)
    }

    @Test("…and does not, when the pane is at the top of the tree")
    func theMovedButtonIsAbsentAtTheProviderRoot() throws {
        // The direction that keeps the fix honest. Unscoped Organize already answers about
        // everything, so a pane at the provider root has not moved off anything and an offer to
        // "Organize everything" there would be a button that changes nothing — the same
        // fires-on-a-condition-nobody-can-see complaint that took the hidden inbox retarget out.
        //
        // Same fixture as above but for the pane's folder, so the *only* thing this can be reading
        // is `OrganizeAim`'s answer.
        let host = mount(Self.manager(queue: 0, names: 0, hasScanned: false, scanFolder: nil),
                         lens: nil, providerRoot: "/root", scanTarget: "/root")
        let band = try #require(strip(host, Self.trailingZone(Self.canvas.width)))
        #expect(counts(band).ink < 20,
                "the overview drew a control with the pane at the provider root — Organize is offering to re-aim at what it is already aimed at")
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
