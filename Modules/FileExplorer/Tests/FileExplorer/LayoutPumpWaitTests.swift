import AppKit
import Testing
@testable import FileExplorer

/// Pins `LayoutPumpWait`'s pass floor, which ten mounted-view suites in this target rely on. A
/// deadline counts seconds while these waits need main-actor turns, and under load the two come
/// apart (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). The floor guarantees enough turns
/// whatever the clock says, and that guarantee is deterministic, so it is tested with a counter and
/// an already-spent deadline instead of by re-rolling pass rates. The loop re-checks once after the
/// deadline, so a floor of N gives N + 1 evaluations.
@MainActor
@Suite struct LayoutPumpWaitTests {

    /// A bare view, deliberately: the subject is this loop's own accounting, not AppKit layout.
    /// Anything with real layout cost would make the pass counts below depend on the machine.
    private func host() -> NSView { NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }

    /// How many passes the conditions below demand. A literal, not derived from the floor: a demand
    /// that moved with the floor would shrink with it and let `held` pass vacuously.
    private static let passesDemanded = 3

    /// Five, not the production fifty: the loop's shape doesn't depend on the floor's size, and a
    /// pass can cost seconds on a saturated CI main actor. A literal, so it can't move with it.
    private static let testFloor = 5

    /// Pins the production floor at fifty, the value every real wait uses. The other tests run
    /// against ``testFloor`` and can't see it. Fifty is the figure measured in `docs/flaky-tests.md`
    /// ("Fixed pumps and fixed sleeps"); changing it is a flake-protection decision.
    @Test func theProductionFloorIsStillFifty() {
        #expect(LayoutPumpWait.pumpFloor == 50,
                "the floor every real wait uses is now \(LayoutPumpWait.pumpFloor) — see docs/flaky-tests.md mechanism 2 before changing it")
        #expect(Self.testFloor < LayoutPumpWait.pumpFloor,
                "the test floor is no longer cheaper than the production one — these tests exist to be cheap")
    }

    /// With the deadline already spent, a condition that needs turns still gets them, which is what
    /// a congested run lacks. The demand must be reachable within the floor, or this would measure
    /// the deadline instead.
    @Test func theFloorOutlivesAnExpiredDeadline() async throws {
        try #require(Self.passesDemanded < Self.testFloor,
                     "\(Self.passesDemanded) passes is not reachable within a floor of \(Self.testFloor) — this would be measuring the deadline")
        var passes = 0
        let needed = Self.passesDemanded
        let outcome = await LayoutPumpWait.pump(host(), upTo: 0, floor: Self.testFloor) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held,
                "gave up after \(outcome.pumps) pass(es) with the deadline already spent — the floor is not carrying the wait")
        #expect(outcome.pumps == needed,
                "held after \(outcome.pumps) passes, expected exactly \(needed)")
    }

    /// The floor is a minimum, not a ceiling: a condition needing more passes still gets them while
    /// the deadline holds. The clock is frozen, because a demand in passes bounded by seconds lets
    /// load decide the verdict; `upTo:`'s 60 doesn't matter.
    @Test func theDeadlineStillCarriesTheWaitPastTheFloor() async {
        var passes = 0
        // Two past the floor: a floor-only loop reaches `floor + 1` through the post-deadline
        // re-check, so this is the smallest demand it can't meet. Any more is pure cost on CI.
        let needed = Self.testFloor + 2
        // Frozen: every read is the same instant, so `now() < deadline` is true forever.
        let frozen = Date(timeIntervalSince1970: 1_770_000_000)
        let outcome = await LayoutPumpWait.pump(host(), upTo: 60, floor: Self.testFloor,
                                                now: { frozen }) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held, "gave up after \(outcome.pumps) passes, needing \(needed)")
        #expect(outcome.pumps == needed,
                "held after \(outcome.pumps) passes, expected exactly \(needed) — the floor became a ceiling")
    }

    /// A never-true condition still gets a verdict after a bounded number of passes. The `+ 1` is
    /// the post-deadline re-check, which sees a condition that came true during the last sleep.
    @Test func aConditionThatNeverHoldsStillGetsAVerdict() async {
        let outcome = await LayoutPumpWait.pump(host(), upTo: 0, floor: Self.testFloor) { false }
        #expect(!outcome.held, "a never-true condition reported held")
        #expect(outcome.pumps == Self.testFloor + 1,
                "gave up after \(outcome.pumps) passes, expected the floor's \(Self.testFloor) plus the post-deadline re-check")
    }

    /// The window entry point has its own copy of the loop, so it gets its own test: the copies can
    /// drift.
    @Test func theWindowEntryPointHonoursTheSameFloor() async {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host()
        defer { window.contentView = nil }

        var passes = 0
        let needed = Self.passesDemanded
        let outcome = await LayoutPumpWait.pump(window, upTo: 0, floor: Self.testFloor) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held,
                "the window variant gave up after \(outcome.pumps) pass(es) with the deadline spent")
        #expect(outcome.pumps == needed)
    }

    // MARK: The escape hatch stays shut

    /// Only a floor's own tests may lower a floor. The override lets them check the loop's shape in
    /// five turns; any other suite that lowers it looks faster locally and goes red on a loaded
    /// runner. Scans every package's tests, comment lines ignored, since every package waits on it.
    @Test func theFloorIsOnlyLoweredByItsOwnTests() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // …/Modules
        // Each of these IS a floor's own test — the only category allowed to lower one.
        let permitted: Set<String> = ["LayoutPumpWaitTests.swift", "LayoutPumpWaitPollTests.swift"]
        var scanned = 0
        var offenders: [String] = []
        var permittedSeen: Set<String> = []

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.path.contains("/Tests/"),
                  // SwiftPM checks dependencies out under `.build`, and one of them passes a
                  // `floor:` of its own. Their sources are not this repo's to police.
                  !url.path.contains("/.build/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // The declaration in `LayoutPumpWait`, in both targets' copies, isn't a caller.
            guard code.replacingOccurrences(of: "floor: Int = pumpFloor", with: "")
                      .contains("floor: ") else { continue }
            let name = url.lastPathComponent
            if permitted.contains(name) { permittedSeen.insert(name) } else { offenders.append(name) }
        }

        // Non-vacuity: the walk read a real tree and can see the uses it permits, so "no offenders"
        // can't just mean "read nothing".
        try #require(scanned > 200, "the scan read \(scanned) test files — it is broken, not the repo")
        #expect(permittedSeen == permitted,
                "the scan did not find `floor:` in \(permitted.subtracting(permittedSeen)) — it would report any caller as clean")
        #expect(offenders.isEmpty,
                "\(offenders) lower a wait floor without being that floor's own test. That is mechanism 2 by hand: the floor is what carries a wait on a congested runner, and a suite that shrinks it will pass locally and go red on CI.")
    }
}
