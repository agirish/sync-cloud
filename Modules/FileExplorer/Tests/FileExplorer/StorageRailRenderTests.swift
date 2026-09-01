import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage inside Organize, in pixels — **the fold held to what row 1 actually draws.**
///
/// This suite used to hold `storageLeadingWidth` against Storage's own rail. That rail is gone: the
/// fold gave the header's rail slot to the Organize rail and moved Storage's sections into the
/// content card as a capsule, so there is no second width model left to check. What replaced it is
/// the claim the fold actually makes, which nothing else can see:
///
/// - **Row 1 draws the ORGANIZE rail when the Storage lens is selected**, and it is the same
///   `leadingWidth` model the other five lenses are measured against. Two rails shedding by
///   different rules is what `OrganizeRailMetrics` warns about in its own comment; this is the
///   assertion that there is now one.
/// - **The capsule is on screen**, below the header, in the content card.
///
/// The pure sizing of the capsule — one width per selection, the two rungs, the type ramp — is in
/// `StorageRailTests`, which is not machine-pinned and runs everywhere. Only the questions that
/// need a live render are here, for the reason the old suite gave: folding them together would pin
/// the pure assertions to this Mac and they would stop running wherever this suite is skipped.
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

    /// A report whose three lists carry **three different digit counts** — 8, 96 and 1,204.
    ///
    /// Deliberate: `badgeWidth` measures the digits it is handed, so a model that charged a flat
    /// figure per badge would agree with the render on a fixture where every count is the same
    /// width and disagree on a real one. This is the same trap the Organize model fell into, where
    /// `410` and `126` each cost ~8pt more than a two-digit estimate allowed.
    private static func report(largest: Int = 8, stale: Int = 96,
                               reclaim: Int = 1_204) -> StorageLensReport {
        StorageLensReport(treemap: [],
                          largest: (0..<largest).map { entry("big\($0).mov", 3_000_000) },
                          stale: (0..<stale).map { entry("old\($0).zip", 1_000_000) },
                          reclaimCandidates: (0..<reclaim).map { entry("r\($0).dmg", 2_000_000) },
                          totalBytes: 48_200_000_000)
    }

    private static func manager(_ report: StorageLensReport?) -> FileSyncManager {
        let m = FileSyncManager()
        m.storageLensReport = report
        m.storageLensRoot = URL(fileURLWithPath: "/root/Documents")
        return m
    }

    // MARK: Harness

    /// The same harness aimed at another lens, for the comparison that makes "one rail" checkable.
    private func mountLens(_ lens: WorkspaceLensKind, _ manager: FileSyncManager,
                           scale: CGFloat = 1) -> NSHostingView<AnyView> {
        let canvas = Self.canvas
        let defaults = ScratchDefaults("StorageRailRenderTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        defaults.removeObject(forKey: StorageSection.defaultsKey)
        let subject = LensWorkspaceView(syncManager: manager, lens: lens, providerName: "Projects",
                               scanTargetFolder: "/root/Documents", onFindDuplicates: {},
                               onBuildStorage: {})
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func mount(_ manager: FileSyncManager, section: StorageSection?,
                       width: CGFloat? = nil, scale: CGFloat = 1) -> NSHostingView<AnyView> {
        let canvas = CGSize(width: width ?? Self.canvas.width, height: Self.canvas.height)
        let defaults = ScratchDefaults("StorageRailRenderTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let section {
            defaults.set(section.rawValue, forKey: StorageSection.defaultsKey)
        } else {
            defaults.removeObject(forKey: StorageSection.defaultsKey)
        }
        // **The RAIL lens is what selects the Storage page now, and passing `lens: .storage` is
        // not enough.** Before the fold the content forked on the workspace's apparatus, so this
        // harness got Storage's page for free; `lensBody` keys on `organizeLens` since, which reads
        // this key. Without it the mount renders Organize's overview and every assertion about
        // Storage's content is made against a page that is not there.
        defaults.set(OrganizeLens.storage.rawValue, forKey: OrganizeLens.defaultsKey)
        let subject = LensWorkspaceView(syncManager: manager, lens: .storage, providerName: "Projects",
                               scanTargetFolder: "/root/Documents", onFindDuplicates: {},
                               onBuildStorage: {})
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison reads as zero difference.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        // Twice: `.onGeometryChange` writes `railStyle` *after* a pass, so a single layout renders
        // the initial value rather than the width-dependent answer.
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// The x-extent of row 1's leading cluster, read off the render.
    ///
    /// Same recipe as `OrganizeRailTests.leadingExtent`, and the two comments there are load-bearing
    /// here too: the band starts at **x 8** because the card paints a border at x≈2.5 that a wider
    /// band merges into the cluster, and a **30pt** run of background ends it — inside Storage's
    /// rail the widest gap is the separator's 13pt, while the reach to the trailing search toggle is
    /// hundreds of points.
    private func leadingExtent(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat? {
        let origin: CGFloat = 8
        guard let rep = strip(host, CGRect(x: origin, y: 12, width: width - origin, height: 30)),
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

    /// The states the fixture's report produces — the same accessor `LensWorkspaceView` hands the model.
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
        // **This is the fold, measured.** Before it, mounting `lens: .storage` drew four storage
        // items here, budgeted by a width model of its own. Now it draws the same rail every other
        // lens draws — and the sharpest way to say that in pixels is not "the model covers it" but
        // "it is the same cluster". If `lens == .storage` ever forks on this row again, the two
        // clusters diverge and this fails; a model comparison would not necessarily notice, because
        // a second rail can be within a few points of the first.
        //
        // Held at every text size because a fork could be introduced in a scale-dependent branch —
        // the failure `theLeadingModelMatchesWhatTheRowDraws` exists to catch on the Organize side.
        let report = Self.report()
        let onStorage = try #require(leadingExtent(mount(Self.manager(report), section: nil, scale: size.scale),
                                                   width: Self.canvas.width),
                                     "row 1 drew no leading cluster on Storage at \(size.scale)× — the rail is not on screen at all")
        let onDuplicates = try #require(leadingExtent(mountLens(.duplicates, Self.manager(report), scale: size.scale),
                                                      width: Self.canvas.width),
                                        "row 1 drew no leading cluster on Duplicates at \(size.scale)×")
        // **Not exact equality, and the reason is a real property of the rail rather than
        // measurement slop.** `RailItemLabel` draws the SELECTED item semibold and the rest medium,
        // so "Storage" selected and "Duplicates" selected are genuinely a fraction of a point
        // apart — measured at 1.0pt at 0.9×, which a `< 1` tolerance refuted. The tolerance is what
        // separates "the same rail with a different item lit" from "a different rail": the storage
        // rail this replaced measured 417.8pt against this one's ~623, so anything that would let
        // the old fork back in is two orders of magnitude outside this band.
        #expect(abs(onStorage - onDuplicates) < 8,
                "at \(size.scale)× row 1's rail draws \(onStorage)pt on Storage and \(onDuplicates)pt on Duplicates — the header is still forking on the lens")

        // Non-vacuity: the cluster is a six-item rail, not a stub the two lenses agree on by both
        // drawing almost nothing. The shared model is the yardstick — a rail this wide cannot be
        // the four-item storage rail that used to be here.
        let quiet = OrganizeRailMetrics.leadingWidth(scale: size.scale, state: { _ in .clean })
        #expect(onStorage > quiet * 0.9,
                "row 1 draws \(onStorage)pt at \(size.scale)× against a \(quiet)pt six-item rail — that is not the Organize rail")
    }

    @Test("The section capsule is drawn below the header, not in it")
    func theCapsuleIsInTheContentCard() throws {
        // Where the switcher went. Asserted as ink in a band BELOW row 1's 81pt rung: the whole
        // point of the move is that the header's geometry is out of the blast radius, and a capsule
        // that had crept back up into it would still pass every sizing test in `StorageRailTests`.
        let host = mount(Self.manager(Self.report()), section: nil)
        let header: CGFloat = 81
        let band = CGRect(x: 8, y: header + 14, width: 420, height: 34)
        let rep = try #require(strip(host, band))
        let background = try #require(rep.colorAt(x: 2, y: rep.pixelsHigh - 2))
        var inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.03 { inked += 1 }
            }
        }
        #expect(inked > 200,
                "the band under the header drew \(inked) inked pixels — the section capsule is not in the content card")
    }
}
