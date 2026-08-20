import Testing
import SwiftUI
import AppKit
import Design
@testable import SyncCloud

/// The three seams between the text-size setting and the app that only the app target can see:
/// the width the setup card gives its preset row, which tiles that row draws, and the launch call
/// that migrates the stored value out of its old shape.
@Suite struct TextSizeSetupIntegrationTests {

    /// The You step's text-size row fits the card at every text size.
    ///
    /// **`SetupSheetFitTests` cannot answer this.** It measures the step's HEIGHT, and a row whose
    /// tile labels truncate is exactly as tall as one whose labels fit — which is how
    /// "Comfortable" shipped rendered as "Comfor…" on three of five tiles with every suite green.
    ///
    /// **The margin here is wide, and saying so is the point.** Measured: the row wants 192–247pt
    /// across the range against 471–486pt available, because the card is wide and the row takes
    /// the space beside a short label. So this is not a tight bound and must not be read as one —
    /// the truncation it is named for came from a `.frame(width: 232)` on the row, which this test
    /// cannot see and `theSetupFormUsesTheSpecimenTilesAndDoesNotPinTheirWidth` is what guards.
    /// What this holds is the outer bound: that the card is wide enough for the control at all.
    @MainActor
    @Test func theSetupTextSizeRowFitsTheCardAtEveryTextSize() {
        let content = SetupSheetMetrics.contentWidth(
            availableSize: CGSize(width: 1200, height: 740), scale: 1)

        for size in FontSize.allCases {
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
    ///
    /// **Two separate failures, and neither is visible to a layout test.**
    ///
    /// The style is a vocabulary decision: this screen runs on step one of a first launch, before
    /// the person has seen a file list, so "Comfortable" and "Compact" name nothing yet. Switching
    /// it to `.named` renders perfectly well — the card has 471pt for a 399pt row — so no geometry
    /// assertion anywhere would object. It is simply words nobody can read the meaning of yet.
    ///
    /// The fixed width is the one that DID render badly: framed at 232pt the tiles truncated to
    /// "Comfor…", and a truncated row is exactly as tall as an intact one, so the step's own fit
    /// test stayed green through it. A preset row narrower than its content does not shrink far
    /// enough to survive — it truncates — so the rule is that it is never given a fixed width.
    @Test func theSetupFormUsesTheSpecimenTilesAndDoesNotPinTheirWidth() throws {
        let source = try Self.appSource("SetupSheet.swift")
        let call = try #require(source.range(of: "SizePresetRow(fontSize: setupFontSize"))
        let statement = source[call.lowerBound...].prefix(220)

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

    /// The app migrates the stored text size at launch.
    ///
    /// **A source scan, because nothing else can reach this.** `MacApp` belongs to no SPM package,
    /// so only the app target compiles `SyncCloudApp.init`, and the failure mode of dropping this
    /// call is silent in the worst way: `@AppStorage(FontSize.defaultsKey) var percent: Int`
    /// cannot see the legacy `String` the key held for every release before this one, so every
    /// user who had chosen Small, Large or Largest would open the app at 100% and the first write
    /// would make it permanent. Nothing would fail; the size would just be gone.
    @Test func theAppMigratesTheStoredTextSizeAtLaunch() throws {
        let source = try Self.appSource("SyncCloudApp.swift")

        #expect(source.contains("FontSize.migrateLegacyValue()"),
                """
                SyncCloudApp no longer calls FontSize.migrateLegacyValue() at launch — every user \
                with a pre-percentage text size on disk silently reverts to 100%.
                """)

        // And that it runs at LAUNCH rather than somewhere lazy: it has to precede any read, which
        // in practice means `init`. Checked by position, since a call moved into a view's
        // `onAppear` would still satisfy the containment above.
        let initRange = try #require(source.range(of: "init() {"))
        let callRange = try #require(source.range(of: "FontSize.migrateLegacyValue()"))
        #expect(callRange.lowerBound > initRange.lowerBound,
                "the migration call is no longer inside App.init — it must run before any read")
    }

    /// The scan can actually read the app — a scan that silently found nothing would pass both
    /// assertions above.
    @Test func theSourceScanCanActuallyReadTheApp() throws {
        let source = try Self.appSource("SyncCloudApp.swift")
        #expect(source.count > 1000, "SyncCloudApp.swift read as \(source.count) characters")
        #expect(source.contains("struct SyncCloudApp"), "this is not SyncCloudApp.swift")
    }

    @MainActor
    private static func idealWidth(_ view: some View, at size: FontSize) -> CGFloat {
        let host = NSHostingView(rootView: view.appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Reads a file out of `MacApp/`, resolved from this test file's own path so it does not
    /// depend on the working directory a runner happens to use.
    private static func appSource(_ name: String, file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let repo = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("MacApp/\(name)"), encoding: .utf8)
    }
}
