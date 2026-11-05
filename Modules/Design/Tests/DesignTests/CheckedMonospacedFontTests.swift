import AppKit
import Testing
@testable import Design

/// `NSFont.monospacedSystemFont` can answer nil, and measuring the toolbar's keycap with that nil
/// aborts the app. These pin both halves of the guard.
@Suite struct CheckedMonospacedFontTests {

    /// The nil AppKit handed back, which Swift's non-optional type cannot otherwise express.
    private let nilFont = unsafeBitCast(Optional<NSFont>.none, to: NSFont.self)

    /// The fallback must measure what the real face does, not merely be fixed-pitch: the keycap
    /// width is charged into the toolbar's reserve, where under-measuring folds it behind the
    /// chevron. The user's fixed-pitch font (Menlo) is 0.4pt narrower here, so it cannot pass this.
    @Test func aNilAnswerFallsBackToTheSameFaceAtTheSameWidth() throws {
        let font = NSFont.fallingBack(from: nilFont, size: 13, weight: .semibold)
        // `#require`, so a nil stops here rather than taking the test process down below.
        try #require(unsafeBitCast(font, to: NSFont?.self) != nil)
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 13)
        // What would crash: measuring with it. A nil here throws inside CoreText and kills the
        // process. The reference is AppKit's own answer, which can be that nil too, so it is
        // checked before anything measures with it.
        let real = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        try #require(unsafeBitCast(real, to: NSFont?.self) != nil, "AppKit answered nil for the reference face")
        for key in ["⌘K", "esc"] {
            #expect((key as NSString).size(withAttributes: [.font: font]).width
                    == (key as NSString).size(withAttributes: [.font: real]).width, "\(key)")
        }
    }

    /// The digits font has the same guard (`ScaledFont.nsFont` measures every count pill with
    /// it): a nil falls back to the system face with equal-width digits, measuring as AppKit's does.
    @Test func aNilDigitsAnswerFallsBackToEqualWidthDigits() throws {
        let font = NSFont.fallingBackToDigits(from: nilFont, size: 16, weight: .semibold)
        try #require(unsafeBitCast(font, to: NSFont?.self) != nil)
        #expect(font.pointSize == 16)
        let real = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        try #require(unsafeBitCast(real, to: NSFont?.self) != nil, "AppKit answered nil for the reference face")
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        // "1" is narrower than "0" in the proportional face, so a fallback without the feature fails here.
        #expect(width("1", font) == width("0", font), "the fallback's digits are proportional")
        for text in ["1", "1234", "410"] {
            #expect(width(text, font) == width(text, real), "\(text)")
        }
        let appKit = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        #expect(NSFont.checkedMonospacedDigitSystemFont(ofSize: 13, weight: .regular) === appKit)
        #expect(NSFont.fallingBackToDigits(from: appKit, size: 13, weight: .regular) === appKit)
    }

    /// The everyday path hands back AppKit's own object, not a copy — `LabelMetrics` keys its
    /// caches on `NSFont` identity, so a lookalike would be a permanent cache miss.
    @Test func aRealAnswerIsReturnedAsIs() {
        let appKit = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        #expect(NSFont.checkedMonospacedSystemFont(ofSize: 13, weight: .semibold) === appKit)
        #expect(NSFont.fallingBack(from: appKit, size: 13, weight: .semibold) === appKit)
    }
}
