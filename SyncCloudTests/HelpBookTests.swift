import AppKit
import Dashboard
import Design
import Foundation
import FileExplorer
import Settings
import Testing
@testable import SyncCloud

/// Pins the Help book's shape: the expected sections exist, every topic has complete copy and a
/// unique id, every cross-link resolves, and search narrows as the sidebar expects. The content is
/// a hand-kept mirror of the app: update a topic and this test together when a feature changes.
@Suite struct HelpBookTests {

    @Test func testSectionsCoverTheExpectedAreas() {
        #expect(HelpBook.sections.map(\.title) == [
            "Getting started",
            // Its own section: what the chat sees, what it may change, and where its changes are
            // listed.
            "Ask Claude",
            "Working with differences",
            // Named for the whole workspace: a name that describes half of it lets the other half
            // go undocumented without anything looking odd.
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

    /// A typed apostrophe finds Help's curly one, and the other way round: Help writes “doesn’t
    /// allow”, and a search for "doesn't allow" must find it. Dropping the folding in `searchFolded`
    /// must fail it.
    @Test func searchTreatsBothApostrophesAlike() {
        for typed in ["doesn't allow filling", "doesn’t allow filling", "DOESN'T ALLOW FILLING"] {
            let ids = Set(HelpBook.filteredSections(matching: typed).flatMap(\.topics).map(\.id))
            #expect(!ids.isEmpty, "“\(typed)” finds nothing")
        }
        #expect(HelpBook.searchFolded("Don’t ‘quote’") == "don't 'quote'")
    }

    @Test func testUnmatchedQueryReturnsNothing() {
        #expect(HelpBook.filteredSections(matching: "zzzznotatopic").isEmpty)
    }

    /// Tabs are findable in Help. Their own discovery route is a right-click, so Help is where
    /// someone who never right-clicks a folder learns tabs exist. Searched rather than read off one
    /// topic, so it holds wherever the copy lives.
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

    /// Every "Settings ▸ X" the Help book prints names a tab that really exists. A tab's case can
    /// keep its name while its label changes (Providers is labelled Sources), so copy can point at a
    /// name not on screen. Derived from `SettingsTab.displayName`, so a relabel fails here. Only the
    /// arrow form is matched: it names a destination, while "cloud providers" as a plain noun is
    /// still correct.
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
    static func copy(of topic: HelpBook.Topic) -> [String] {
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

    /// The tab names in every "Settings ▸ X" in a string. Scanning stops at the first character
    /// that is neither a letter nor a space (a bracket, full stop or comma), and only the leading
    /// capitalised words are kept, so "Settings ▸ Sources and it appears…" yields `Sources`.
    static func settingsDestinations(in text: String) -> [String] {
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

    /// Every workspace the bar offers has a help topic, derived from `Workspace` so a new one fails
    /// here rather than shipping unexplained. And ⌘? opens there: `HelpBook.topicID(for:)` is the map
    /// below, and the overlay falls back to it when nothing named a page.
    @Test func everyWorkspaceHasATopic() throws {
        let expected: [Workspace: String] = [
            .browse: "browse-workspace",
            .compare: "scan",
            .filing: "organize-workspace",
            .editor: "editor-workspace",
        ]
        for workspace in Workspace.allCases {
            let id = expected[workspace]
            #expect(id != nil, "\(workspace.title) is a workspace with no help topic named here")
            if let id { #expect(HelpBook.topic(id: id) != nil, "\(workspace.title)'s topic \(id) is gone") }
            #expect(HelpBook.topicID(for: workspace) == id, "⌘? in \(workspace.title) opens somewhere else")
        }
        let overlay = try CodeText(declarationBody(of: "private var helpOverlay: some View",
                                                   in: macAppFile("ContentView.swift")))
        #expect(overlay.contains("openAt: helpTopic ?? HelpBook.topicID(for: selectedWorkspace, pdfIsOpen: editorPDF.path != nil)"),
                "⌘? no longer opens at the workspace's page, or the PDF's with one open")
        #expect(HelpBook.topicID(for: .editor, pdfIsOpen: true) == "pdf-workspace")
        #expect(HelpBook.topicID(for: .browse, pdfIsOpen: true) == "browse-workspace",
                "a PDF left open in Edit took ⌘? in Browse to the PDF's page")
        #expect(HelpBook.sectionTitle(forTopicID: "browse-workspace") == "Getting started")

        // The copy counts the workspaces too, and a number in prose doesn't move when one is added.
        // The articles read better with the word, so the count is checked here rather than
        // interpolated. Folded to a `Bool` first: `everyWord` is the whole book, and `#expect` on it
        // would dump every article into the failure.
        let count = Workspace.allCases.count
        let everyWord = HelpBook.allTopics.flatMap(Self.copy(of:)).joined(separator: " ")
        for claim in ["⌘1 through ⌘\(count)", "⌘1 – ⌘\(count)", "the \(Self.spelled(count)) workspaces"] {
            let saidSomewhere = everyWord.contains(claim)
            #expect(saidSomewhere,
                    "no article says “\(claim)” — the workspace count moved and the copy did not")
        }
    }

    /// Edit's article names every door into Edit, and the ways back out and around. The count is a
    /// number in prose, which doesn't move on its own, so each door is looked for by what the article
    /// must say to name it, and any other count anywhere in the book fails. A stale count, a dropped
    /// door's clause, or "they all do the same thing" must each fail it.
    @MainActor
    @Test func editsArticleNamesEveryDoorIntoEdit() throws {
        let topic = try #require(HelpBook.topic(id: "editor-workspace"))
        let text = Self.copy(of: topic).joined(separator: " ")
        // The menu's doors by the titles, and Open in Edit's chord, the File menu really has.
        let file = try appMenu("File")
        func item(_ title: String) throws -> NSMenuItem {
            try #require(file.items.first { $0.title == title }, "File has no \(title)")
        }
        let openInEdit = try item("Open in Edit")
        let menuDoors = ["File ▸ \(openInEdit.title) — \(chordGlyphs(openInEdit))",   // the menu and its chord
                         "File ▸ \(try item("Open Recent").title)",                   // and the empty page's list
                         "File ▸ \(try item("Close Document").title)"]                // the way out
        let doors = [
            "eight ways to bring a file here",
            "right-click a text file and choose Open in Edit",     // a file pane's row menu
            // Info's Open in Edit, the first of its buttons.
            "the first of the buttons under the file’s name in a pane’s Info",   // ⌘I
            "Compare’s list of differences offers Open in Edit",   // per side
            "a copy in Organize’s duplicates offers it first",
            "in Finder, a text file’s Open With menu offers SyncCloud",   // ExternalOpen
            "a file dragged from Finder onto Edit’s page",
            // What they do to the pane: all but one move it (Compare's list is `.staysPut`).
            "Every one but Compare’s list of differences also takes the file pane on the left",
        ]
        let backAndAround = [
            "Reveal in Browse", "Reveal in Finder, Quick Look, Rename and Move to Trash",
            "New Text File, on the file name’s row",
            "“in Finance”", "“iCloud › Documents › Finance”",                   // both readings
            "“No document open”",                                               // the empty page
        ]
        for phrase in menuDoors + doors + backAndAround {
            let said = text.contains(phrase)
            #expect(said, "Edit's article no longer says “\(phrase)”")
        }
        let everyWord = HelpBook.allTopics.flatMap(Self.copy(of:)).joined(separator: " ")
        for stale in ["four", "five", "six", "seven", "nine"].map({ "\($0) ways to bring" }) {
            let said = everyWord.contains(stale)
            #expect(!said, "an article still says “\(stale)” — there are eight")
        }
        // Not since Compare's list of differences stopped moving the pane.
        #expect(!text.contains("all do the same thing"),
                "Edit's article says the doors all do the same thing — the differences list leaves the pane put")
        // The release notes too, both copies: neither may say the doors all do the same thing.
        for notes in ["RELEASE_NOTES.md", "docs/releases.html"] {
            let body = try repoFile(notes)
            #expect(body.contains("Open in Edit"), "\(notes) does not mention Open in Edit — this check would be vacuous")
            for stale in ["all four do the same thing", "all do the same thing"] {
                #expect(!body.contains(stale), "\(notes) still says “\(stale)” — the differences list leaves the pane put")
            }
        }
    }

    /// Help names controls by their current labels: Restructure's re-read is “Update the Survey”
    /// (never a Rescan, never “…now”), File's trash item is Move Selection to Trash…, and a kept
    /// folder is in Favorites, not "pinned", a word reserved for tabs. Each positive half is checked
    /// against the control's own source, so a rename on either side fails here.
    @Test func helpNamesControlsByTheirCurrentLabels() throws {
        let book = HelpBook.allTopics.flatMap(Self.copy(of:)).joined(separator: " ")
        for stale in ["a Rescan beside it", "Update the Survey now", "then Delete, then"] {
            #expect(!book.contains(stale), "Help still says “\(stale)”")
        }
        // "Pinned" is a tab's word now; a folder is a favorite. Any other "pinned" is the old name.
        let lines = HelpBook.allTopics.flatMap(Self.copy(of:))
        let pinned = lines.filter { $0.localizedCaseInsensitiveContains("pinned") }
        #expect(!pinned.isEmpty, "Help no longer mentions a pinned tab — this scan would be vacuous")
        for line in pinned where !line.contains("a pinned tab") {
            Issue.record("Help says “pinned” about something other than a tab: \(line)")
        }
        #expect(book.contains("“Update the Survey”"))
        #expect(book.contains("then Move Selection to Trash…, then Close Document"))
        let lens = try repoFile("Modules/FileExplorer/Sources/FileExplorer/RestructureLens.swift")
        #expect(lens.contains(": \"Update the Survey\""), "Restructure's button no longer reads Update the Survey")
        let commands = try repoFile("MacApp/ShortcutCommands.swift")
        #expect(commands.contains("Button(\"Move Selection to Trash…\")"), "File's trash item was renamed")
    }

    /// The lines about Edit say what Edit does, each checked against what it describes: Edit
    /// autosaves, so it doesn't save "when you ask it to"; a non-Markdown file, or none, has a Files
    /// tab alone (`EditorRailTab.shown`); README's Edit section says "file list", not "rail", and
    /// offers a PDF's outline only at two or more bookmarks (`EditorRailTab.minimumPDFBookmarks`);
    /// and ⌘O opens a selected PDF as well as a text file. Any stale line must fail it.
    @Test func editsLinesSayWhatEditDoes() throws {
        let book = HelpBook.allTopics.flatMap(Self.copy(of:)).joined(separator: " ")
        for stale in ["it saves when you ask it to", "The file list has two tabs: Files and Outline"] {
            let said = book.contains(stale)
            #expect(!said, "Help still says “\(stale)”")
        }
        #expect(EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: false) == [.files],
                "the Files tab is no longer alone without a Markdown file — Help's sentence is wrong again")
        let edit = try #require(HelpBook.topic(id: "editor-workspace"))
        let tabs = Self.copy(of: edit).joined(separator: " ").contains("Outline beside it while a Markdown file is open")
        #expect(tabs, "Help does not say when Outline is offered")

        let readme = try repoFile("README.md")
        let edits = try #require(readme.range(of: "### ✏️ Edit"))
        let section = readme[edits.lowerBound...].prefix(6_000)
        for stale in ["a rail lists", "The rail shows", "**＋** makes a new file", "**×** puts the open one away"] {
            #expect(!section.contains(stale), "README's Edit section still says “\(stale)”")
        }
        // README's PDF line names the outline and the app's condition on it
        // (`EditorRailTab.pdfOutlineIsWorthATab`).
        #expect(EditorRailTab.minimumPDFBookmarks == 2,
                "a PDF's Outline no longer needs two bookmarks — README's PDF line is wrong again")
        #expect(section.contains("the outline when a PDF has two or more bookmarks"),
                "README's Edit section no longer says when a PDF shows its outline")

        let rows = ShortcutsReference.groups.flatMap(\.items).filter { $0.keys.contains("⌘ O") }
        #expect(rows.map(\.action) == ["New or selected file, in Edit"])
    }

    /// PDFs have a page of their own, next to Edit's, and each links to the other. Its paragraphs
    /// live only there; Edit's article keeps one line pointing at it. Moving a paragraph back into
    /// Edit's article must fail it.
    @Test func pdfsHaveATopicBesideEdits() throws {
        let edit = try #require(HelpBook.topic(id: "editor-workspace"))
        let pdf = try #require(HelpBook.topic(id: "pdf-workspace"))
        #expect(pdf.title == "Read, fill and sign a PDF")
        let started = try #require(HelpBook.sections.first { $0.title == "Getting started" }).topics.map(\.id)
        let at = try #require(started.firstIndex(of: "editor-workspace"))
        #expect(started.indices.contains(at + 1) && started[at + 1] == "pdf-workspace",
                "the PDF's page is not straight after Edit's")
        #expect(edit.article.related.contains("pdf-workspace") && pdf.article.related.contains("editor-workspace"))
        let editText = Self.copy(of: edit).joined(separator: " "), pdfText = Self.copy(of: pdf).joined(separator: " ")
        for paragraph in ["A PDF opens in Edit through the same doors as a text file:", "Tools, after Fill & Sign, is the PDF’s Tools menu",
                          "Fill & Sign, beside Find, floats a palette", "Replace, after Text in the palette, retypes",
                          "A PDF with fields of its own — a W-9, a visa form —"] {
            #expect(pdfText.contains(paragraph), "the PDF's page lacks “\(paragraph)”")
            #expect(!editText.contains(paragraph), "Edit's article still holds “\(paragraph)”")
        }
        #expect(editText.contains("are in Read, fill and sign a PDF."), "Edit's article does not point at the PDF's page")
    }

    /// Help gives the shortcuts window's key, interpolated from the chord so a new key can't leave
    /// the old one in the sentence.
    @Test func helpNamesTheShortcutsWindowsKey() throws {
        let keys = try #require(HelpBook.topic(id: "keyboard-shortcuts"))
        let said = Self.copy(of: keys).joined(separator: " ")
            .contains("Window ▸ Keyboard Shortcuts (\(AppChord.shortcutsReference.display))")
        #expect(said, "Help does not give the shortcuts window's key")
    }

    /// Help names the Markup verbs that only add. Not every verb "takes itself off if you choose it
    /// again": Link wraps the selection in another link, Code Block in another fence, Divider adds
    /// another line, and the Table items make or change a table. The overclaiming sentence must fail
    /// it.
    @Test func markupHelpNamesTheVerbsThatOnlyAdd() throws {
        let topic = try #require(HelpBook.topic(id: "editor-workspace"))
        let text = Self.copy(of: topic).joined(separator: " ")
        let named = text.contains("Link, Code Block, Divider and the Table items only ever add")
        #expect(named, "Edit's article does not name the Markup verbs that only add")
        let overclaims = text.contains("takes itself off if you choose it again")
        #expect(!overclaims, "Edit's article says every Markup verb takes itself off")
        for verb in [MarkupVerb.link, .codeBlock, .horizontalRule] {
            let titled = text.contains(verb.title)
            #expect(titled, "Edit's article does not name \(verb.title)")
        }
    }

    /// Restore Standard Places brings back as many places as Help says, counted from
    /// `SidebarFavoritePlaces.standard`. A wrong spelled-out count must fail it.
    @Test func restoreStandardPlacesCountsTheStandardSet() throws {
        let topic = try #require(HelpBook.topic(id: "folder-sidebar"))
        let line = try #require(Self.copy(of: topic).first { $0.contains("Restore Standard Places") },
                                "the sidebar article no longer mentions Restore Standard Places")
        let count = Self.spelled(SidebarFavoritePlaces.standard.count)
        #expect(line.contains("brings the \(count) it starts with back"),
                "Help miscounts the standard places — there are \(count): \(line)")
    }

    /// Help's File ▸ Fill & Sign Tool list names every tool the menu holds, read from the menu's
    /// `tool("…")` lines. Taking a tool, such as Replace, out of the Help sentence must fail it.
    @Test func fillSignToolHelpNamesEveryTool() throws {
        let source = try repoFile(
            "Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSignMenuItems.swift")
        let tools = source.matches(of: /tool\("([A-Za-z ]+)", \./).map { String($0.output.1) }
        #expect(tools.contains("Replace") && tools.contains("Form Fields"),
                "the menu's tool lines were not found — this check would be vacuous: \(tools)")
        let topic = try #require(HelpBook.topic(id: "pdf-workspace"))
        let line = try #require(Self.copy(of: topic).first { $0.contains("File ▸ Fill & Sign Tool holds") })
        let list = try #require(line.range(of: "holds the palette’s tools — ").map { line[$0.upperBound...] })
        for tool in tools {
            #expect(list.contains(tool), "Help's Fill & Sign Tool list leaves out \(tool)")
        }
    }

    /// The small numbers Help spells out. Above six the copy should be using digits, and this
    /// falls back to them rather than pretending it knows the word.
    private static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six"]
        return words.indices.contains(n) ? words[n] : "\(n)"
    }

    /// Every one of Organize's rail sections has an article of its own. A substring scan can't show
    /// that: "Rules" appears in several topics, so deleting the Rules article would leave it green.
    /// The map below names the topic each section is documented by, walked over `allCases` so a
    /// section added without one fails here.
    @Test func everyOrganizeSectionHasAnArticle() {
        let expected: [OrganizeLens: String] = [
            .toFile: "file-loose-items",
            .duplicates: "tidy-duplicates",
            .renames: "fix-names",
            .restructure: "restructure-shapes",
            .rules: "automation-rules",
            // The assertion below requires a lens's topic to live in the Organize section, so a
            // lens moved into Organize whose article stayed put fails here.
            .storage: "storage-lens",
        ]
        for lens in OrganizeLens.allCases {
            guard let id = expected[lens] else {
                Issue.record("Organize ▸ \(lens.title) is a rail item with no help topic named here")
                continue
            }
            // `Issue.record` + `continue`, not `#expect`, which keeps going: the checks below would
            // run against a missing topic and report one gap as three unrelated failures.
            guard let topic = HelpBook.topic(id: id) else {
                Issue.record("Organize ▸ \(lens.title) is documented by “\(id)”, which is gone")
                continue
            }
            #expect(HelpBook.sectionTitle(forTopicID: id) == "Organize",
                    "“\(id)” documents Organize ▸ \(lens.title) and does not live in the Organize section")
            // The article names the section, so the reader can tell which rail item it is about.
            #expect(Self.copy(of: topic).contains { $0.contains(lens.title) },
                    "“\(id)” never says “\(lens.title)”")
        }
    }

    // MARK: - Restructure, since it grew a surface that writes

    /// Restructure's four articles exist, and all stay in the Organize section.
    /// ``everyOrganizeSectionHasAnArticle`` maps each rail item to one topic, so it can't see the
    /// planning, applying and scaffolding articles, the only ones about a surface that moves the
    /// reader's files.
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

    /// Help may not call Restructure read-only while Apply exists: a claim like "it never rewrites"
    /// would be a false promise about the reader's data, and every other guard here reads structure,
    /// not claims. Tied to the code: while `applyPlan` is in `Sync` the phrases are banned; if Apply
    /// is removed, the anchor fails first and the ban is reconsidered.
    @Test func noArticleCallsRestructureReadOnly() throws {
        let apply = try repoFile("Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift")
        try #require(apply.contains("func applyPlan("),
                     "applyPlan is gone from Sync — the claims banned below may be true again")

        for phrase in ["never rewrites", "cannot change a file", "it never acts"] {
            let hits = HelpBook.filteredSections(matching: phrase).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty,
                    "Help still says “\(phrase)” about a section that now writes: \(hits)")
        }
    }

    /// Restructure's two undos are both taught, and told apart. ⌘Z is a grouped undo held in memory
    /// for the session; *Undo this reorganisation* replays a reversal kept on disk. Teaching only
    /// the first says a reorganisation stops being reversible at quit; teaching only the second
    /// loses the one keystroke that takes a landing straight back.
    @Test func bothOfRestructuresUndosAreTaught() throws {
        let topic = try #require(HelpBook.topic(id: "restructure-apply"))
        let words = Self.copy(of: topic).joined(separator: " ")
        #expect(words.contains("⌘Z"), "the session undo is no longer taught")
        #expect(words.lowercased().contains("undo this reorganization"),
                "the ledger undo is no longer taught by name")
        #expect(words.contains("survives quitting") || words.contains("survives a quit"),
                "nothing says the ledger undo outlives the session — the whole difference between the two")
    }

    /// The positive control for the walk above: a section name Organize doesn't have finds nothing,
    /// so the copy half matches titles, not everything.
    @Test func theOrganizeSectionScanCanActuallyFail() {
        #expect(HelpBook.filteredSections(matching: "Quarantine").isEmpty)
        #expect(!OrganizeLens.allCases.map(\.title).contains("Quarantine"),
                "“Quarantine” is a section name now — this test's counter-example is no longer one")
    }

    /// No topic is reachable only by scrolling the sidebar: the related chips are the one route
    /// between articles. `testEveryRelatedLinkResolvesToARealTopic` walks the graph from the links,
    /// so it can't see a topic nothing points at. No exemption for the topic Help opens on: if it
    /// ever ends up unlinked, that is a decision to make, not one already made.
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

    /// Help may not send anyone to Help menu items the app no longer has (Keyboard Shortcuts,
    /// Activity Log and Sync History live elsewhere): ``everyMenuPathInHelpNamesARealMenuItem``
    /// checks every "Help ▸ X" against the menu. This is the other half: the Help entries that do
    /// exist are still taught, so that check can't become a rule against naming the Help menu.
    @Test func noArticleSendsTheUserToARetiredHelpMenuItem() {
        let reveal = HelpBook.filteredSections(matching: "Help ▸ Reveal Log File").flatMap(\.topics).map(\.id)
        #expect(reveal.contains("activity-log"))
        let setup = HelpBook.filteredSections(matching: "Help ▸ Set Up SyncCloud").flatMap(\.topics).map(\.id)
        #expect(setup.contains("setup"))
    }

    /// Every "<Menu> ▸ <Item>" in the Help book names a menu item the running app really has. Read
    /// off `NSApp.mainMenu`, not the source: whether a `CommandMenu` or a nested `Menu` became the
    /// arrangement it declares is something only the running app answers (as in `WindowMenuTests`).
    /// Moving an item between menus otherwise breaks no test. "Settings ▸ …" is excluded: Settings is
    /// a tab rail, checked by ``everySettingsPathInHelpNamesARealTab``.
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

    /// The reverse walk: every menu the app has is written about somewhere in the book. The forward
    /// walk can't see a menu nobody wrote about, since an unwritten path is never wrong. Derived from
    /// `NSApp.mainMenu`, so a new menu is covered the day it appears. The match is on "<Menu> ▸ ",
    /// never the bare word: "File", "Edit", "View", "Go" and "Window" are ordinary English, and only
    /// a menu path has the arrow.
    @MainActor
    @Test func everyMenuInTheBarIsDescribedInTheBook() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let book = HelpBook.allTopics.flatMap { Self.copy(of: $0) }.joined(separator: "\n")

        let ours = mainMenu.items.filter { !$0.title.isEmpty && $0.submenu != nil }
        #expect(ours.count > 5, "only \(ours.count) menus were found — this scan has gone vacuous")

        for menu in ours {
            // Folded to a Bool before `#expect` sees it: the macro prints its subexpressions, and
            // `book` is the whole Help text.
            let described = book.contains("\(menu.title) ▸ ")
            #expect(described,
                    "the app has a \(menu.title) menu and no article names a \(menu.title) ▸ … path")
        }
    }

    /// The positive control for the reverse walk, about the bare word: a scan for "Edit" alone is
    /// satisfied by ordinary prose, so the arrow is what is asserted.
    @Test func theMenuCoverageScanCanActuallyFail() {
        let book = HelpBook.allTopics.flatMap { Self.copy(of: $0) }.joined(separator: "\n")
        let inventedMenu = book.contains("Bookmarks ▸ ")
        #expect(!inventedMenu, "the book names a Bookmarks menu, which this app has never had")
        // The real Edit coverage is a path, not a loose word: without the article naming Edit ▸ …
        // this fails, while a bare-word scan would not.
        let editIsAPath = book.contains("Edit ▸ ")
        let editIsALooseWord = book.contains("Edit") || book.contains("edit")
        #expect(editIsAPath, "no article names an Edit ▸ … path")
        #expect(editIsALooseWord, "the loose word is present too — which is exactly why it proves nothing")
    }

    /// The positive control: a real path is extracted and matched, and a plausible wrong one is
    /// caught. Organize's sections must not be back in View.
    @MainActor
    @Test func theMenuPathScanCanActuallyFail() throws {
        #expect(Self.menuDestinations(in: "Open it from Window ▸ Activity Log, or press ⌘L.")
                    .map(\.item) == ["Activity Log"])
        // Punctuation around the menu name must not become part of it: "(Settings ▸ Intelligence)"
        // must not read as a menu called "(Settings" and fail a correct sentence.
        #expect(Self.menuDestinations(in: "needs a key (Settings ▸ Intelligence).")
                    .map(\.menu) == ["Settings"])
        #expect(Self.menuDestinations(in: "“Settings ▸ Sources is where SyncCloud lists them.")
                    .map(\.menu) == ["Settings"])
        let mainMenu = try #require(NSApp.mainMenu)
        let view = try #require(mainMenu.items.first { $0.title == "View" }?.submenu)
        #expect(!view.items.contains { $0.title.hasPrefix("Restructure") },
                "View carries Organize's sections again — the copy this test defends would be right, not wrong")
    }

    /// The `(menu, item)` pairs in every "<Menu> ▸ <Item>" in a string. Like
    /// ``settingsDestinations(in:)``: the item runs to the first character that is not a letter,
    /// space or ellipsis, and only its leading capitalised words are kept.
    private static func menuDestinations(in text: String) -> [(menu: String, item: String)] {
        var out: [(String, String)] = []
        var rest = Substring(text)
        while let marker = rest.range(of: " ▸ ") {
            let head = rest[..<marker.lowerBound]
            // The word before the arrow, stripped to letters: a sentence may open with the menu name
            // ("Settings ▸ Sources is where…") or bracket it ("(Settings ▸ Intelligence)"), and an
            // unstripped "(Settings" could be neither skipped as Settings nor found as a menu.
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

    /// The macOS version Help claims is the one the app is built against; a wrong one costs a reader
    /// a download and a failed launch. `Bundle.main` is the app here, since `SyncCloud.app` hosts
    /// `SyncCloudTests`. `HelpBook.minimumSystemRequirement` reads the bundle, so this catches the
    /// two ways the derived string can still be wrong: the fallback firing (no
    /// `LSMinimumSystemVersion`), and the formatting (`26.0` must read `26`, `15.4` must keep `.4`).
    @Test func theStatedSystemRequirementMatchesTheBuild() throws {
        let raw = try #require(Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String,
                               "the host bundle carries no LSMinimumSystemVersion — this test cannot see the truth")
        let expected = raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw

        let about = try #require(HelpBook.topic(id: "about"))
        let copy = about.article.blocks.map(String.init(describing:)).joined(separator: " ")
        #expect(copy.contains("Requires macOS \(expected) or later."),
                "the About topic does not state the built requirement (macOS \(expected)) — it says: \(copy)")
        // Named separately, as the failure with no other symptom: the fallback is grammatical,
        // plausible, and tells the reader nothing.
        #expect(!copy.contains("a recent version of macOS"),
                "the requirement fell back to the vague form inside the real app bundle")
    }

    /// The requirement is derived and can't be typed back in: a literal is the obvious edit, reads
    /// fine, and is right only on the day it is typed. Comment-stripped, so a doc comment quoting the
    /// phrase isn't the failure. Scoped to `HelpBook.swift`, the one file where exactly one
    /// occurrence (the property's own interpolation) is expected.
    @Test func theRequirementIsNotWrittenOutAsALiteral() throws {
        let source = sourceCodeOnly(try macAppFile("HelpBook.swift"))
        try #require(source.count > 10_000, "HelpBook.swift read as \(source.count) characters")
        // The one legitimate occurrence is the interpolation inside `minimumSystemRequirement`.
        let occurrences = source.components(separatedBy: "Requires macOS ").count - 1
        #expect(occurrences == 1,
                "“Requires macOS ” appears \(occurrences) times in HelpBook.swift — the only one allowed is the interpolation in minimumSystemRequirement")
        #expect(source.contains("Requires macOS \\(shown) or later."),
                "the surviving occurrence is not the interpolated one — the number has been typed back in")
    }

    /// Retired product vocabulary stays out of the copy: "Filing" is Organize's To File lens, and
    /// "tidy" is no longer the product's voice. Search-based like the drag test below, so every
    /// block type is covered. Topic ids aren't searched: `tidy-duplicates` is a frozen identifier.
    @Test func testNoArticleUsesRetiredVocabulary() {
        for word in ["tidy", "filing"] {
            let hits = HelpBook.filteredSections(matching: word).flatMap(\.topics).map(\.id)
            #expect(hits.isEmpty, "Help topics still say “\(word)”: \(hits)")
        }
    }

    /// No article may teach cross-pane drag & drop, which the app doesn't have. The other tests pin
    /// structure, so an article could document a missing feature and stay green. The phrases are
    /// that feature's own, not a ban on dragging: the tab strip's reorder drag is real, and the last
    /// check keeps it taught.
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


/// The related-chip row is a wrapping layout, not an `HStack`, which squeezes instead of wrapping
/// and hyphenates labels inside tall ovals. A source scan of the call site's choice of container:
/// `FlowLayoutMathTests` pins the wrapping geometry, and a layout or render test can't tell a
/// squeezed row from a wrapped one. It also keeps MacApp on FileExplorer's flow layout rather than
/// a third copy. `declarationBody` is brace-bounded, so a neighbour can't answer for this struct.
@Suite struct HelpChipRowTests {

    static func source() throws -> String { try macAppFile("HelpBook.swift") }

    @Test func theChipsUseTheSharedWrappingLayout() throws {
        let body = try declarationBody(of: "private struct FlexibleChips", in: Self.source())
        #expect(body.contains("FileExplorer.FlowLayout"),
                "the related chips no longer use the shared wrapping layout")
        #expect(!body.contains("HStack(spacing: 8)"),
                "the chip row is an HStack again — it squeezes rather than wraps")
    }
}
