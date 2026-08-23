import Foundation
import Testing
@testable import Sync

/// The live tree and roster the ground-truth suite measures against. A separate type solely so
/// the suite's `@Suite(.enabled(if:))` attribute can reference it — an attribute referencing the
/// annotated type's own statics is a circular macro reference.
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

/// What the household proposer actually finds on a real tree, measured against a real roster.
///
/// **Machine-pinned, and it earns the pin.** The rule is a heuristic over folder names, and the only
/// honest way to know whether it is useful is to run it over a tree somebody really organised and
/// compare it with the household they really wrote down. A fixture cannot answer that: I would be
/// grading the rule against folders I invented to suit it.
///
/// Gated on the developer's `~/Documents` and its `people.json` being present, so it reports SKIPPED
/// on any other machine rather than failing. `PersonCandidatesGateTests` always runs and prints the
/// verdict, because a suite that silently vanishes is one nobody notices has stopped checking.
///
/// The `.enabled(if:)` is what makes that sentence true: the in-test `#require(Self.isAvailable)`
/// lines FAIL when the roster is absent — they are the belt for a machine where the roster
/// disappears between discovery and run — so without this gate, the companion printed SKIPPED for
/// a state that actually went red.
@Suite(.enabled(if: PersonCandidatesLiveData.isAvailable,
                "no live tree or roster on this machine"))
struct PersonCandidatesGroundTruthTests {

    // Forwarders: the data lives in `PersonCandidatesLiveData` because a `@Suite` attribute that
    // references the suite's own statics is a circular macro reference and does not compile; the
    // gate companion and the tests keep reading it through these names.
    static var root: URL { PersonCandidatesLiveData.root }
    static func roster() -> [Person]? { PersonCandidatesLiveData.roster() }
    static var isAvailable: Bool { PersonCandidatesLiveData.isAvailable }

    /// The proposer finds most of a real household, and says so with numbers.
    ///
    /// **Recall is what is asserted, not precision**, and the asymmetry is the design: a name the
    /// rule misses is a person the user has to think of unprompted, while a name it over-proposes is
    /// one tick to refuse with the evidence beside it. A rule tuned the other way — tight enough to
    /// propose only people — would drop the household members who have a single folder.
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

        // The bar is deliberately a majority rather than everybody: a member with one folder and no
        // household parent has nothing for a name-only rule to find, and the dialog's Add field is
        // what covers them. If this ever fails, the rule got tighter, not the tree.
        #expect(found.count * 2 >= roster.count,
                "the proposer found \(found.count) of \(roster.count) — it is missing more of the household than it finds, and the setup step would be offering noise")
    }

    /// The proposals a human has to wade through stay in the same order of magnitude as the roster.
    ///
    /// Not a precision bar — over-proposing is the intended direction — but a list of two hundred
    /// names is not a confirmation step, it is a second job. This is the number that says whether
    /// the step is usable, and it is printed either way.
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

/// Always runs, and prints whether the suite above did.
///
/// The same shape as `FolderSurveyGroundTruthGateTests`: a machine-pinned suite is routinely absent
/// from a green run, and a green run does not say which suites were in it. This one names the gate
/// that closed.
@Suite struct PersonCandidatesGateTests {
    @Test func reportsWhetherTheGroundTruthSuiteCanRun() {
        // The exclusion is consulted FIRST, from the same gate the tests' own
        // `.machinePinned(.liveProfile)` traits read. Without it this printed "RAN — the proposer
        // was checked against the live tree" on every CI run — where the trait had disabled all
        // three tests — which is the exact false positive the template
        // (`FolderSurveyGroundTruthGateTests`) exists to prevent: a report that cannot say RAN
        // for a suite its trait has skipped. The old `#expect(Bool(true))` asserted nothing;
        // the line is now held to the gates it read.
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
