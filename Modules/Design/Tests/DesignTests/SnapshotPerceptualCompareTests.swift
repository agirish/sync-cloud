import AppKit
import SnapshotTesting
import Testing

/// The diffing strategy every snapshot suite in the four packages goes through, driven on images
/// whose difference is known exactly — so a broken compare shows up as a named red here, on CI,
/// instead of as a SIGABRT inside a snapshot suite CI never runs.
///
/// On macOS 27 SnapshotTesting's perceptual compare threw an uncaught ObjC exception on the first
/// image that was not byte-identical to its reference, killing the whole package's test process
/// (`installPerceptualCompareShim` in `SnapshotRendering.swift` has the mechanism). Not
/// `.machinePinned`: nothing here depends on how this Mac rasterises anything — the images are
/// built pixel by pixel.
///
/// Not crashing is only half of it. Each image below takes the perceptual path (none is
/// byte-identical to the reference), and the expectations pin the NUMBER the compare reports, so
/// a shim that let the filter run over the wrong extent would fail here rather than pass quietly.
@Suite @MainActor struct SnapshotPerceptualCompareTests {

    /// The strategy `assertViewSnapshot` uses, with the same tolerances.
    private static let strategy = Diffing<NSImage>.image(precision: 0.99, perceptualPrecision: 0.98)

    /// A 100×100 white image with `changed` pixels painted black, as one 10-wide block in a corner
    /// — so exactly `changed`% of the canvas differs, each by the maximum deltaE.
    ///
    /// A corner block, not whole rows: rows spread the change evenly across x, so an extent of
    /// the wrong WIDTH still averages to the same fraction and the numbers below would pass. A
    /// corner makes every sub-rectangle read a different fraction. (Rows were tried first; a
    /// mutation handing CoreImage a half-width extent survived them.)
    private static func canvas(changed: Int) -> NSImage {
        let side = 100
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32)!
        precondition(changed % 10 == 0, "the block is 10 wide")
        for x in 0..<side {
            for y in 0..<side {
                let ink: CGFloat = x < 10 && y < changed / 10 ? 0 : 1
                rep.setColor(NSColor(deviceRed: ink, green: ink, blue: ink, alpha: 1), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// Runs the diff the way `verifySnapshot` does: reference round-tripped through PNG data.
    private static func diff(changed: Int) -> String? {
        installPerceptualCompareShim()
        let reference = strategy.fromData(strategy.toData(canvas(changed: 0)))
        return strategy.diff(reference, canvas(changed: changed))?.0
    }

    /// Positive control: without this the passing case below could be passing on byte equality,
    /// never reaching the filter that aborted.
    @Test func theImagesUnderTestAreNotByteIdentical() {
        #expect(Self.strategy.toData(Self.canvas(changed: 0)) != Self.strategy.toData(Self.canvas(changed: 50)))
    }

    /// Within tolerance: 0.5% of pixels differ, 99.5% match, above the 99% bar — a pass, reached
    /// through the perceptual path. This is the case that aborted most often in practice, since
    /// ordinary anti-aliasing jitter lands here.
    @Test func aDifferenceInsideTheToleranceIsAPass() {
        #expect(Self.diff(changed: 50) == nil)
    }

    /// Outside tolerance: 3% differ. The compare must come back with a message — an ordinary red —
    /// and the fraction it reports must be the one painted, which it cannot be if `CIAreaAverage`
    /// averaged over anything but the whole image.
    @Test func aDifferenceOutsideTheToleranceIsAnOrdinaryFailureWithTheRightNumbers() throws {
        let message = try #require(Self.diff(changed: 300))
        // Read as numbers: the compare renders through a half-float buffer, so 0.97 comes back
        // as 0.9700012 — a string match would pin the rounding, not the measurement.
        let matching = try #require(Self.number(after: "The percentage of pixels that match ", in: message))
        let perceptual = try #require(Self.number(after: "The lowest perceptual color precision ", in: message))
        #expect(abs(matching - 0.97) < 0.0005, "\(message)")
        // Black on white is the largest deltaE there is, so the worst pixel is ~0% alike.
        #expect(perceptual < 0.01, "\(message)")
    }

    private static func number(after prefix: String, in message: String) -> Double? {
        guard let start = message.range(of: prefix)?.upperBound else { return nil }
        return Double(message[start...].prefix { $0.isNumber || $0 == "." })
    }
}
