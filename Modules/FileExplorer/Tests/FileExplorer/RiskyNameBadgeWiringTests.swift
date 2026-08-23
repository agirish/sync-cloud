import Testing
import AppKit
import SwiftUI
import Sync
import Design
@testable import FileExplorer

/// That the badge is actually IN the rows it ships on — the half of the feature nothing was
/// holding.
///
/// **What this exists for.** `RiskyNameBadgePredicateTests` covers the verdict thoroughly, and
/// `theBadgeIsEmptyForACleanName` covers `RiskyNameBadge` rendered on its own. Between them sat the
/// hand-off, and it had no coverage at all: replacing `reason:` with `nil` at BOTH call sites —
/// `FileRowView` (which serves the tree panes and, through `ColumnRowView`, the Columns stack) and
/// `DifferenceNameCell` — left **737 package tests green and `xcodebuild test -scheme SyncCloud`
/// reporting TEST SUCCEEDED**. The feature could be switched off on every surface it ships on and
/// both halves of CI would pass.
///
/// That is the same defect the download cluster had ("mutating the caption to a constant and the
/// ProgressView swap to `if false` left 677 tests green"), so these follow the same remedy: assert
/// what AppKit actually laid out, and prove the assertion could fail.
///
/// **Width, and then pixels.** The width delta catches a row that stopped reserving space for the
/// badge. It cannot catch a badge that reserves space and paints nothing — an `Image(systemName:)`
/// with a name that resolves to no symbol does exactly that — so the caution-colour sample is the
/// second assertion rather than a nicety.
@MainActor
@Suite(.serialized) struct RiskyNameBadgeWiringTests {

    private static let reason = "OneDrive doesn't allow \":\" in names"

    private func rowInfo(name: String) -> FileRowInfo {
        FileRowInfo(FileNode(id: "/root/\(name)", name: name, isDirectory: false, fileSize: 1024))
    }

    private func difference(_ relativePath: String) -> FileDifference {
        FileDifference(relativePath: relativePath,
                       leftItemPath: "/left/\(relativePath)",
                       rightItemPath: "/right/\(relativePath)",
                       type: .missingOnRight,
                       action: .copyToRight,
                       description: "only on the left")
    }

    /// Lays a view out at a generous width and returns what it actually asked for.
    private func fittingWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    // MARK: The pane / Columns row

    /// `FileRowView` is the row both pane presentations render — the tree pane directly, the
    /// Columns stack through `ColumnRowView`. A reason must make the row wider, because the badge
    /// is in it.
    ///
    /// The two rows differ ONLY in `riskyReason`: same node, same name, same density, same fonts.
    /// Varying the name instead would change the text's own width and the delta would prove
    /// nothing about the badge.
    @Test(.machinePinned(.layoutMetrics)) func aPaneRowIsWiderWhenItsNameIsRisky() {
        let node = rowInfo(name: "Q3: final.pdf")
        let badged = fittingWidth(
            FileRowView(node: node, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                        density: .comfortable, riskyReason: Self.reason))
        let plain = fittingWidth(
            FileRowView(node: node, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                        density: .comfortable, riskyReason: nil))

        #expect(plain > 0, "the row did not lay out at all; got \(plain)")
        #expect(badged > plain,
                "a risky name must widen the row by its badge — badged \(badged), plain \(plain)")
    }

    /// The same row at compact density, because the badge takes the pane's resolved fonts and a
    /// density change is exactly the sort of thing that quietly drops a trailing element.
    @Test(.machinePinned(.layoutMetrics)) func aCompactPaneRowCarriesTheBadgeToo() {
        let node = rowInfo(name: "Q3: final.pdf")
        let badged = fittingWidth(
            FileRowView(node: node, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                        density: .compact, riskyReason: Self.reason))
        let plain = fittingWidth(
            FileRowView(node: node, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                        density: .compact, riskyReason: nil))
        #expect(badged > plain, "compact row lost its badge — badged \(badged), plain \(plain)")
    }

    // MARK: The Differences row

    /// `DifferenceNameCell` resolves the reason itself from both panes' rulesets, so this drives
    /// the whole chain on that surface: real name, real ruleset, real badge.
    ///
    /// The ONE name, judged by two rulesets — not two names judged by one. Two names would differ
    /// in text width whatever the badge did (`:` and a space are not the same number of points, and
    /// equal character counts do not make equal widths), so the delta would prove nothing. Holding
    /// the name fixed and moving the ruleset leaves the badge as the only thing that can change,
    /// and it pins the per-provider answer this surface exists for: a colon is fatal on OneDrive
    /// and fine on iCloud.
    @Test(.machinePinned(.layoutMetrics)) func aDifferencesRowBadgesANameOnlyTheDestinationRejects() {
        let row = difference("Q3: final.pdf")

        let strict = fittingWidth(
            DifferenceNameCell(difference: row, paneRules: .strictest))
        let permissive = fittingWidth(
            DifferenceNameCell(difference: row,
                               paneRules: PaneProviderRules(left: .iCloud, right: .iCloud)))

        #expect(permissive > 0, "the cell did not lay out at all; got \(permissive)")
        #expect(strict > permissive,
                "a differences row did not badge a name OneDrive rejects — strict \(strict), permissive \(permissive)")
    }

    /// A keep silences the badge on this surface too. Same row, same ruleset — only the kept set
    /// differs, so this cannot pass by the name having been fine all along.
    @Test(.machinePinned(.layoutMetrics)) func aKeptNameDropsTheDifferencesBadge() {
        let risky = difference("Q3: final.pdf")

        let badged = fittingWidth(
            DifferenceNameCell(difference: risky, paneRules: .strictest))
        let kept = fittingWidth(
            DifferenceNameCell(difference: risky, paneRules: .strictest,
                               keptNames: ["Q3: final.pdf"]))

        #expect(badged > kept,
                "keeping the name did not silence the differences badge — badged \(badged), kept \(kept)")
    }

    // MARK: It paints, not merely reserves

    /// The width assertions above prove the row made ROOM for the badge. They cannot prove the
    /// badge drew anything: an `Image(systemName:)` whose symbol name resolves to nothing reserves
    /// its font's space and paints empty, which is the failure the pane's own missing-asset bug
    /// already taught this project to check for by counting pixels.
    ///
    /// So sample the row for the badge's colour. `SemanticColor.caution` is what Organize's chip
    /// and its list rows wear, and the doc comment on `RiskyNameBadge` makes matching them the
    /// point — a finding that changes appearance by surface reads as two findings.
    @Test(.machinePinned(.pixelSampling)) func theBadgeActuallyPaintsItsCautionColour() throws {
        let node = rowInfo(name: "Q3: final.pdf")
        let canvas = CGSize(width: 320, height: 28)

        func cautionPixels(riskyReason: String?) throws -> Int {
            let subject = FileRowView(node: node, isIgnored: false, diffStatus: nil,
                                      containedDiffCount: 0, density: .comfortable,
                                      riskyReason: riskyReason)
                .frame(width: canvas.width, height: canvas.height, alignment: .leading)
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: AnyView(subject))
            host.frame = CGRect(origin: .zero, size: canvas)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.colorSpace = .sRGB
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                   "no bitmap rep")
            host.cacheDisplay(in: host.bounds, to: rep)
            let target = try #require(
                NSColor(SemanticColor.caution).usingColorSpace(.sRGB), "caution has no sRGB value")

            var hits = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                    guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // Generous tolerance: the glyph is antialiased and drawn with
                    // `foregroundStyle`, so only its core pixels are the flat colour.
                    let distance = abs(px.redComponent - target.redComponent)
                        + abs(px.greenComponent - target.greenComponent)
                        + abs(px.blueComponent - target.blueComponent)
                    if distance < 0.18, px.alphaComponent > 0.9 { hits += 1 }
                }
            }
            return hits
        }

        let withBadge = try cautionPixels(riskyReason: Self.reason)
        let without = try cautionPixels(riskyReason: nil)

        // The control: a clean row must not already be painting this colour, or the count above
        // would be measuring something else entirely.
        #expect(without == 0, "a clean row already paints the caution colour (\(without) px)")
        #expect(withBadge > 0, "the badge reserved space but painted nothing")
    }
}
