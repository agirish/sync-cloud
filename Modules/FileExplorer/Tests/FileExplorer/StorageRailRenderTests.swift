import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage inside Organize, in pixels: with the Storage lens selected, row 1 draws the Organize
/// rail by the same `leadingWidth` model as the other lenses (`OrganizeRailMetrics` warns about two
/// rails shedding by different rules), and Storage's section capsule sits below the header, in the
/// content card. The capsule's pure sizing is in `StorageRailTests`, which isn't machine-pinned;
/// merged in here, those assertions would stop running wherever this suite is skipped.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct StorageRailRenderTests {

    /// 1400 for the reason `OrganizeRailTests` gives: wide enough that the rail is spelled out, so
    /// the measurement is of the full rung rather than the shed one.
    private static let canvas = CGSize(width: 1400, height: 620)

    // MARK: Fixture

    private static func entry(_ name: String, _ bytes: Int) -> StorageEntry {
        StorageEntry(path: "/root/\(name)", name: name, bytes: bytes,
                     modified: Date(timeIntervalSince1970: 0))
    }

    /// A report whose three lists carry three different digit counts: 8, 96 and 1,204.
    /// `badgeWidth` measures the digits it is handed, so a model charging a flat figure per badge
    /// would agree with the render only on a fixture whose counts are all the same width.
    private static func report(largest: Int = 8, stale: Int = 96,
                               reclaim: Int = 1_204) -> StorageLensReport {
        StorageLensReport(treemap: [],
                          largest: (0..<largest).map { entry("big\($0).mov", 3_000_000) },
                          stale: (0..<stale).map { entry("old\($0).zip", 1_000_000) },
                          reclaimCandidates: (0..<reclaim).map { entry("r\($0).dmg", 2_000_000) },
                          totalBytes: 48_200_000_000, fileCount: largest, staleCount: stale,
                          reclaimCount: reclaim, reclaimableBytes: reclaim * 2_000_000)
    }

    private static func manager(_ report: StorageLensReport?) -> FileSyncManager {
        let m = FileSyncManager()
        m.storageLensReport = report
        m.storageLensRoot = URL(fileURLWithPath: "/root/Documents")
        return m
    }

    // MARK: Harness

    /// Storage's page, or with `lens` the same harness aimed at another lens, for the comparison
    /// that makes "one rail" checkable.
    private func mount(_ manager: FileSyncManager, lens: WorkspaceLensKind = .storage, section: StorageSection?,
                       width: CGFloat? = nil, scale: CGFloat = 1) -> NSHostingView<AnyView> {
        let canvas = CGSize(width: width ?? Self.canvas.width, height: Self.canvas.height)
        let defaults = ScratchDefaults("StorageRailRenderTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let section {
            defaults.set(section.rawValue, forKey: StorageSection.defaultsKey)
        } else {
            defaults.removeObject(forKey: StorageSection.defaultsKey)
        }
        // The rail lens selects the Storage page; `lens: .storage` alone isn't enough. `lensBody`
        // keys on `organizeLens`, which reads this key, so without it the mount renders Organize's
        // overview and every assertion about Storage's content is made against the wrong page.
        if lens == .storage { defaults.set(OrganizeLens.storage.rawValue, forKey: OrganizeLens.defaultsKey) }
        let subject = LensWorkspaceView(syncManager: manager, lens: lens, providerName: "Projects",
                               scanTargetFolder: "/root/Documents", onFindDuplicates: {},
                               onBuildStorage: {})
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        // Twice: `.onGeometryChange` writes `railStyle` after a pass, so a single layout renders
        // the initial value rather than the width-dependent answer.
        return ReviewLensHost.mount(subject, size: canvas, passes: 2).host
    }

    /// The x-extent of row 1's leading cluster, read off the render by the recipe of
    /// `OrganizeRailTests.leadingExtent`. The band starts at x 8 because the card paints a border
    /// at x≈2.5 that a wider band merges into the cluster, and a 30pt run of background ends it:
    /// the gaps inside the rail are far narrower, while the reach to the trailing search toggle is
    /// hundreds of points.
    private func leadingExtent(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = PixelProbe.render(host, CGRect(x: origin, y: 12, width: width - origin, height: 30)),
              let background = rep.colorAt(x: 2, y: 2) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (width - origin)
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var n = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.03 { n += 1 }
            }
            inked.append(n >= 2)
        }
        var runs: [(CGFloat, CGFloat)] = []
        var start: Int?
        var blank = 0
        let gap = Int(30 * scale)
        for (i, on) in inked.enumerated() {
            if on {
                if start == nil { start = i }
                blank = 0
            } else if let s = start {
                blank += 1
                if blank >= gap {
                    runs.append((CGFloat(s) / scale, CGFloat(i - blank) / scale))
                    start = nil
                }
            }
        }
        if let s = start { runs.append((CGFloat(s) / scale, CGFloat(inked.count - 1) / scale)) }
        guard let cluster = runs.first(where: { $0.1 - $0.0 > 3 }) else { return nil }
        return cluster.1 - cluster.0
    }

    /// The states the fixture's report produces, through the same accessor `LensWorkspaceView`
    /// hands the model.
    private static func states(_ report: StorageLensReport?) -> (StorageSection) -> RailItemState {
        { section in
            guard let report else { return .notScanned }
            let n = section.entries(in: report).count
            return n > 0 ? .reporting(n) : .clean
        }
    }

    // MARK: The claim

    @Test("Row 1 draws the same rail on Storage as on any other lens", arguments: FontSize.allCases)
    func theStorageLensDrawsTheOrganizeRail(size: FontSize) throws {
        // Mounting `lens: .storage` must draw the rail every other lens draws, checked as the same
        // cluster rather than "the model covers it": if `lens == .storage` ever forks this row, the
        // clusters diverge, while a model comparison might not notice a second rail a few points
        // off. Held at every text size because a fork could hide in a scale-dependent branch (as
        // `theLeadingModelMatchesWhatTheRowDraws` checks on the Organize side).
        let report = Self.report()
        let onStorage = try #require(leadingExtent(mount(Self.manager(report), section: nil, scale: size.scale),
                                                   width: Self.canvas.width),
                                     "row 1 drew no leading cluster on Storage at \(size.scale)× — the rail is not on screen at all")
        let onDuplicates = try #require(leadingExtent(mount(Self.manager(report), lens: .duplicates, section: nil, scale: size.scale),
                                                      width: Self.canvas.width),
                                        "row 1 drew no leading cluster on Duplicates at \(size.scale)×")
        // Not exact equality: `RailItemLabel` draws the selected item semibold and the rest medium,
        // so the rail with "Storage" lit and with "Duplicates" lit differ by up to about a point.
        // A different rail would be far outside this band.
        #expect(abs(onStorage - onDuplicates) < 8,
                "at \(size.scale)× row 1's rail draws \(onStorage)pt on Storage and \(onDuplicates)pt on Duplicates — the header is still forking on the lens")

        // Non-vacuity: the cluster is the six-item rail, not a stub both lenses agree on by drawing
        // almost nothing. The shared model is the yardstick.
        let quiet = OrganizeRailMetrics.leadingWidth(scale: size.scale, state: { _ in .clean })
        #expect(onStorage > quiet * 0.9,
                "row 1 draws \(onStorage)pt at \(size.scale)× against a \(quiet)pt six-item rail — that is not the Organize rail")
    }

    @Test("The section capsule is drawn below the header, not in it")
    func theCapsuleIsInTheContentCard() throws {
        // Ink in a band below row 1's 81pt rung: the capsule must stay out of the header's
        // geometry, and one that crept back up into it would still pass every sizing test in
        // `StorageRailTests`.
        let host = mount(Self.manager(Self.report()), section: nil)
        let header: CGFloat = 81
        let band = CGRect(x: 8, y: header + 14, width: 420, height: 34)
        let rep = try #require(PixelProbe.render(host, band))
        let background = try #require(rep.colorAt(x: 2, y: rep.pixelsHigh - 2))
        let inked = PixelProbe.count(in: rep) { PixelProbe.distance($0, background) > 0.03 }
        #expect(inked > 200,
                "the band under the header drew \(inked) inked pixels — the section capsule is not in the content card")
    }
}
