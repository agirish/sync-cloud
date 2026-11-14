import Testing
import SwiftUI
import AppKit
import Design
@testable import SyncCloud

/// The two seams between the text-size setting and the app that only the app target can see:
/// the width the setup card gives its preset row, and which tiles that row draws.
@Suite struct TextSizeSetupIntegrationTests {

    /// The You step's text-size row fits the card at every text size; a row whose labels truncate
    /// is as tall as one that fits, so the height measurements can't see it. The outer bound only:
    /// a fixed width on the row is the next test's.
    @MainActor
    @Test(.machinePinned(.layoutMetrics)) func theSetupTextSizeRowFitsTheCardAtEveryTextSize() {
        for size in FontSize.allCases {
            // The card widens with the text setting (`resolvedWidth` is `cardWidth * scale`), so
            // the row at 135% is held against the card at 135%; the unscaled card would report a
            // width the user never sees.
            let content = SetupSheetMetrics.contentWidth(
                availableSize: CGSize(width: 1200, height: 740), scale: size.scale)
            let label = Self.idealWidth(Text("Text size").scaledFont(.callout), at: size)
            let row = Self.idealWidth(
                SizePresetRow(fontSize: .constant(size), density: .constant(.comfortable),
                              style: .specimen),
                at: size)
            // The `Spacer(minLength: 12)` between them.
            let available = content - label - 12

            #expect(row > 0 && label > 0, "a piece laid out to nothing at \(size.percent)%")
            #expect(row <= available,
                    """
                    At \(size.percent)% the You step's preset row wants \(row)pt beside a \
                    \(label)pt label, and the card offers \(available)pt — the tiles truncate.
                    """)
        }
    }

    /// The setup form draws the tiles that do not name a row spacing, and does not pin their width.
    /// Neither failure is visible to a layout test.
    ///
    /// Before the person has seen a file list, "Comfortable" and "Compact" name nothing yet. A fixed
    /// width truncates the tile labels ("Comfor…") without changing the row's height.
    @Test func theSetupFormUsesTheSpecimenTilesAndDoesNotPinTheirWidth() throws {
        let source = try macAppFile("Setup/AppearanceScreen.swift")
        let statement = try #require(Self.expression(containing: "SizePresetRow(fontSize: $fontSize",
                                                    in: source))

        #expect(statement.contains("style: .specimen"),
                """
                The setup form's preset row is no longer using the specimen tiles. The named ones \
                print "Comfortable" and "Compact" on step one of a first launch, before either \
                word means anything: \(statement)
                """)
        #expect(!statement.contains(".frame(width:"),
                """
                The setup form's preset row has been pinned to a fixed width again — that is what \
                truncated the tile labels to "Comfor…": \(statement)
                """)
    }

    /// The whole SwiftUI expression a call belongs to: its own line, plus the modifier lines
    /// chained under it. Not a fixed character window, which would run into the next control's
    /// modifiers or miss one of this call's.
    static func expression(containing needle: String, in source: String) -> String? {
        guard let hit = source.range(of: needle) else { return nil }
        let lines = source[..<hit.lowerBound].components(separatedBy: "\n")
        let startLine = lines.count - 1
        let all = source.components(separatedBy: "\n")
        var collected = [all[startLine]]
        var i = startLine + 1
        while i < all.count, all[i].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            collected.append(all[i])
            i += 1
        }
        return collected.joined(separator: "\n")
    }

    @MainActor
    private static func idealWidth(_ view: some View, at size: FontSize) -> CGFloat {
        let host = NSHostingView(rootView: view.appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
}

/// The source-scan helper, tested on fixtures: a helper that silently answers nothing turns
/// every scan built on it into a test that cannot fail.
@Suite struct SourceScanHelperTests {

    @Test func theExpressionHelperStopsAtTheEndOfTheStatement() {
        let source = """
        HStack {
            Widget(a: 1, b: 2)
                .frame(width: 40)
                .padding(4)
            Other()
                .frame(width: 999)
        }
        """
        let expression = TextSizeSetupIntegrationTests.expression(containing: "Widget(a:", in: source)

        #expect(expression?.contains(".frame(width: 40)") == true, "it dropped the call's own modifier")
        #expect(expression?.contains(".padding(4)") == true)
        // The point of the helper: the next view's frame is not part of this statement.
        #expect(expression?.contains("999") == false,
                "the helper ran past the statement into the next view — the 220-character bug")
        #expect(TextSizeSetupIntegrationTests.expression(containing: "Missing(", in: source) == nil)
    }
}
