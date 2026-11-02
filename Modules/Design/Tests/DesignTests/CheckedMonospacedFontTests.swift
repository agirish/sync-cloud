import AppKit
import Testing
@testable import Design

/// `NSFont.monospacedSystemFont` answered nil once at launch and the toolbar's keycap measure
/// aborted the app on it. These pin both halves of the guard that took its place.
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
        // What crashed: measuring with it. A nil here throws inside CoreText and kills the process.
        // The reference is AppKit's own answer, which can be that nil too: it took down a full
        // Design run on 2026-11-02, so it is checked before anything measures with it.
        let real = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        try #require(unsafeBitCast(real, to: NSFont?.self) != nil, "AppKit answered nil for the reference face")
        for key in ["⌘K", "esc"] {
            #expect((key as NSString).size(withAttributes: [.font: font]).width
                    == (key as NSString).size(withAttributes: [.font: real]).width, "\(key)")
        }
    }

    /// The everyday path hands back AppKit's own object, not a copy — `LabelMetrics` keys its
    /// caches on `NSFont` identity, so a lookalike would be a permanent cache miss.
    @Test func aRealAnswerIsReturnedAsIs() {
        let appKit = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        #expect(NSFont.checkedMonospacedSystemFont(ofSize: 13, weight: .semibold) === appKit)
        #expect(NSFont.fallingBack(from: appKit, size: 13, weight: .semibold) === appKit)
    }
}
