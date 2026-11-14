import Testing
import AppKit
import SwiftUI
import Sync
import Design
@testable import FileExplorer

/// The badge is in the rows it ships on: passing `nil` for `reason:` at either call site,
/// `FileRowView` (tree panes and, through `ColumnRowView`, Columns) or `DifferenceNameCell`, fails
/// here. The width delta catches a row that stopped reserving the badge's space; the caution-colour
/// sample catches a badge that reserves space and paints nothing (an `Image(systemName:)` naming no
/// symbol does that).
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

    /// `FileRowView` is the row both pane presentations render (the tree pane directly, the Columns
    /// stack through `ColumnRowView`); a reason must widen it by the badge. The two rows differ only
    /// in `riskyReason`, since varying the name would change the text's own width.
    @Test func aPaneRowIsWiderWhenItsNameIsRisky() {
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

    /// The same row at compact density: the badge takes the pane's resolved fonts, and a density
    /// change is the sort of thing that quietly drops a trailing element.
    @Test func aCompactPaneRowCarriesTheBadgeToo() {
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

    /// `DifferenceNameCell` resolves the reason itself from both panes' rulesets, so this drives the
    /// whole chain on that surface: real name, real ruleset, real badge.
    ///
    /// One name judged by two rulesets, not two names by one, which would differ in text width
    /// whatever the badge did. The badge is then the only thing that can change, and this pins the
    /// per-provider answer: a colon is fatal on OneDrive and fine on iCloud.
    @Test func aDifferencesRowBadgesANameOnlyTheDestinationRejects() {
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

    /// A keep silences the badge on this surface too. Same row, same ruleset, only the kept set
    /// differs, so this can't pass by the name having been fine all along.
    @Test func aKeptNameDropsTheDifferencesBadge() {
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

    /// The width assertions above prove the row made room for the badge, not that it drew: an
    /// `Image(systemName:)` whose symbol resolves to nothing reserves its font's space and paints
    /// empty. So this samples the row for the badge's colour, `SemanticColor.caution`, which
    /// Organize's chip and list rows also wear: a finding that changes look by surface reads as two.
    @Test(.machinePinned(.pixelSampling)) func theBadgeActuallyPaintsItsCautionColour() throws {
        let node = rowInfo(name: "Q3: final.pdf")
        let canvas = CGSize(width: 320, height: 28)

        func cautionPixels(riskyReason: String?) throws -> Int {
            let subject = FileRowView(node: node, isIgnored: false, diffStatus: nil,
                                      containedDiffCount: 0, density: .comfortable,
                                      riskyReason: riskyReason)
                .frame(width: canvas.width, height: canvas.height, alignment: .leading)
                .environment(\.colorScheme, .light)
            let rep = try #require(PixelDiff.render(subject, size: canvas), "no bitmap rep")
            // What the badge is specified to paint in this appearance. Raw `SemanticColor.caution`
            // is `Color.yellow`, and a glyph whose colour is its meaning takes `ChromeInk.semantic`
            // (deepened in light, untouched in dark), because system yellow on a light row falls
            // under the 3:1 such a glyph needs. The window is `.aqua`, so light is under test.
            let target = try #require(
                NSColor(ChromeInk.semantic(.light, SemanticColor.caution)).usingColorSpace(.sRGB),
                "the badge's ink has no sRGB value")

            var hits = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                    guard let px = rep.colorAt(x: x, y: y) else { continue }
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

        // The control: a clean row must not already paint this colour, or the count above would be
        // measuring something else.
        #expect(without == 0, "a clean row already paints the caution colour (\(without) px)")
        #expect(withBadge > 0, "the badge reserved space but painted nothing")
    }
}
