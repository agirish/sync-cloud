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

    /// Rendered with and without the handler — the strip has to lay out either way.
    @Test func theStripRendersWithAndWithoutThePointer() {
        for handler in [{ }, nil] as [(() -> Void)?] {
            let lens = RestructureLens(
                findings: [], hasProfile: true, folderCount: 3013,
                deadWeight: ["Travel/2019": .empty],
                accent: .blue, onReveal: { _ in }, hasReviewed: true,
                onOpenHelp: handler)
            let hosting = NSHostingView(rootView: lens.frame(width: 660, height: 320))
            hosting.frame = NSRect(x: 0, y: 0, width: 660, height: 320)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0)
        }
    }
}
