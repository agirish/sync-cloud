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
/// **Both checks are scoped to one view's own modifier chain, and that is load-bearing.** A first
/// version compared the first `.contentShape` anywhere in the body against the first `.padding`
/// anywhere in it, and passed with the bug reintroduced as long as an unrelated `.contentShape` sat
/// earlier — adding one to the scrim, an entirely idiomatic thing to do to a tap target, was enough.
/// Two tokens in the same body say nothing about being in the same chain.
///
/// Helpers come from `OrganizeScopeCallSiteTests`: same target, same directory, and the brace-bounded
/// window and the non-vacuity guards are exactly the things that should not have two owners.
@Suite struct CommandPaletteHitShapeTests {

    private typealias Scan = OrganizeScopeCallSiteTests

    /// The palette's body with whole-line comments stripped, split at the card into the scrim's
    /// half and the card's half.
    ///
    /// Comments are stripped because the body carries a ten-line block that names both
    /// `.contentShape` and `.padding(.top, Self.cardTopInset)` while explaining their order — prose
    /// that would otherwise be matched as if it were the code it describes.
    static func halves() throws -> (scrim: String, card: String) {
        let body = Scan.codeOnly(try Scan.body(of: "    public var body: some View {",
                                               in: try Scan.source("CommandPaletteView.swift")))
        // Anchored on the newline as well as the indent, so `cardStack`/`cardColumn` cannot match a
        // renamed-but-prefixed view and silently move the split.
        let card = try #require(body.range(of: "\n            card\n"),
                                "the palette's body no longer declares `card` at the ZStack's top level — this scan has lost its anchor and would answer about the wrong text")
        return (String(body[..<card.lowerBound]), String(body[card.lowerBound...]))
    }

    @Test func theCardsHitShapeIsTheCardAndNotItsPadding() throws {
        let card = try Self.halves().card
        let shape = try #require(card.range(of: ".contentShape(Rectangle())"),
                                 "the card no longer declares a hit shape at all")
        let padding = try #require(card.range(of: ".padding(.top, Self.cardTopInset)"),
                                   "the card's top inset is gone, or is inline again — see cardTopInset")
        #expect(shape.lowerBound < padding.lowerBound,
                "`.contentShape` is applied after the padding, so the strip above the card is a dead hit target again and clicking there will not dismiss the palette")
    }

    /// The scrim is what the strip above the card must fall through to, so it has to be the thing
    /// carrying the dismissing tap. Without this the test above passes over a palette whose scrim
    /// stopped closing anything.
    ///
    /// Asserted in both directions: on the scrim, and **not** on the card. Ordering alone was not
    /// enough — adding a second `.onTapGesture(perform: onClose)` to the card's own chain left the
    /// first one still ahead of the card and the check still green, while the card consumed taps
    /// meant for its own rows.
    @Test func theScrimStillOwnsTheDismissingTapAndTheCardDoesNot() throws {
        let (scrim, card) = try Self.halves()
        #expect(scrim.contains(".onTapGesture(perform: onClose)"),
                "the scrim no longer dismisses on click — the strip above the card falls through to nothing")
        #expect(!card.contains(".onTapGesture(perform: onClose)"),
                "the card took the dismissing tap as well, so clicking the card or its rows closes the palette")
    }
}
