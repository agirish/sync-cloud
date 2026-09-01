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
            .editor: "editor-workspace",
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

    /// Every one of Organize's rail sections has an article of its own.
    ///
    /// **Three of the five were undocumented for a release.** Renames, Restructure and Rules are
    /// rail items with their own intros, badges, scan behaviour and menu-bar routes, and the Help
    /// book covered only the two it had always covered.
    ///
    /// **The first version of this was a substring scan over the copy, and it could not have
    /// caught that.** Searching for "Rules" matches six topics — `fix-names` says "this provider's
    /// own rules", `intelligence` says "no model involved" beside rule talk — so deleting the
    /// Rules article outright left the scan green. It pinned a spelling, not an article. The map
    /// below names the topic each section is documented BY, and is walked over `allCases` so a
    /// section added without one fails here rather than shipping.
    @Test func everyOrganizeSectionHasAnArticle() {
        let expected: [OrganizeLens: String] = [
            .toFile: "file-loose-items",
            .duplicates: "tidy-duplicates",
            .renames: "fix-names",
            .restructure: "restructure-shapes",
            .rules: "automation-rules",
            // Storage's article already existed — it was a WORKSPACE topic, filed outside this
            // section. The fold moved it here, and this map is what forced that: the assertion
            // below requires a lens's topic to live in the Organize section, so a re-homed lens
            // whose article stayed put fails rather than shipping a rail item documented under a
            // heading that no longer describes it.
            .storage: "storage-lens",
        ]
        for lens in OrganizeLens.allCases {
            guard let id = expected[lens] else {
                Issue.record("Organize ▸ \(lens.title) is a rail item with no help topic named here")
                continue
            }
            // `Issue.record` + `continue` rather than `#expect` and carry on: `#expect` records and
            // KEEPS GOING, so the two checks below would run against a topic just shown not to
            // exist and report a missing article as three unrelated failures.
            guard let topic = HelpBook.topic(id: id) else {
                Issue.record("Organize ▸ \(lens.title) is documented by “\(id)”, which is gone")
                continue
            }
            #expect(HelpBook.sectionTitle(forTopicID: id) == "Organize",
                    "“\(id)” documents Organize ▸ \(lens.title) and does not live in the Organize section")
            // And the article names the section, so the reader can tell which rail item it is
            // about. This is the substring half — kept, but no longer the whole guard.
            #expect(Self.copy(of: topic).contains { $0.contains(lens.title) },
                    "“\(id)” never says “\(lens.title)”")
        }
    }

    // MARK: - Restructure, since it grew a surface that writes

    /// Restructure's four articles exist, and all four stay in the Organize section.
    ///
    /// ``everyOrganizeSectionHasAnArticle`` maps each rail item to **one** topic, so it is
    /// satisfied by `restructure-shapes` alone — the three articles v5.0 added, for planning,
    /// applying and scaffolding, are invisible to it. They are also the only articles in the book
    /// about a surface that moves the reader's files, which is where a silent deletion would cost
    /// the most.
    @Test func restructureIsDocumentedInFourArticles() {
        for id in ["restructure-shapes", "restructure-plan", "restructure-apply",
                   "restructure-scaffold"] {
            guard let topic = HelpBook.topic(id: id) else {
                Issue.record("“\(id)” is gone — Restructure's help has lost an article")
                continue
            }
            #expect(HelpBook.sectionTitle(forTopicID: id) == "Organize",
                    "“\(topic.title)” has left the Organize section")
        }
    }

    /// **Help may not call Restructure read-only while Apply exists.**
    ///
    /// Until v5.0 the lens only reported, and the book said so — `staying-safe` carried
    /// *"Restructure cannot change a file at all"* and `organize-workspace` carried *"it reports;
    /// it never rewrites"*. Apply shipped, and both became promises about the reader's data that
    /// the app no longer keeps. **Nothing failed:** the sentences are grammatical, they name a
    /// real section, and every other guard in this file reads structure rather than claims.
    ///
    /// So the ban is tied to the code that decides it. While `applyPlan` is in `Sync`, no article
    /// may tell anyone Restructure leaves the tree alone; if Apply is ever taken out, the anchor
    /// fails first and the ban is reconsidered rather than quietly outliving its reason.
    @Test func noArticleCallsRestructureReadOnly() throws {
        let sync = macAppDirectory().deletingLastPathComponent()
            .appendingPathComponent("Modules/Sync/Sources/Sync")
        let apply = try #require(
            try? String(contentsOf: sync.appendingPathComponent("FileSyncManager+RestructureApply.swift"),
                        encoding: .utf8),
            "cannot read the Apply source — the ban below would rest on nothing")
        try #require(apply.contains("func applyPlan("),
                     "applyPlan is gone from Sync — the claims banned below may be true again")

        for phrase in ["never rewrites", "cannot change a file", "it never acts"] {
            let hits = HelpBook.filteredSections(matching: phrase).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty,
                    "Help still says “\(phrase)” about a section that now writes: \(hits)")
        }
    }

    /// The two undos stay two, and stay distinguishable.
    ///
    /// ⌘Z and *Undo this reorganisation* are different mechanisms, and the app's own tooltip says
    /// so — one is a grouped undo living in memory for the session, the other replays a reversal
    /// kept on disk. A book that teaches only the first tells people a reorganisation stops being
    /// reversible when they quit, which is the opposite of what v5.0 built; one that teaches only
    /// the second loses the single keystroke that takes a landing straight back.
    @Test func bothOfRestructuresUndosAreTaught() throws {
        let topic = try #require(HelpBook.topic(id: "restructure-apply"))
        let words = Self.copy(of: topic).joined(separator: " ")
        #expect(words.contains("⌘Z"), "the session undo is no longer taught")
        #expect(words.lowercased().contains("undo this reorganisation"),
                "the ledger undo is no longer taught by name")
        #expect(words.contains("survives quitting") || words.contains("survives a quit"),
                "nothing says the ledger undo outlives the session — the whole difference between the two")
    }

    /// The positive control for the walk above: a section name Organize does not have finds
    /// nothing, so the copy half is matching titles rather than matching everything.
    @Test func theOrganizeSectionScanCanActuallyFail() {
        #expect(HelpBook.filteredSections(matching: "Quarantine").isEmpty)
        #expect(!OrganizeLens.allCases.map(\.title).contains("Quarantine"),
                "“Quarantine” is a section name now — this test's counter-example is no longer one")
    }

    /// No topic is reachable only by scrolling the sidebar.
    ///
    /// The related chips are the one route between articles, and **`restructure-shapes` shipped
    /// with no inbound link at all** — the newest and least-known of Organize's five sections was
    /// the one topic nothing pointed at. `testEveryRelatedLinkResolvesToARealTopic` walks the same
    /// graph in the other direction and is blind to this by construction: every link it checks
    /// resolves precisely because it starts from the links rather than from the topics.
    ///
    /// **No exemption for the topic Help opens on**, though it is the one that could argue for it.
    /// The first draft skipped it — it needs no route in, being where you land — and that branch
    /// could not fire: `setup` is linked from three other articles, so the exemption was dead code
    /// that made the walk look more careful than it was. Every topic is held to the same bar, and
    /// if a reorganisation ever does leave the entry unlinked, the failure is a decision to make
    /// rather than a rule someone already made blind.
    @Test func everyTopicIsLinkedFromSomewhere() {
        var inbound: [String: Int] = [:]
        for topic in HelpBook.allTopics {
            for id in topic.article.related { inbound[id, default: 0] += 1 }
        }
        for topic in HelpBook.allTopics {
            #expect(inbound[topic.id, default: 0] > 0,
                    "“\(topic.title)” is linked from no other article — the sidebar is its only route")
        }
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

    /// The **reverse** walk: every menu the app actually has is written about somewhere in the book.
    ///
    /// ``everyMenuPathInHelpNamesARealMenuItem`` catches a path that has gone stale. Nothing caught
    /// a menu that was never written about at all — and a path that is never written is a path
    /// that can never be wrong, so the forward walk stayed green while the gap grew.
    ///
    /// **v4.2 gave the app an Edit menu and the book did not mention it.** Cut, Copy, Paste and
    /// Select All became file verbs that reach Finder in both directions, `⌘X` then `⌘V`
    /// became a move, and the word "clipboard" appeared in no article, in any section, for the whole
    /// release. Every other guard here was green: the topic count was right, every link resolved,
    /// every path named a real item.
    ///
    /// Derived from `NSApp.mainMenu` rather than from a list written here, so a menu added later is
    /// covered on the day it appears rather than the day somebody remembers to extend a list.
    ///
    /// **The match is on "<Menu> ▸ ", never on the bare word**, and that is the whole reason this
    /// is not vacuous. "File", "Edit", "View", "Go" and "Window" are ordinary English — a
    /// substring scan for them is satisfied by "a file", "edit the name" and "the window" without one
    /// sentence about a menu anywhere. The arrow appears only in a menu path.
    @MainActor
    @Test func everyMenuInTheBarIsDescribedInTheBook() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let book = HelpBook.allTopics.flatMap { Self.copy(of: $0) }.joined(separator: "\n")

        let ours = mainMenu.items.filter { !$0.title.isEmpty && $0.submenu != nil }
        #expect(ours.count > 5, "only \(ours.count) menus were found — this scan has gone vacuous")

        for menu in ours {
            // Folded to a Bool BEFORE `#expect` sees it: the macro prints the values of its
            // subexpressions, and `book` is the whole Help text — every article, on failure, ahead
            // of the one sentence naming which menu is undocumented.
            let described = book.contains("\(menu.title) ▸ ")
            #expect(described,
                    "the app has a \(menu.title) menu and no article names a \(menu.title) ▸ … path")
        }
    }

    /// The positive control for the reverse walk, and it is about the *bare word*, not the menu.
    ///
    /// A scan that looked for "Edit" alone would have been satisfied by the Renames article the
    /// whole time it was wrong. The arrow is what makes the difference, so that is what is asserted.
    @Test func theMenuCoverageScanCanActuallyFail() {
        let book = HelpBook.allTopics.flatMap { Self.copy(of: $0) }.joined(separator: "\n")
        let inventedMenu = book.contains("Bookmarks ▸ ")
        #expect(!inventedMenu, "the book names a Bookmarks menu, which this app has never had")
        // The real Edit coverage is a path, not a loose word — delete the clipboard article and
        // this fails while a bare-word scan would not.
        let editIsAPath = book.contains("Edit ▸ ")
        let editIsALooseWord = book.contains("Edit") || book.contains("edit")
        #expect(editIsAPath, "no article names an Edit ▸ … path")
        #expect(editIsALooseWord, "the loose word is present too — which is exactly why it proves nothing")
    }

    /// The positive control: a real path is extracted and matched, and a plausible wrong one is
    /// caught. `View ▸ Organize` is the specific mistake this test was written after — the five
    /// sections were a submenu there for one afternoon.
    @MainActor
    @Test func theMenuPathScanCanActuallyFail() throws {
        #expect(Self.menuDestinations(in: "Open it from Window ▸ Activity Log, or press ⌘L.")
                    .map(\.item) == ["Activity Log"])
        // Punctuation around the menu name must not become part of it — the old copy wrote
        // "(Settings ▸ Intelligence)", which would have read as a menu called "(Settings" and
        // failed the walk on a correct sentence.
        #expect(Self.menuDestinations(in: "needs a key (Settings ▸ Intelligence).")
                    .map(\.menu) == ["Settings"])
        #expect(Self.menuDestinations(in: "“Settings ▸ Sources is where SyncCloud lists them.")
                    .map(\.menu) == ["Settings"])
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
            // Trailing word before the arrow, stripped of anything that is not a letter — a
            // sentence may open with the menu name ("Settings ▸ Sources is where…") or wrap it
            // ("(Settings ▸ Intelligence)", which the copy used to say). Left unstripped, a
            // bracketed name reads as the menu "(Settings", which is neither skippable as
            // Settings nor findable as a menu, and a perfectly correct sentence fails here.
            let menu = String(head.split(separator: " ").last ?? "").filter(\.isLetter)
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
    /// contradict.
    ///
    /// `Bundle.main` is the app itself here: `SyncCloudTests` is hosted by `SyncCloud.app`, which
    /// is why this can be asked at all. Under `swift test` it could not.
    ///
    /// **What this asserts changed in v4.2, and the reason is worth keeping.** The book used to
    /// carry the number as a literal and this test compared it against the bundle — a real check,
    /// because the two sides were independent. `HelpBook.minimumSystemRequirement` now *reads* the
    /// bundle, so that comparison would be the bundle against itself and could never fail. What is
    /// left for it to catch is the two ways a derived string can still be wrong, and both are real:
    /// the **fallback** firing (a bundle with no `LSMinimumSystemVersion`, which would publish
    /// "a recent version of macOS" to every reader), and the **formatting** — `26.0` must reach the
    /// page as `26`, and a `15.4` must keep its `.4`.
    @Test func theStatedSystemRequirementMatchesTheBuild() throws {
        let raw = try #require(Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String,
                               "the host bundle carries no LSMinimumSystemVersion — this test cannot see the truth")
        let expected = raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw

        let about = try #require(HelpBook.topic(id: "about"))
        let copy = about.article.blocks.map(String.init(describing:)).joined(separator: " ")
        #expect(copy.contains("Requires macOS \(expected) or later."),
                "the About topic does not state the built requirement (macOS \(expected)) — it says: \(copy)")
        // Named separately, because this is the failure with no other symptom: the fallback is
        // grammatical, plausible, and tells the reader nothing.
        #expect(!copy.contains("a recent version of macOS"),
                "the requirement fell back to the vague form inside the real app bundle")
    }

    /// The requirement is derived, and **cannot be typed back in.**
    ///
    /// Deriving it closes the trap only for as long as nobody writes the sentence out again — and
    /// writing it out is the obvious edit, because the literal reads perfectly well and the number
    /// is right on the day it is typed. That is exactly how it came to say **15** for two majors.
    ///
    /// Scanned over comment-stripped source so the doc comment on `minimumSystemRequirement`, which
    /// quotes the old literal in order to explain it, is not itself the failure. Scoped to
    /// `HelpBook.swift` rather than the whole of `MacApp/` for the reason `macAppSources()` gives
    /// about `!contains`: the property's own `return` legitimately contains the phrase, so the
    /// haystack has to be the one file where exactly one occurrence is expected.
    @Test func theRequirementIsNotWrittenOutAsALiteral() throws {
        let path = macAppDirectory().appendingPathComponent("HelpBook.swift")
        let source = sourceCodeOnly(try #require(try? String(contentsOf: path, encoding: .utf8),
                                                 "cannot read HelpBook.swift — this scan would be vacuous"))
        try #require(source.count > 10_000, "HelpBook.swift read as \(source.count) characters")
        // The one legitimate occurrence is the interpolation inside `minimumSystemRequirement`.
        let occurrences = source.components(separatedBy: "Requires macOS ").count - 1
        #expect(occurrences == 1,
                "“Requires macOS ” appears \(occurrences) times in HelpBook.swift — the only one allowed is the interpolation in minimumSystemRequirement")
        #expect(source.contains("Requires macOS \\(shown) or later."),
                "the surviving occurrence is not the interpolated one — the number has been typed back in")
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


/// The related-chip row is a WRAPPING layout, not an `HStack`.
///
/// **A source scan, deliberately, and the narrow kind.** What this defends is the call site's
/// choice of container — a spelling-level fact — and the behaviour behind it is already tested:
/// `FlowLayoutMathTests` pins the wrapping geometry, over-wide clamp included. What no test could
/// see is `FlexibleChips` going back to the `HStack` it shipped as, which squeezes instead of
/// wrapping and renders "Clear out dupli-cates" hyphenated inside a tall oval at five chips. A
/// layout test cannot catch it (a squeezed row is exactly as wide as an intact one) and a render
/// assertion would have to tell a wrapped label from a hyphenated one in pixels.
///
/// It also stops a third flow layout being written here: two already exist in this repo —
/// FileExplorer's and Settings' — and the one MacApp uses is FileExplorer's.
///
/// **`declarationBody` rather than the fixed character window this shipped with.** That window was
/// 1,200 characters from the declaration and the struct is 1,081, so it read 119 characters of
/// whatever came next — the same defect `01f7ff27` had just fixed in the setup-form scan two
/// commits earlier, where a fixed 220 ran into an unrelated row. A neighbour added after
/// `FlexibleChips` could have failed the negative assertion below, or answered it. The helper is
/// brace-bounded and reads comment-stripped source, so this member's own prose — which discusses
/// the `HStack` it replaced — cannot answer a question asked about its code.
@Suite struct HelpChipRowTests {

    static let source: String = {
        let file = macAppDirectory().appendingPathComponent("HelpBook.swift")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }()

    @Test func theSourceIsActuallyReadable() {
        #expect(Self.source.contains("private struct FlexibleChips"),
                "HelpBook.swift could not be read from macAppDirectory() — every check below would be vacuous")
    }

    @Test func theChipsUseTheSharedWrappingLayout() throws {
        let body = try declarationBody(of: "private struct FlexibleChips", in: Self.source)
        #expect(body.contains("FileExplorer.FlowLayout"),
                "the related chips no longer use the shared wrapping layout")
        #expect(!body.contains("HStack(spacing: 8)"),
                "the chip row is an HStack again — it squeezes rather than wraps")
    }

    /// The bound really is the declaration's, not a character count: the body stops before whatever
    /// is declared next. Without this the scan above could be reading its neighbour and nobody
    /// would know — which is exactly how it shipped.
    @Test func theScanStopsAtTheDeclarationItIsAbout() throws {
        let body = try declarationBody(of: "private struct FlexibleChips", in: Self.source)
        #expect(!body.contains("struct ChipFlow"))
        #expect(!body.contains("private var relatedChips"))
        #expect(body.contains("let ids: [String]"), "the body no longer reaches its own members")
    }
}
