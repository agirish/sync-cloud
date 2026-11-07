import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Does the "Save a rule?" offer paint every phrasing the proposer produced, and does the sentence
/// under the chips follow the selection? Checked in pixels: `fittingSize` on a fixed frame sees
/// only the frame, and a caption check passes vacuously with no assistive client attached. The key
/// test is `theSentenceFollowsTheSelection`: the chip label is an abbreviation, and only the
/// sentence says both words are required. Machine-pinned because it reads pixels back from a live
/// renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct RuleOfferPromptTests {

    private static let canvas = CGSize(width: 900, height: 110)
    /// The chip row and the sentence beneath it, clear of the headline and short of the Save / Not
    /// now buttons, which would add a constant to every comparison. The chips ink y 42–62pt, the
    /// sentence y 68–80pt, the buttons start at x≈770; the band is a little wider so a point of
    /// drift can't empty it, and `theBandActuallyContainsThePicker` fails if it does.
    private static let pickerBand = CGRect(x: 0, y: 38, width: 700, height: 26)
    /// The sentence under the chips, alone. Selecting a phrasing also re-tints the chips, so a band
    /// covering both rows would differ even with the sentence hard-wired to `variants[0]`.
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
        // The background matters: without it the content composites against the borderless
        // window's own buffer and every comparison reads zero difference. Never ordered in.
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

    /// Pixels that are not the background, taken as the band's most common colour. Not the corner
    /// pixel: the prompt is a washed card filling the band, so a corner sample counts the whole
    /// wash as ink. Not brightness either: that counts a chip's dark text but not its pale capsule.
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

    /// The band's pixels bucketed at 32 levels per channel, so anti-aliasing noise can't split one
    /// flat wash into many shades. Keyed on the buckets, not a rebuilt `NSColor`: an sRGB colour
    /// never matches `colorAt`'s own colour space, so every pixel would count as ink.
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
        return PixelDiff.differingPixels(a, b, tolerance: 0.02)
    }

    /// The band is a hard-coded rectangle over a laid-out view, which can go stale silently and
    /// leave every comparison below passing over empty card. Two states whose picker differs must
    /// differ inside it.
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

    /// The sentence is the only thing that says both words are required. Wired to `variants[0]` it
    /// renders the same for both selections; wired to the selection, the third phrasing (one word,
    /// no kind) is visibly shorter.
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
