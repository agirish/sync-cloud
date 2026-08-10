import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// ROADMAP 15's trap, **mounted and read back**: opening Rules aims Organize at the source root,
/// and leaving it puts the scope back.
///
/// ## Why this suite is not `OrganizeLensTests`
///
/// `OrganizeLens.isScoped` is a pure two-line rule and is asserted directly over there. What that
/// cannot see is whether the view *obeys* it — a rule extracted for testability is one revert away
/// from being decorative, and this feature has three distinct places that must agree with it: the
/// rows (`filteredRows`), the badges (`railCounts`) and the chip (`scopeChip`). Each is a private
/// member of a view SwiftUI will not let a test drive, so the instrument is pixels.
///
/// ## Every claim is a DIFFERENCE between two mounts that differ in one thing
///
/// Each test renders the same lens twice — once with a scope stored, once without — and asserts the
/// two bands either match or differ. Holding the lens fixed is what makes the comparison mean
/// something: comparing Rules against To File would move the selection ring, the readout and the
/// whole content card at the same time, and any of those would explain a difference.
///
/// The fixture is the trap itself. The scope is the loose-files inbox — the sticky one-click scope
/// Organize's own overview offers — and the rules file *out* of it, into `Medical/…` and
/// `Finance/{year}`, so under the predicate this replaced **every** rule was filtered away.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeRulesScopeTests {

    private static let canvas = CGSize(width: 1400, height: 620)
    private static let root = "/root"
    /// The inbox, which is where the rail is parked when the trap springs.
    private static let inbox = "/root/TODO"

    /// The rail: six capsules on row 1, badges and all. Same band `OrganizeRailTests` measured.
    private static let railZone = CGRect(x: 8, y: 12, width: 580, height: 30)
    /// Row 2, where the scope chip is drawn — for every lens, above the switch.
    private static let readoutZone = CGRect(x: 8, y: 44, width: 580, height: 30)
    /// The content card: the rule list itself, well below the two-row header ladder.
    private static let contentZone = CGRect(x: 20, y: 110, width: 1360, height: 420)

    // MARK: Fixtures

    /// Two complete rules, **both filing out of the inbox and into somewhere else** — which is what
    /// every real rule does, and what made the scope predicate hide all of them.
    private static var rules: [AutomationRule] {
        [AutomationRule(name: "Medical bills", matchMode: .any,
                        conditions: [.mentionsAll(["bill"])],
                        destinationTemplate: "Medical/Bills"),
         AutomationRule(name: "Tax forms", matchMode: .any,
                        conditions: [.mentionsAll(["1099"])],
                        destinationTemplate: "Finance/{year}")]
    }

    /// Findings for the five lenses that ARE scoped, deliberately placed OUTSIDE the inbox — so a
    /// scope that is being applied takes their badges to nothing and an unapplied one leaves them
    /// reporting. That difference is what `theOtherFiveBadgesKeepTheirScope` reads.
    private static func manager() -> FileSyncManager {
        let m = FileSyncManager()
        m.automationRules = rules
        m.riskyNames = (1...7).map {
            RiskyName(id: "/root/Legal/bad:name\($0).pdf", relativePath: "Legal/bad:name\($0).pdf",
                      currentName: "bad:name\($0).pdf", sanitizedName: "bad-name\($0).pdf",
                      reason: "colon", isDirectory: false)
        }
        m.hasScannedNames = true
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
        // The scope goes through the key `TidyView` actually reads, and as a STORED string — the
        // hazard a persisted, user-arrangeable value has is that a fixture built from the in-memory
        // default never exercises what a real launch reads off disk.
        defaults.set(scope ?? "", forKey: OrganizeScopeDefaults.pathKey)
        let subject = TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: Self.root, onFindDuplicates: {},
                               providerRoot: Self.root)
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        // Twice: `.onGeometryChange` writes `railStyle` after a pass, so one layout renders the
        // initial `.full` and never the width-dependent answer.
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else {
            fatalError("no bitmap rep for \(band)")
        }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels that differ between two same-sized bands.
    ///
    /// **A count, not a Bool.** "They differ" is satisfied by one stray antialiased pixel, and the
    /// claims below are about a whole rule list or a whole chip appearing — so the assertions carry
    /// a floor, and the ones that demand sameness demand exactly zero.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 {
                    differing += 1
                }
            }
        }
        return differing
    }

    /// Pixels in a band that are not its own background corner — the "did anything render" check
    /// that keeps every comparison below from passing over two blank images.
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - background.redComponent),
                       max(abs(c.greenComponent - background.greenComponent),
                           abs(c.blueComponent - background.blueComponent))) > 0.03 {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: The trap

    /// **The rule list is identical with and without a scope.** This is the whole item.
    ///
    /// Scoped to the inbox, the predicate this replaced hid both rules and the lens rendered its
    /// "nothing matches" state — the one rail item that is not allowed to say "nothing here" saying
    /// exactly that with rules configured, and the only way out being to abandon the scope you were
    /// working. Zero differing pixels is the strongest form of "the scope does not reach here": not
    /// "enough rules survived", but *the scope changed nothing at all*.
    @Test func theRuleListIsTheSameWithAndWithoutAScope() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.contentZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.contentZone)
        #expect(inked(scoped) > 2_000,
                "the Rules content card rendered almost nothing — this comparison would be vacuous")
        #expect(differingPixels(scoped, global) == 0,
                "the rule list changed when a scope was set — Rules is being narrowed by a folder again")
    }

    /// **The chip stays on screen while Rules suspends it.**
    ///
    /// The alternative — hiding it — reads as *the scope was cleared*, and the user's next move is
    /// to set it again, which is the one-way trip stated backwards. Read as a difference between
    /// scoped and unscoped on the SAME lens: with the chip suppressed the two rows would be
    /// identical.
    @Test func theScopeChipStillDrawsOnRules() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.readoutZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.readoutZone)
        #expect(differingPixels(scoped, global) > 200,
                "row 2 renders the same with and without a scope on Rules — the chip has vanished, which reads as the scope having been cleared")
    }

    /// **Standing on Rules must not lift the scope off the other five badges.**
    ///
    /// The rail draws all six whatever is selected. `railCounts` reading the *selected* lens's scope
    /// — one `let scope = scope` at the top, which is what it used to be — takes every other badge
    /// back to its global number the instant you click Rules: Names jumping from nothing to 7
    /// because a sixth item does not use the scope. The fixture's risky names all sit in `Legal`,
    /// outside the inbox, so an applied scope hides them and an unapplied one does not.
    @Test func theOtherFiveBadgesKeepTheirScopeWhileRulesIsSelected() {
        let scoped = strip(mount(Self.manager(), lens: .rules, scope: Self.inbox), Self.railZone)
        let global = strip(mount(Self.manager(), lens: .rules, scope: nil), Self.railZone)
        #expect(inked(scoped) > 1_000, "the rail rendered almost nothing — this comparison is vacuous")
        #expect(differingPixels(scoped, global) > 40,
                "the rail draws the same badges with and without a scope while Rules is selected — selecting Rules has lifted the scope off the five lenses that do use it")
    }

    /// **The suspended chip drops the accent wash**, so it cannot be mistaken for one that applies.
    ///
    /// `theScopeChipStillDrawsOnRules` proves the chip is *there*; on its own that is satisfied by a
    /// chip drawn exactly as a live one, which would be the worst of the three outcomes — the lists
    /// silently ignoring a chip that still looks like it is narrowing them. `OrganizeScopeChipTests`
    /// proves the two states render differently *in isolation*; this is the wiring between them,
    /// which is the half a view-level suite cannot see.
    ///
    /// Measured as blue-over-red on the chip's own leading run: the live capsule is an accent wash
    /// (hue pinned to blue by the fixture) and the suspended one is neutral, so the count separates
    /// them without depending on either's exact geometry.
    @Test func theSuspendedChipDropsTheAccentWash() {
        func accentPixels(_ lens: OrganizeLens) -> Int {
            let rep = strip(mount(Self.manager(), lens: lens, scope: Self.inbox),
                            CGRect(x: 8, y: 44, width: 240, height: 30))
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.blueComponent - c.redComponent > 0.08 { count += 1 }
                }
            }
            return count
        }
        let live = accentPixels(.toFile)
        let suspended = accentPixels(.rules)
        #expect(live > 300, "the live chip painted no accent wash — this comparison would be vacuous")
        #expect(suspended < live / 4,
                "the chip on Rules is still wearing the accent wash (\(suspended) vs \(live) accent pixels) — it looks like it is narrowing a list it is not")
    }

    /// The control case: on a lens that IS scoped, the scope reaches the list.
    ///
    /// Without this the three tests above are satisfied by a build where the scope does nothing
    /// anywhere — the failure mode where a feature is "fixed" by deleting it. Names is scoped, its
    /// findings are outside the inbox, so its list must change when the scope is set.
    @Test func aScopedLensStillNarrowsItsList() {
        let scoped = strip(mount(Self.manager(), lens: .names, scope: Self.inbox), Self.contentZone)
        let global = strip(mount(Self.manager(), lens: .names, scope: nil), Self.contentZone)
        #expect(inked(global) > 2_000, "the Names list rendered almost nothing — vacuous comparison")
        #expect(differingPixels(scoped, global) > 1_000,
                "the Names list is unchanged by a scope that excludes every one of its findings — the scope has stopped reaching the lenses that do use it")
    }
}
