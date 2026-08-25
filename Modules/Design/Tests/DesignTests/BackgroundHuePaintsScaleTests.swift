import Testing
import Foundation
@testable import Design

/// Every hue paint in the app background answers to the Tint slider.
///
/// **This exists because the alternative was prose.** `LiquidGlassBackground` paints the hue in
/// four separate places — the accent diagonal, Clear's even veil, Clear's titlebar boost, and
/// dark's accent glow — and the change that put them all under the slider described that set in a
/// comment. A comment cannot notice a fifth one. The failure it would hide is specific and quiet:
/// a new accent paint added at full strength would sit at the same opacity whatever the slider
/// said, so Tint 0 would look almost untouched in exactly the configuration the new paint applies
/// to, and every numeric test in `TintCurveTests` would still pass — they test the curve, and the
/// curve would be right.
///
/// So the set is DERIVED from the source rather than listed here. A paint added tomorrow is
/// counted by the same scan that counts today's four, and has to carry the scale or fail.
struct BackgroundHuePaintsScaleTests {

    /// The `LiquidGlassBackground` modifier's source, from its declaration to its closing brace at
    /// column zero.
    private static func backgroundBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DesignTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // Design
            .appendingPathComponent("Sources/Design/LiquidGlassStyle.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "LiquidGlassStyle.swift read as \(text.count) characters — truncated?")
        let start = try #require(text.range(of: "private struct LiquidGlassBackground: ViewModifier {"),
                                 "the background modifier is gone — this scan would be vacuous")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"), "the modifier never closes at column zero")
        return String(rest[..<end.lowerBound])
    }

    /// The argument of every call of `opener`, read to its BALANCED closing parenthesis — the
    /// arguments here contain their own parentheses (`(seeThrough ? … ) * x`), which is exactly
    /// what a `[^)]*` pattern cannot read.
    private static func arguments(of opener: String, in source: String) -> [String] {
        var found: [String] = []
        var search = source.startIndex
        while let start = source.range(of: opener, range: search..<source.endIndex) {
            var depth = 1
            var index = start.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                if depth > 0 { index = source.index(after: index) }
            }
            found.append(String(source[start.upperBound..<index]))
            search = index < source.endIndex ? source.index(after: index) : source.endIndex
        }
        return found
    }

    // MARK: - The premise

    @Test func theScanReadsTheBackgroundModifierAndCouldFail() throws {
        let body = try Self.backgroundBody()
        // Landmarks that have been in this modifier since it was written, so a slice that came back
        // empty or pointed somewhere else cannot report the assertions below as satisfied.
        #expect(body.contains("BehindWindowGlass("))
        #expect(body.contains("backgroundIntensity"))
        #expect(!body.contains("private struct LiquidGlassBackground"), "the slice swallowed its own declaration")
        // And the extractor really reads balanced arguments: one of the four wraps a ternary in
        // parentheses, which is the case a naive scan truncates.
        let arguments = Self.arguments(of: "hue.accentColor.opacity(", in: body)
        #expect(arguments.contains { $0.contains("?") && $0.contains(")") },
                "no argument with a nested parenthesis was read — the extractor may be truncating")
    }

    // MARK: - The invariant

    @Test func everyAccentPaintInTheBackgroundIsScaledByTheTint() throws {
        let body = try Self.backgroundBody()
        let arguments = Self.arguments(of: "hue.accentColor.opacity(", in: body)
        // Derived, not listed: whatever the modifier paints today is what gets checked.
        #expect(arguments.count >= 3,
                "only \(arguments.count) accent paints found — the scan has lost sight of them")
        for argument in arguments {
            #expect(argument.contains("hueStrength"),
                    "an accent paint is not scaled by the tint: opacity(\(argument))")
        }
    }

    @Test func theAccentDiagonalIsScaledByTheTint() throws {
        // The diagonal is the one hue paint that does not go through `accentColor.opacity` — it
        // maps `hue.gradientColors` against its own opacity table — so the scan above cannot see
        // it, and it is the paint that dominates every level but Clear.
        //
        // **Sliced to the end of the statement, not to a line or a character budget.** The first
        // cut of this took "the anchor's line plus the one after it", which read the `.map` only
        // because of where the line happens to break today; re-wrapping the expression would have
        // moved the multiplication out of view and passed.
        let statement = try Self.gradientAssignment()
        let opacities = Self.arguments(of: ".opacity(", in: statement)
        try #require(!opacities.isEmpty,
                     "the diagonal's assignment paints no opacity — re-derive this check")
        for argument in opacities {
            #expect(argument.contains("hueStrength"),
                    "the accent diagonal is not scaled by the tint: opacity(\(argument))")
        }
    }

    /// The whole `gradientColors` assignment — from its `let` to the blank line that ends the
    /// statement group, so the check sees the expression however it is wrapped.
    private static func gradientAssignment() throws -> String {
        let body = try backgroundBody()
        let start = try #require(body.range(of: "let gradientColors = zip(hue.gradientColors, opacities)"),
                                 "the accent diagonal is built differently now — re-derive this check")
        let rest = body[start.lowerBound...]
        let end = try #require(rest.range(of: "\n\n"), "the assignment is no longer followed by a blank line")
        return String(rest[..<end.lowerBound])
    }

    @Test func theStrengthComesFromTheSharedCurve() throws {
        // One source for all of them. Two call sites computing their own floor is how the four
        // paints would drift apart at the low end.
        let body = try Self.backgroundBody()
        #expect(body.contains("LiquidGlass.backgroundHueStrength(forTint: tint)"))
        #expect(body.components(separatedBy: "backgroundHueStrength").count - 1 == 1,
                "the strength is computed more than once — the paints can now disagree")
    }
}
