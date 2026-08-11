import Testing
import Foundation
@testable import FileExplorer

/// Where the palette's card stops taking clicks.
///
/// **A source scan, because this one genuinely cannot be measured.** The question is whether a
/// click in the strip above the card hits the card or the scrim, and both are SwiftUI:
/// `NSHostingView.hitTest` does not decompose either into a view of its own, so it answers "the
/// hosting view" whichever is true. This repo has already written that test and deleted it —
/// `ShortcutKeycap`'s `allowsHitTesting(false)` carries the note — because it passed with the line
/// removed and was proving nothing. A scan that reads the modifier order at least fails when the
/// order changes, which is the whole of the defect.
///
/// The defect: `.contentShape(Rectangle())` applied **after** `.padding(.top, …)` makes the hit
/// region the padded frame — a 620×96pt invisible block directly above the card that swallowed
/// every click in it. Reported from the running app in exactly those terms: the title bar dismissed
/// the palette on the left and on the right, and not immediately above it.
///
/// ## Four ways an earlier version of this suite passed with the bug present, each mutation-measured
///
/// - It compared the first `.contentShape` *anywhere in the body* against the first `.padding`
///   anywhere in it, so adding a `.contentShape` to the scrim — idiomatic on a tap target — let the
///   real defect back in. Both checks are now scoped to **one view's own chain**.
/// - It asserted only that `.contentShape` precedes the padding, so anything hit-testable appended
///   *after* the padding (`.background(Color.clear)`, a second `.contentShape`, an `.onTapGesture`)
///   restored the same dead strip. The padding must now be **last** in the card's chain.
/// - Its "the card does not take the tap" check forbade one spelling — `.onTapGesture { onClose() }`
///   sailed through — and looked only inside `body`, so a tap attached inside `private var card`,
///   the most natural place for one, was invisible. It now asserts the **capability** across both.
/// - `body(of:)` took the first match, so a second `public var body: some View {` above this one
///   made the whole scan read a decoy. Uniqueness is now asserted in that shared helper.
///
/// Helpers come from `OrganizeScopeCallSiteTests`: same target, same directory, and the
/// brace-bounded window and the non-vacuity guards are exactly the things that should not have two
/// owners.
@Suite struct CommandPaletteHitShapeTests {

    private typealias Scan = OrganizeScopeCallSiteTests

    static func paletteSource() throws -> String { try Scan.source("CommandPaletteView.swift") }

    /// The palette's body with whole-line comments stripped, split at the card into the scrim's
    /// half and the card's half.
    ///
    /// Comments are stripped because the body carries a block that names both `.contentShape` and
    /// `.padding(.top, Self.cardTopInset)` while explaining their order — prose that would otherwise
    /// be matched as if it were the code it describes.
    static func halves(_ source: String) throws -> (scrim: String, card: String) {
        let body = Scan.codeOnly(try Scan.body(of: "    public var body: some View {", in: source))
        // Matched as a whole line rather than as the literal "\n            card\n": a trailing
        // comment or one extra space is behaviour-preserving and used to hard-fail the split.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        // The line's CODE must be exactly `card` — a trailing `// …` is behaviour-preserving and
        // used to hard-fail this split, and `codeOnly` only strips whole-line comments.
        let isCardLine: (Substring) -> Bool = { line in
            line.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces) == "card"
        }
        let cardLine = try #require(lines.firstIndex(where: isCardLine),
                                    "the palette's body no longer declares `card` on its own line at the ZStack's top level — this scan has lost its anchor and would answer about the wrong text")
        // **The card's half ends where the ZStack closes, found by BALANCING BRACES.** Stopping at
        // "the first line that is just `}`" was measured wrong: wrapping the card's chain in a
        // `VStack { … }` made that line the VStack's close, the region ended right after the
        // padding, and a hit-testable `.background` appended to the VStack — the shipped bug — went
        // unseen with all three tests green.
        var depth = 0
        var stackClose: Int?
        for index in cardLine..<lines.count {
            for character in lines[index].prefix(while: { $0 != "/" }) {
                if character == "{" { depth += 1 }
                if character == "}" {
                    if depth == 0 { stackClose = index; break }
                    depth -= 1
                }
            }
            if stackClose != nil { break }
        }
        let close = try #require(stackClose, "no closing brace for the palette's ZStack")
        // Exactly two children, so a third one sweeping into the "card" region fails loudly here
        // rather than being mis-blamed on the card by the assertions downstream.
        let topLevel = lines[..<close].filter { line in
            let code = line.prefix { $0 != "/" }
            return code.hasPrefix("            ") && !code.hasPrefix("             ")
                && !code.trimmingCharacters(in: .whitespaces).hasPrefix(".")
                && !code.trimmingCharacters(in: .whitespaces).isEmpty
        }
        #expect(topLevel.count == 2,
                "the palette's ZStack has \(topLevel.count) top-level children, not the scrim and the card this scan assumes — the split below would attribute a sibling's modifiers to the card")
        return (lines[..<cardLine].joined(separator: "\n"),
                lines[cardLine..<close].joined(separator: "\n"))
    }

    @Test func theCardsHitShapeIsTheCardAndNotItsPadding() throws {
        let card = try Self.halves(try Self.paletteSource()).card
        let shape = try #require(card.range(of: ".contentShape(Rectangle())"),
                                 "the card no longer declares a hit shape at all")
        let padding = try #require(card.range(of: ".padding(.top, Self.cardTopInset)"),
                                   "the card's top inset is gone, or is inline again — see cardTopInset")
        #expect(shape.lowerBound < padding.lowerBound,
                "`.contentShape` is applied after the padding, so the strip above the card is a dead hit target again and clicking there will not dismiss the palette")
    }

    /// ...and nothing may follow the padding, because ordering alone does not close the hole.
    ///
    /// `.contentShape` before `.padding` only makes the strip scrim if the padding is the *end* of
    /// the chain. Any hit-testable modifier appended after it re-inflates the hit region to the
    /// padded frame and restores the exact 620×96pt dead block.
    @Test func nothingHitTestableIsAppliedAfterTheCardsTopInset() throws {
        let card = try Self.halves(try Self.paletteSource()).card
        let padding = try #require(card.range(of: ".padding(.top, Self.cardTopInset)"),
                                   "the card's top inset is gone — see cardTopInset")
        // Inert modifiers are allowed through by name. Demanding *nothing* at all follow the padding
        // was measured over-strict: `.accessibilityLabel("Command palette")` changes no hit region
        // and failed the suite. Anything not on this list is treated as hit-testable, so the default
        // for an unrecognised modifier is to fail — the safe direction for this particular bug.
        let inert = ["accessibility", "help(", "zIndex(", "animation(", "transition(", "id(",
                     "opacity(", "shadow(", "blur(", "compositingGroup("]
        let after = card[padding.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { modifier in !inert.contains { modifier.hasPrefix(".\($0)") } }
        #expect(after.isEmpty,
                "\(after) is applied after the card's top inset; anything hit-testable there re-inflates the hit region to the padded frame and the strip above the card becomes a dead hit target again")
    }

    /// The scrim is what the strip above the card must fall through to, so it has to be the thing
    /// carrying the dismissing tap — and the card must not carry one **in any spelling, anywhere**.
    ///
    /// Asserted as a capability rather than a string: `.onTapGesture { onClose() }` dismisses just
    /// as well as `.onTapGesture(perform: onClose)`, and `private var card` is outside `body`
    /// entirely, so a tap attached there was invisible to the earlier check. Both mutations passed.
    @Test func onlyTheScrimCarriesTheDismissingTap() throws {
        let source = try Self.paletteSource()
        let (scrim, card) = try Self.halves(source)
        #expect(scrim.contains(".onTapGesture(perform: onClose)"),
                "the scrim no longer dismisses on click — the strip above the card falls through to nothing")

        // No *gesture* may sit on the card, in either region, in any spelling — a gesture is the
        // only way a click on the card could reach `onClose`, and forbidding the gesture catches
        // `.onTapGesture { onClose() }` as well as `.onTapGesture(perform: onClose)`.
        //
        // Gestures rather than `onClose`, because `onClose` is legitimately reachable from the
        // keyboard: `.onExitCommand(perform: onClose)` is esc. It happens to live in
        // `private var field`, outside both regions scanned here — an earlier version of this
        // comment placed it in `private var card` and called that "measured", which it was not.
        let cardDeclaration = Scan.codeOnly(try Scan.body(of: "    private var card: some View {", in: source))
        for (region, name) in [(card, "the card's branch of the body"),
                               (cardDeclaration, "`private var card`")] {
            for gesture in ["onTapGesture", "simultaneousGesture", "highPriorityGesture", "TapGesture("] {
                #expect(!region.contains(gesture),
                        "\(name) installs a \(gesture) — if it dismisses, the card and every result row close the palette instead of running, and this scan cannot tell whether it does")
            }
        }
        #expect(!card.contains("onClose"),
                "the card's branch of the body dismisses the palette, so clicking the card closes it")
    }
}
