import AppKit
import SwiftUI
import Testing
@testable import Design

/// **A semantic colour used as body text has to be readable as body text.**
///
/// Found by rendering the People section and looking at the PNG: its one actionable line — the
/// unclaimed-person row — used bare `SemanticColor.caution` as `.foregroundStyle`, which is
/// `Color.yellow`, on a near-white sheet. Everywhere else in this app a caution is a fill behind a
/// wash, and a sibling file says so; four other sites had drifted the same way.
///
/// The numbers are measured here rather than quoted, because the obvious fix is wrong by a margin
/// too small to notice: `AccentFill.deepened` targets what a FILL needs to carry a white label, and
/// re-used for coloured ink on a light ground it lands at 4.17:1 — under the 4.5:1 body-text floor,
/// and close enough to it to look fine in a screenshot.
@Suite struct SemanticInkContrastTests {

    /// The lightest ground these sentences are drawn on — the Settings sheet.
    static let sheet = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    /// The darkest ground, for the other appearance.
    static let darkSheet = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    static let bodyTextFloor: CGFloat = 4.5

    static let semantics: [(String, Color)] = [
        ("caution", SemanticColor.caution), ("warning", SemanticColor.warning),
        ("error", SemanticColor.error), ("success", SemanticColor.success),
        ("info", SemanticColor.info), ("move", SemanticColor.move),
    ]

    private func srgb(_ c: Color) -> NSColor {
        guard let converted = NSColor(c).usingColorSpace(.sRGB) else {
            Issue.record("\(c) has no sRGB representation"); return .white
        }
        return converted
    }
    private func lum(_ c: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
    private func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (lum(a) + 0.05, lum(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    /// **The fixture must reproduce the defect**, or the test below could pass with the fix removed.
    @Test func rawCautionIsUnreadableAsText() {
        let raw = ratio(srgb(SemanticColor.caution), Self.sheet)
        #expect(raw < 2.0, "caution is no longer the near-invisible ink this exists for: \(raw):1")
    }

    /// And the fill-target deepening — the transform already in the app, and the obvious thing to
    /// reach for — does not clear the text floor either. Pinned so nobody "simplifies" the text
    /// target back into the fill one.
    @Test func theFillTargetIsNotEnoughForText() {
        let deep = ratio(AccentFill.deepened(srgb(SemanticColor.caution)), Self.sheet)
        #expect(deep < Self.bodyTextFloor,
                "the fill target now clears the text floor; `deepenedForText` may be redundant")
    }

    @Test func everySemanticColourIsReadableAsInkInLight() {
        for (name, color) in Self.semantics {
            let ink = srgb(AccentFill.deepenedForText(color))
            let r = ratio(ink, Self.sheet)
            #expect(r >= Self.bodyTextFloor, "\(name) as body text on the light sheet is \(r):1")
        }
    }

    /// Dark is untouched on purpose — deepening there fixes one appearance by breaking the other.
    @Test func everySemanticColourStaysReadableInDark() {
        for (name, color) in Self.semantics {
            let r = ratio(srgb(color), Self.darkSheet)
            #expect(r >= 3.0, "\(name) on the dark sheet is \(r):1")
        }
    }
}
