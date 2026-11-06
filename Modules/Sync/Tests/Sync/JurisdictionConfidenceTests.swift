import CoreGraphics
import Foundation
import Testing
@testable import Sync

/// The bar for pre-ticking a country, on fixtures. What the number should be is decided by
/// ``JurisdictionConfidenceGroundTruthTests`` below, against the reference tree. These pin what the
/// rule is made of, so a change to either half fails as itself.
@Suite struct JurisdictionConfidenceTests {

    private static func candidate(_ value: String, parents: Int) -> JurisdictionCandidate {
        JurisdictionCandidate(value: value,
                              parents: (0..<parents).map { "Parent\($0)" },
                              folderCount: parents * 2)
    }

    /// A country code that splits enough branches is offered already ticked: the case the rule
    /// exists for (`US` and `IN` on the reference tree).
    @Test func aRealCountryOverTheBarIsConfident() {
        #expect(JurisdictionCandidates.isConfident(Self.candidate("US", parents: 5)))
        #expect(JurisdictionCandidates.isConfident(Self.candidate("IN", parents: 9)))
    }

    /// Being a country is not enough. A value under the bar is proposed and left unticked: the
    /// user is asked, which costs a glance, rather than answered for, which costs a wrong profile.
    @Test func aRealCountryUnderTheBarIsProposedButNotTicked() {
        #expect(!JurisdictionCandidates.isConfident(Self.candidate("US", parents: 4)))
    }

    /// The count alone can't tell a country from a department, so both conditions are needed.
    /// Neither is sufficient: `IT` is a real ISO code and clears any bar on a tree with an IT
    /// department.
    @Test func somethingThatIsNotACountryIsNeverTicked() {
        #expect(!JurisdictionCandidates.isConfident(Self.candidate("EMP", parents: 12)))
        #expect(!JurisdictionCandidates.isConfident(Self.candidate("PRD", parents: 12)))
        #expect(JurisdictionCandidates.isConfident(Self.candidate("IT", parents: 12)),
                "IT is Italy to ISO, and the rule cannot see the department — the user unticks it")
    }

    /// A known limit: three-letter codes are proposed but never pre-tick, because the region list
    /// is alpha-2.
    @Test func threeLetterCodesCanNeverPreTick() {
        #expect(!JurisdictionCandidates.isConfident(Self.candidate("USA", parents: 20)))
        #expect(!JurisdictionCandidates.isConfident(Self.candidate("UAE", parents: 20)))
    }

    /// The two bars are different numbers on purpose, and in this order.
    @Test func theTickBarSitsAboveTheProposalBar() {
        #expect(JurisdictionCandidates.confidentDistinctParents
                > JurisdictionCandidates.minimumDistinctParents)
    }
}

/// The measurement the bar is set from: every value setup would pre-tick on the reference tree is
/// one the hand-built profile carries. Only the 3,000-folder tree the profile was written for can
/// answer that. If this fails, raise ``JurisdictionCandidates/confidentDistinctParents`` until it
/// passes and record the new number in that constant's doc comment.
///
/// Gated like ``FolderSurveyGroundTruthTests``: no live profile, a sleeping display (an iCloud
/// walk makes no progress), and CI. `SYNCCLOUD_SKIP_MACHINE_PINNED` names `liveProfile` there, so
/// this only runs locally, with the display awake and held.
@Suite(.enabled(if: LiveProfile.isAvailable,
                "no live folder profile on this machine — the confidence bar was not measured"),
       .enabled(if: FolderSurveyGroundTruth.displayIsAwake,
                "the display is asleep — an iCloud walk makes no progress until it wakes"),
       .machinePinned(.liveProfile))
struct JurisdictionConfidenceGroundTruthTests {

    @Test func everyPreTickedValueIsOneTheProfileCarries() throws {
        let profile = try #require(LiveProfile.profile)
        let (tree, stalled) = FolderSurveyGroundTruth.liveWalk
        try #require(!stalled, "the live walk gave up; nothing below was measured on a whole tree")
        try #require(!tree.isEmpty)

        let candidates = JurisdictionCandidates.propose(tree: tree, root: profile.root)
        let confident = candidates.filter(JurisdictionCandidates.isConfident)
        let declared = RestructureRederive.entryJurisdictions(of: profile)

        // Non-vacuity: a bar so high that nothing pre-ticks would pass the assertion below while
        // making the whole feature pointless.
        #expect(!confident.isEmpty,
                "nothing pre-ticks on the reference tree — the bar is too high to be useful")
        let wrong = confident.map(\.value).filter { !declared.contains($0) }
        let highest = confident.filter { wrong.contains($0.value) }.map(\.parents.count).max() ?? 0
        let why = "setup would pre-tick \(wrong) — raise confidentDistinctParents past \(highest) "
            + "and record the new number in its doc comment"
        #expect(wrong.isEmpty, "\(why)")

        print("[jurisdiction-confidence] proposed \(candidates.map(\.value)); "
              + "pre-ticked \(confident.map { "\($0.value)(\($0.parents.count))" }); "
              + "profile carries \(declared.sorted())")
    }
}
