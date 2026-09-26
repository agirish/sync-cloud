import Foundation
import Testing
@testable import Sync

/// Routing the loose files by name alone, which is what setup can honestly claim.
@Suite struct SetupLooseFileRoutingTests {

    private static func walk(folders: [String], loose: [String]) -> SetupWalk {
        SetupWalk.summarising(tree: FixtureTree.of(folders: folders, files: loose),
                              root: URL(fileURLWithPath: "/root"), recordedRoot: "~/Documents",
                              known: [])
    }

    private static func profile(_ walk: SetupWalk) -> FolderProfile {
        FolderSurveyBuilder.build(tree: walk.tree, root: "~/Documents", profileId: "test",
                                  registry: nil, jurisdictionValues: [])
    }

    private static func routes(folders: [String], loose: [String]) -> [SetupLooseFileRouting.LooseFileRoute] {
        let walk = Self.walk(folders: folders, loose: loose)
        return SetupLooseFileRouting.route(walk: walk, profile: Self.profile(walk))
    }

    /// A name that shares its words with exactly one folder gets that folder, clearly.
    @Test func aNameThatMatchesOneFolderRoutesConfidently() {
        let routes = Self.routes(
            folders: ["Finance/Bank Statements", "Photos/2019", "Family/Mother"],
            loose: ["bank statement march.pdf"])
        let route = routes.first
        #expect(route?.home == "Finance/Bank Statements")
        #expect(route?.confidence == .high)
        #expect(route?.isReady == true)
    }

    /// Two folders with equal claim leave the file unsure, and unsure is shown as unsure rather
    /// than as a guess — the margin is the whole point of ranking rather than picking a maximum.
    @Test func twoEquallyGoodDestinationsAreNotAnAnswer() {
        let routes = Self.routes(folders: ["Home/Insurance", "Work/Insurance"],
                                 loose: ["insurance.pdf"])
        #expect(routes.first?.confidence == .low)
        #expect(routes.first?.isReady == false)
    }

    /// Nothing in the tree resembles the name, so setup says nothing about it.
    @Test func aNameNothingMatchesHasNoHome() {
        let routes = Self.routes(folders: ["Photos/2019", "Photos/2020"],
                                 loose: ["zzqx.pdf"])
        #expect(routes.first?.isReady == false)
    }

    /// The ready count is the count at the bar, not the count of files that scored anything.
    @Test func theReadyCountIsTheCountAtTheBar() {
        let routes = Self.routes(
            folders: ["Finance/Bank Statements", "Home/Insurance", "Work/Insurance"],
            loose: ["bank statement march.pdf", "insurance.pdf", "zzqx.pdf"])
        #expect(routes.count == 3)
        #expect(SetupLooseFileRouting.readyCount(routes) == 1)
        #expect(SetupLooseFileRouting.readyCount(routes)
                == routes.filter { $0.confidence >= SetupLooseFileRouting.readyBar && $0.home != nil }.count)
    }

    /// An inbox is not offered as a home, here as everywhere: the index drops folders the profile
    /// refuses, so setup cannot preview a route the app would not take.
    @Test func anInboxIsNeverProposedAsAHome() {
        let routes = Self.routes(folders: ["TODO", "Photos/2019"], loose: ["todo list.pdf"])
        #expect(routes.first?.home != "TODO")
    }

    /// Every loose file gets a row, including the ones with no answer — the screen's count is the
    /// root's own file count, so a file that silently dropped out would leave the two disagreeing.
    @Test func everyLooseFileGetsARow() {
        let routes = Self.routes(folders: ["Finance/Bank Statements"],
                                 loose: ["a.pdf", "b.txt", "c.jpg", "bank statement.pdf"])
        #expect(routes.map(\.fileName) == ["a.pdf", "b.txt", "bank statement.pdf", "c.jpg"],
                "in the walk's own order, which is sorted")
    }
}
