import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage's rail, in pixels — **the model held to what it actually draws.**
///
/// `StorageRailTests` is pure: it asserts the section-to-list mapping, the labels, the glyph table
/// against the renderer, and that the rail fits. Every one of those compares the arithmetic against
/// itself or against one measured constant, which is exactly the shape of assertion that let
/// Organize's leading model sit **63pt short of its own row** while nineteen tests stayed green.
/// The fix there was `theLeadingModelMatchesWhatTheRowDraws`, which measures the cluster off a live
/// render; this is its counterpart, and it was the gap left open when the Storage rail shipped.
///
/// It is worth being precise about what was and was not already covered, because "the glyphs are
/// pinned" reads like the model is:
///
/// - ``OrganizeRailMetrics/storageGlyphWidth(_:scale:)`` **is** checked against the renderer, and
///   caught three wrong guesses (14/16/14 against a true 13/15/16).
/// - The **assembly** — the overview item, the separator, and how many `itemGap`s five elements
///   carry between them — was checked by nothing. That is where Organize's model went wrong twice
///   in one afternoon: a separator charged for the gap on both sides (12pt over) and the unscanned
///   dot charged to every quiet item (30pt over). Both were arithmetic about spacing, and both were
///   invisible to any test that did not look at the row.
///
/// **A separate suite from `StorageRailTests`, not a test added to it.** This one reads pixels back
/// out of a live renderer, so it is `.machinePinned(.pixelSampling)`; folding it in would pin the
/// pure assertions to this Mac along with it and they would stop running wherever this suite is
/// skipped.
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
        let subject = TidyView(syncManager: manager, lens: .storage, providerName: "Projects",
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

    /// The states the fixture's report produces — the same accessor `TidyView` hands the model.
    private static func states(_ report: StorageLensReport?) -> (StorageSection) -> RailItemState {
        { section in
            guard let report else { return .notScanned }
            let n = section.entries(in: report).count
            return n > 0 ? .reporting(n) : .clean
        }
    }

    // MARK: The claim

    @Test("Storage's leading model matches what row 1 draws, at every text size",
          arguments: FontSize.allCases)
    func theStorageLeadingModelMatchesWhatTheRowDraws(size: FontSize) throws {
        let report = Self.report()
        let host = mount(Self.manager(report), section: nil, scale: size.scale)
        let drawn = try #require(leadingExtent(host, width: Self.canvas.width),
                                 "row 1 drew no leading cluster at \(size.scale)× — Storage's rail is not on screen at all")
        let model = OrganizeRailMetrics.storageLeadingWidth(scale: size.scale,
                                                            state: Self.states(report))

        // **Over, never under.** A model short of the row it describes lets the row overrun before
        // it sheds, which is this type's whole failure mode; a model far over it sheds labels on a
        // header that would have seated them.
        #expect(model >= drawn,
                "at \(size.scale)× Storage's rail draws \(drawn)pt but the model budgets \(model)pt — it is \(drawn - model)pt short, so the row will overrun before it sheds")
        #expect(model - drawn < 12,
                "at \(size.scale)× the model budgets \(model)pt for a rail that draws \(drawn)pt — \(model - drawn)pt of slack sheds the labels early")
    }

    @Test("The model tracks the rail's states, not just its item count")
    func theModelFollowsTheStatesTheRowDraws() throws {
        // The neighbour above renders one state at four sizes. This renders two states at one size,
        // which is the other axis the model has to be right on: a badge, a dot and nothing are three
        // different widths, and a model that charged per *item* rather than per *state* would agree
        // with the render on whichever fixture it was tuned against and disagree on the other.
        let reporting = Self.report()
        let unscanned: StorageLensReport? = nil

        let hot = try #require(leadingExtent(mount(Self.manager(reporting), section: nil),
                                             width: Self.canvas.width))
        let cold = try #require(leadingExtent(mount(Self.manager(unscanned), section: nil),
                                              width: Self.canvas.width))
        #expect(hot > cold,
                "a rail with three counts drew \(hot)pt and one that has never scanned drew \(cold)pt — the states are not changing the row, so there is nothing for the model to track")

        let hotModel = OrganizeRailMetrics.storageLeadingWidth(scale: 1, state: Self.states(reporting))
        let coldModel = OrganizeRailMetrics.storageLeadingWidth(scale: 1, state: Self.states(unscanned))
        #expect(hotModel >= hot && hotModel - hot < 12)
        #expect(coldModel >= cold && coldModel - cold < 12,
                "the unscanned rail draws \(cold)pt and models \(coldModel)pt — the dot is charged wrongly")
    }
}
