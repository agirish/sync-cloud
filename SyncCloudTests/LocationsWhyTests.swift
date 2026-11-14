import AppKit
import Design
import Settings
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// What the Locations Why panel draws beside the list. The panel is a picture of the idea and the
/// list is the list, so the marks are one per kind of location, not one per account.
@MainActor
@Suite struct LocationsWhyMarkTests {
    private func provider(_ id: String, _ display: String, _ image: String) -> CloudProvider {
        CloudProvider(id: id, displayName: display, imageName: image,
                      rootPath: "/tmp/\(id)", type: .googleDrive)
    }

    /// Several accounts of one provider wear one mark, and the provider behind them is not lost:
    /// taking the first few accounts would drop a provider whose accounts sit further down the list.
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

/// The panel draws each provider's own mark, not one cloud in four tints. Rendered, because a
/// tinted `cloud.fill` per provider has the right count, names and distinct colours, and only the
/// pixels show it isn't Dropbox's or OneDrive's logo.
@MainActor
@Suite struct LocationsWhyRenderTests {
    /// The panel with one mark, at the width the card gives it.
    private func render(_ mark: LocationsWhy.Mark) throws -> NSBitmapImageRep {
        let panel = LocationsWhy(hue: .blue, marks: [mark])
        let size = CGSize(width: SetupWhyMetrics.width(scale: 1), height: 200)
        let host = NSHostingView(rootView: panel.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    /// Pixels where two renders differ. Matching bytes in one format skip a row or pixel; the rest
    /// compare `colorAt` components, read once per distinct value (`PixelMemo`), since `colorAt` on
    /// every pixel is slow on the main actor.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        let components: (NSColor?) -> [CGFloat]? = { colour in
            colour.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
        }
        let pa = PixelMemo(a, components), pb = PixelMemo(b, components)
        let sameFormat = pa.sameFormat(as: pb)
        var count = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            if sameFormat, pa.rowMatches(y, in: pb) { continue }
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                if sameFormat, let key = pa.key(x, y), key == pb.key(x, y) { continue }
                guard let p = pa(x, y), let q = pb(x, y) else { continue }
                if abs(p[0] - q[0]) > 0.02 || abs(p[1] - q[1]) > 0.02
                    || abs(p[2] - q[2]) > 0.02 || abs(p[3] - q[3]) > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// Two marks with the same name and different assets draw differently. The name is held fixed
    /// so any difference is the asset: one shared symbol tinted by `ProviderHue.classify` would be
    /// pixel-identical under one name.
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

    /// The four marks stay on one row at every text size: the column and the type scale together,
    /// which 100% alone can't show.
    @Test func theMarkStripStaysOnOneRow() throws {
        for size in FontSize.allCases {
            let scale = size.scale
            // The marks and gaps follow the card's geometry, which never shrinks; only the type
            // follows the text scale. Mixing the two makes a ceiling wrong by a point.
            let geo = SetupSheetMetrics.chromeScale(scale)
            let height = stripHeight(LocationsWhy.fallback, scale: scale)
            // One row of marks plus a label of up to two lines; a second row adds a cap height.
            let ceiling = LocationsWhy.MarkStrip.baseCapHeight * geo
                + LocationsWhy.MarkStrip.baseGap * geo + lineHeight(scale) * 2 + 1
            #expect(height <= ceiling,
                    "at \(size.percent)% the strip is \(Int(height))pt against \(Int(ceiling))pt for one row of marks — they wrapped")
        }
    }

    /// No name is broken inside a word ("OneDri/ve"), which SwiftUI does in a too-narrow cell; the
    /// tell is an extra line of height. One mark at a time, since the strip is as tall as its
    /// tallest cell and "Google Drive"'s two real lines would hide the others' breaks.
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

    /// No provider name has to shrink to fit: `minimumScaleFactor` is only a floor for a
    /// pathologically long word. Every word must fit its cell whole at each text size.
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
