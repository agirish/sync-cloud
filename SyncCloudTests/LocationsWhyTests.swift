import AppKit
import Design
import Settings
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// What the Locations Why panel draws beside the list.
///
/// **The panel is a picture of the idea, and the list is the list** — so the marks are one per
/// *kind* of location, not one per account. On this Mac that is ten locations against four marks.
@MainActor
@Suite struct LocationsWhyMarkTests {

    private func provider(_ id: String, _ display: String, _ image: String) -> CloudProvider {
        CloudProvider(id: id, displayName: display, imageName: image,
                      rootPath: "/tmp/\(id)", type: .googleDrive)
    }

    /// Several accounts of one provider wear one mark, and the provider behind them is not lost.
    ///
    /// **This is the defect, stated.** Taking the first three *accounts* off a real roster showed
    /// iCloud, Dropbox and OneDrive and dropped Google Drive — the provider whose folder is open in
    /// the other pane — because three Drive accounts sat behind them in the list.
    @Test func accountsOfOneProviderCollapseToOneMark() {
        let providers = [
            provider("iCloud", "iCloud", "icloud"),
            provider("gd-a", "Google Drive (a@example.com)", "googledrive"),
            provider("gd-b", "Google Drive (b@example.com)", "googledrive"),
            provider("gd-c", "Google Drive (c@example.com)", "googledrive"),
            provider("dropbox", "Dropbox", "dropbox"),
            provider("onedrive", "OneDrive (work)", "onedrive"),
        ]
        let marks = LocationsWhy.marks(for: providers)
        #expect(marks.map(\.imageName) == ["icloud", "googledrive", "dropbox", "onedrive"],
                "six locations of four kinds drew \(marks.map(\.imageName))")
        #expect(marks.map(\.name) == ["iCloud", "Google Drive", "Dropbox", "OneDrive"],
                "a mark carries the provider's name, not one account's address")
    }

    /// The cap is on marks, and it is reached only by genuinely different providers.
    @Test func theCapCountsKindsRatherThanAccounts() {
        let manyAccounts = (0..<9).map { provider("gd-\($0)", "Google Drive (\($0)@x.com)", "googledrive") }
        #expect(LocationsWhy.marks(for: manyAccounts).count == 1,
                "nine accounts of one provider are one picture")

        let fiveKinds = ["icloud", "googledrive", "dropbox", "onedrive", "folder.fill"]
            .enumerated().map { provider("p\($0.offset)", "P\($0.offset)", $0.element) }
        #expect(LocationsWhy.marks(for: fiveKinds).count == 4, "the cap is four")
    }

    /// A folder source has no brand asset, and is still a kind.
    @Test func aFolderSourceIsItsOwnKind() {
        let marks = LocationsWhy.marks(for: [
            provider("iCloud", "iCloud", "icloud"),
            provider("f1", "Archive", "folder.fill"),
        ])
        #expect(marks.map(\.imageName) == ["icloud", "folder.fill"])
    }

    /// Nothing discovered yet still draws the four the app supports.
    @Test func theFallbackNamesEveryProviderTheAppSupports() {
        #expect(LocationsWhy.marks(for: []).isEmpty)
        #expect(Set(LocationsWhy.fallback.map(\.imageName))
                == ["icloud", "googledrive", "dropbox", "onedrive"])
    }
}

/// The panel draws each provider's own mark, not one cloud in four tints.
///
/// **Rendered, because the defect was invisible to every other kind of check.** The panel drew
/// `Image(systemName: "cloud.fill")` tinted by `ProviderHue.classify(name)`, so it had the right
/// number of glyphs, the right names under them and a different colour each — and Dropbox's folded
/// box and OneDrive's twin lobes both came out as the same cloud, two inches from their own logos
/// in the list beside them. Only the pixels say so.
@MainActor
@Suite struct LocationsWhyRenderTests {

    /// The panel with one mark, at the width the card gives it.
    private func render(_ mark: LocationsWhy.Mark) throws -> NSBitmapImageRep {
        let panel = LocationsWhy(hue: .blue, marks: [mark])
        let size = CGSize(width: SetupWhyMetrics.width(scale: 1), height: 200)
        let host = NSHostingView(rootView: panel.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                               "the panel would not render — every measurement here is vacuous")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels where two renders of the same panel differ.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02
                    || abs(p.alphaComponent - q.alphaComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// **Two marks with the same name and different assets draw differently.**
    ///
    /// Holding the *name* fixed is what gives this teeth, and the first spelling of this test did
    /// not: it compared four quarter-width columns of one render, which caught the four different
    /// *labels* under the marks and passed happily with `cloud.fill` restored for all of them. With
    /// one name across both renders the old code is pixel-identical — same symbol, and
    /// `ProviderHue.classify` gives the same tint to the same string — so any difference at all is
    /// the asset.
    @Test func aMarkIsTheProvidersOwnAssetRatherThanOneSharedSymbol() throws {
        let names = ["dropbox", "onedrive", "googledrive", "icloud"]
        var renders: [(String, NSBitmapImageRep)] = []
        for asset in names {
            renders.append((asset, try render(.init(name: "Location", imageName: asset))))
        }
        for a in 0..<renders.count {
            for b in (a + 1)..<renders.count {
                let differing = differingPixels(renders[a].1, renders[b].1)
                #expect(differing > 200,
                        "\(renders[a].0) and \(renders[b].0) differ in \(differing) pixels under one name — the panel is drawing one shared symbol, not each provider's mark")
            }
        }
    }

    /// The height of one line of `caption2` at this text size, measured rather than derived.
    private func lineHeight(_ scale: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView:
            Text("Xg").scaledFont(.caption2).environment(\.appFontScale, scale).fixedSize())
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The real strip, laid out in the real panel column, at one text size.
    private func stripHeight(_ marks: [LocationsWhy.Mark], scale: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: LocationsWhy.MarkStrip(marks: marks)
            .environment(\.appFontScale, scale)
            .frame(width: SetupWhyMetrics.textWidth(scale: scale)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// **The four marks stay on one row, at every text size.**
    ///
    /// Wrapped, the strip put iCloud, Dropbox and OneDrive on the first line and left Google Drive
    /// alone on the second — under a heading, on the provider this Mac uses most. Whether they fit
    /// is a measurement rather than a matter of taste.
    ///
    /// Every stop, because the column and the type now scale together and the claim is that they
    /// keep step. Before they did, 90% was the size that truncated and 135% the size that broke
    /// words, and neither was visible at the 100% every other test used.
    @Test func theMarkStripStaysOnOneRow() throws {
        for size in FontSize.allCases {
            let scale = size.scale
            // The marks and the gaps follow the card's geometry, which never shrinks; only the
            // type follows the text scale. Mixing the two is what makes a ceiling wrong by a point.
            let geo = SetupSheetMetrics.chromeScale(scale)
            let height = stripHeight(LocationsWhy.fallback, scale: scale)
            // One row of marks, with room for a label of up to two lines under them. A second row
            // of *marks* adds another cap height on top of that, which is what this catches.
            let ceiling = LocationsWhy.MarkStrip.baseCapHeight * geo
                + LocationsWhy.MarkStrip.baseGap * geo + lineHeight(scale) * 2 + 1
            #expect(height <= ceiling,
                    "at \(size.percent)% the strip is \(Int(height))pt against \(Int(ceiling))pt for one row of marks — they wrapped")
        }
    }

    /// **No name is broken inside a word, at any text size.**
    ///
    /// This is the defect the screenshots showed: at 135% the strip read "iCloud", "OneDri/ve",
    /// "Google/Drive", "Dropb/ox" — two of the four split mid-word, which is what SwiftUI does when
    /// a cell is narrower than the word in it.
    ///
    /// The tell is height, and the expected height is *measured* rather than assumed: a name that
    /// fits its cell takes one line, and one that does not takes as many lines as it has words,
    /// because a space is where it is allowed to break. A name broken inside a word takes a line
    /// more than that.
    ///
    /// **One mark at a time, and that is not a stylistic choice.** Measured across the whole strip
    /// this passed with two of the four names broken, because the strip is as tall as its tallest
    /// cell and "Google Drive" legitimately wants two lines — so the two that were breaking hid
    /// behind the one that was not. Each mark is laid out alone, in a cell the width the real strip
    /// would give it.
    @Test func noNameIsBrokenInsideAWord() throws {
        for size in FontSize.allCases {
            let scale = size.scale
            let geo = SetupSheetMetrics.chromeScale(scale)
            let marks = LocationsWhy.fallback
            let cell = LocationsWhy.MarkStrip.cellWidth(marks.count, scale: scale)

            for mark in marks {
                let natural = NSHostingView(rootView: Text(mark.name).scaledFont(.caption2)
                    .environment(\.appFontScale, scale).fixedSize())
                natural.layoutSubtreeIfNeeded()
                let lines = natural.fittingSize.width <= cell
                    ? 1 : max(1, mark.name.split(separator: " ").count)

                let host = NSHostingView(rootView: LocationsWhy.MarkStrip(marks: [mark])
                    .environment(\.appFontScale, scale)
                    .frame(width: cell))
                host.layoutSubtreeIfNeeded()
                let height = host.fittingSize.height

                let expected = LocationsWhy.MarkStrip.baseCapHeight * geo
                    + LocationsWhy.MarkStrip.baseGap * geo + lineHeight(scale) * CGFloat(lines)
                #expect(abs(height - expected) <= 2,
                        "at \(size.percent)% \"\(mark.name)\" draws \(Int(height))pt in a \(Int(cell))pt cell where wrapping only at spaces wants \(Int(expected))pt for \(lines) line(s) — it is being broken inside a word")
            }
        }
    }

    /// **No provider name has to shrink to fit.**
    ///
    /// `minimumScaleFactor` is the floor under a pathologically long word, not the mechanism: a
    /// name drawn smaller than the three beside it is the exact defect that made the first attempt
    /// worse than the wrap it replaced. So every word of every mark must fit its cell whole, with
    /// the cell measured off the real panel column at each text size.
    @Test func noProviderNameHasToShrinkToFit() throws {
        for size in FontSize.allCases {
            let scale = size.scale
            let marks = LocationsWhy.fallback
            let cell = LocationsWhy.MarkStrip.cellWidth(marks.count, scale: scale)
            for mark in marks {
                for word in mark.name.split(separator: " ").map(String.init) {
                    let host = NSHostingView(rootView: Text(word).scaledFont(.caption2)
                        .environment(\.appFontScale, scale).fixedSize())
                    host.layoutSubtreeIfNeeded()
                    let wanted = host.fittingSize.width
                    #expect(wanted <= cell,
                            "at \(size.percent)% \"\(word)\" wants \(Int(wanted))pt in a \(Int(cell))pt cell — it will be shrunk below the names beside it")
                }
            }
        }
    }

    /// A positive control: the same mark twice is the same picture, so the comparison above is
    /// measuring the asset and not the renderer's own noise.
    @Test func theSameMarkTwiceIsIdentical() throws {
        let one = try render(.init(name: "Location", imageName: "dropbox"))
        let two = try render(.init(name: "Location", imageName: "dropbox"))
        #expect(differingPixels(one, two) == 0,
                "two renders of one mark differ — this comparison cannot distinguish an asset from noise")
    }
}
