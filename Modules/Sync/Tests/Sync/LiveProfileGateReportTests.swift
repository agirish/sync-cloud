import Foundation
import Testing
@testable import Sync

/// The `FolderSurveyGroundTruthGateTests` treatment, extended to the other liveProfile-pinned
/// suites: a machine-pinned suite is routinely absent from a green run, and a green run does not
/// say which suites were in it — so each pinned suite gets an ungated companion line in the CI
/// step log saying whether it ran, and which gate closed it when it did not.
///
/// `FolderSurveyGroundTruth` carries its own (it has a third gate, the display); this file covers
/// `PersonChannelReplayTests` and `OrganizeScopeLiveProfileTests`, which until now vanished from
/// every CI run with nothing said.
enum LiveProfileSuiteGate {
    /// Exclusion first — it outranks every content gate, and it is the branch CI always takes:
    /// with `SYNCCLOUD_SKIP_MACHINE_PINNED=liveProfile` the trait disables the suite whatever the
    /// gates say, so naming a closed content gate would send the reader to fix a profile that was
    /// never the reason. Then the FIRST closed gate, because later gates were never the reason
    /// either.
    static func line(excluded: Bool, gates: [(name: String, open: Bool)]) -> String {
        if excluded {
            return "SKIPPED — machine-pinned (liveProfile), excluded via SYNCCLOUD_SKIP_MACHINE_PINNED"
        }
        if let closed = gates.first(where: { !$0.open }) {
            return "SKIPPED — \(closed.name)"
        }
        return "RAN — every gate open"
    }
}

@Suite struct LiveProfileSuiteGateTests {

    /// The line's own logic, across the combinations, so it cannot come to say "ran" for a closed
    /// gate — the first half of the template's split.
    @Test func exclusionOutranksTheGatesAndTheFirstClosedGateIsNamed() {
        for combo in [[true, true], [true, false], [false, true], [false, false]] {
            let line = LiveProfileSuiteGate.line(excluded: true,
                                                gates: [("a", combo[0]), ("b", combo[1])])
            #expect(line.hasPrefix("SKIPPED"), "an excluded reason reported \(line)")
            #expect(line.contains("SYNCCLOUD_SKIP_MACHINE_PINNED"),
                    "an excluded reason must name the variable that excluded it: \(line)")
        }
        #expect(LiveProfileSuiteGate.line(excluded: false, gates: [("a", true), ("b", true)])
            .hasPrefix("RAN"))
        #expect(LiveProfileSuiteGate.line(excluded: false, gates: [("first gate", false), ("b", false)])
            .contains("first gate"),
                "the first closed gate is the reason; naming a later one misdirects the reader")
        #expect(LiveProfileSuiteGate.line(excluded: false, gates: [("a", true), ("second gate", false)])
            .contains("second gate"))
    }

    /// The real lines, read from the SAME gates the suites' own traits consult, so the report
    /// cannot say RAN for a suite the trait has disabled — the second half of the split. stdout,
    /// because that is what a CI step log keeps; the Activity Log's in-memory buffer is capped and
    /// shared.
    @Test func theRunSaysWhetherTheLiveProfileSuitesRan() {
        let excluded = MachinePinnedGate.isExcluded(.liveProfile)

        let replayGates = [(name: "no live filing profile on this machine", open: LiveProfile.isAvailable),
                           (name: "no live corpus on this machine", open: LiveCorpus.isAvailable)]
        let replay = LiveProfileSuiteGate.line(excluded: excluded, gates: replayGates)
        print("[channel-replay] \(replay)")
        #expect(replay.hasPrefix("RAN") == (!excluded && LiveProfile.isAvailable && LiveCorpus.isAvailable),
                "the gate report says \(replay) while the gates read excluded=\(excluded) profile=\(LiveProfile.isAvailable) corpus=\(LiveCorpus.isAvailable)")

        let scopeGates = [(name: "no live filing profile on this machine", open: LiveProfile.isAvailable)]
        let scope = LiveProfileSuiteGate.line(excluded: excluded, gates: scopeGates)
        print("[organize-scope-live] \(scope)")
        #expect(scope.hasPrefix("RAN") == (!excluded && LiveProfile.isAvailable),
                "the gate report says \(scope) while the gates read excluded=\(excluded) profile=\(LiveProfile.isAvailable)")
    }
}
