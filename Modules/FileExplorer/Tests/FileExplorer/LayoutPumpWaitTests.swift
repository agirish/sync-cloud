import AppKit
import Testing
@testable import FileExplorer

/// Pins `LayoutPumpWait`'s pass floor — the one constant ten mounted-view suites in this target
/// depend on, and until now the only thing in the flake defence with no test of its own.
///
/// The floor exists because a deadline is in seconds while everything these waits wait for arrives
/// on main-actor turns, and under full-suite congestion the two units come apart (see
/// `docs/flaky-tests.md`, mechanism 2). That failure only reproduces under load, which is exactly
/// why it must not be the thing the fix is argued from: a flake fix that can only be shown by
/// re-rolling pass rates is a flake fix nobody can check. The floor's *guarantee* is deterministic
/// even though the bug it prevents is not — it is a property of this loop, provable with a counter
/// and an already-spent deadline, on an idle machine, in under a second.
///
/// Verified by mutation on the real constant, and the results are worth recording exactly because
/// two of them are not what they look like:
///
/// - `pumpFloor = 0` — the premise guard fails, and both floor tests fail on `held` AND on their
///   count (1 pass against the 25 demanded). This is the mutation that matters: with the floor
///   gone, every one of the ten calling suites reverts silently to the wall-clock behaviour that
///   was flaking, and no other suite in the target would have said so.
/// - `pumpFloor = 24`, one short of the demand — **only the premise guard fails.** The floor tests
///   still pass, because the loop evaluates `condition()` once more after the deadline, so 24
///   passes buys a 25th evaluation. The floor's real guarantee is `pumpFloor + 1` evaluations, and
///   that off-by-one is the whole reason the premise guard is a separate test rather than a
///   comment: without it a floor lowered to just under the demand would look healthy here.
/// - `aConditionThatNeverHoldsStillGetsAVerdict` catches neither, because its expectation is
///   written in terms of `pumpFloor` and moves with it. It is pinning the post-deadline re-check
///   and the fact that a never-true condition terminates at all — not the floor's magnitude.
@MainActor
@Suite struct LayoutPumpWaitTests {

    /// A bare view, deliberately: the subject is this loop's own accounting, not AppKit layout.
    /// Anything with real layout cost would make the pass counts below depend on the machine.
    private func host() -> NSView { NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }

    /// How many passes the conditions below demand — a LITERAL, deliberately not derived from
    /// `pumpFloor`. Writing it as `pumpFloor / 2` was the first version and it defeated its own
    /// mutation test: zeroing the floor also zeroed the requirement, so the condition held on the
    /// first pass and the `held` assertion — the load-bearing one — passed vacuously against
    /// exactly the change it exists to catch. The count assertion still failed, so the suite went
    /// red, but for an incidental reason. A demand that moves with the thing under test cannot
    /// measure it.
    private static let passesDemanded = 3

    /// The floor these tests run against — **five, not the production fifty.**
    ///
    /// Everything below asserts a SHAPE: a demand under the floor is served after an expired
    /// deadline, a demand over it is served while the deadline holds, a never-true condition still
    /// terminates. None of those depend on the floor's magnitude, and depending on it was
    /// expensive: a pass costs 5–7 SECONDS on a saturated CI main actor (8ms idle), so this suite
    /// and its two siblings were spending ~1,737s of a 665s CI step between them — the largest
    /// single cost in the run, and all of it testing the test helper rather than the app.
    ///
    /// A literal, like ``passesDemanded``, and for the same reason: derived from `pumpFloor` it
    /// would move with the thing under test and stop measuring it.
    private static let testFloor = 5

    /// Keeps the literal above meaningful: it must be reachable within the floor, or these tests
    /// would be measuring the deadline instead. Fails loudly rather than drifting if the floor
    /// is ever lowered past it.
    @Test func theDemandUsedByTheseTestsSitsBelowTheFloor() {
        #expect(Self.passesDemanded < Self.testFloor,
                "\(Self.passesDemanded) passes is not reachable within a floor of \(Self.testFloor) — the floor tests below would be measuring the deadline")
    }

    /// **The production floor's VALUE, pinned here because nothing else exercises it any more.**
    ///
    /// The tests below run against ``testFloor`` so they cost five passes instead of fifty. That
    /// is sound for the loop's shape and blind to the number every real wait actually uses — so
    /// the number gets its own assertion, which costs nothing. Fifty is the measured figure from
    /// `docs/flaky-tests.md` mechanism 2; changing it is a decision about flake protection, and
    /// this is where that decision has to be made deliberately.
    @Test func theProductionFloorIsStillFifty() {
        #expect(LayoutPumpWait.pumpFloor == 50,
                "the floor every real wait uses is now \(LayoutPumpWait.pumpFloor) — see docs/flaky-tests.md mechanism 2 before changing it")
        #expect(Self.testFloor < LayoutPumpWait.pumpFloor,
                "the test floor is no longer cheaper than the production one — these tests exist to be cheap")
    }

    /// The load-bearing property. With the deadline ALREADY spent, a condition that needs turns
    /// still gets them — which is precisely what a congested run has too few of.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
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

    /// The floor is a minimum, not a ceiling: a condition that needs more passes than the floor
    /// still gets them while the deadline holds. Without this, "raise the floor" and "the wait
    /// stops early" would look identical from the test above.
    ///
    /// **The clock is frozen, and that is the whole point.** This test asserts that a demand
    /// denominated in PASSES is served; bounding it with a budget denominated in SECONDS is
    /// mechanism 2 committed by the test written to document mechanism 2, and it went wrong twice:
    ///
    /// - At 30s it failed six full-package runs out of six while passing every time under
    ///   `--filter` — sixty passes cost ~1.1s each on a congested main actor against 8ms idle, so
    ///   the deadline expired around pass 50 and the loop stopped at the floor.
    /// - It was then "fixed" by raising the deadline to 300s, on the argument that congestion could
    ///   not reach that. On 2026-08-13 congestion reached it: 57 passes of the 60 needed, in 304
    ///   seconds — ~5.3s per pass, five times the rate that argument had already called congested.
    ///   The run was red, on a commit that shares no symbol with this file.
    ///
    /// A bigger number was never the answer. `poll` has had an injectable clock since 2026-08-03
    /// for exactly this reason and `pump` did not; now it does. With `now` frozen the deadline can
    /// never expire, so the CONDITION decides when the loop ends and this asserts the loop's shape
    /// rather than the machine's throughput. `upTo:` is left at an ordinary 60 to make the point
    /// that its value no longer matters — see ``LayoutPumpWaitPollTests``, whose sibling test has
    /// had this shape all along.
    ///
    /// The regression it guards against still returns immediately: if the floor became a ceiling
    /// the loop exits at `pumpFloor` and reports 51 passes, red, in milliseconds.
    @Test func theDeadlineStillCarriesTheWaitPastTheFloor() async {
        var passes = 0
        let needed = Self.testFloor + 10
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

    /// A real regression must still get a verdict, and must get it after a bounded number of
    /// passes rather than by spinning. The `+ 1` is the loop's post-deadline re-check, which is
    /// what lets a condition that became true during the last sleep still be seen.
    @Test func aConditionThatNeverHoldsStillGetsAVerdict() async {
        let outcome = await LayoutPumpWait.pump(host(), upTo: 0, floor: Self.testFloor) { false }
        #expect(!outcome.held, "a never-true condition reported held")
        #expect(outcome.pumps == Self.testFloor + 1,
                "gave up after \(outcome.pumps) passes, expected the floor's \(Self.testFloor) plus the post-deadline re-check")
    }

    /// The window entry point carries a byte-identical loop, and the two have drifted before —
    /// the note on `LayoutPumpWait` records the copy that kept a bug after the other was fixed.
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

    /// **Only a floor's own tests may lower a floor.**
    ///
    /// The repo has several of these waits and each carries a floor of 50 main-actor turns. The
    /// override exists so that the tests OF a floor can assert its shape in five turns instead of
    /// fifty — they assert a shape, and the shape does not depend on the magnitude. Every real wait
    /// must take the default: a suite that quietly lowered its own floor would be re-opening
    /// mechanism 2 by hand, and it would look like a speed-up right up until it went red on a
    /// loaded runner, which is exactly the history `docs/flaky-tests.md` records.
    ///
    /// Scanned across every package's test tree rather than this one, because the floors live in
    /// four places and the rule is about all of them — `ShortcutRevealTrackerTests` owns Design's.
    /// Comment-stripped, so a note *about* `floor:` is not a violation.
    @Test func theFloorIsOnlyLoweredByItsOwnTests() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // …/Modules
        // Each of these IS a floor's own test — the only category allowed to lower one.
        let permitted: Set<String> = ["LayoutPumpWaitTests.swift", "LayoutPumpWaitPollTests.swift",
                                      "ShortcutRevealTrackerTests.swift"]
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
            // The DECLARATION is not a caller: `LayoutPumpWait` itself spells the parameter out,
            // in both targets' copies, and that is the thing being guarded rather than a use of it.
            guard code.replacingOccurrences(of: "floor: Int = pumpFloor", with: "")
                      .contains("floor: ") else { continue }
            let name = url.lastPathComponent
            if permitted.contains(name) { permittedSeen.insert(name) } else { offenders.append(name) }
        }

        // Non-vacuity, both halves: the walk found a real tree, and it can actually see the uses
        // it is permitting — otherwise "no offenders" would mean "no reader".
        try #require(scanned > 200, "the scan read \(scanned) test files — it is broken, not the repo")
        #expect(permittedSeen == permitted,
                "the scan did not find `floor:` in \(permitted.subtracting(permittedSeen)) — it would report any caller as clean")
        #expect(offenders.isEmpty,
                "\(offenders) lower a wait floor without being that floor's own test. That is mechanism 2 by hand: the floor is what carries a wait on a congested runner, and a suite that shrinks it will pass locally and go red on CI.")
    }
}
