import Foundation
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

    /// No article may teach dragging or dropping.
    ///
    /// Cross-pane drag & drop was removed in `4d55246`, but the "Copy and move" topic went on
    /// telling users "Drag items between panes to copy; hold ⇧ or ⌘ while dropping to move"
    /// until `94f1776`'s follow-up. Every other test here pins only STRUCTURE — sections exist,
    /// copy is non-empty, ids are unique, related links resolve — so an article can document a
    /// deleted feature and stay green. This is the app teaching the user something false, which
    /// is worse than a stale code comment.
    ///
    /// Asserted through `filteredSections(matching:)` because that is the same body-text search
    /// the Help window itself runs, so it covers every block type without this test having to
    /// know their shapes. If a future feature legitimately involves dragging (resizing a divider,
    /// say), narrow this to the cross-pane transfer wording rather than deleting it.
    @Test func testNoArticleTeachesDragAndDrop() {
        let dragHits = HelpBook.filteredSections(matching: "drag")
            .flatMap(\.topics).map(\.id)
        #expect(dragHits.isEmpty, "Help topics still mention dragging: \(dragHits)")

        let dropHits = HelpBook.filteredSections(matching: "dropping")
            .flatMap(\.topics).map(\.id)
        #expect(dropHits.isEmpty, "Help topics still mention dropping: \(dropHits)")
    }

    /// The macOS version Help claims is the one the app is actually built against.
    ///
    /// **The claim is right on this line and was wrong on `v3.x`** — same file, same sentence,
    /// `deploymentTarget: "26.0"` against a book saying 15 — which is what a typed number does when
    /// the target moves out from under it. `HelpBook.minimumSystemRequirement` reads the bundle now,
    /// so this asserts the two ways a derived string can still be wrong: the **fallback** firing
    /// (which would publish "a recent version of macOS" to every reader), and the **formatting**,
    /// where `15.0` must reach the page as `15` and a `15.4` must keep its `.4`.
    ///
    /// `Bundle.main` is the app itself here: `SyncCloudTests` is hosted by `SyncCloud.app`, which is
    /// why this can be asked at all. Under `swift test` it could not.
    @Test func theStatedSystemRequirementMatchesTheBuild() throws {
        let raw = try #require(Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String,
                               "the host bundle carries no LSMinimumSystemVersion — this test cannot see the truth")
        let expected = raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw

        let about = try #require(HelpBook.sections.flatMap(\.topics).first { $0.id == "about" },
                                 "the About topic is gone, so nothing states a system requirement")
        let copy = about.article.blocks.map(String.init(describing:)).joined(separator: " ")
        #expect(copy.contains("Requires macOS \(expected) or later."),
                "the About topic does not state the built requirement (macOS \(expected)) — it says: \(copy)")
        #expect(!copy.contains("a recent version of macOS"),
                "the requirement fell back to the vague form inside the real app bundle")
    }
}
