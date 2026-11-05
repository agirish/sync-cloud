import AppKit
import SwiftUI
import Testing
@testable import Design

/// A semantic colour used as body text has to be readable as body text. Bare
/// `SemanticColor.caution` is `Color.yellow`, near-invisible as ink on a near-white sheet.
///
/// The ratios are measured here rather than quoted because the obvious fix misses by too little to
/// notice: `AccentFill.deepened` targets what a fill needs to carry a white label, and as coloured
/// ink on a light ground it lands just under the 4.5:1 body-text floor.
@Suite struct SemanticInkContrastTests {

    /// The lightest ground these sentences are drawn on — the Settings sheet.
    static let sheet = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    /// The darkest ground, for the other appearance.
    static let darkSheet = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    static let bodyTextFloor: CGFloat = 4.5

    /// Read from the table, not restated beside it: a hand-written copy would let a new member go
    /// unmeasured with every test still passing. `everySemanticColorMemberIsInTheAllList` proves
    /// the list is the whole set.
    static let semantics: [(String, Color)] = SemanticColor.all.map { ($0.name, $0.color) }

    private func srgb(_ c: Color) -> NSColor {
        guard let converted = NSColor(c).usingColorSpace(.sRGB) else {
            Issue.record("\(c) has no sRGB representation"); return .white
        }
        return converted
    }
    fileprivate func lum(_ c: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
    private func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (lum(a) + 0.05, lum(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    /// The fixture must reproduce the defect, or the tests below could pass with the fix removed.
    @Test func rawCautionIsUnreadableAsText() {
        let raw = ratio(srgb(SemanticColor.caution), Self.sheet)
        #expect(raw < 2.0, "caution is no longer the near-invisible ink this exists for: \(raw):1")
    }

    /// The fill-target deepening, the obvious thing to reach for, doesn't clear the text floor.
    /// Pinned so nobody folds the text target back into the fill one.
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

    /// The dark side, at the same body-text bar, not the 3:1 glyph bar. Untouched, `move` misses it
    /// on the dark sheet and `error` has nothing to spare, so dark ink goes through
    /// `lightenedForText`.
    @Test func everySemanticColourIsReadableAsInkInDark() {
        for (name, color) in Self.semantics {
            let ink = srgb(AccentFill.lightenedForText(color))
            let r = ratio(ink, Self.darkSheet)
            #expect(r >= Self.bodyTextFloor, "\(name) as body text on the dark sheet is \(r):1")
        }
    }

    /// The fixture must still reproduce what the lift is for, or the test above could pass with
    /// `lightenedForText` returning its input.
    @Test func theRawColoursDoNotAllClearTheDarkTextFloor() {
        let misses = Self.semantics.filter { ratio(srgb($0.1), Self.darkSheet) < Self.bodyTextFloor }
        #expect(!misses.isEmpty,
                "every raw semantic colour now clears the dark text floor; `lightenedForText` may be a no-op")
    }

    /// The lift only ever lightens and leaves a colour already at the floor untouched, mirroring
    /// `deepened`, so the table isn't flattened toward one luminance. Gated on the luminance floor,
    /// as `deepened` is, not a ratio against one sheet: these colours are drawn on several surfaces.
    @Test func theLiftNeverDarkensAndLeavesColoursAtTheFloorAlone() {
        for (name, color) in Self.semantics {
            let raw = srgb(color), lifted = srgb(AccentFill.lightenedForText(color))
            #expect(lum(lifted) >= lum(raw) - 0.0001, "\(name) got darker")
            if lum(raw) >= AccentFill.darkTextLuminance {
                #expect(lifted.redComponent == raw.redComponent
                        && lifted.greenComponent == raw.greenComponent
                        && lifted.blueComponent == raw.blueComponent,
                        "\(name) was already at the floor and was moved anyway")
            }
        }
        // ...and one that genuinely moves, so the loop above cannot pass by the lift doing nothing.
        #expect(lum(srgb(AccentFill.lightenedForText(SemanticColor.move)))
                > lum(srgb(SemanticColor.move)) + 0.05, "the lift is a no-op on the colour it exists for")
    }

    // MARK: - The list is the whole set

    /// `SemanticColor.all` must contain every member, or one added to the type and forgotten in
    /// `all` is measured by nothing. `SemanticColor` is a namespace of static lets, not a
    /// `CaseIterable` enum, so this reads the declarations out of the source file.
    @Test func everySemanticColorMemberIsInTheAllList() throws {
        let source = URL(fileURLWithPath: #filePath)     // …/Design/Tests/DesignTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                 // …/Modules/Design
            .appendingPathComponent("Sources/Design/SemanticColor.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // `public static let <name> = Color.…`: the member declarations, not `all`, which is an
        // array of tuples rather than a Color.
        let declaration = try Regex(#"public static let (\w+) = Color\."#)
        let declared = text.matches(of: declaration).compactMap { $0[1].substring.map(String.init) }

        // Prove the scan found the file and parsed it before asserting about what it did not find.
        #expect(declared.count >= 6, "only \(declared.count) members parsed — the scan did not resolve")
        #expect(declared.contains("neutral"), "the pattern missed a member it should have matched")

        let listed = Set(SemanticColor.all.map(\.name))
        let missing = declared.filter { !listed.contains($0) }
        #expect(missing.isEmpty,
                "declared on SemanticColor but absent from `all`, so nothing measures them: \(missing)")

        // And the other direction: a name in `all` that no longer exists means a stale entry.
        let stale = listed.subtracting(declared)
        #expect(stale.isEmpty, "listed in `all` but not declared on the type: \(stale.sorted())")
    }
}
