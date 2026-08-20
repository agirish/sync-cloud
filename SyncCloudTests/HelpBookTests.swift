import AppKit
import Foundation
import FileExplorer
import Settings
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
            // "Organize", not the "Cleanup tools" this shipped as: three of the workspace's five
            // sections had no article at all while the section was named for the two that did,
            // and a name that describes half a workspace is what let the other half go
            // undocumented without anything looking odd.
            "Organize",
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

    /// Every "Settings ▸ X" the Help book prints names a tab that really exists.
    ///
    /// **This drifted for a whole release and nothing looked.** The Providers tab was relabelled
    /// **Sources** when it started listing plain folders beside the cloud accounts — the case kept
    /// its name so the stored `settingsSelectedTab` and every deep link survived, which is correct,
    /// and the copy was simply left behind. Two Help articles went on directing users to a tab whose
    /// name is not on screen anywhere.
    ///
    /// Derived from `SettingsTab.displayName` rather than from a list of today's names, so the next
    /// relabel fails here rather than shipping. Only the arrow form is matched, because that is the
    /// spelling that names a *destination* — "cloud providers" as a plain noun is still correct
    /// English about the things the tab lists.
    @Test func everySettingsPathInHelpNamesARealTab() {
        let realNames = Set(SettingsView.SettingsTab.allCases.map(\.displayName))
        var found = 0

        for topic in HelpBook.allTopics {
            for text in Self.copy(of: topic) {
                for named in Self.settingsDestinations(in: text) {
                    found += 1
                    #expect(realNames.contains(named),
                            "“\(topic.title)” sends the user to Settings ▸ \(named), which is not a tab. Real tabs: \(realNames.sorted())")
                }
            }
        }

        #expect(found > 0, "no “Settings ▸ …” references were found at all — this scan is vacuous")
    }

    /// The positive control: the extractor finds a destination, and a wrong one is caught.
    @Test func theSettingsPathScanCanActuallyFail() {
        let realNames = Set(SettingsView.SettingsTab.allCases.map(\.displayName))
        #expect(Self.settingsDestinations(in: "Add a folder in Settings ▸ Sources.") == ["Sources"])
        #expect(Self.settingsDestinations(in: "Add a folder in Settings ▸ Providers.") == ["Providers"])
        #expect(!realNames.contains("Providers"),
                "“Providers” is a tab name again — this test's example is no longer a counter-example")
        #expect(Self.settingsDestinations(in: "SyncCloud finds your cloud providers automatically").isEmpty,
                "a plain noun is being read as a destination")
    }

    /// Every string a topic shows the reader.
    private static func copy(of topic: HelpBook.Topic) -> [String] {
        var out = [topic.title, topic.article.intro]
        for block in topic.article.blocks {
            switch block {
            case .paragraph(let text), .tip(let text):
                out.append(text)
            case .bullets(let items):
                out.append(contentsOf: items)
            case .legend(let items):
                out.append(contentsOf: items.flatMap { [$0.title, $0.detail] })
            }
        }
        return out
    }

    /// The tab names in every "Settings ▸ X" in a string.
    ///
    /// Scanning stops at the first character that is neither a letter nor a space — so a closing
    /// bracket, a full stop or a comma ends the name — and then only the leading *capitalised*
    /// words are kept, so "Settings ▸ Sources and it appears in every pane menu" yields `Sources`
    /// rather than the rest of the sentence.
    private static func settingsDestinations(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let marker = rest.range(of: "Settings ▸ ") {
            let tail = rest[marker.upperBound...]
            let run = tail.prefix { $0.isLetter || $0 == " " }
            let words = run.split(separator: " ").map(String.init)
            var name: [String] = []
            for word in words {
                guard let first = word.first, first.isUppercase else { break }
                name.append(word)
            }
            if !name.isEmpty { out.append(name.joined(separator: " ")) }
            rest = tail
        }
        return out
    }

    /// Every workspace the bar offers has a help topic, derived from `Workspace` so the next one
    /// added fails here rather than shipping unexplained.
    ///
    /// **This started life as a Browse-only test.** Browse shipped without a topic and the Help
    /// book described the app as Compare-plus-cleanup for a whole release while the bar's first
    /// segment went unmentioned — which is exactly the shape of failure a hand-named check cannot
    /// generalise out of. Storage was the second: it had a topic, and the topic was filed under
    /// "Cleanup tools" beside two Organize sections, which is not what a read-only workspace is.
    /// `testTheBrowseWorkspaceHasATopic` is folded in here rather than kept beside this — every
    /// assertion it made is one of the four below, and two tests asking the same question is how
    /// one of them comes to be the only one anybody updates.
    @Test func everyWorkspaceHasATopic() {
        let expected: [Workspace: String] = [
            .browse: "browse-workspace",
            .compare: "what-is-synccloud",
            .filing: "organize-workspace",
            .storage: "storage-lens",
        ]
        for workspace in Workspace.allCases {
            let id = expected[workspace]
            #expect(id != nil, "\(workspace.title) is a workspace with no help topic named here")
            if let id { #expect(HelpBook.topic(id: id) != nil, "\(workspace.title)'s topic \(id) is gone") }
        }
        #expect(HelpBook.sectionTitle(forTopicID: "browse-workspace") == "Getting started")

        // The copy counts the segments too, and a number written out in prose is exactly the
        // thing that does not move when one is added. `ShortcutsReference` derives its own row
        // from `allCases` for this reason; the articles read better with the word, so the count
        // is checked here rather than interpolated into the copy.
        //
        // The match is folded to a `Bool` first on purpose: `everyWord` is the whole Help book,
        // and asserting `.contains` on it directly dumps every article into the failure.
        let count = Workspace.allCases.count
        let everyWord = HelpBook.allTopics.flatMap(Self.copy(of:)).joined(separator: " ")
        for claim in ["⌘1 through ⌘\(count)", "⌘1 – ⌘\(count)", "the \(Self.spelled(count)) workspaces"] {
            let saidSomewhere = everyWord.contains(claim)
            #expect(saidSomewhere,
                    "no article says “\(claim)” — the workspace count moved and the copy did not")
        }
    }

    /// The small numbers Help spells out. Above six the copy should be using digits, and this
    /// falls back to them rather than pretending it knows the word.
    private static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six"]
        return words.indices.contains(n) ? words[n] : "\(n)"
    }

    /// Every one of Organize's rail sections is named somewhere in Help.
    ///
    /// **Three of the five were undocumented for a release.** Renames, Restructure and Rules are
    /// rail items with intros, badges and menu-bar routes of their own, and the Help book covered
    /// only the two it had always covered. Derived from `OrganizeLens.allCases`, because the
    /// failure mode is a section that exists without prose, which no list written by hand here
    /// would ever have caught.
    @Test func everyOrganizeSectionIsDocumented() {
        for lens in OrganizeLens.allCases {
            let hits = HelpBook.filteredSections(matching: lens.title).flatMap(\.topics).map(\.id)
            #expect(!hits.isEmpty, "Organize ▸ \(lens.title) is a rail item no Help topic mentions")
        }
    }

    /// The positive control for the scan above: a section name Organize does not have finds
    /// nothing, so the walk is matching the titles rather than matching everything.
    @Test func theOrganizeSectionScanCanActuallyFail() {
        #expect(HelpBook.filteredSections(matching: "Quarantine").isEmpty)
        #expect(!OrganizeLens.allCases.map(\.title).contains("Quarantine"),
                "“Quarantine” is a section name now — this test's counter-example is no longer one")
    }

    /// Help may not send anyone to a menu the app does not have.
    ///
    /// **Three articles did, for a release.** `cd87b08e` moved Keyboard Shortcuts, Activity Log
    /// and Sync History out of the Help menu — they were listed twice, in two menus, under two
    /// names — and the articles telling users to open them from Help were left behind. The bar is
    /// low on purpose: this pins the four phrasings that went stale, not every sentence about a
    /// menu, because the general form of this question is what `WindowMenuTests` reads off the
    /// running app.
    @Test func noArticleSendsTheUserToARetiredHelpMenuItem() {
        for phrase in ["Help ▸ Keyboard Shortcuts",
                       "Help ▸ Open Activity Log",
                       "Help ▸ Open Sync History",
                       "Help ▸ About SyncCloud"] {
            let hits = HelpBook.filteredSections(matching: phrase).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty, "Help still sends the user to “\(phrase)”, which is not there: \(hits)")
        }
        // The other half: the two Help entries that DO exist are still taught, so the bans above
        // cannot quietly become a rule against naming the Help menu at all.
        let reveal = HelpBook.filteredSections(matching: "Help ▸ Reveal Log File").flatMap(\.topics).map(\.id)
        #expect(reveal.contains("activity-log"))
        let setup = HelpBook.filteredSections(matching: "Help ▸ Set Up SyncCloud").flatMap(\.topics).map(\.id)
        #expect(setup.contains("setup"))
    }

    /// Every "<Menu> ▸ <Item>" in the Help book names a menu item the running app really has.
    ///
    /// **Read off `NSApp.mainMenu`, not the source, and that is the whole point.** Whether a
    /// `CommandMenu` or a `Menu` inside a `CommandGroup` became the arrangement it was declared as
    /// is not a question the source can answer — `WindowMenuTests` exists for the same reason.
    ///
    /// This is the general form of the failure this file keeps meeting. `cd87b08e` moved three
    /// windows out of the Help menu and left three articles pointing at it; `75b9488e` moved
    /// Organize's sections and verbs out of View and File into a menu of their own, hours after
    /// the articles describing the old arrangement were written. Neither broke a test, because
    /// prose about a menu is invisible to everything that reads either one.
    ///
    /// "Settings ▸ …" is excluded on purpose — Settings is a tab rail, not a menu, and
    /// ``everySettingsPathInHelpNamesARealTab`` is the check that fits it.
    @MainActor
    @Test func everyMenuPathInHelpNamesARealMenuItem() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        var checked = 0

        for topic in HelpBook.allTopics {
            for text in Self.copy(of: topic) {
                for (menuName, itemName) in Self.menuDestinations(in: text) {
                    guard menuName != "Settings" else { continue }
                    checked += 1
                    let menu = mainMenu.items.first { $0.title == menuName }?.submenu
                    #expect(menu != nil,
                            "“\(topic.title)” names a \(menuName) menu, and the app has none")
                    let titles = (menu?.items ?? []).map(\.title)
                    // Prefix rather than equality: the extractor stops at the first lowercase
                    // word, so "Reveal Log File in Finder" arrives as "Reveal Log File".
                    let found = titles.contains { $0.hasPrefix(itemName) }
                    #expect(found,
                            "“\(topic.title)” sends the user to \(menuName) ▸ \(itemName), which is not in that menu: \(titles)")
                }
            }
        }

        #expect(checked > 4, "only \(checked) menu paths were found — this scan has gone vacuous")
    }

    /// The positive control: a real path is extracted and matched, and a plausible wrong one is
    /// caught. `View ▸ Organize` is the specific mistake this test was written after — the five
    /// sections were a submenu there for one afternoon.
    @MainActor
    @Test func theMenuPathScanCanActuallyFail() throws {
        #expect(Self.menuDestinations(in: "Open it from Window ▸ Activity Log, or press ⌘L.")
                    .map(\.item) == ["Activity Log"])
        let mainMenu = try #require(NSApp.mainMenu)
        let view = try #require(mainMenu.items.first { $0.title == "View" }?.submenu)
        #expect(!view.items.contains { $0.title.hasPrefix("Restructure") },
                "View carries Organize's sections again — the copy this test defends would be right, not wrong")
    }

    /// The `(menu, item)` pairs in every "<Menu> ▸ <Item>" in a string. Same shape as
    /// ``settingsDestinations(in:)``: the item name runs to the first character that is neither a
    /// letter, a space nor an ellipsis, and only its leading capitalised words are kept.
    private static func menuDestinations(in text: String) -> [(menu: String, item: String)] {
        var out: [(String, String)] = []
        var rest = Substring(text)
        while let marker = rest.range(of: " ▸ ") {
            let head = rest[..<marker.lowerBound]
            let menu = String(head.split(separator: " ").last ?? "")
            let tail = rest[marker.upperBound...]
            let run = tail.prefix { $0.isLetter || $0 == " " || $0 == "…" }
            var name: [String] = []
            for word in run.split(separator: " ").map(String.init) {
                guard let first = word.first, first.isUppercase else { break }
                name.append(word)
            }
            if !menu.isEmpty, !name.isEmpty { out.append((menu, name.joined(separator: " "))) }
            rest = tail
        }
        return out
    }

    /// The macOS version Help claims is the one the app is actually built against.
    ///
    /// It said **15** while the deployment target had moved to 26 — a claim that costs somebody a
    /// download and a failed launch to disprove, and one nothing else in the app would ever
    /// contradict. Derived from the built bundle's `LSMinimumSystemVersion` rather than from a
    /// number typed here, so the next bump of `deploymentTarget` fails this test instead of
    /// ageing quietly the way the last one did.
    ///
    /// `Bundle.main` is the app itself here: `SyncCloudTests` is hosted by `SyncCloud.app`, which
    /// is why this can be asked at all. Under `swift test` it could not.
    @Test func theStatedSystemRequirementMatchesTheBuild() throws {
        let raw = try #require(Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String,
                               "the host bundle carries no LSMinimumSystemVersion — this test cannot see the truth")
        let built = try #require(Int(raw.prefix { $0.isNumber }))

        let about = try #require(HelpBook.topic(id: "about"))
        let copy = about.article.blocks.map(String.init(describing:)).joined(separator: " ")
        let range = try #require(copy.range(of: "Requires macOS "),
                                 "the About topic no longer states a system requirement at all")
        let claimed = try #require(Int(copy[range.upperBound...].prefix { $0.isNumber }))

        #expect(claimed == built,
                "Help says “Requires macOS \(claimed)” and the app is built against \(built)")
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
