import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// RD46.11 — in Frosted and Clear a rail item's count ARRIVES: when a scan finds something while
/// the rail is on screen, the badge drops out of the item on the lens's lead spring, and when the
/// count goes to zero it melts back in. Solid keeps today's instant badge.
///
/// Mounted through the real `LensWorkspaceView`, because the animation is the rail's — keyed on
/// which items report, so the neighbours an item pushes move with it, and the selection lens with
/// them — and a test of `RailItemLabel` alone would pass with the rail's half missing. A count is
/// made to arrive by handing the live manager a duplicate group, which is what a finished
/// Duplicates scan does.
///
/// What is measured is the accent in the rail's band: a reporting item paints its glyph and its
/// digits in it. Captured in the same synchronous turn as the change, an arriving badge has not
/// arrived (Frosted) or is already there (Solid); once the change has settled, both rails agree.
@MainActor
@Suite(.serialized) struct SelectionLensRailCountTests {

    nonisolated static let canvas = CGSize(width: 1400, height: 620)
    /// Row 1, where the rail is.
    nonisolated static let railBand: ClosedRange<CGFloat> = 0...60

    static func group() -> DuplicateGroup {
        let a = DuplicateCopy(id: "/root/Downloads/Visa.pdf", name: "Visa.pdf", isDirectory: false, size: 1,
                              itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 0,
                              isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/root/Downloads/Old/Visa.pdf", name: "Visa.pdf", isDirectory: false, size: 1,
                              itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 1,
                              isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: "Visa.pdf", isDirectory: false, copies: [a, b],
                              reclaimableBytes: 1)
    }

    /// Blue's accent as the render returns it, `(0.22, 0.53, 0.92)`, ± 0.12.
    nonisolated static let isAccent: Pixel.Match = { r, g, b in
        abs(Int(r) - 56) < 31 && abs(Int(g) - 135) < 31 && abs(Int(b) - 235) < 31
    }

    @MainActor final class Rig {
        let manager = FileSyncManager()
        let rig: ProbeRig<AnyView>

        init(level: GlassLevel, groups: [DuplicateGroup], selected: OrganizeLens? = nil) {
            let defaults = ScratchDefaults("SelectionLensRailCountTests")
            defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
            if let selected {
                defaults.set(selected.rawValue, forKey: OrganizeLens.defaultsKey)
            } else {
                defaults.removeObject(forKey: OrganizeLens.defaultsKey)
            }
            manager.duplicateGroups = groups
            let subject = LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                                            scanTargetFolder: "/root/Downloads", onFindDuplicates: {},
                                            onUpdateFolderMemory: {}, onConfigureCloudRefine: {},
                                            providerRoot: nil)
                .defaultAppStorage(defaults)
                .environment(\.selectionLensAppearance,
                             SelectionLensAppearance(level: level, hue: .blue, tint: 0, drawsProbe: true))
                .environment(\.controlActiveState, .active)
                .environment(\._accessibilityReduceMotion, false)
                .environment(\._accessibilityReduceTransparency, false)
                .frame(width: SelectionLensRailCountTests.canvas.width,
                       height: SelectionLensRailCountTests.canvas.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            rig = ProbeRig(AnyView(subject), size: SelectionLensRailCountTests.canvas)
        }

        /// Accent pixels in the rail's band.
        func accent() -> Int { rig.count(rows: SelectionLensRailCountTests.railBand, SelectionLensRailCountTests.isAccent) }

        /// The selection lens's box in the rail's band.
        func lens() -> CGRect? { rig.box(rows: SelectionLensRailCountTests.railBand, Pixel.lensProbe) }

        /// The rail's accent once a change has finished moving — waited for in main-actor TURNS,
        /// not seconds: in a full parallel run the main queue is drained back to back, the display
        /// link that advances the animation gets no turn, and a fixed wait read the first frame as
        /// the last (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
        func settled(from start: Int, margin: Int = 40) async -> (count: Int, pumps: Int) {
            var last = accent()
            let wait = await LayoutPumpWait.pump(rig.host, upTo: 15) {
                let now = accent()
                defer { last = now }
                return abs(now - start) > margin && now == last
            }
            return (last, wait.pumps)
        }
    }

    @Test func theReportingItemsAreTheRowsKey() {
        // What the rail's animation is keyed on: one flag per item, in rail order.
        var counts = LensWorkspaceView.RailCounts()
        let quiet = LensWorkspaceView.reportingItems(counts)
        #expect(quiet.count == OrganizeLens.railItems.count)
        #expect(!quiet.contains(true))
        counts.duplicates = 3
        let one = LensWorkspaceView.reportingItems(counts)
        #expect(one.filter { $0 }.count == 1)
        #expect(one[OrganizeLens.railItems.firstIndex(of: .duplicates)!])
    }

    @Test(.machinePinned(.pixelSampling), arguments: [GlassLevel.frosted, .clear])
    func aCountArrivesInGlass(level: GlassLevel) async throws {
        let rig = Rig(level: level, groups: [])
        let before = rig.accent()
        rig.manager.duplicateGroups = [Self.group()]
        let immediate = rig.accent()
        let (settled, pumps) = await rig.settled(from: before)
        try #require(settled - before > 40,
                     "the Duplicates item never came to report — \(before) → \(settled) after \(pumps) passes")
        #expect(immediate - before < (settled - before) / 4,
                "the count was there at once (\(before) → \(immediate) → \(settled)) — it did not arrive")
    }

    @Test(.machinePinned(.pixelSampling), arguments: [GlassLevel.frosted, .clear])
    func aCountMeltsAwayInGlass(level: GlassLevel) async throws {
        let rig = Rig(level: level, groups: [Self.group()])
        let before = rig.accent()
        rig.manager.duplicateGroups = []
        let immediate = rig.accent()
        let (settled, pumps) = await rig.settled(from: before)
        try #require(before - settled > 40,
                     "the Duplicates item never stopped reporting — \(before) → \(settled) after \(pumps) passes")
        #expect(before - immediate < (before - settled) / 4,
                "the count was gone at once (\(before) → \(immediate) → \(settled)) — it did not melt")
    }

    @Test(.machinePinned(.pixelSampling))
    func solidShowsTheCountAtOnceAsToday() {
        let rig = Rig(level: .solid, groups: [])
        let before = rig.accent()
        rig.manager.duplicateGroups = [Self.group()]
        let immediate = rig.accent()
        #expect(immediate - before > 40, "Solid's count did not appear at once — \(before) → \(immediate)")
    }

    @Test(.machinePinned(.pixelSampling))
    func aRailDrawnAlreadyReportingShowsItsCountAtRest() {
        // Only a change arrives: the rail drawn for the first time with a count is simply there.
        let reporting = Rig(level: .frosted, groups: [Self.group()]).accent()
        let quiet = Rig(level: .frosted, groups: []).accent()
        #expect(reporting - quiet > 40, "a rail drawn already reporting hid its count — \(quiet) vs \(reporting)")
    }

    /// **The lens rides the row's spring.** With Renames chosen, a count arriving on Duplicates —
    /// to its left — pushes Renames along. The spring that moves it must move the lens too: the
    /// first version scoped the animation inside the lens's host, so the item sprang and the lens,
    /// drawn in the host's background, jumped straight to where the item would end up. Read the
    /// turn the change lands: the lens is still where it was, and it gets to the item's new place
    /// only as the item does.
    @Test(.machinePinned(.pixelSampling))
    func theLensRidesTheRowWhenAnItemBeforeItGrowsACount() async throws {
        let rig = Rig(level: .frosted, groups: [], selected: .renames)
        let before = try #require(rig.lens(), "no lens on Renames")
        rig.manager.duplicateGroups = [Self.group()]
        let immediate = try #require(rig.lens())
        var settled = immediate
        let wait = await LayoutPumpWait.pump(rig.rig.host, upTo: 15) {
            guard let now = rig.lens() else { return false }
            defer { settled = now }
            return now.minX > before.minX + 4 && now == settled
        }
        #expect(wait.held, "the lens never followed Renames along — \(before) → \(settled) after \(wait.pumps) passes")
        #expect(abs(immediate.minX - before.minX) < (settled.minX - before.minX) / 2,
                "the lens jumped to Renames' new place at once (\(before.minX) → \(immediate.minX) → \(settled.minX)) — it is not riding the row's spring")
    }
}
