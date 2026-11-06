import Foundation
import Testing
@testable import Sync

/// The live tree and roster the ground-truth suite measures against. A separate type so the
/// suite's `@Suite(.enabled(if:))` can reference it: an attribute naming the annotated type's own
/// statics is a circular macro reference.
enum PersonCandidatesLiveData {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Documents") }

    static var profilesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/SyncCloud/profiles")
    }

    /// The roster as the user wrote it, or nil when this machine has none.
    static func roster() -> [Person]? {
        guard let id = FilingProfileStore.activeProfileId(in: profilesDirectory) else { return nil }
        let loaded = FilingProfileStore.personRegistry(id: id, profile: nil, in: profilesDirectory)
        return loaded.people.isEmpty ? nil : loaded.people
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.path) && roster() != nil
    }
}

/// What the household proposer finds on a real tree, measured against a real roster. Pinned to
/// this machine because the rule is a heuristic over folder names, and only a tree somebody really
/// organised can say whether it is useful; a fixture would grade it against invented folders.
/// Gated by `.enabled(if:)` on `~/Documents` and `people.json`, so it skips elsewhere; the in-test
/// `#require`s fail if the roster vanishes between discovery and run. `PersonCandidatesGateTests`
/// prints whether it ran.
@Suite(.enabled(if: PersonCandidatesLiveData.isAvailable,
                "no live tree or roster on this machine"))
struct PersonCandidatesGroundTruthTests {

    // Forwarders to `PersonCandidatesLiveData`, which the gate companion and the tests read
    // through these names.
    static var root: URL { PersonCandidatesLiveData.root }
    static func roster() -> [Person]? { PersonCandidatesLiveData.roster() }
    static var isAvailable: Bool { PersonCandidatesLiveData.isAvailable }

    /// The proposer finds most of a real household, and prints the numbers. Recall is asserted, not
    /// precision: a missed name is a person the user must think of unprompted, while an extra one
    /// is one tick to refuse. A rule tight enough to propose only people would drop members with a
    /// single folder.
    @Test(.machinePinned(.liveProfile))
    func theProposerFindsMostOfARealHousehold() async throws {
        try #require(Self.isAvailable, "no live tree or roster on this machine")
        let people = try #require(Self.roster())
        let tree = await FileSyncManager.buildTree(url: Self.root, sortOption: .name)
        try #require(!tree.isEmpty, "the live tree walked to nothing — this would measure an empty rule")

        let proposals = PersonCandidates.propose(tree: tree)
        let proposed = Set(proposals.map { $0.name.lowercased() })
        let roster = Set(people.map { $0.displayName.lowercased() })
        let found = roster.intersection(proposed)
        let missed = roster.subtracting(proposed)

        print("[people-ground-truth] tree=\(tree.count) top-level, roster=\(roster.count), "
              + "proposed=\(proposals.count), of the roster found=\(found.count) "
              + "missed=\(missed.sorted().joined(separator: ", "))")
        print("[people-ground-truth] proposals: "
              + proposals.prefix(15).map { "\($0.name)(\($0.folderCount))" }.joined(separator: " "))

        // A majority, not everybody: a member with one folder and no household parent gives a
        // name-only rule nothing to find, and the dialog's Add field covers them. A failure here
        // means the rule got tighter, not the tree.
        #expect(found.count * 2 >= roster.count,
                "the proposer found \(found.count) of \(roster.count) — it is missing more of the household than it finds, and the setup step would be offering noise")
    }

    /// The proposal list stays within the roster's order of magnitude. Not a precision bar, since
    /// over-proposing is intended, but two hundred names to confirm is a second job, not a step.
    /// Printed either way.
    @Test(.machinePinned(.liveProfile))
    func theProposalListStaysShortEnoughToRead() async throws {
        try #require(Self.isAvailable, "no live tree or roster on this machine")
        let people = try #require(Self.roster())
        let tree = await FileSyncManager.buildTree(url: Self.root, sortOption: .name)
        let proposals = PersonCandidates.propose(tree: tree)

        print("[people-ground-truth] \(proposals.count) proposal(s) for a \(people.count)-person roster")
        #expect(proposals.count <= 40,
                "\(proposals.count) names to confirm is not a step, it is a second job")
    }

    /// Names already on the roster are not offered back.
    @Test(.machinePinned(.liveProfile))
    func theProposerDoesNotOfferPeopleTheRosterAlreadyHas() async throws {
        try #require(Self.isAvailable, "no live tree or roster on this machine")
        let people = try #require(Self.roster())
        let tree = await FileSyncManager.buildTree(url: Self.root, sortOption: .name)

        let known = Set(people.flatMap(\.nameForms))
        let proposals = PersonCandidates.propose(tree: tree, known: known)
        let offeredBack = proposals.filter { candidate in
            people.contains { $0.displayName.lowercased() == candidate.name.lowercased() }
        }
        #expect(offeredBack.isEmpty,
                "offered \(offeredBack.map(\.name)) back to a user who already added them")
    }
}

/// Always runs, and prints whether the suite above did, naming the gate that closed. A green run
/// doesn't say which machine-pinned suites were in it. The same shape as
/// `FolderSurveyGroundTruthGateTests`.
@Suite struct PersonCandidatesGateTests {
    @Test func reportsWhetherTheGroundTruthSuiteCanRun() {
        // The exclusion comes first, from the gate the tests' `.machinePinned(.liveProfile)`
        // traits read, so the report can't say RAN on CI where the trait skipped every test. The
        // line is then held to the gates it read.
        let excluded = MachinePinnedGate.isExcluded(.liveProfile)
        let available = PersonCandidatesGroundTruthTests.isAvailable
        let line: String
        if excluded {
            line = "SKIPPED — machine-pinned (liveProfile), excluded via SYNCCLOUD_SKIP_MACHINE_PINNED"
        } else if available {
            line = "RAN — the proposer was checked against the live tree and roster"
        } else {
            let tree = FileManager.default.fileExists(atPath: PersonCandidatesGroundTruthTests.root.path)
            line = "SKIPPED — " + (tree ? "no roster on this machine" : "no ~/Documents on this machine")
        }
        print("[people-ground-truth] \(line)")
        #expect(line.hasPrefix("RAN") == (!excluded && available),
                "the gate report says \(line) while the gates read excluded=\(excluded) available=\(available)")
    }
}
