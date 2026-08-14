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
        // "keeper" appears only in the Duplicates topic's body.
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

    /// Every workspace the bar offers has a help topic. Browse shipped without one — the Help
    /// book described the app as Compare-plus-cleanup for a whole release while the bar's first
    /// segment went unexplained.
    @Test func testTheBrowseWorkspaceHasATopic() {
        let topic = HelpBook.topic(id: "browse-workspace")
        #expect(topic != nil, "Browse has no help topic")
        #expect(HelpBook.sectionTitle(forTopicID: "browse-workspace") == "Getting started")
    }

    /// **Tabs are findable in Help.** The feature's own discovery route is a right-click, which the
    /// roadmap accepts as a weakness — so Help is where someone who never right-clicks a folder
    /// finds out tabs exist at all. Searched rather than read off one topic, which is the shape the
    /// tests below use: it holds wherever the copy ends up living.
    @Test func testTabsAreDocumented() {
        let hits = HelpBook.filteredSections(matching: "tab").flatMap(\.topics).map(\.id)
        #expect(hits.contains("browse-workspace"),
                "Help describes Browse without its tabs — the one surface that could teach them")
        let browse = HelpBook.topic(id: "browse-workspace")
        let copy = (browse?.article.blocks ?? []).map(String.init(describing:)).joined(separator: " ")
        #expect(copy.contains("Open in New Tab"), "Help does not name the way tabs are discovered")
        #expect(copy.contains("⌘T"), "Help does not give the chord")
        #expect(copy.contains("pin it"), "Help does not mention pinning, which has no other teacher")
    }

    /// Retired product vocabulary stays out of the copy. "Filing" became Organize's To File lens
    /// and "tidy" left the product's voice with it; both survived in Help long after every other
    /// surface was reworded, because nothing looked. Same search-based shape as the drag test
    /// below, so every block type is covered. Topic IDs are deliberately NOT searched —
    /// `tidy-duplicates` is a frozen identifier, not copy.
    @Test func testNoArticleUsesRetiredVocabulary() {
        for word in ["tidy", "filing"] {
            let hits = HelpBook.filteredSections(matching: word).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty, "Help topics still say “\(word)”: \(hits)")
        }
    }

    /// No article may teach the CROSS-PANE drag & drop that was removed.
    ///
    /// Cross-pane drag & drop was removed in `4d55246`, but the "Copy and move" topic went on
    /// telling users "Drag items between panes to copy; hold ⇧ or ⌘ while dropping to move"
    /// until `94f1776`'s follow-up. Every other test here pins only STRUCTURE — sections exist,
    /// copy is non-empty, ids are unique, related links resolve — so an article can document a
    /// deleted feature and stay green. This is the app teaching the user something false, which
    /// is worse than a stale code comment.
    ///
    /// **Narrowed from "no article mentions dragging" when tab reordering landed**, which is what
    /// the previous version of this test told the next reader to do rather than delete it: the
    /// strip's reorder drag is a drag that genuinely exists, and a blanket ban would have been
    /// answered by rewording the Help copy to avoid a true word. The phrases below are the removed
    /// feature's own, and the last check is the other half — the drag that DOES exist is still
    /// taught, so this narrowing cannot quietly become a deletion.
    @Test func testNoArticleTeachesCrossPaneDragAndDrop() {
        for phrase in ["drag items", "drag files", "between panes", "dropping"] {
            let hits = HelpBook.filteredSections(matching: phrase).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty, "Help topics still teach “\(phrase)”: \(hits)")
        }

        let reorder = HelpBook.filteredSections(matching: "drag a tab").flatMap(\.topics).map(\.id)
        #expect(reorder.contains("browse-workspace"),
                "the one drag the app has is no longer taught — this test has become a ban on a word")
    }
}
