import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The lens points at its own Help page (proposal O14). The book already explains the plan flow
/// and why taking a landing back is not ⌘Z; the reader most in need of that page was the one
/// least likely to go looking for it.
@MainActor
@Suite struct RestructureHelpPointerTests {

    /// A glyph-only control needs a NAME as well as a tooltip — `.help` is the tooltip, and
    /// VoiceOver reads the label.
    @Test func theAffordanceIsNamedAndDescribed() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let pointer = try #require(text.range(of: "private var helpPointer: some View {"))
        let body = String(text[pointer.lowerBound...].prefix(900))
        #expect(body.contains(".accessibilityLabel(\"About Restructure\")"),
                "a glyph-only button with no label is unreadable to VoiceOver")
        #expect(body.contains(".help("), "and the tooltip says what the page covers")
        #expect(body.contains("questionmark.circle"))
    }

    /// nil hides it: a pointer at documentation that goes nowhere is worse than none.
    @Test func noHandlerMeansNoAffordance() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("if let onOpenHelp {"))
    }

    /// Rendered with and without the handler — the strip lays out either way, **and the pointer
    /// is visibly there in one and not the other.** A `fittingSize` closer here passed with the
    /// whole overlay deleted, which is the mutation this exists to catch.
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
