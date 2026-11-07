import Testing
import Settings
@testable import SyncCloud

/// Organize ▸ Suggestions names a Help topic; this checks the book has it. Like
/// `RestructureHelpTopicTests`: pointer and article live in different modules, and an id that
/// doesn't resolve opens the book at its cover instead of failing. This article carries the app's
/// privacy claim, so the checks also pin that it still says what the switch beside the pointer
/// implies, and still names the one exception.
@Suite struct OnDeviceReadingHelpTopicTests {

    private static var topic: HelpBook.Topic? {
        HelpBook.allTopics.first { $0.id == SettingsHelpTopics.onDeviceReading }
    }

    private static func copy(of topic: HelpBook.Topic) -> String {
        ([topic.title, topic.article.intro]
            + topic.article.blocks.map(\.searchableText)).joined(separator: "\n")
    }

    /// The page is still the one about reading files, not a neighbour that inherited the id.
    @Test func theTopicIsTheOneAboutReading() throws {
        let topic = try #require(Self.topic)
        #expect(topic.title == "Reading your documents")
    }

    /// The claim the pointer promises is still on the page. `NoTelemetryTests` keeps these
    /// sentences true; this keeps them present, since a tidy-up can drop the paragraph while the
    /// code stays quiet.
    @Test func theArticleStillMakesThePrivacyClaim() throws {
        let text = try #require(Self.topic.map(Self.copy))
        for phrase in ["opens no network connection",
                       "no server of its own",
                       "no usage statistics",
                       "no crash reports"] {
            #expect(text.contains(phrase), "the article no longer says “\(phrase)”")
        }
    }

    /// And it still names the exception: Refine with Claude reaches `api.anthropic.com`. Losing
    /// this paragraph makes no sentence false, but it makes the page misleading.
    @Test func theArticleStillNamesTheOneException() throws {
        let text = try #require(Self.topic.map(Self.copy))
        #expect(text.contains("Refine with Claude"),
                "the article no longer names the one feature that does reach the internet")
        #expect(text.contains("Anthropic"),
                "the article no longer says where Refine sends what it sends")
        #expect(text.contains("API key you supply"),
                "the article no longer says the key is the reader's own")
    }

    /// The article says where the learned material lives, so the reader can act on it and delete
    /// it.
    @Test func theArticleSaysWhereItAllLives() throws {
        let text = try #require(Self.topic.map(Self.copy))
        #expect(text.contains("Application Support/SyncCloud/profiles"),
                "the article no longer names the folder that holds what was learned")
    }
}
