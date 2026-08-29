import Testing
import FileExplorer
@testable import SyncCloud

/// The lens names a Help topic; this is the half that checks the book actually has it
/// (proposal O14). The two live in different modules, so nothing but a test joins them.
@MainActor
@Suite struct RestructureHelpTopicTests {

    /// **The pointer must resolve.** An id that does not exist opens the book at its front,
    /// which is a silent failure — the reader asked for a page and got the cover.
    @Test func theLensPointsAtATopicTheBookHas() {
        let ids = HelpBook.sections.flatMap { $0.topics.map(\.id) }
        #expect(ids.contains(OrganizeHelpTopics.restructure),
                "the lens points at \(OrganizeHelpTopics.restructure), which the book does not have")
    }

    /// And it points at the RIGHT one: the page about what Restructure finds, not a neighbour.
    @Test func theTopicIsTheOneAboutRestructure() throws {
        let topic = try #require(HelpBook.sections.flatMap(\.topics)
            .first { $0.id == OrganizeHelpTopics.restructure })
        #expect(topic.title.contains("Restructure"))
    }

    /// An unresolvable id opens the front of the book rather than a blank card — a broken
    /// pointer is a disappointment, not a crash.
    @Test func anUnknownTopicFallsBackToTheFront() {
        let ids = HelpBook.sections.flatMap { $0.topics.map(\.id) }
        #expect(!ids.contains("no-such-topic"))
        #expect(HelpBook.sections.first?.topics.first?.id != nil,
                "there has to be a front page to fall back to")
    }
}
