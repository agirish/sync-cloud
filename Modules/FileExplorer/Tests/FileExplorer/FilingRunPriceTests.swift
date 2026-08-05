import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The rules governing what Organize's setup card may claim about cost. Every one of these is a
/// statement about honesty rather than formatting: the button is the thing that spends money, so
/// a number on it that is wrong, or missing when it should be there, is the whole defect.
@Suite struct FilingRunPriceTests {

    private func entry(cost: Double = 0.1843, files: Int = 150,
                       model: String = "claude-opus-5") -> FilingSpendEntry {
        FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_800_000_000), model: model,
                         fileCount: files, placedCount: files - 19, inputTokens: 10_165,
                         outputTokens: 5_339, cacheReadTokens: 0, cacheCreationTokens: 0,
                         estimatedCostUSD: cost)
    }

    @Test func onDeviceQuotesNothingAtAll() {
        // The free backend must not carry a price. "≈ $0.00" reads as a rounding error rather
        // than as "this costs nothing", and there is no question being asked to answer.
        let readout = FilingRunPrice.readout(cloudEnabled: false, last: entry())
        #expect(readout.buttonSuffix == nil)
        #expect(readout.detail == nil)
    }

    @Test func onDeviceStaysSilentEvenWithNoHistory() {
        let readout = FilingRunPrice.readout(cloudEnabled: false, last: nil)
        #expect(readout.buttonSuffix == nil)
        #expect(readout.detail == nil)
    }

    @Test func aFirstCloudRunNamesNoNumber() {
        // Nothing has run, so any figure would be invented. The button stays plain — but the card
        // still says the run is billed, because "no price shown" must not read as "free".
        let readout = FilingRunPrice.readout(cloudEnabled: true, last: nil)
        #expect(readout.buttonSuffix == nil)
        let detail = try! #require(readout.detail)
        #expect(detail.contains("billed"))
        #expect(!detail.contains("$"))
    }

    @Test func aRecordedRunPutsItsCostOnTheButton() {
        let readout = FilingRunPrice.readout(cloudEnabled: true, last: entry(cost: 0.1843))
        let suffix = try! #require(readout.buttonSuffix)
        #expect(suffix.contains("$0.18"))
        // "last run" is what stops the figure reading as a quote for the button beneath it.
        #expect(suffix.contains("last run"))
    }

    @Test func theDetailSaysWhichRunAndThatThisFolderMayDiffer() {
        // The spend store records cost per API call and NOT which folder it was for, so the
        // figure is the last cloud call wherever it pointed. The card has to say so, or it is
        // quietly presenting an unrelated number as this folder's price.
        let readout = FilingRunPrice.readout(cloudEnabled: true,
                                             last: entry(cost: 0.1843, files: 150, model: "claude-opus-5"))
        let detail = try! #require(readout.detail)
        #expect(detail.contains("150 files"))
        #expect(detail.contains("Opus"))
        #expect(detail.contains("may differ"))
    }

    @Test func theDetailCreditsTheCache() {
        // A repeat scan sends only the files whose suggestions aren't already saved, so quoting
        // the last run's full figure without that caveat overstates what the next one will cost.
        let detail = try! #require(FilingRunPrice.readout(cloudEnabled: true, last: entry()).detail)
        #expect(detail.contains("aren't sent again"))
    }

    @Test func aSingleFileRunReadsAsOneFile() {
        let detail = try! #require(FilingRunPrice.readout(cloudEnabled: true,
                                                          last: entry(files: 1)).detail)
        #expect(detail.contains("1 file"))
        #expect(!detail.contains("1 files"))
    }

    @Test func aSubCentRunKeepsItsPrecision() {
        // `FilingSpendFormat` switches to four decimals under a cent precisely so a cheap run
        // does not render as "~$0.00" — the card must inherit that rather than round it away.
        let suffix = try! #require(FilingRunPrice.readout(cloudEnabled: true,
                                                          last: entry(cost: 0.0037)).buttonSuffix)
        #expect(suffix.contains("0.0037"))
    }

    @Test func theSamplesShowBothOutcomes() {
        // The third sample is the one that earns its place: "no confident home" is a normal
        // result, and meeting it for the first time inside a real list makes it look like a bug.
        #expect(FilingSetupCard.samples.count == 3)
        #expect(FilingSetupCard.samples.contains { !$0.isConfident })
        #expect(FilingSetupCard.samples.contains { $0.isConfident })
    }
}

import AppKit
import SwiftUI

/// Does the price actually reach the screen?
///
/// `FilingRunPriceTests` pins what the model decides; nothing there can tell whether the string
/// ever gets painted. It cannot be asserted through the accessibility tree either — there is no
/// assistive client under `swift test`, so a label assertion passes vacuously. Comparing rendered
/// pixels is the channel that is actually open: if the suffix never reached the button, the priced
/// and unpriced cards would rasterize identically.
@Suite struct FilingSetupCardRenderTests {

    @MainActor
    private func render(_ view: some View, size: CGSize = CGSize(width: 620, height: 460)) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    @MainActor
    private func card(_ suffix: String?) -> some View {
        FilingSetupCard(
            intro: LensIntros.organize(scanTargetName: "TODO"),
            price: FilingRunPrice.Readout(buttonSuffix: suffix, detail: nil),
            accent: .blue,
            onStart: {})
    }

    @MainActor
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent > 0.05 && c.brightnessComponent < 0.92 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    @Test func theCardActuallyPaintsSomething() {
        // Guards the vacuity trap: a card that laid out to the right size but drew nothing would
        // satisfy every other assertion here.
        #expect(inkedPixels(render(card(nil))) > 500)
    }

    @MainActor
    @Test func thePriceChangesWhatIsPainted() {
        // The load-bearing one. Same card, same size, differing only in the suffix the model
        // produced — so any pixel difference can only come from the price reaching the button.
        let plain = inkedPixels(render(card(nil)))
        let priced = inkedPixels(render(card("last run ~$0.18")))
        #expect(priced > plain)
    }
}
