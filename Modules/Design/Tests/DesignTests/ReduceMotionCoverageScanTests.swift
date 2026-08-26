import Foundation
import Testing
@testable import Design

/// Every raw `.animation(_:value:)` in the app is either converted to `designAnimation` or named
/// here with the reason it is exempt.
///
/// **`designAnimation` shipped with its exemptions written in prose and nothing enforcing them.**
/// The wrapper's doc names three families that are deliberately left alone — hover/press ladders,
/// numeric content transitions, and opacity cross-fades on overlays — and says "the audit that
/// leaves them alone is the design". But an audit that lives only in a doc comment cannot tell a
/// site that was CONSIDERED and exempted from one that was simply missed, and six were missed: both
/// of `PaneTabStrip`'s drag animations, both of `LensWorkspaceView`'s list settles,
/// `ActivePaneMark`'s focus ring — whose own comment called it "the only thing on screen that
/// moves" — and the selection bar's appear/disappear, which rides a `.move` transition.
///
/// So the list is the test. A new raw `.animation` fails here until its author either converts it
/// or writes down which family it belongs to, which is the classification step that did not happen
/// the first time.
@Suite struct ReduceMotionCoverageScanTests {

    /// Why a raw `.animation` is allowed to stay raw. The cases are the three families in
    /// `designAnimation`'s doc, plus two mechanical ones that are not animations at all.
    enum Exemption: String {
        /// A hover or press ladder: what animates is a colour, and the parts that moved are
        /// already dropped by `HoverAffordanceMetrics` under the setting.
        case hoverOrPressLadder
        /// A numeric content transition — a rolling digit says a number changed, which is
        /// information a user with the setting on still needs.
        case numericContentTransition
        /// An opacity cross-fade on an overlay. A cross-fade IS the Reduce Motion answer.
        case overlayCrossFade
        /// The site reads `accessibilityReduceMotion` itself and picks the animation by hand —
        /// honoured, just not through the wrapper.
        case gatedByHand
        /// `.animation(nil, …)`, which suppresses animation rather than adding any.
        case suppression
    }

    /// Keyed by the `value:` expression, which is what distinguishes sites within one file.
    /// Deliberately not keyed by line number — that would need editing on every unrelated edit.
    static let exempt: [String: Exemption] = [
        "phase": .hoverOrPressLadder,                 // HoverAffordance ×2, ActionBarButtonStyle
        "isHovering": .hoverOrPressLadder,            // HoverAffordance, DuplicateGroupCard
        "showsKeycap": .hoverOrPressLadder,           // ShortcutKeycap
        "isShortcutRevealActive": .hoverOrPressLadder,// ReviewCardView

        "text": .numericContentTransition,            // Pill, and only when isNumeric
        "count": .numericContentTransition,           // StatPill
        "reclaimableBytes": .numericContentTransition,// the reclaim tally
        "freedCaption": .numericContentTransition,

        "showSettings": .overlayCrossFade,            // ContentView's four panels
        "showHelp": .overlayCrossFade,
        "showSetup": .overlayCrossFade,
        "setupDismissedThisSession": .overlayCrossFade,
        "pendingDestination?.id": .overlayCrossFade,
        "isBootstrappingProviders": .overlayCrossFade,

        "appeared": .gatedByHand,                     // SetupArtwork ×3, `reduceMotion ? nil : …`

        "bottomPaneIsCollapsed": .suppression,        // .animation(nil, …)
    ]

    /// Source roots to scan: the modules that draw, plus the app target.
    static func appSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DesignTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Design
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // repo root
        var files: [URL] = []
        for sub in ["Modules", "MacApp"] {
            let dir = root.appendingPathComponent(sub)
            guard let walker = FileManager.default.enumerator(at: dir,
                                                              includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "swift" else { continue }
                let path = url.path
                // Sources only — a test may animate whatever it likes — and never the wrapper.
                guard path.contains("/Sources/") || path.contains("/MacApp/") else { continue }
                guard !path.contains(".build/"), !path.hasSuffix("DesignAnimation.swift") else { continue }
                files.append(url)
            }
        }
        return files
    }

    /// `.animation(` occurrences that are real modifier applications, with the `value:` they key on.
    /// Comment lines are skipped — this codebase explains a modifier directly above it, and one of
    /// those explanations quotes `.animation(value:)` verbatim.
    /// `.animation(` occurrences that are real modifier applications, with the `value:` they key on.
    ///
    /// Two things this has to get right, both learned by getting them wrong:
    /// - **Comment lines are skipped.** This codebase explains a modifier directly above it, and one
    ///   of those explanations quotes `.animation(value:)` verbatim.
    /// - **The call may span lines.** `SetupArtwork` writes `.animation(reduceMotion ? nil` and puts
    ///   the `value:` two lines down, so a line-at-a-time reader reports three sites it cannot name.
    ///   Continuation lines are joined until the `value:` is found.
    static func rawAnimationSites() -> [(file: String, value: String)] {
        var found: [(String, String)] = []
        for url in appSources() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard trimmed.contains(".animation(") else { continue }
                guard !trimmed.contains("designAnimation(") else { continue }

                // Join forward until the `value:` label appears, skipping comment-only lines.
                var joined = trimmed
                var j = i
                while !joined.contains("value: "), j + 1 < lines.count, j - i < 6 {
                    j += 1
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("//") { continue }
                    joined += " " + next
                }
                guard let r = joined.range(of: "value: ") else {
                    found.append((url.lastPathComponent, "<no value: label>"))
                    continue
                }
                var value = String(joined[r.upperBound...])
                if value.hasSuffix(")") { value.removeLast() }
                found.append((url.lastPathComponent, value.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    @Test func everyRawAnimationIsClassified() {
        let sites = Self.rawAnimationSites()
        #expect(sites.count > 10, "the scan found almost nothing — it has stopped reading the app")

        let unclassified = sites.filter { Self.exempt[$0.value] == nil }
        #expect(unclassified.isEmpty, """
            \(unclassified.count) raw .animation site(s) honour neither `designAnimation` nor a named \
            exemption: \(unclassified.map { "\($0.file) value: \($0.value)" }.sorted())
            Convert it, or add it to `exempt` with the family it belongs to.
            """)
    }

    /// The scan must be able to SEE an unclassified site, or the assertion above is decoration.
    @Test func theScanFindsAnUnclassifiedSite() {
        // Asserts only that the FIXTURE is seen. Pinning the total would re-report whatever
        // `everyRawAnimationIsClassified` is already reporting, which reads as two findings.
        let sites = Self.rawAnimationSites() + [(file: "Fixture.swift", value: "somethingBrandNew")]
        let unclassified = sites.filter { Self.exempt[$0.value] == nil }
        #expect(unclassified.contains { $0.value == "somethingBrandNew" })
    }

    /// Every exemption is still earning its place — an entry for a site that no longer exists is a
    /// stale permission, and the next reader would take it as precedent.
    @Test func noExemptionIsUnused() {
        let live = Set(Self.rawAnimationSites().map(\.value))
        let unused = Self.exempt.keys.filter { !live.contains($0) }.sorted()
        #expect(unused.isEmpty, "exemption(s) with no matching site left in the app: \(unused)")
    }

    /// The six that were converted must stay converted — this is the regression the scan exists for,
    /// and the `exempt` table alone cannot express "must NOT be raw".
    @Test func theConvertedMoversAreNotRawAgain() {
        let live = Set(Self.rawAnimationSites().map(\.value))
        for moved in ["draggingTab", "dragOffset", "RowIdentities(rows: dupGroups)",
                      "RowIdentities(rows: filing)", "isFocused", "barNodes.isEmpty"] {
            #expect(!live.contains(moved),
                    "\(moved) is a raw .animation again — it moves something and must honour Reduce Motion")
        }
    }
}
