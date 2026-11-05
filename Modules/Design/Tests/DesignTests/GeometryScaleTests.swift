import AppKit
import SwiftUI
import Testing
@testable import Design

/// The `Radius` scale, and the two ways a scale fails silently: older names for its stops drifting
/// away from it, and raw literals accumulating beside it.
///
/// The value checks pin relationships rather than echo each number, since a test reading `6` and
/// finding `6` passes just as well when `6` is wrong. The exception is `overlayShadow`, where the
/// literal is the claim: the four panels that share it must keep painting exactly this shadow.
@Suite struct GeometryScaleTests {

    // MARK: - The scales hold their shape

    @Test func theRadiusScaleAscendsWithNoDuplicateStops() {
        #expect(Radius.all == Radius.all.sorted(), "the stops are not in ascending order")
        #expect(Set(Radius.all).count == Radius.all.count, "two stops carry the same value")
        #expect(Radius.all.allSatisfy { $0 > 0 }, "a corner radius of zero is not a stop")
    }

    /// Every gap between adjacent radius stops is big enough to see. Stops one point apart, like
    /// 5, 6 and 7, are one stop in all but name: nobody can tell them apart on a chip.
    @Test func adjacentRadiusStopsAreFarEnoughApartToDistinguish() {
        for (lower, upper) in zip(Radius.all, Radius.all.dropFirst()) {
            #expect(upper - lower >= 2,
                    "\(lower) and \(upper) are \(upper - lower)pt apart — that is the defect the scale replaced")
        }
    }

    // MARK: - The older names cannot drift from the scale

    /// `cardCornerRadius` and `smallCornerRadius` are older names still used at call sites. They
    /// read from the scale, and this stops a literal typed into either from adding a stray stop.
    @Test func theOlderRadiusNamesAreTheScaleStops() {
        #expect(LiquidGlass.cardCornerRadius == Radius.card)
        #expect(LiquidGlass.smallCornerRadius == Radius.well)
    }

    // MARK: - Elevation

    /// `overlayShadow` is the one shadow the setup sheet, the help book, the destination picker and
    /// the settings overlay share, pinned by value so none of them changes look unnoticed.
    @Test func theOverlayShadowIsWhatTheFourPanelsUsedToWriteInline() {
        let shadow = LiquidGlass.overlayShadow
        #expect(shadow.color == Color.black.opacity(0.3))
        #expect(shadow.radius == 30)
        #expect(shadow.x == 0)
        #expect(shadow.y == 8)
    }

    /// An overlay floats over a dimmed window; a card floats over the window's own background.
    /// The order is the point: if they ever meet, the elevation language has collapsed.
    @Test func anOverlayReadsAsHigherThanACard() {
        #expect(LiquidGlass.overlayShadow.radius > LiquidGlass.cardShadow.radius)
        #expect(LiquidGlass.cardShadow.radius > LiquidGlass.subtleShadow.radius)
    }

    /// `.overlayPanelShadow()` must change nothing but the shadow: a shadow takes no part in
    /// layout, so the panel's footprint stays the same.
    @Test @MainActor func theOverlayShadowModifierDoesNotChangeLayout() {
        let bare = NSHostingView(rootView: Color.clear.frame(width: 120, height: 40))
        let shadowed = NSHostingView(rootView: Color.clear.frame(width: 120, height: 40)
            .overlayPanelShadow())
        #expect(bare.fittingSize == shadowed.fittingSize,
                "the shadow changed the panel's footprint: \(bare.fittingSize) vs \(shadowed.fittingSize)")
    }

    // MARK: - No new strays

    /// The scale only holds if nothing writes past it: a hand-written radius in the 5…11 band
    /// fails here instead of being noticed by eye releases later.
    ///
    /// Scoped to the band the scale covers. Radii of 1–4 are bar caps and hairline rules (a 2pt
    /// progress bar's cap is half its height, not a corner) and 12 is a deliberate one-off; `Radius`
    /// documents both as out of scope.
    @Test func noSourceHandWritesARadiusInsideTheScalesBand() throws {
        let sources = try Self.appSwiftSources()
        // `cornerRadius: <digits>`, the literal form. A named constant is what this wants.
        let literal = try Regex(#"cornerRadius: (\d+)(?![\d.])"#)

        var strays: [String] = []
        var scanned = 0
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let match = try literal.firstMatch(in: String(line)),
                      let value = Int(match[1].substring ?? "") else { continue }
                guard (5...11).contains(value) else { continue }
                strays.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Prove the scan actually read something, or an empty `sources` passes this vacuously.
        #expect(scanned > 100, "only \(scanned) files were read — the scan did not resolve")
        let report = strays.prefix(10).joined(separator: "\n")
        #expect(strays.isEmpty,
                "\(strays.count) raw radii inside the scale's band — use a `Radius` stop:\n\(report)")
    }

    /// The scan itself has to be able to fail: a regex that matches nothing would pass the test
    /// above on any tree.
    @Test func theStrayScanFindsAStrayWhenThereIsOne() throws {
        let literal = try Regex(#"cornerRadius: (\d+)(?![\d.])"#)
        let planted = "            RoundedRectangle(cornerRadius: 9, style: .continuous)"
        let match = try literal.firstMatch(in: planted)
        #expect(match != nil, "the pattern no longer matches a hand-written radius at all")
        #expect(Int(match?[1].substring ?? "") == 9)
        // And that it doesn't fire on the token form, which is what every call site reads.
        #expect(try literal.firstMatch(in: "RoundedRectangle(cornerRadius: Radius.well)") == nil,
                "the pattern matches the token form — every converted site would be reported")
    }

    // MARK: - The first-run sheet answers the pointer

    /// With `.buttonStyle(.plain)` the control draws its own chrome and AppKit gives it no hover
    /// state, which `HoverAffordanceStyle` exists to supply. The setup sheet is the app's first
    /// impression, so none of its buttons may sit inert under the pointer.
    ///
    /// Scoped to the setup sheet, not the whole app, because two sites elsewhere are plain on
    /// purpose (`TidyGroupCard`'s keeper radio pushes an `NSCursor`; `DifferencesView`'s count pill
    /// gates hover on `hasScanned`). An app-wide check would need an allow-list, and an allow-list
    /// stops covering the whole set as soon as a file is added.
    @Test func theSetupSheetHasNoChromelessButtonWithoutAHoverAffordance() throws {
        // The sheet is a directory. Scanning only `SetupSheet.swift` would read the host, which
        // draws no button of its own, and report a clean sweep of nothing.
        let files = try Self.appSwiftSources().filter {
            $0.path.contains("/MacApp/Setup/") || $0.path.hasSuffix("MacApp/SetupSheet.swift")
        }
        #expect(files.count >= 10,
                "the setup sheet is \(files.count) file(s) — the scan is looking at the wrong place")
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        // Prove the read is the real one before asserting anything about its absences: an empty or
        // wrong set of files has no `.plain` in it either, and would pass this silently.
        #expect(text.contains("struct SetupSheet"), "that is not the setup sheet")
        #expect(text.contains("struct SetupScreenCard"), "the sheet's chrome was not read")
        let affordances = text.components(separatedBy: ".buttonStyle(.hoverAffordance(").count - 1
        // Where the affordances live: the accent swatch, the two chip rows (people and countries),
        // the name forms, the outline rows in the tree, More options, the found-name chips and the
        // Start-with buttons.
        #expect(affordances >= 8,
                "only \(affordances) hover affordances in the setup sheet — the conversion regressed")

        let plain = text.components(separatedBy: ".buttonStyle(.plain)").count - 1
        #expect(plain == 0,
                "\(plain) chrome-less button(s) in the setup sheet give no hover feedback")
    }

    /// Every app source, with the vacuity guards; same shape as `SegmentedAccentTests`. `MacApp/` is
    /// in no SPM package, so it is added by hand. Each module's own `Sources` is walked, because
    /// searching `Modules/` for `/Sources/` would sweep in dependencies checked out in `.build/`.
    private static func appSwiftSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)      // …/Design/Tests/DesignTests/<this>.swift
            .deletingLastPathComponent()                // …/Design/Tests/DesignTests
            .deletingLastPathComponent()                // …/Design/Tests
            .deletingLastPathComponent()                // …/Modules/Design
            .deletingLastPathComponent()                // …/Modules
            .deletingLastPathComponent()                // …/<repo>

        let modules = repo.appendingPathComponent("Modules")
        var roots = [repo.appendingPathComponent("MacApp")]
        roots += try FileManager.default
            .contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources") }

        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            files += FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        #expect(files.count > 100, "found only \(files.count) app sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("MacApp/SyncCloudApp.swift") },
                "MacApp is not being scanned")
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
