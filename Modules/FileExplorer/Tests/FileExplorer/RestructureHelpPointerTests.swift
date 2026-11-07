import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The lens points at its own Help page, which explains the plan flow and why taking a landing
/// back is not ⌘Z: the reader who most needs it is the least likely to go looking.
@MainActor
@Suite struct RestructureHelpPointerTests {

    /// A glyph-only control needs a name as well as a tooltip: `.help` is the tooltip, and
    /// VoiceOver reads the label.
    @Test func theAffordanceIsNamedAndDescribed() throws {
        let text = try SourceText.fileExplorer("RestructureLens.swift")
        let body = try SourceText.block(opening: "private var helpPointer: some View {", in: text)
        #expect(body.contains(".accessibilityLabel(\"About Restructure\")"),
                "a glyph-only button with no label is unreadable to VoiceOver")
        #expect(body.contains(".help("), "and the tooltip says what the page covers")
        #expect(body.contains("questionmark.circle"))
    }

    /// Rendered with and without the handler: the strip lays out either way, and the pointer is
    /// visibly there in only one, since nil hides it (a pointer at documentation that goes nowhere
    /// is worse than none). Deleting the overlay must fail it.
    @Test func theStripRendersWithAndWithoutThePointer() throws {
        func lens(_ handler: (() -> Void)?) -> RestructureLens {
            RestructureLens(
                findings: [], hasProfile: true, folderCount: 3013,
                deadWeight: ["Travel/2019": .empty],
                accent: .blue, onReveal: { _ in }, hasReviewed: true,
                onOpenHelp: handler)
        }
        let without = try #require(RestructureRender.raster(lens(nil), width: 660, height: 320))
        let with = try #require(RestructureRender.raster(lens({ }), width: 660, height: 320))
        #expect(RestructureRender.inkedPixels(without) > 1000, "the strip drew either way")
        #expect(RestructureRender.differingPixels(without, with) > 20,
                "the pointer is drawn when there is somewhere for it to go")
    }
}
