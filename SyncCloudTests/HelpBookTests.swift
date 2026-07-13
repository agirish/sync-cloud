import Testing
@testable import SyncCloud

/// Pins the Help book's shape: the expected sections exist, every topic carries complete copy
/// with a unique id, every cross-link resolves to a real topic, and search narrows the way the
/// sidebar expects. The CONTENT is a hand-maintained mirror of the app — update a topic and this
/// test together when a feature changes.
@Suite struct HelpBookTests {

    @Test func testSectionsCoverTheExpectedAreas() {
        #expect(HelpBook.sections.map(\.title) == [
            "Getting started",
            "Working with differences",
            "Cleanup tools",
            "Settings and more",
            "Help and safety",
        ])
    }

    @Test func testEverySectionHasTopics() {
        for section in HelpBook.sections {
            #expect(!section.topics.isEmpty)
        }
    }

    @Test func testEveryTopicHasCompleteCopy() {
        for topic in HelpBook.allTopics {
            #expect(!topic.id.isEmpty)
            #expect(!topic.title.isEmpty)
            #expect(!topic.systemImage.isEmpty)
            #expect(!topic.article.intro.isEmpty)
        }
    }

    @Test func testTopicIDsAreUnique() {
        let ids = HelpBook.allTopics.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func testEveryRelatedLinkResolvesToARealTopic() {
        for topic in HelpBook.allTopics {
            for relatedID in topic.article.related {
                #expect(HelpBook.topic(id: relatedID) != nil, "\(topic.id) links to unknown topic \(relatedID)")
                // A topic shouldn't list itself as related.
                #expect(relatedID != topic.id)
            }
        }
    }

    @Test func testEveryBlockHasContent() {
        for topic in HelpBook.allTopics {
            for block in topic.article.blocks {
                switch block {
                case .paragraph(let text), .tip(let text):
                    #expect(!text.isEmpty)
                case .bullets(let items):
                    #expect(!items.isEmpty)
                    #expect(items.allSatisfy { !$0.isEmpty })
                case .legend(let items):
                    #expect(!items.isEmpty)
                    #expect(items.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.systemImage.isEmpty })
                }
            }
        }
    }

    @Test func testSectionTitleLookupMatchesOwningSection() {
        for section in HelpBook.sections {
            for topic in section.topics {
                #expect(HelpBook.sectionTitle(forTopicID: topic.id) == section.title)
            }
        }
    }

    @Test func testEmptyQueryReturnsEverything() {
        #expect(HelpBook.filteredSections(matching: "") == HelpBook.sections)
        #expect(HelpBook.filteredSections(matching: "   ") == HelpBook.sections)
    }

    @Test func testQueryNarrowsToMatchingTopics() {
        // "keeper" appears only in the Tidy topic's body.
        let results = HelpBook.filteredSections(matching: "keeper")
        let matchedIDs = results.flatMap(\.topics).map(\.id)
        #expect(matchedIDs == ["tidy-duplicates"])
        // Empty sections drop out entirely.
        #expect(results.allSatisfy { !$0.topics.isEmpty })
    }

    @Test func testQueryMatchesBodyText_notJustTitles() {
        // "checksum" lives only in body copy (Scan + Sync preferences), never in a title.
        let results = HelpBook.filteredSections(matching: "checksum")
        let ids = Set(results.flatMap(\.topics).map(\.id))
        #expect(ids.contains("scan"))
        #expect(ids.contains("sync-preferences"))
    }

    @Test func testUnmatchedQueryReturnsNothing() {
        #expect(HelpBook.filteredSections(matching: "zzzznotatopic").isEmpty)
    }
}
