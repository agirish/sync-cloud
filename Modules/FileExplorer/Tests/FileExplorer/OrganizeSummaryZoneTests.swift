import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's header card has one rule and one control that used to go missing. Both are pixels.
///
/// **The rule: a capsule is a control.** The summary row carried six tinted capsules of which three
/// were buttons — the focus chips navigate; `10 ready`, `4 new folders` and `4 unsure` do nothing
/// when clicked — and the only way to find out which half was live was to click. The readout is
/// `SummaryRun` now, which draws no capsule at all. Nothing but a render can check that: `SummaryRun`
/// and `StatPill` lay out to nearly the same size, produce the same accessibility label, and swapping
/// one for the other changes no measurement this repo takes except the painted wash.
///
/// **The control: Rescan.** It was nested inside each focus's apply gate, so filing everything left
/// Organize showing `0 to file · 3 risky names · 126 folders to rename` above an empty row 1.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels back out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeSummaryZoneTests {

    private static let canvas = CGSize(width: 900, height: 620)

    /// Row 2, the same band `OrganizeFocusChipTests` uses.
    private static let summaryStrip = CGRect(x: 0, y: 42, width: 900, height: 40)

    /// The focus chips alone, inset from both ends so neither the card's own edge nor the boundary
    /// with the readout falls inside. Measured on the fixture below: the queue chip spans x 14–104,
    /// the names chip 112–236, and the divider that starts the readout sits at ~241.
    private static let chipsZone = CGRect(x: 10, y: 42, width: 220, height: 40)
    /// The readout — divider, scope, and the filing runs — stopping before the row runs out of
    /// content at x≈415.
    private static let readoutZone = CGRect(x: 250, y: 42, width: 165, height: 40)

    /// Row 1's trailing half, **excluding the search toggle** at x≈860–890, which is drawn in every
    /// state and would make this band non-empty no matter what the actions did.
    private static let actionsZone = CGRect(x: 600, y: 12, width: 255, height: 40)

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

    /// The hue goes into the store the view itself reads — the INNERMOST `defaultAppStorage` wins.
    private func mount(_ manager: FileSyncManager) -> NSHostingView<AnyView> {
        let defaults = ScratchDefaults("OrganizeSummaryZoneTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        let subject = TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: "/root/Downloads", onFindDuplicates: {})
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
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
    /// **`wash` is the measurement that separates a capsule from a run of text.** A tinted capsule
    /// covers its whole area in a 14%-opacity fill — a large, soft, uniform departure from the
    /// background. Glyphs and text are the opposite: a small area of near-black `ink`, with a thin
    /// antialiased fringe. So a zone full of capsules reads dense in `wash`, and a zone of the same
    /// words drawn without them reads nearly empty of it however much text is in there.
    ///
    /// Deliberately not a brightness filter: `brightness < 0.90` counts the dark text inside a
    /// capsule and none of the pale wash behind it, which is exactly backwards for this question —
    /// the same mistake `OrganizeFocusChipTests` documents having made.
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

    /// `wash` per point of band width, so two bands of different widths compare directly.
    private func washDensity(_ rep: NSBitmapImageRep, width: CGFloat) -> Double {
        Double(counts(rep).wash) / Double(width)
    }

    // MARK: The rule — a capsule is a control

    @Test("The focus chips wear a capsule and the readout beside them does not")
    func onlyTheControlsWearCapsules() throws {
        let host = mount(Self.manager(queue: 24, names: 17))
        let chips = try #require(strip(host, Self.chipsZone))
        let readout = try #require(strip(host, Self.readoutZone))

        // Staleness guard first, and it is the half that makes the claim mean anything: a band that
        // has drifted off the row paints nothing, and "nothing" satisfies "no capsule" trivially.
        // The readout must be full of TEXT while being empty of WASH — that pairing is only true of
        // words drawn without a capsule behind them.
        let readoutInk = counts(readout).ink
        #expect(readoutInk > 400,
                "the readout band drew only \(readoutInk) inked pixels — it has drifted off the row, and every wash assertion below it is vacuous")

        // Measured on the shipping render: **64.5** wash px per point across the chips against
        // **5.1** across the readout, a 12× gap, with each threshold sitting well clear of both
        // figures rather than tuned against either. Mutation-checked in the direction that matters:
        // putting `StatPill` back on `ready` / `new folders` / `unsure` takes the readout to 33.8
        // and fails this — it does not reach chip density, because the divider and the scope in
        // this band never wore a capsule to begin with, which is exactly why the threshold is 20
        // and not 60.
        let chipDensity = washDensity(chips, width: Self.chipsZone.width)
        let readoutDensity = washDensity(readout, width: Self.readoutZone.width)
        #expect(chipDensity > 40,
                "the focus chips painted \(Int(chipDensity)) wash px/pt — they have lost their capsules, and with them the only thing on this row that says which half is clickable")
        #expect(readoutDensity < 20,
                "the readout painted \(Int(readoutDensity)) wash px/pt — it is wearing capsules again, so `10 ready` looks exactly as pressable as the chips that are")
    }

    @Test("The readout still says its numbers")
    func theReadoutIsNotSimplyGone() throws {
        // The cheapest way to pass the test above is to draw no readout at all. So pin that the
        // readout still tracks the scan: same queue length, different confidence mix, which moves
        // `ready` and `unsure` without changing any chip.
        let allConfident = FileSyncManager()
        allConfident.publishFilingSuggestions((0..<24).map { Self.suggestion("f\($0).pdf", confident: true) })
        allConfident.hasSuggestedFiling = true
        allConfident.filingScanFolder = "/root/Downloads"
        allConfident.riskyNames = (0..<17).map { Self.risky("bad:name\($0).pdf") }
        allConfident.hasScannedNames = true

        let mixed = try #require(strip(mount(Self.manager(queue: 24, names: 17)), Self.readoutZone))
        let clean = try #require(strip(mount(allConfident), Self.readoutZone))
        #expect(counts(mixed).ink != counts(clean).ink,
                "the readout painted the same thing for 24 ready and for 16 ready with 8 unsure — it is not reading the scan")
    }

    // MARK: The control — Rescan outlives the queue

    @Test("Rescan is there once a scan has run, even with nothing left to file")
    func rescanSurvivesAnEmptyQueue() throws {
        // The reported state: everything filed, findings still standing. Row 1 used to be empty
        // here, because Rescan sat inside the gate that draws "File all".
        let filed = try #require(strip(mount(Self.manager(queue: 0, names: 17)), Self.actionsZone))
        #expect(counts(filed).ink > 100,
                "row 1 painted nothing with an empty queue beside 17 risky names — Rescan is gated on the queue again, and there is no way to look at the folder afresh")
    }

    @Test("…and is absent before the first scan, where the intro owns the invitation")
    func rescanIsAbsentBeforeAnyScan() throws {
        // The other direction, and what stops the test above from being satisfied by a button that
        // is simply always drawn. A "Rescan" before any scan describes something that never
        // happened; the intro state's own button is the same call and says so correctly.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false)),
                                       Self.actionsZone))
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
        let full = try #require(strip(mount(Self.manager(queue: 24, names: 17)), Self.actionsZone))
        let rescanOnly = try #require(strip(mount(Self.manager(queue: 0, names: 17)), Self.actionsZone))
        #expect(counts(full).ink > counts(rescanOnly).ink + 200,
                "three controls and one control inked this band almost identically — it is not over the actions")
    }
}
