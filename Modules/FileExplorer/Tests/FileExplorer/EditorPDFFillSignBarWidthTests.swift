import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// **Fill & Sign's toolbar at the header's bound**: its narrowest rung — the tools as glyphs on
/// one row, size, ink and the buttons on a second — fits the document column at the smallest
/// window (`EditorPDFHeaderWidthTests.column`) at every text size, and each rung is narrower than
/// the one before, so `ViewThatFits` has something to choose.
@MainActor
@Suite final class EditorPDFFillSignBarWidthTests {
    private let defaults = ScratchDefaults("EditorPDFFillSignBarWidthTests")

    private func width(_ rung: EditorPDFFillSignBar.Rung, scale: CGFloat) -> CGFloat {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        let bar = EditorPDFFillSignBar(fill: fill, tools: EditorPDFTools(), accent: .blue)
            .content(rung)
            .padding(.horizontal, 10)
        return NSHostingView(rootView: bar.environment(\.appFontScale, scale)).fittingSize.width
    }

    @Test func theNarrowestRungFitsTheColumnAtEveryTextSize() throws {
        let narrowest = try #require(EditorPDFFillSignBar.Rung.allCases.last)
        for percent in FontSize.selectablePercents {
            let measured = width(narrowest, scale: FontSize(percent: percent).scale)
            #expect(measured <= EditorPDFHeaderWidthTests.column,
                    "at \(percent)% the narrowest Fill & Sign bar is \(measured)pt, over the \(EditorPDFHeaderWidthTests.column)pt column")
        }
    }

    @Test func eachRungShedsWidth() {
        for percent in FontSize.selectablePercents {
            let widths = EditorPDFFillSignBar.Rung.allCases.map { width($0, scale: FontSize(percent: percent).scale) }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 + 10 },
                    "at \(percent)% the bar's rungs measure \(widths)")
        }
    }
}
