import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// The People section: the store's editing rules, and the layout claims the rows make.
///
/// The store tests are the important half — a roster is persisted state, and "it worked in the
/// window" says nothing about what a relaunch reads back.
@MainActor
@Suite struct PeopleSectionTests {

    /// The real household, which is the fixture worth testing against: three of these people share
    /// a surname with a fourth's given name.
    static func household() -> [Person] {
        [Person(id: "abhishek", displayName: "Abhishek", relationship: "me",
                fullNames: ["Abhishek Girish"]),
         Person(id: "aditi", displayName: "Aditi", relationship: "daughter",
                fullNames: ["Aditi Abhishek"]),
         Person(id: "muktha", displayName: "Muktha", relationship: "mother",
                fullNames: ["Muktha Girish"], aliases: ["Mom"])]
    }

    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("people-\(UUID().uuidString)")
    }

    // MARK: - The store

    /// **A relaunch is the only proof an edit was saved.** A fresh store over the same directory is
    /// that relaunch — the same shape `KeptNamesSettingsTests` uses.
    @Test func addingAPersonSurvivesARelaunch() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        #expect(store.people.isEmpty)

        store.add(displayName: "Divit", relationship: "son", fullNames: ["Divit Abhishek"])

        let reopened = PeopleStore(directory: dir, profileId: "t", profile: nil)
        let divit = try #require(reopened.people.first)
        #expect(divit.id == "divit")
        #expect(divit.relationship == "son")
        #expect(divit.fullNames == ["Divit Abhishek"])
        #expect(reopened.source == .file)
    }

    /// Editing keeps the id, and that is load-bearing: a folder's `axes.person` and every rule that
    /// will key on a person resolve through it, so a rename must not orphan them.
    @Test func renamingAPersonKeepsTheirIdentity() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        let added = try #require(store.add(displayName: "Shweta", fullNames: ["Shweta Dani"]))

        var edited = added
        edited.displayName = "Shweta D."
        edited.fullNames.append("Shweta Ravindra Dani")
        store.update(edited)

        let reopened = PeopleStore(directory: dir, profileId: "t", profile: nil)
        let shweta = try #require(reopened.people.first)
        #expect(shweta.id == added.id, "the id moved — every folder recorded as hers is now orphaned")
        #expect(shweta.displayName == "Shweta D.")
        #expect(shweta.fullNames.count == 2)
    }

    @Test func removingAPersonTakesThemOutOfTheRosterAndTheFile() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        store.add(displayName: "Aditi")
        store.add(displayName: "Divit")
        store.remove(id: "aditi")

        #expect(store.people.map(\.id) == ["divit"])
        #expect(PeopleStore(directory: dir, profileId: "t", profile: nil).people.map(\.id) == ["divit"])
    }

    /// Two people can share a first name, and the second must not overwrite the first's folders by
    /// silently taking their id.
    @Test func twoPeopleWithTheSameNameGetDistinctIds() {
        let store = PeopleStore(people: [])
        store.add(displayName: "Anuraag")
        store.add(displayName: "Anuraag")
        #expect(store.people.map(\.id) == ["anuraag", "anuraag-2"])
    }

    /// Blank and duplicate entries are refused rather than stored — a roster with `""` in its
    /// `fullNames` matches everything or nothing depending on the matcher's mood.
    @Test func blanksAndDuplicatesAreCleanedAway() throws {
        let store = PeopleStore(people: [])
        #expect(store.add(displayName: "   ") == nil)
        let p = try #require(store.add(displayName: "  Aditi  ",
                                       fullNames: ["Aditi Abhishek", "  ", "aditi abhishek"]))
        #expect(p.displayName == "Aditi")
        #expect(p.fullNames == ["Aditi Abhishek"])
    }

    /// **A seeded roster is not the user's until they touch it**, and the file is what records
    /// that. Nothing is written on load — the file appears on the first edit.
    @Test func aSeededRosterWritesNothingUntilItIsEdited() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FolderProfile(profileId: "t", root: "~", folders: [:],
                                    personTokens: ["aditi", "mom", "muktha"],
                                    personAliases: ["mom": "muktha"])
        let store = PeopleStore(directory: dir, profileId: "t", profile: profile)
        #expect(store.source == .profileAxis)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        store.add(displayName: "Divit")
        #expect(store.source == .file)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The registry recompiles on every edit — a stale matcher would attribute documents through a
    /// household the user has already corrected.
    @Test func theRegistryFollowsAnEdit() {
        let store = PeopleStore(people: Self.household())
        #expect(store.registry.detect(in: "Mom - passport.pdf") == ["muktha"])
        store.remove(id: "muktha")
        #expect(store.registry.detect(in: "Mom - passport.pdf").isEmpty)
    }

    // MARK: - The facts each row states

    /// Every number the row prints comes from here, so this is where they are pinned.
    @Test func theFactsDescribeWhatTheEngineWillDo() throws {
        let registry = PersonRegistry(people: Self.household())
        let entry = FolderProfileEntry(path: "Immigration/OCI/Aditi", role: .personBucket,
                                       naming: nil, anchors: [], acceptsNewFiles: nil,
                                       fileCount: 2, subfolderCount: 0, axes: ["person": "Aditi"])
        let profile = FolderProfile(profileId: "t", root: "~",
                                    folders: ["Immigration/OCI/Aditi": entry],
                                    personTokens: ["aditi"])
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Immigration/OCI/Aditi": FilingMemoryEntry(docs: 4, anchors: [], idHashes: []),
        ])
        let aditi = try #require(registry.people.first { $0.id == "aditi" })
        let facts = PersonFilingFacts.make(for: aditi, registry: registry,
                                           profile: profile, memory: memory)

        #expect(facts.folders == ["Immigration/OCI/Aditi"])
        #expect(facts.filedDocuments == 4)
        #expect(facts.uniqueWords == ["aditi"])
        #expect(facts.sharedWords.map(\.word) == ["abhishek"])
        #expect(facts.sharedWords.first?.othersSharing == 1)
        // Longest first — the order they are TRIED in, which is what makes the line an explanation
        // rather than a list.
        #expect(facts.matchedForms == ["Aditi Abhishek", "Aditi"])
    }

    /// An alias resolves the folder to its owner, so `Family/Mom` counts toward Muktha. Without the
    /// alias map this row would report zero folders for her — the visible face of the bug the
    /// registry was built to fix.
    @Test func anAliasedFolderCountsTowardItsOwner() throws {
        let registry = PersonRegistry(people: Self.household())
        let entry = FolderProfileEntry(path: "Family/Mom", role: .personBucket, naming: nil,
                                       anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                       subfolderCount: 0, axes: ["person": "Mom"])
        let profile = FolderProfile(profileId: "t", root: "~", folders: ["Family/Mom": entry],
                                    personTokens: ["mom", "muktha"])
        let muktha = try #require(registry.people.first { $0.id == "muktha" })
        let facts = PersonFilingFacts.make(for: muktha, registry: registry,
                                           profile: profile, memory: nil)
        #expect(facts.folders == ["Family/Mom"])
    }

    /// **A full name attributes a person who has no distinctive word of their own.**
    ///
    /// Abhishek shares both his words: `abhishek` is three other people's surname and `girish` is
    /// three others' too. He is nonetheless perfectly attributable, because "Abhishek Girish" is
    /// matched as a phrase — so the row must not tell him to add a full name he already has.
    ///
    /// This is pinned because the first version of the section judged on unique words alone and
    /// rendered **all seven** of a real household in amber; the caution meant nothing, and a
    /// mutation reverting the fix went unnoticed until this test existed.
    @Test func aFullNameMakesSomeoneAttributableWithoutAUniqueWord() throws {
        let registry = PersonRegistry(people: Self.household())
        let abhishek = try #require(registry.people.first { $0.id == "abhishek" })
        let facts = PersonFilingFacts.make(for: abhishek, registry: registry,
                                           profile: nil, memory: nil)
        #expect(!facts.hasAnyUniqueWord, "fixture drifted — he is supposed to share every word")
        #expect(facts.isAttributable, "“Abhishek Girish” names him; the row would nag him to add it")

        // And the state the caution IS for: one shared word, no full name, nothing to match on.
        let stranded = PersonRegistry(people: Self.household()
                                      + [Person(id: "girish-2", displayName: "Girish")])
        let other = try #require(stranded.people.first { $0.id == "girish-2" })
        let strandedFacts = PersonFilingFacts.make(for: other, registry: stranded,
                                                   profile: nil, memory: nil)
        #expect(!strandedFacts.isAttributable)
    }

    /// On a machine with no survey the facts are honestly empty rather than wrong.
    @Test func withNoProfileTheFactsReportNoFolders() throws {
        let registry = PersonRegistry(people: Self.household())
        let aditi = try #require(registry.people.first { $0.id == "aditi" })
        let facts = PersonFilingFacts.make(for: aditi, registry: registry, profile: nil, memory: nil)
        #expect(facts.folders.isEmpty)
        #expect(facts.filedDocuments == 0)
        #expect(!facts.matchedForms.isEmpty, "names are known even when nothing has been surveyed")
    }

    // MARK: - The editor's own rules

    /// A name is the only requirement — everything else is evidence, and a person with none is
    /// still worth recording.
    @Test func onlyANameIsRequiredToSave() {
        #expect(PersonEditor.canSave(displayName: "Aditi"))
        #expect(!PersonEditor.canSave(displayName: ""))
        #expect(!PersonEditor.canSave(displayName: "   "))
    }

    /// **A name typed but not yet added with ⏎ must not vanish on Save.** This is the single most
    /// likely way to lose an edit in this sheet, and the editor folds the pending field in instead.
    ///
    /// Tested through `folding` rather than by setting the view's `@State`: that has no storage
    /// outside a rendered view, so the obvious version of this test read back the initial value and
    /// passed with the rule deleted.
    @Test func aPendingNameIsKeptWhenSaveIsPressed() {
        let person = Person(id: "aditi", displayName: "Aditi")
        let folded = PersonEditor.folding(person, pendingFullName: "Aditi Abhishek",
                                          pendingAlias: "  ")
        #expect(folded.fullNames == ["Aditi Abhishek"])
        #expect(folded.aliases.isEmpty)

        // Committing it first and then pressing Save must not store it twice.
        var committed = person
        committed.fullNames = ["Aditi Abhishek"]
        #expect(PersonEditor.folding(committed, pendingFullName: "aditi abhishek",
                                     pendingAlias: "").fullNames == ["Aditi Abhishek"])
    }

    // MARK: - The unreadable-roster warning is actually on screen

    /// Ink drawn by `view` at `width`, counted as pixels differing from the window background.
    ///
    /// **Pixels, because room is not paint.** A height comparison would pass against a note that
    /// reserved space and drew nothing, which is the failure this file's neighbours keep meeting.
    /// Light appearance with an opaque background fill, for the reason `PeopleRenderProbe` gives:
    /// without it a render decodes as white-on-transparent and reads as an empty view.
    private func ink(_ view: some View, width: CGFloat) -> Int {
        let subject = view.frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: subject)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero,
                            size: CGSize(width: width, height: max(1, host.fittingSize.height)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var painted = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.brightnessComponent - background.brightnessComponent) > 0.08 { painted += 1 }
            }
        }
        return painted
    }

    /// **The claim is split in two because a whole-list render cannot carry it, and the first
    /// attempt at one passed with the wiring deleted.** Comparing a readable list against an
    /// unreadable one measures `sourceNote` as well: it swaps "Saved in people.json" for the much
    /// longer "Suggested from your folder names…" whenever the roster is seeded, which is *always*
    /// true in the unreadable case. That difference alone cleared the threshold, so the test
    /// reported the warning present while `PeopleList` no longer drew it — a measurement adjacent
    /// to the claim, which is the shape this codebase keeps meeting.
    ///
    /// So: this asserts the note **paints**, and `theUnreadableRosterNoteIsWiredIntoTheList`
    /// asserts it is **reached**. Neither alone is the claim; together they are.
    /// **The control is the same Label with no message**, and it has to be: a bare threshold on the
    /// note's own ink passed with the `Text` emptied, because the warning triangle alone paints
    /// hundreds of pixels. The icon is not the claim — the sentence is.
    @Test func theUnreadableRosterNotePaintsItsMessage() {
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)
        let note = ink(PeopleList.unreadableRosterNote, width: width)
        let iconOnly = ink(
            Label { Text("") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .scaledFont(.callout).foregroundStyle(.secondary),
            width: width)
        #expect(iconOnly > 50, "the harness drew nothing even for the icon (\(iconOnly))")
        #expect(note > iconOnly * 3,
                "the warning is little more than its icon (\(note) vs \(iconOnly)) — its message is not being drawn")
    }

    /// The other half: the note is reached from `PeopleList.body`, under the store's own flag.
    ///
    /// Source-level because SwiftUI cannot be driven from here and the render above cannot isolate
    /// this branch. Bounded to `body` by its closing brace and failing loudly if the declaration
    /// moves, so a rename cannot quietly empty the haystack.
    @Test func theUnreadableRosterNoteIsWiredIntoTheList() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Settings/SettingsView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SettingsView.swift — this scan would be vacuous")
        let marker = "struct PeopleList: View {"
        #expect(source.components(separatedBy: marker).count - 1 == 1,
                "PeopleList is declared more than once — this scan would read the wrong one")
        let start = try #require(source.range(of: marker), "PeopleList is gone")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    var body: some View {"),
                               "PeopleList has no body")
        let bodyStart = rest[end.upperBound...]
        let bodyEnd = try #require(bodyStart.range(of: "\n    }"), "no closing brace for body")
        let body = String(bodyStart[..<bodyEnd.lowerBound])

        #expect(body.contains("store.rosterIsUnreadable"),
                "PeopleList no longer asks whether the roster loaded — the refusal to save is silent")
        #expect(body.contains("unreadableRosterNote"),
                "PeopleList no longer draws the warning")
    }
}
