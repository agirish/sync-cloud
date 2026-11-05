import Foundation
import Testing
@testable import Design

/// Every raw `.animation(_:value:)` in the app is either converted to `designAnimation` or named
/// here with the reason it is exempt.
///
/// `designAnimation`'s doc names three families deliberately left alone: hover/press ladders,
/// numeric content transitions, and opacity cross-fades on overlays. An audit that lives only in
/// prose can't tell a site that was considered and exempted from one that was missed, so the list
/// is the test: a new raw `.animation` fails here until its author converts it or names its
/// family.
@Suite struct ReduceMotionCoverageScanTests {

    /// Why a raw `.animation` is allowed to stay raw. The cases are the three families in
    /// `designAnimation`'s doc, plus two mechanical ones that are not animations at all.
    enum Exemption: String {
        /// A hover or press ladder: what animates is a colour, and the parts that moved are
        /// already dropped by `HoverAffordanceMetrics` under the setting.
        case hoverOrPressLadder
        /// A numeric content transition: a rolling digit says a number changed, which a user with
        /// the setting on still needs to know.
        case numericContentTransition
        /// An opacity cross-fade on an overlay. A cross-fade is the Reduce Motion answer.
        case overlayCrossFade
        /// The site reads `accessibilityReduceMotion` itself and picks the animation by hand:
        /// honoured, just not through the wrapper.
        case gatedByHand
        /// `.animation(nil, …)`, which suppresses animation rather than adding any.
        case suppression
    }

    /// Keyed by the `value:` expression, which is what distinguishes sites within one file.
    /// Not keyed by line number, which would need editing on every unrelated edit.
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
        "selectedWorkspace": .suppression,            // .animation(nil, …) — a switch snaps (speed audit 11)
        "panesHiddenForCurrentTab": .suppression,     // .animation(nil, …) — a pane toggle snaps
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
                // Sources only (a test may animate whatever it likes), and never the wrapper.
                guard path.contains("/Sources/") || path.contains("/MacApp/") else { continue }
                guard !path.contains(".build/"), !path.hasSuffix("DesignAnimation.swift") else { continue }
                files.append(url)
            }
        }
        return files
    }

    /// `.animation(` occurrences that are real modifier applications, with the `value:` they key on.
    ///
    /// - Comment lines are skipped: this codebase explains a modifier directly above it, and an
    ///   explanation may quote `.animation(value:)` verbatim.
    /// - The call may span lines: `SetupArtwork` writes `.animation(reduceMotion ? nil` with the
    ///   `value:` two lines down, so continuation lines are joined until the `value:` is found.
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

    /// The scan must be able to see an unclassified site, or the assertion above is decoration.
    @Test func theScanFindsAnUnclassifiedSite() {
        // Asserts only that the fixture is seen. Pinning the total would re-report whatever
        // `everyRawAnimationIsClassified` already reports, which reads as two findings.
        let sites = Self.rawAnimationSites() + [(file: "Fixture.swift", value: "somethingBrandNew")]
        let unclassified = sites.filter { Self.exempt[$0.value] == nil }
        #expect(unclassified.contains { $0.value == "somethingBrandNew" })
    }

    /// Every exemption still earns its place: an entry for a site that no longer exists is a stale
    /// permission, and the next reader would take it as precedent.
    @Test func noExemptionIsUnused() {
        let live = Set(Self.rawAnimationSites().map(\.value))
        let unused = Self.exempt.keys.filter { !live.contains($0) }.sorted()
        #expect(unused.isEmpty, "exemption(s) with no matching site left in the app: \(unused)")
    }

    /// These movers use `designAnimation` and must stay that way; the `exempt` table alone can't
    /// express "must not be raw".
    @Test func theConvertedMoversAreNotRawAgain() {
        let live = Set(Self.rawAnimationSites().map(\.value))
        for moved in ["draggingTab", "dragOffset", "RowIdentities(rows: dupGroups)",
                      "RowIdentities(rows: filing)", "isFocused", "barNodes.isEmpty"] {
            #expect(!live.contains(moved),
                    "\(moved) is a raw .animation again — it moves something and must honour Reduce Motion")
        }
    }
}

// MARK: - The other door

/// The same audit for `withAnimation`, which the scan above cannot see at all.
///
/// `.animation(_:value:)` and `withAnimation` are two independent ways to animate. A change inside
/// `withAnimation` carries its own animation into the transaction, and an `.animation(_:value:)`
/// naming the same value overrides it (measured with a probe reading `Transaction.animation`), which
/// is why the inspector is gated though it is toggled inside a `withAnimation`. A mover driven only
/// by `withAnimation` has nothing to override it, so the setting never reaches it and the scan
/// above, with no `.animation(` to read, stays green.
///
/// Keyed by the first thing the closure touches rather than by line number, which would need
/// editing on every unrelated edit.
@Suite struct WithAnimationCoverageScanTests {

    /// Why a raw `withAnimation` is allowed to stay raw.
    enum Exemption: String {
        /// An ancestor applies `.animation(_:value:)`/`designAnimation` to the same value, and that
        /// wins over the transaction's animation. Verified by probe, not by reading the docs.
        case gatedByAModifier
        /// The site resolves its own animation against `accessibilityReduceMotion` before calling:
        /// `SetupArtwork`'s ternaries, `LensWorkspaceView.listSettle`.
        case gatedByHand
        /// `scrollTo` moves the viewport to something the user asked to see. Reduce Motion asks
        /// for less decorative movement, not for navigation to stop.
        case scrollToDestination
        /// Reports rather than travels: a spinner appearing, a countdown draining, a glow fading.
        case reportsRatherThanTravels
        /// An opacity cross-fade, which is the Reduce Motion answer.
        case overlayCrossFade
        /// A hover or press ladder: what animates is a colour.
        case hoverOrPressLadder
    }

    /// Keyed `File.swift/firstTouchedIdentifier`.
    static let exempt: [String: Exemption] = [
        "ContentView+Toolbar.swift/showInspector": .gatedByAModifier,
        "ContentView.swift/showInspector": .gatedByAModifier,
        "ShortcutCommands.swift/showInspector": .gatedByAModifier,

        "SetupArtwork.swift/appeared": .gatedByHand,
        "SetupArtwork.swift/breathe": .gatedByHand,
        "SetupArtwork.swift/caretOn": .gatedByHand,
        "SetupArtwork.swift/drift": .gatedByHand,
        "LensWorkspaceView.swift/setScope": .gatedByHand,

        "DestinationPicker.swift/proxy": .scrollToDestination,
        "FileTreeView.swift/proxy": .scrollToDestination,
        "PaneColumnsView.swift/proxy": .scrollToDestination,
        "LensWorkspaceView.swift/rail": .scrollToDestination,
        "LensWorkspaceView.swift/proxy": .scrollToDestination,

        "ContentView.swift/isScanning": .reportsRatherThanTravels,
        "ContentView.swift/isScanShown": .reportsRatherThanTravels, // the scanning card, the Stop rung
        "OperationBannerView.swift/countdown": .reportsRatherThanTravels,
        "LensWorkspaceView.swift/glow": .reportsRatherThanTravels,

        "SetupModel.swift/screen": .overlayCrossFade,             // the same card, cross-fading
        "ContentView+ResultMessage.swift/isLeft": .overlayCrossFade, // the bar + message edge flip

        "DifferencesView.swift/isCountPillHovered": .hoverOrPressLadder,
    ]

    /// Every `withAnimation(` in the app sources, with the first identifier its closure touches.
    static func sites() -> [(file: String, key: String)] {
        var found: [(String, String)] = []
        for url in ReduceMotionCoverageScanTests.appSources() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // `withAnimation {` counts too: no explicit animation still animates.
                guard let call = trimmed.range(of: "withAnimation") else { continue }
                guard !trimmed.contains("withDesignAnimation") else { continue }

                // The first identifier of its own closure, found by scanning forward from the call,
                // not from the start of the line. A site written inline behind another closure
                // (`? { withAnimation(…) { … } }`) has an earlier `{` on the same line, which would
                // name every such site "withAnimation".
                let afterCall = String(trimmed[call.upperBound...])
                var body = ""
                if let brace = afterCall.range(of: "{") { body = String(afterCall[brace.upperBound...]) }
                var j = i
                while body.trimmingCharacters(in: .whitespaces).isEmpty, j + 1 < lines.count, j - i < 6 {
                    j += 1
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("//") || next.isEmpty { continue }
                    body = next
                }
                var rest = body.trimmingCharacters(in: .whitespaces)
                var ident = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                // Step past control flow: `if pane.isLeft { … }` is animating `pane`, not `if`.
                while ["if", "guard", "let", "var", "for", "switch"].contains(String(ident)) {
                    rest = String(rest.dropFirst(ident.count)).trimmingCharacters(in: .whitespaces)
                    let next = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if next.isEmpty { break }
                    ident = next
                }
                found.append((url.lastPathComponent, "\(url.lastPathComponent)/\(ident)"))
            }
        }
        return found
    }

    @Test func everyWithAnimationIsClassified() {
        let sites = Self.sites()
        #expect(sites.count > 5, "the scan found almost nothing — it has stopped reading the app")

        let unclassified = sites.filter { Self.exempt[$0.key] == nil }
        #expect(unclassified.isEmpty, """
            \(unclassified.count) raw withAnimation site(s) neither use `withDesignAnimation` nor \
            carry a named exemption: \(Set(unclassified.map(\.key)).sorted())
            """)
    }

    /// The list must not outlive what it describes: an entry naming a site that is gone is a
    /// classification nobody can check, and the next reader would trust it.
    @Test func noExemptionNamesASiteThatIsGone() {
        let live = Set(Self.sites().map(\.key))
        let stale = Self.exempt.keys.filter { !live.contains($0) }.sorted()
        #expect(stale.isEmpty, "exemption(s) for withAnimation sites that no longer exist: \(stale)")
    }
}
