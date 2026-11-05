import Testing
import SwiftUI
import AppKit
import Design
@testable import SyncCloud

/// The three seams between the text-size setting and the app that only the app target can see:
/// the width the setup card gives its preset row, which tiles that row draws, and the launch call
/// that migrates the stored value out of its old shape.
@Suite struct TextSizeSetupIntegrationTests {

    /// The You step's text-size row fits the card at every text size. `SetupSheetFitTests`
    /// measures the step's height, and a row whose tile labels truncate is as tall as one that fits.
    ///
    /// The margin is wide (the row wants roughly half the width available), so this is only the
    /// outer bound: the card is wide enough for the control at all. A fixed width on the row, which
    /// would truncate it, is guarded by `theSetupFormUsesTheSpecimenTilesAndDoesNotPinTheirWidth`.
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
    /// The style is a vocabulary decision: this screen runs on step one of a first launch, before
    /// the person has seen a file list, so "Comfortable" and "Compact" name nothing yet, though
    /// `.named` would fit the card. A fixed width truncates the tile labels ("Comfor…") without
    /// changing the row's height, so the row is never given one.
    @Test func theSetupFormUsesTheSpecimenTilesAndDoesNotPinTheirWidth() throws {
        let source = try Self.appSource("Setup/AppearanceScreen.swift")
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

    /// The app migrates the stored text size at launch. A source scan, because only the app target
    /// compiles `SyncCloudApp.init`. Dropping the call is silent: `@AppStorage(FontSize.defaultsKey)
    /// var percent: Int` cannot see the legacy `String` value, so a user who chose Small, Large or
    /// Largest would open at 100% and the first write would make it permanent.
    @Test func theAppMigratesTheStoredTextSizeAtLaunch() throws {
        let source = try Self.appSource("SyncCloudApp.swift")

        #expect(source.contains("FontSize.migrateLegacyValue()"),
                """
                SyncCloudApp no longer calls FontSize.migrateLegacyValue() at launch — every user \
                with a pre-percentage text size on disk silently reverts to 100%.
                """)

        // And that it runs at launch, before any read, which means `init`. Brace-matched, not
        // compared by position: "later in the file than `init() {`" would also pass a call moved
        // into an `onAppear` or any method declared below.
        let body = try #require(Self.body(ofFirst: "init() {", in: source))
        #expect(body.contains("FontSize.migrateLegacyValue()"),
                "the migration call is no longer inside App.init — it must run before any read")
    }

    /// The scan can actually read the app: one that silently found nothing would pass the negative
    /// assertions above.
    @Test func theSourceScanCanActuallyReadTheApp() throws {
        let source = try Self.appSource("SyncCloudApp.swift")
        #expect(source.count > 1000, "SyncCloudApp.swift read as \(source.count) characters")
        #expect(source.contains("struct SyncCloudApp"), "this is not SyncCloudApp.swift")
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

    /// The body of the first declaration matching `opener`, by brace matching.
    static func body(ofFirst opener: String, in source: String) -> String? {
        guard let start = source.range(of: opener) else { return nil }
        var depth = 0
        var index = source.index(before: start.upperBound)   // the opener's own `{`
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    @MainActor
    private static func idealWidth(_ view: some View, at size: FontSize) -> CGFloat {
        let host = NSHostingView(rootView: view.appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Reads a file out of `MacApp/`, resolved from this test file's own path so it does not
    /// depend on the runner's working directory.
    private static func appSource(_ name: String, file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let repo = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("MacApp/\(name)"), encoding: .utf8)
    }
}

/// The two source-scan helpers, tested on fixtures: a helper that silently answers nothing turns
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

    @Test func theBodyHelperMatchesBracesRatherThanPositions() {
        let source = """
        init() {
            first()
            if condition { nested() }
        }

        func later() {
            afterTheInit()
        }
        """
        let body = TextSizeSetupIntegrationTests.body(ofFirst: "init() {", in: source)

        #expect(body?.contains("first()") == true)
        #expect(body?.contains("nested()") == true, "it closed on the first inner brace")
        // The reason for brace matching: this call is later in the file but not in init.
        #expect(body?.contains("afterTheInit()") == false,
                "the helper swallowed a declaration below init — the positional-compare bug")
        #expect(TextSizeSetupIntegrationTests.body(ofFirst: "nope() {", in: source) == nil)
    }
}
