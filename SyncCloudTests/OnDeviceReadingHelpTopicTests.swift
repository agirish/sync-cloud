import Testing
import Settings
@testable import SyncCloud

/// Settings ▸ Intelligence names a Help topic; this is the half that checks the book has it.
///
/// The twin of `RestructureHelpTopicTests`, and it exists for the same reason: the pointer and the
/// article live in different modules, so nothing but a test in this target can join them, and an id
/// that does not resolve opens the book at its cover rather than failing — the reader asked a
/// specific question and got the front page.
///
/// **What is different here is what the article is FOR.** This one carries the app's privacy claim
/// in its own words, so the checks below go past "a topic with this id exists": they pin that the
/// article still says the things the switch beside the pointer implies, and that it still names the
/// one exception. An article that quietly loses its "nothing is sent anywhere" paragraph would
/// leave a pointer promising an answer the page no longer gives.
@Suite struct OnDeviceReadingHelpTopicTests {

    private static var topic: HelpBook.Topic? {
        HelpBook.allTopics.first { $0.id == SettingsHelpTopics.onDeviceReading }
    }

    private static func copy(of topic: HelpBook.Topic) -> String {
        ([topic.title, topic.article.intro]
            + topic.article.blocks.map(\.searchableText)).joined(separator: "\n")
    }

    @Test func theSettingsPointerResolves() {
        let ids = HelpBook.allTopics.map(\.id)
        #expect(ids.contains(SettingsHelpTopics.onDeviceReading),
                "Settings points at \(SettingsHelpTopics.onDeviceReading), which the book does not have")
    }

    /// The page is still the one about reading files, not a neighbour that inherited the id.
    @Test func theTopicIsTheOneAboutReading() throws {
        let topic = try #require(Self.topic)
        #expect(topic.title == "Reading your documents")
    }

    /// **The claim the pointer promises is still on the page.**
    ///
    /// `NoTelemetryTests` keeps these sentences *true*; this keeps them *present*. The two are
    /// separate failures — an article can lose its privacy paragraph in a tidy-up while the code
    /// stays as quiet as it ever was, and the reader who clicked the glyph beside a switch about
    /// reading their files is then shown a page that never answers them.
    @Test func theArticleStillMakesThePrivacyClaim() throws {
        let text = try #require(Self.topic.map(Self.copy))
        for phrase in ["opens no network connection",
                       "no server of its own",
                       "no usage statistics",
                       "no crash reports"] {
            #expect(text.contains(phrase), "the article no longer says “\(phrase)”")
        }
    }

    /// **And it still names the exception.**
    ///
    /// The article's claim is scoped — the app does reach `api.anthropic.com` for Refine with
    /// Claude — and the whole reason it holds up is that the page volunteers that itself instead of
    /// waiting to be caught out by a reader who finds the button. Losing this paragraph would not
    /// make any sentence false; it would make the page misleading, which is worse and quieter.
    @Test func theArticleStillNamesTheOneException() throws {
        let text = try #require(Self.topic.map(Self.copy))
        #expect(text.contains("Refine with Claude"),
                "the article no longer names the one feature that does reach the internet")
        #expect(text.contains("Anthropic"),
                "the article no longer says where Refine sends what it sends")
        #expect(text.contains("API key you supply"),
                "the article no longer says the key is the reader's own")
    }

    /// The article says where the learned material lives, so it can be deleted.
    ///
    /// A privacy page that explains what is kept and not where reads as an assurance rather than
    /// something the reader can act on.
    @Test func theArticleSaysWhereItAllLives() throws {
        let text = try #require(Self.topic.map(Self.copy))
        #expect(text.contains("Application Support/SyncCloud/profiles"),
                "the article no longer names the folder that holds what was learned")
    }

    /// The positive control: these checks can fail.
    @Test func theScanIsNotVacuous() throws {
        let text = try #require(Self.topic.map(Self.copy))
        #expect(!text.contains("Firebase"),
                "the article's text is not being read — this phrase cannot be in it")
        #expect(text.count > 800,
                "the article read as \(text.count) characters; the phrase checks above are near-vacuous")
    }
}
