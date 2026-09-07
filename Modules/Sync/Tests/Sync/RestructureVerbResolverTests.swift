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
            kind: .duplicatedTaxonomy, family: "Work/Acme", subject: "Work/Acme/Forms",
            detail: .duplicatedTaxonomy(counterpart: "Tax/2016/Forms", matchedDocuments: 5))
        #expect(!RestructureVerbResolver.offers(.plan, taxonomy))
        #expect(RestructureVerbResolver.finding(
            forFolder: "\(Self.root)/Work/Acme/Forms", root: Self.root,
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

    // MARK: The one answer both the menu and the workspace read

    /// **A refusal, not a greyed item.** A plan's first act is to save a draft; when the store
    /// cannot be read the card withholds its trigger, and the menu used to offer it anyway.
    @Test func anUnreadableStoreRefusesThePlanVerbWithASentence() {
        let findings = [Self.shape("Finance/US/Income Tax")]
        let folder = "\(Self.root)/Finance/US/Income Tax"
        let refused = RestructureVerbResolver.resolve(.plan, folder: folder, root: Self.root,
                                                      in: findings, storeIsReadable: false)
        guard case .refuse(let sentence) = refused else {
            Issue.record("an unreadable store must refuse, not run")
            return
        }
        #expect(sentence.contains("read-only"), "the sentence says what the state is")

        // **And the scaffold refuses too, for its own reason.** It was exempt in the first
        // version of this rule — "it does not save a draft, so the plan store is not its
        // problem" — which was wrong: a scaffold IS a landing, and `restructureLandingRefusal`
        // refuses one whose ledger record could not be kept. The menu item was left enabled over
        // a handler that warned and did nothing.
        let scaffold = RestructureVerbResolver.resolve(
            .setUp, folder: "\(Self.root)/Health/Dental/2026", root: Self.root,
            in: [Self.backlog("Health/Dental/2026")], storeIsReadable: false)
        guard case .refuse(let scaffoldSentence) = scaffold else {
            Issue.record("a scaffold cannot be recorded without the store either")
            return
        }
        #expect(scaffoldSentence.contains("recorded"),
                "its sentence is about the landing's record, not about a draft")
        #expect(RestructureVerbResolver.resolve(
            .setUp, folder: "\(Self.root)/Health/Dental/2026", root: Self.root,
            in: [Self.backlog("Health/Dental/2026")], storeIsReadable: true)
                == .run(Self.backlog("Health/Dental/2026")),
                "and it runs when the store can be written")
    }

    /// **A landed scaffold is no longer on offer.** The card swaps its button for "Scaffolded —
    /// the survey hasn't caught up yet"; the menu item stayed enabled and minted a second ledger
    /// record whose landing created nothing.
    @Test func aScaffoldThatLandedIsNoLongerOffered() {
        let findings = [Self.backlog("Health/Dental/2026")]
        let folder = "\(Self.root)/Health/Dental/2026"
        #expect(RestructureVerbResolver.resolve(.setUp, folder: folder, root: Self.root,
                                                in: findings, storeIsReadable: true)
                == .run(findings[0]))
        #expect(RestructureVerbResolver.resolve(.setUp, folder: folder, root: Self.root,
                                                in: findings, storeIsReadable: true,
                                                alreadyScaffolded: ["Health/Dental/2026"])
                == .unavailable)
        // Another subject's landing is not this one's.
        #expect(RestructureVerbResolver.resolve(.setUp, folder: folder, root: Self.root,
                                                in: findings, storeIsReadable: true,
                                                alreadyScaffolded: ["Work/Benefits/2026"])
                == .run(findings[0]))
    }

    /// A folder outside the root, and one with no finding, are `unavailable` — a greyed item,
    /// with nothing to say about it.
    @Test func aFolderWithNothingToActOnIsUnavailable() {
        let findings = [Self.shape("Finance/US/Income Tax")]
        #expect(RestructureVerbResolver.resolve(.plan, folder: "/elsewhere/Finance",
                                                root: Self.root, in: findings,
                                                storeIsReadable: true) == .unavailable)
        #expect(RestructureVerbResolver.resolve(.plan, folder: "\(Self.root)/Photos",
                                                root: Self.root, in: findings,
                                                storeIsReadable: true) == .unavailable)
    }
}
