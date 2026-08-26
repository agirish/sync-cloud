import AppKit
import SwiftUI
import Testing
@testable import Design

/// The `Radius` / `Space` scales, and the two things that can go wrong with a scale silently:
/// the older names for the same stops drifting away from it, and new raw literals accumulating
/// beside it until there are eleven radii again.
///
/// The value assertions here deliberately pin *relationships* rather than echoing each number —
/// a test reading `6` and finding `6` passes just as happily when `6` is the wrong answer. The
/// one exception is `overlayShadow`, where the literal IS the claim: it has to keep painting what
/// the four call sites painted before they were converted, and the only way to say that is to
/// write down what they used to say.
@Suite struct GeometryScaleTests {

    // MARK: - The scales hold their shape

    @Test func theRadiusScaleAscendsWithNoDuplicateStops() {
        #expect(Radius.all == Radius.all.sorted(), "the stops are not in ascending order")
        #expect(Set(Radius.all).count == Radius.all.count, "two stops carry the same value")
        #expect(Radius.all.allSatisfy { $0 > 0 }, "a corner radius of zero is not a stop")
    }

    @Test func theSpaceScaleAscendsWithNoDuplicateSteps() {
        #expect(Space.all == Space.all.sorted(), "the steps are not in ascending order")
        #expect(Set(Space.all).count == Space.all.count, "two steps carry the same value")
    }

    /// Every gap between adjacent radius stops is big enough to SEE. This is the whole argument
    /// for the scale: 5, 6 and 7 were three stops in everything but name, and no reader could tell
    /// them apart on a chip. Two stops one point apart would recreate exactly that.
    @Test func adjacentRadiusStopsAreFarEnoughApartToDistinguish() {
        for (lower, upper) in zip(Radius.all, Radius.all.dropFirst()) {
            #expect(upper - lower >= 2,
                    "\(lower) and \(upper) are \(upper - lower)pt apart — that is the defect the scale replaced")
        }
    }

    /// The 4pt grid, with the 2pt half-step at the bottom that `xxs` is documented as.
    @Test func theSpaceScaleIsAFourPointGridAboveItsHalfStep() {
        #expect(Space.xxs * 2 == Space.xs, "the half-step is not half of the first whole step")
        for step in Space.all.dropFirst() {
            #expect(step.truncatingRemainder(dividingBy: 4) == 0,
                    "\(step) is not on the 4pt grid")
        }
    }

    // MARK: - The older names cannot drift from the scale

    /// `cardCornerRadius` and `smallCornerRadius` predate the scale and are still spelled that way
    /// at ~10 call sites. They now READ from the scale, and this is what stops someone re-typing a
    /// literal into either one and quietly reintroducing a fifth stop.
    @Test func theOlderRadiusNamesAreTheScaleStops() {
        #expect(LiquidGlass.cardCornerRadius == Radius.card)
        #expect(LiquidGlass.smallCornerRadius == Radius.well)
    }

    // MARK: - Elevation

    /// `overlayShadow` has to keep painting exactly what the setup sheet, the help book, the
    /// destination picker and the settings overlay each wrote inline before they were converted.
    /// The conversion claimed to be invisible; this is the claim.
    @Test func theOverlayShadowIsWhatTheFourPanelsUsedToWriteInline() {
        let shadow = LiquidGlass.overlayShadow
        #expect(shadow.color == Color.black.opacity(0.3))
        #expect(shadow.radius == 30)
        #expect(shadow.x == 0)
        #expect(shadow.y == 8)
    }

    /// An overlay floats over a dimmed window; a card floats over the window's own background.
    /// The order is the point — if they ever meet, the elevation language has collapsed.
    @Test func anOverlayReadsAsHigherThanACard() {
        #expect(LiquidGlass.overlayShadow.radius > LiquidGlass.cardShadow.radius)
        #expect(LiquidGlass.cardShadow.radius > LiquidGlass.subtleShadow.radius)
    }

    /// `.overlayPanelShadow()` must not change what it is applied to beyond the shadow — it
    /// replaced four inline `.shadow(...)` calls, and a shadow does not participate in layout.
    @Test @MainActor func theOverlayShadowModifierDoesNotChangeLayout() {
        let bare = NSHostingView(rootView: Color.clear.frame(width: 120, height: 40))
        let shadowed = NSHostingView(rootView: Color.clear.frame(width: 120, height: 40)
            .overlayPanelShadow())
        #expect(bare.fittingSize == shadowed.fittingSize,
                "the shadow changed the panel's footprint: \(bare.fittingSize) vs \(shadowed.fittingSize)")
    }

    // MARK: - No new strays

    /// **The scale only holds if nothing writes past it.** Before this, 80 call sites hand-wrote a
    /// radius in the 5…11 band and no two neighbours had to agree; the fix is only durable if a
    /// new one fails here rather than being noticed by eye three releases later.
    ///
    /// Scoped to the band the scale actually covers. Radii of 1–4 are bar caps and hairline rules
    /// (a 2pt progress bar's cap is half its height, not a corner) and 12 is a deliberate one-off —
    /// both are documented on `Radius` as out of scope, so flagging them here would be this test
    /// asserting something the design does not claim.
    @Test func noSourceHandWritesARadiusInsideTheScalesBand() throws {
        let sources = try Self.appSwiftSources()
        // `cornerRadius: <digits>` — the literal form. A named constant is exactly what this wants.
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

    /// The scan itself has to be able to fail. A regex that matches nothing would make the test
    /// above pass on any tree at all, which is the failure mode source scans die of.
    @Test func theStrayScanFindsAStrayWhenThereIsOne() throws {
        let literal = try Regex(#"cornerRadius: (\d+)(?![\d.])"#)
        let planted = "            RoundedRectangle(cornerRadius: 9, style: .continuous)"
        let match = try literal.firstMatch(in: planted)
        #expect(match != nil, "the pattern no longer matches a hand-written radius at all")
        #expect(Int(match?[1].substring ?? "") == 9)
        // And that it does NOT fire on the converted form, which is what every call site now reads.
        #expect(try literal.firstMatch(in: "RoundedRectangle(cornerRadius: Radius.well)") == nil,
                "the pattern matches the token form — every converted site would be reported")
    }

    // MARK: - The first-run sheet answers the pointer

    /// **`.buttonStyle(.plain)` means the control draws its own chrome, so AppKit contributes no
    /// hover state at all** — which is what `HoverAffordanceStyle` was built to replace, and what
    /// its own doc comment says it replaces. The 2026-07-25 sweep converted 44 of 46 sites, but
    /// `SetupSheet` was written after it, so the app's FIRST impression was seven controls that
    /// sit inert under the pointer: the accent swatches, "Make primary", "Remove", the person and
    /// place capsules, "Change", and a chip's dismiss glyph.
    ///
    /// Scoped to this one file rather than the whole app because two sites elsewhere are
    /// deliberately unconverted (`TidyGroupCard`'s keeper radio pushes an `NSCursor`;
    /// `DifferencesView`'s count pill gates hover on `hasScanned`), and an app-wide assertion
    /// would need an allow-list — which is a registry, and a registry is exactly what stops
    /// covering the whole set the moment someone adds a file to it.
    @Test func theSetupSheetHasNoChromelessButtonWithoutAHoverAffordance() throws {
        let sheet = try Self.appSwiftSources()
            .first { $0.path.hasSuffix("MacApp/SetupSheet.swift") }
        let path = try #require(sheet, "SetupSheet.swift was not found — the scan cannot prove anything")
        let text = try String(contentsOf: path, encoding: .utf8)

        // Prove the file read is the real one before asserting anything about its absences: an
        // empty or wrong file has no `.plain` in it either, and would pass this silently.
        #expect(text.contains("struct SetupSheet"), "that is not the setup sheet")
        let affordances = text.components(separatedBy: ".buttonStyle(.hoverAffordance(").count - 1
        #expect(affordances >= 7,
                "only \(affordances) hover affordances in the setup sheet — the conversion regressed")

        let plain = text.components(separatedBy: ".buttonStyle(.plain)").count - 1
        #expect(plain == 0,
                "\(plain) chrome-less button(s) in the setup sheet give no hover feedback")
    }

    /// Every app source, with the vacuity guards. Same shape as `SegmentedAccentTests` — `MacApp/`
    /// is a sibling of `Modules/` and in no SPM package, so it has to be added by hand or the
    /// likeliest home for a stray is not scanned at all; and walking `Modules/` for `/Sources/`
    /// rather than each module's own `Sources` sweeps in checked-out dependencies from `.build/`.
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
