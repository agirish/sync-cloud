import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Opening Rules aims Organize at the source root, and leaving it puts the scope back, checked in
/// pixels in all three places that must obey `OrganizeLens.isScoped`: rows, badges and chip. Each
/// claim is a difference between two mounts of the same lens, with and without a stored scope.
/// The fixture is the trap: the scope is the inbox and the rules file out of it, so a scope
/// predicate applied to Rules hides every rule.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeRulesScopeTests {

    private static let canvas = CGSize(width: 1400, height: 620)
    private static let root = "/root"
    /// The inbox, where the scope is parked when the trap springs.
    private static let inbox = "/root/TODO"

    /// The rail: six capsules on row 1, badges and all. Same band `OrganizeRailTests` measured.
    private static let railZone = CGRect(x: 8, y: 12, width: 580, height: 30)
    /// Row 2, where the scope chip is drawn — for every lens, above the switch.
    private static let readoutZone = CGRect(x: 8, y: 44, width: 580, height: 30)
    /// The content card: the rule list itself, well below the two-row header ladder.
    private static let contentZone = CGRect(x: 20, y: 110, width: 1360, height: 420)

    // MARK: Fixtures

    /// Two complete rules, both filing out of the inbox into somewhere else, as every real rule
    /// does, so a scope predicate would hide them all.
    private static var rules: [AutomationRule] {
        [AutomationRule(name: "Medical bills", matchMode: .any,
                        conditions: [.mentionsAll(["bill"])],
                        destinationTemplate: "Medical/Bills"),
         AutomationRule(name: "Tax forms", matchMode: .any,
                        conditions: [.mentionsAll(["1099"])],
                        destinationTemplate: "Finance/{year}")]
    }

    /// Findings for the five scoped lenses, placed outside the inbox, so an applied scope takes
    /// their badges to nothing and an unapplied one leaves them reporting.
    /// `theOtherFiveBadgesKeepTheirScopeWhileRulesIsSelected` reads that difference.
    private static func manager() -> FileSyncManager {
        let m = FileSyncManager()
        m.automationRules = rules
        m.riskyNames = (1...7).map {
            RiskyName(id: "/root/Legal/bad:name\($0).pdf", relativePath: "Legal/bad:name\($0).pdf",
                      currentName: "bad:name\($0).pdf", sanitizedName: "bad-name\($0).pdf",
                      reason: "colon", isDirectory: false)
        }
        m.hasScannedNames = true
// The risky names render inside Renames only after the file pass has run; without this, both
// mounts show the same setup card.
        m.hasSuggestedFiling = true
        return m
    }

    private func mount(_ manager: FileSyncManager, lens: OrganizeLens?, scope: String?)
        -> NSHostingView<AnyView> {
        let defaults = ScratchDefaults("OrganizeRulesScopeTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let lens {
            defaults.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            defaults.removeObject(forKey: OrganizeLens.defaultsKey)
        }
// Through the key `LensWorkspaceView` reads, as a stored string, as a real launch reads it.
        defaults.set(scope ?? "", forKey: OrganizeScopeDefaults.pathKey)
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: Self.root, onFindDuplicates: {},
                               providerRoot: Self.root)
            .defaultAppStorage(defaults)
        // Twice: `.onGeometryChange` writes `railStyle` after a pass.
        return ReviewLensHost.mount(subject, size: Self.canvas, passes: 2).host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep {
        PixelProbe.render(host, band)!
    }

/// Pixels that differ between two same-sized bands: a count, so assertions carry a floor, and the
/// ones that demand sameness demand exactly zero.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        return PixelDiff.differingPixels(a, b, tolerance: 0.01)
    }

    /// Pixels in a band that differ from its background corner: the "did anything render" check
    /// that keeps the comparisons from passing over two blank images.
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        return PixelProbe.count(in: rep) { PixelProbe.distance($0, background) > 0.03 }
    }

    // MARK: The trap

/// The rule list is identical with and without a scope; scoped to the inbox, a filtered list would
/// draw "nothing matches" with rules configured.
    @Test func theRuleListIsTheSameWithAndWithoutAScope() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.contentZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.contentZone)
        #expect(inked(scoped) > 2_000,
                "the Rules content card rendered almost nothing — this comparison would be vacuous")
        #expect(differingPixels(scoped, global) == 0,
                "the rule list changed when a scope was set — Rules is being narrowed by a folder again")
    }

/// The chip stays on screen while Rules suspends it; hiding it would read as the scope cleared.
    @Test func theScopeChipStillDrawsOnRules() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.readoutZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.readoutZone)
        #expect(differingPixels(scoped, global) > 200,
                "row 2 renders the same with and without a scope on Rules — the chip has vanished, which reads as the scope having been cleared")
    }

/// Standing on Rules must not lift the scope off the other five badges: if `railCounts` read the
/// selected lens's scope, every other badge would jump to its global number.
    @Test func theOtherFiveBadgesKeepTheirScopeWhileRulesIsSelected() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.railZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.railZone)
        #expect(inked(scoped) > 1_000, "the rail rendered almost nothing — this comparison is vacuous")
        #expect(differingPixels(scoped, global) > 40,
                "the rail draws the same badges with and without a scope while Rules is selected — selecting Rules has lifted the scope off the five lenses that do use it")
    }

/// The suspended chip drops the accent wash, so it can't be mistaken for one that applies.
/// `OrganizeScopeChipTests` proves the two states differ in isolation; this checks the wiring.
/// Counted as blue-over-red on the chip's leading run.
    @Test func theSuspendedChipDropsTheAccentWash() {
        func accentPixels(_ lens: OrganizeLens) -> Int {
            let rep = strip(mount(Self.manager(), lens: lens, scope: Self.inbox),
                            CGRect(x: 8, y: 44, width: 240, height: 30))
            return PixelProbe.count(in: rep) { $0.blueComponent - $0.redComponent > 0.08 }
        }
        let live = accentPixels(.toFile)
        let suspended = accentPixels(.rules)
        #expect(live > 300, "the live chip painted no accent wash — this comparison would be vacuous")
        #expect(suspended < live / 4,
                "the chip on Rules is still wearing the accent wash (\(suspended) vs \(live) accent pixels) — it looks like it is narrowing a list it is not")
    }

/// The control: on a scoped lens the scope reaches the list, or the tests above pass on a build
/// where the scope does nothing anywhere.
    @Test func aScopedLensStillNarrowsItsList() {
        let scoped = strip(mount(Self.manager(), lens: .renames, scope: Self.inbox), Self.contentZone)
        let global = strip(mount(Self.manager(), lens: .renames, scope: nil), Self.contentZone)
        #expect(inked(global) > 2_000, "the Renames list rendered almost nothing — vacuous comparison")
        #expect(differingPixels(scoped, global) > 1_000,
                "the Renames list is unchanged by a scope that excludes every one of its findings — the scope has stopped reaching the lenses that do use it")
    }
}
