import Foundation
import Testing
@testable import Sync

/// §11's deferred verbs need a selection-to-finding resolver, and this is it (proposal O10).
@Suite struct RestructureVerbResolverTests {

    private static let root = "/Users/x/Documents"

    private static func shape(_ family: String) -> StructureFinding {
        StructureFinding(family: family,
                         schemes: [.init(vocabulary: ["forms"], members: ["2013", "2014"]),
                                   .init(vocabulary: ["federal"], members: ["2016"])])
    }

    private static func backlog(_ subject: String, scaffold: [String] = ["Claims"])
        -> StructureFinding {
        StructureFinding(kind: .backlog,
                         family: (subject as NSString).deletingLastPathComponent,
                         subject: subject,
                         detail: .backlog(scaffold: scaffold, looseFiles: 3))
    }

    // MARK: Which finding

    /// The folder's OWN finding wins — someone who selected it means it.
    @Test func anExactSubjectMatchIsPreferred() throws {
        let findings = [Self.shape("Finance"), Self.shape("Finance/US/Income Tax")]
        let found = try #require(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Finance/US/Income Tax", root: Self.root,
            in: findings, verb: .plan))
        #expect(found.subject == "Finance/US/Income Tax")
    }

    /// Failing that, the family it belongs to — a member of a shape family is inside the finding
    /// about that family, and planning from a member is the ordinary case.
    @Test func aMemberResolvesToItsFamily() throws {
        let found = try #require(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Finance/US/Income Tax/2013", root: Self.root,
            in: [Self.shape("Finance/US/Income Tax")], verb: .plan))
        #expect(found.subject == "Finance/US/Income Tax")
    }

    /// **The NEAREST ancestor**, when a folder sits inside two nested families. The closer one is
    /// the one the user can see themselves inside.
    @Test func theNearestAncestorWins() throws {
        let findings = [Self.shape("Finance"), Self.shape("Finance/US/Income Tax")]
        let found = try #require(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Finance/US/Income Tax/2013", root: Self.root,
            in: findings, verb: .plan))
        #expect(found.subject == "Finance/US/Income Tax")
    }

    /// A folder with no finding above or below it greys the item. A verb that acted on something
    /// else would be worse than one that is unavailable.
    @Test func anUnrelatedFolderResolvesToNothing() {
        #expect(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Travel/2019", root: Self.root,
            in: [Self.shape("Finance/US/Income Tax")], verb: .plan) == nil)
        #expect(RestructureVerbResolver.finding(
            forFolder: "/somewhere/else", root: Self.root,
            in: [Self.shape("Finance")], verb: .plan) == nil,
                "a folder outside the surveyed root is not resolvable at all")
    }

    /// A component prefix is not containment: `Finance Archive` is not inside `Finance`.
    @Test func containmentIsByComponent() {
        #expect(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Finance Archive/2013", root: Self.root,
            in: [Self.shape("Finance")], verb: .plan) == nil)
    }

    // MARK: Which verb

    /// **`plan` follows the card's own routing**, so a menu item cannot offer a surface the lens
    /// would withhold — duplicated taxonomy has a finding and no plan surface.
    @Test func planFollowsTheSameRoutingTheCardDoes() {
        let taxonomy = StructureFinding(
            kind: .duplicatedTaxonomy, family: "Work/MapR", subject: "Work/MapR/Forms",
            detail: .duplicatedTaxonomy(counterpart: "Tax/2016/Forms", matchedDocuments: 5))
        #expect(!RestructureVerbResolver.offers(.plan, taxonomy))
        #expect(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Work/MapR/Forms", root: Self.root,
            in: [taxonomy], verb: .plan) == nil)

        let echo = StructureFinding(
            kind: .echoName, family: "Home/PG&E", subject: "Home/PG&E/PGE",
            detail: .echoName(counterpart: "Home/PG&E", relation: .parentChild))
        #expect(RestructureVerbResolver.offers(.plan, echo))
    }

    /// `setUp` is the scaffold, and only a backlog finding with something to create has one — an
    /// all-drift family vouches for nothing, and the card offers only the hand-off.
    @Test func setUpBelongsToABacklogWithSomethingToCreate() {
        #expect(RestructureVerbResolver.offers(.setUp, Self.backlog("Health/Dental/2026")))
        #expect(!RestructureVerbResolver.offers(
            .setUp, Self.backlog("Health/Dental/2026", scaffold: [])),
                "nothing to create is nothing to offer")
        #expect(!RestructureVerbResolver.offers(.setUp, Self.shape("Finance")))
    }

    /// The two verbs resolve independently: a folder can offer one and not the other.
    @Test func theVerbsDoNotBorrowEachOthersAvailability() {
        let findings = [Self.shape("Finance/US/Income Tax"),
                        Self.backlog("Health/Dental/2026")]
        let folder = "\(Self.root)/Finance/US/Income Tax/2013"
        #expect(RestructureVerbResolver.finding(forFolder: folder, root: Self.root,
                                                in: findings, verb: .plan) != nil)
        #expect(RestructureVerbResolver.finding(forFolder: folder, root: Self.root,
                                                in: findings, verb: .setUp) == nil)
    }

    // MARK: The root

    /// The root arrives tilde-abbreviated from the profile and absolute from the pane. Both are
    /// expanded — the mismatch that made `Plan…` derive nothing on every real profile once.
    @Test func bothSpellingsOfTheRootResolve() {
        let home = NSHomeDirectory()
        #expect(RestructureVerbResolver.relativePath(of: "\(home)/Documents/Finance",
                                                     under: "~/Documents") == "Finance")
        #expect(RestructureVerbResolver.relativePath(of: "~/Documents/Finance",
                                                     under: "\(home)/Documents") == "Finance")
        #expect(RestructureVerbResolver.relativePath(of: "~/Documents",
                                                     under: "~/Documents") == ".")
        #expect(RestructureVerbResolver.relativePath(of: "", under: "~/Documents") == nil)
    }
}
