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
@Suite struct CommandPaletteHitShapeTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/FileExplorer/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/CommandPaletteView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read CommandPaletteView.swift — this scan would be vacuous")
        #expect(text.count > 500, "CommandPaletteView.swift is implausibly short")
        return text
    }

    /// The card's own body, bounded by its closing brace rather than a character count — a fixed
    /// window is a known way for a scan in this repo to answer about the wrong text.
    static func paletteBody(_ source: String) throws -> String {
        let start = try #require(source.range(of: "    public var body: some View {"),
                                 "the palette's body is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for the palette's body")
        return String(rest[..<end.lowerBound])
    }

    @Test func theCardsHitShapeIsTheCardAndNotItsPadding() throws {
        let body = try Self.paletteBody(try Self.source())
        let shape = try #require(body.range(of: ".contentShape(Rectangle())"),
                                 "the card no longer declares a hit shape at all")
        let padding = try #require(body.range(of: ".padding(.top, Self.cardTopInset)"),
                                   "the card's top inset is gone, or is inline again — see cardTopInset")
        #expect(shape.lowerBound < padding.lowerBound,
                "`.contentShape` is applied after the padding, so the strip above the card is a dead hit target again and clicking there will not dismiss the palette")
    }

    /// The scrim is what the strip above the card must fall through to, so it has to be the thing
    /// carrying the dismissing tap. Without this the test above passes over a palette whose scrim
    /// stopped closing anything.
    @Test func theScrimStillOwnsTheDismissingTap() throws {
        let body = try Self.paletteBody(try Self.source())
        let scrimTap = try #require(body.range(of: ".onTapGesture(perform: onClose)"),
                                    "the scrim no longer dismisses on click")
        let card = try #require(body.range(of: "            card"))
        #expect(scrimTap.lowerBound < card.lowerBound,
                "the dismissing tap has moved off the scrim and onto the card")
    }
}
