import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Does the "Save a rule?" offer actually show the phrasings the proposer produced, and does the
/// sentence under the chips follow the selection?
///
/// **Pixels, because nothing else here is open.** The chips are `Text` inside `Button`s inside an
/// `HStack`: `fittingSize` on a view that fills a fixed frame sees the frame, and a caption
/// assertion passes vacuously with no assistive client attached to the test process. The proposer's
/// own suite proves what the variants *are*; this proves the prompt asks for them and paints them.
///
/// The claim that matters most is `theSentenceFollowsTheSelection`: the chip label is an
/// abbreviation (`“tmobile” + “autopay”`), and the sentence beneath is the only thing on screen that
/// says both words are *required*. A sentence wired to `variants[0]` instead of to the selection
/// renders identically for the default and differs for every other choice — which is exactly what
/// this measures.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels back out of a live renderer, the repo-wide
/// marker for a suite that only produces a trustworthy verdict on the recording Mac.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct RuleOfferPromptTests {

    private static let canvas = CGSize(width: 900, height: 110)
    /// The picker row and the sentence beneath it: clear of the headline above, and stopping well
    /// short of the Save / Not now buttons at the trailing edge — those paint in the same rows and
    /// would put a constant in every comparison.
    ///
    /// Measured on the shipping render by dumping which rows change when the selection changes: the
    /// chips ink y 42–62pt and the sentence y 68–80pt; the buttons start at x≈770. The band is a
    /// little wider than the chips on both sides so a point of drift cannot empty it, and
    /// `theBandActuallyContainsThePicker` is the guard that fails if it ever does.
    private static let pickerBand = CGRect(x: 0, y: 38, width: 700, height: 26)
    /// The sentence under the chips, ALONE.
    ///
    /// **Separated because the chip row moves too.** Selecting a different phrasing re-tints and
    /// re-weights the chips, so a band covering both rows registers a difference whether or not the
    /// sentence follows the selection — mutation testing caught exactly that: a sentence hard-wired
    /// to `variants[0]` passed the combined-band version of `theSentenceFollowsTheSelection`.
    private static let sentenceBand = CGRect(x: 0, y: 66, width: 700, height: 16)

    private static func variant(_ conditions: [AutomationCondition], _ chip: String)
    -> AutomationRuleProposer.Variant {
        AutomationRuleProposer.Variant(conditions: conditions, chipLabel: chip)
    }

    /// The shape a memory-backed proposal takes: narrower / balanced / broader.
    private static let threeWay: [AutomationRuleProposer.Variant] = [
        variant([.mentionsAll(["tmobile", "autopay"])], "“tmobile” + “autopay”"),
        variant([.mentionsAll(["tmobile", "autopay"]), .kindIs(.pdf)], "“tmobile” + “autopay” + PDF"),
        variant([.mentionsAll(["tmobile"])], "“tmobile”"),
    ]

    private static func offer(_ variants: [AutomationRuleProposer.Variant]) -> RuleOffer {
        let rule = AutomationRule(name: "T-Mobile", matchMode: .all, conditions: variants[0].conditions,
                                  destinationTemplate: "Home/Utilities/T-Mobile/{year}")
        return RuleOffer(fileName: "DetailedBillApr2025.pdf",
                         proposal: AutomationRuleProposer.Proposal(
                            rule: rule, variants: variants,
                            destinationTemplate: "Home/Utilities/T-Mobile/{year}"))
    }

    private func mount(_ offer: RuleOffer,
                       selected: AutomationRuleProposer.Variant? = nil) -> NSHostingView<AnyView> {
        // A constant binding: the view reads it, and nothing in a unit test can click a SwiftUI
        // Button anyway — the selection is set here and the render is what gets asserted.
        let subject = RuleOfferPromptView(offer: offer, accent: .blue,
                                          variantChoice: .constant(selected),
                                          onSave: {}, onNotNow: {})
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // The window background is not decoration: without one the content composites against the
        // borderless window's own buffer and every comparison reads as zero difference. Never
        // ordered in — the back of an uncovered desktop is still in plain sight.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func band(_ host: NSHostingView<AnyView>, _ rect: CGRect? = nil) -> NSBitmapImageRep? {
        let area = rect ?? Self.pickerBand
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        host.cacheDisplay(in: area, to: rep)
        return rep
    }

    /// Pixels that are not the background.
    ///
    /// **The background is the band's most common colour, not its corner pixel.** This prompt is a
    /// washed card that fills the band, so the corner sample (taken outside the card) made every
    /// pixel of the wash count as ink and returned the same saturated figure — 98,560 of 102,400 —
    /// for one chip and for three. Brightness is no better: a `< 0.90` filter counts the dark text
    /// in a chip and none of the pale capsule behind it.
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        let cells = quantized(rep)
        guard let background = cells.max(by: { $0.value < $1.value })?.key else { return 0 }
        return cells
            .filter { key, _ in
                max(abs(key.r - background.r),
                    max(abs(key.g - background.g), abs(key.b - background.b))) > 1
            }
            .values.reduce(0, +)
    }

    /// The band's pixels bucketed into 32 levels per channel, so anti-aliasing noise does not split
    /// one flat wash into a thousand near-identical shades. Keyed on the buckets rather than on a
    /// reconstructed `NSColor`: rebuilding one in sRGB and comparing it against `colorAt`'s own
    /// colour space matched NOTHING, and every pixel of the band then counted as ink — the same
    /// saturated 112,000 for one chip and for three.
    private func quantized(_ rep: NSBitmapImageRep) -> [Cell: Int] {
        var cells: [Cell: Int] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                cells[Cell(r: Int(c.redComponent * 32), g: Int(c.greenComponent * 32),
                           b: Int(c.blueComponent * 32)), default: 0] += 1
            }
        }
        return cells
    }

    /// One colour bucket: a channel triple at 32 levels each.
    private struct Cell: Hashable {
        let r: Int, g: Int, b: Int
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// The band is a hard-coded rectangle over a laid-out view — the kind of constant that goes
    /// stale silently, leaving every comparison below "passing" over empty card. Pin it against two
    /// states whose PICKER differs and require the band to see the difference.
    @Test func theBandActuallyContainsThePicker() throws {
        let three = try #require(band(mount(Self.offer(Self.threeWay))))
        let one = try #require(band(mount(Self.offer([Self.threeWay[2]]))))
        #expect(inkedPixels(three) > 400, "the picker band is nearly blank — it has drifted off the row")
        #expect(differingPixels(three, one) > 200,
                "the band cannot tell three chips from one — it is not over the picker")
    }

    /// Every phrasing the proposer produced reaches the row. A view that painted only the default
    /// would rasterize these two identically.
    @Test func everyVariantPaintsAChip() throws {
        let one = try #require(band(mount(Self.offer([Self.threeWay[0]]))))
        let two = try #require(band(mount(Self.offer(Array(Self.threeWay.prefix(2))))))
        let three = try #require(band(mount(Self.offer(Self.threeWay))))
        // Chips are added left to right, so each one strictly adds ink to the row.
        #expect(inkedPixels(two) > inkedPixels(one), "a second variant added no chip")
        #expect(inkedPixels(three) > inkedPixels(two), "a third variant added no chip")
    }

    /// **The sentence is the only thing that says both words are required.** Wired to `variants[0]`
    /// rather than to the selection it renders identically here; wired to the selection the third
    /// phrasing (one word, no kind) is visibly shorter than the first.
    @Test func theSentenceFollowsTheSelection() throws {
        let defaulted = try #require(band(mount(Self.offer(Self.threeWay), selected: Self.threeWay[0]),
                                          Self.sentenceBand))
        let broader = try #require(band(mount(Self.offer(Self.threeWay), selected: Self.threeWay[2]),
                                        Self.sentenceBand))
        // Non-vacuity first: a band that had drifted off the sentence would report 0 ink and 0
        // difference, and "the sentence never changes" reads the same as "there is no sentence".
        #expect(inkedPixels(defaulted) > 200, "the sentence band is blank — it has drifted off the text")
        #expect(differingPixels(defaulted, broader) > 100,
                "picking the broader phrasing left the sentence saying the same thing")
    }

    /// No selection yet — the state the prompt opens in — shows the default, not an empty row. A
    /// `variantChoice` of nil that fell through to "nothing selected" would drop the sentence and
    /// leave every chip unringed.
    @Test func noSelectionRendersTheDefault() throws {
        let unset = try #require(band(mount(Self.offer(Self.threeWay), selected: nil)))
        let explicit = try #require(band(mount(Self.offer(Self.threeWay), selected: Self.threeWay[0])))
        #expect(differingPixels(unset, explicit) == 0,
                "the opening state does not match the default phrasing")
    }
}
