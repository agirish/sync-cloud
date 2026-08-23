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

    /// The report's gates are a COPY of the suites' traits, and only convention kept them equal —
    /// a suite that gained a third gate (the folder-survey template has one: display awake) would
    /// leave the report printing RAN for a suite the new gate had skipped, and nothing above can
    /// see that: the RAN assertion compares the line to the report's OWN inputs. This scan binds
    /// the copy to the suites' `@Suite(` attributes: a condition joining or leaving either trait
    /// fails here and names the report as the thing to update.
    @Test func theReportedGatesMatchTheSuitesOwnTraits() throws {
        func suiteAttribute(of file: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent(file)
            let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                    "cannot read \(file) — the trait pin would be vacuous")
            let start = try #require(text.range(of: "\n@Suite("), "\(file) lost its @Suite attribute")
            let after = text[start.upperBound...]
            let end = try #require(after.range(of: "\nstruct "), "\(file)'s @Suite attribute never reaches its struct")
            return String(after[..<end.lowerBound])
        }

        let replayTraits = try suiteAttribute(of: "PersonChannelReplayTests.swift")
        #expect(replayTraits.contains("LiveProfile.isAvailable && LiveCorpus.isAvailable"),
                "the replay suite's gate changed — update theRunSaysWhetherTheLiveProfileSuitesRan's replayGates to match: \(replayTraits)")
        #expect(replayTraits.components(separatedBy: ".enabled(if:").count - 1 == 1,
                "the replay suite gained or lost an .enabled gate — the report's gates are now a stale copy")
        #expect(replayTraits.contains(".machinePinned(.liveProfile)"))

        let scopeTraits = try suiteAttribute(of: "OrganizeScopeLiveProfileTests.swift")
        #expect(scopeTraits.contains("LiveProfile.isAvailable"))
        #expect(!scopeTraits.contains("LiveCorpus"),
                "the scope suite now consults the corpus — the report's single-gate copy is stale")
        #expect(scopeTraits.components(separatedBy: ".enabled(if:").count - 1 == 1,
                "the scope suite gained or lost an .enabled gate — the report's gates are now a stale copy")
        #expect(scopeTraits.contains(".machinePinned(.liveProfile)"))
    }
}
