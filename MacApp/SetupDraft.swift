import Events
import Foundation
import Sync

/// The answers setup collects that it cannot write down yet.
///
/// The You and People answers land in a file inside a profile (`people.json` sits beside
/// `folder-profile.json` under `profiles/<id>/`), and a fresh Mac has no profile until the folder
/// survey mints one. So on exactly the Mac setup is for, they have nowhere to write. They are held
/// here and applied to the roster as soon as one exists: at once where a profile already exists,
/// or by the survey stage after it writes the first one.
///
/// Answers that can be written immediately (`@AppStorage` preferences, the `SettingsManager`
/// source list) never pass through here: a draft shadowing live settings would be a second source
/// of truth.
struct SetupDraft: Codable, Equatable, Sendable {

    /// One person as the form collected them, before they have a roster id.
    ///
    /// No id field: `PeopleStore` derives ids from display names and keeps them unique within the
    /// roster (`Person.id` is a `let` so a rename can't orphan the folders and rules that resolve
    /// through it). A draft minting its own would invent identity for records that don't exist yet,
    /// and two drafts applied to one roster could collide on it.
    struct DraftPerson: Codable, Equatable, Sendable {
        var displayName: String
        var relationship: String?
        var fullNames: [String]
        var aliases: [String]

        init(displayName: String, relationship: String? = nil,
             fullNames: [String] = [], aliases: [String] = []) {
            self.displayName = displayName
            self.relationship = relationship
            self.fullNames = fullNames
            self.aliases = aliases
        }
    }

    /// What your folders call you: the display name of your own roster record.
    var yourName: String = ""
    /// Every full form your documents might print. The field that does the work: a full name is
    /// matched before any single word, so a shared surname doesn't make two people out of one
    /// document.
    var yourFullNames: [String] = []
    /// The rest of the household.
    var others: [DraftPerson] = []

    /// Whether there is anything here worth applying.
    var isEmpty: Bool {
        yourName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && yourFullNames.isEmpty && others.isEmpty
    }

    /// Everyone in the draft, you first. The order matters: `PeopleStore.add` makes ids unique
    /// within the roster as it stands, so the first record to claim a name gets the plain id and a
    /// later namesake the suffixed one. Every other surface resolves through your record, so it
    /// goes first.
    var everyone: [DraftPerson] {
        var all: [DraftPerson] = []
        let name = yourName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            all.append(DraftPerson(displayName: name, relationship: "me", fullNames: yourFullNames))
        }
        all.append(contentsOf: others)
        return all
    }

    /// The draft as a registry the folder walk can use, or nil when it holds nobody.
    ///
    /// The walk needs a household before there is a roster to hold one, so the answers become a
    /// `PersonRegistry` straight from the draft.
    ///
    /// Ids are made unique here, because nothing downstream does it. Two people can share an
    /// `idCandidate` (`Anne Marie` and `Anne-Marie` both fold to `anne-marie`), and
    /// `PersonRegistry.init` keeps only the last of a repeated id, so the walk would silently lose
    /// someone. `PeopleStore.add` disambiguates the same way; a draft has no store to do it.
    var registry: PersonRegistry? {
        var used: Set<String> = []
        let people: [Person] = everyone.map { drafted in
            let base = Person.idCandidate(from: drafted.displayName)
            var id = base
            var suffix = 2
            while used.contains(id) {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(id)
            return Person(id: id, displayName: drafted.displayName,
                          relationship: drafted.relationship, fullNames: drafted.fullNames,
                          aliases: drafted.aliases)
        }
        return people.isEmpty ? nil : PersonRegistry(people: people, source: .profileAxis)
    }

    /// Writes the draft into a roster, adding what is missing and filling in what is thin.
    ///
    /// Idempotent, because it runs more than once: on every step commit where a profile exists,
    /// and again after the survey stage mints one. A second run must not add a second Father.
    /// Matching is by display name, compared as the roster compares names, and a match is updated,
    /// never replaced, so setup never deletes a full name the user typed in Settings.
    ///
    /// Editing your own name renames your record. Matching by name alone would add a second "me",
    /// which People hides, so neither would show. The old name stays as an alias, since folders
    /// that called you by it still do.
    ///
    /// Returns the number of people added and the number updated, for the log line.
    @discardableResult
    @MainActor
    static func apply(_ draft: SetupDraft, to store: PeopleStore) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for person in draft.everyone {
            let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let byName = store.people.first(where: {
                $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            })
            if byName == nil, PeopleOrder.tier(of: person.relationship) == .yourself,
               var me = store.people.first(where: { PeopleOrder.tier(of: $0.relationship) == .yourself }) {
                let previous = me.displayName
                me.displayName = name
                me.aliases = union(me.aliases, [previous])
                me.fullNames = union(me.fullNames, person.fullNames)
                store.update(me)
                updated += 1
                Logger.shared.info("Setup: renamed your roster record from “\(previous)” to “\(name)”")
            } else if let existing = byName {
                var merged = existing
                merged.relationship = existing.relationship ?? person.relationship
                merged.fullNames = union(existing.fullNames, person.fullNames)
                merged.aliases = union(existing.aliases, person.aliases)
                if merged != existing {
                    store.update(merged)
                    updated += 1
                }
            } else {
                store.add(displayName: name, relationship: person.relationship,
                          fullNames: person.fullNames, aliases: person.aliases)
                added += 1
            }
        }
        if added > 0 || updated > 0 {
            Logger.shared.info("Setup: applied the draft roster — \(added) added, \(updated) updated")
        }
        return (added, updated)
    }

    /// `existing` order preserved, `incoming` appended where it says something new.
    ///
    /// Compared case- and diacritic-insensitively, as the matcher compares: otherwise “Father
    /// Elder” added beside “father elder” would be a duplicate matching the same documents.
    private static func union(_ existing: [String], _ incoming: [String]) -> [String] {
        var out = existing
        for candidate in incoming {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let known = out.contains {
                $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if !known { out.append(trimmed) }
        }
        return out
    }
}

/// Reads and writes ``SetupDraft`` as a single JSON file.
///
/// `~/Library/Application Support/SyncCloud/setup-draft.json`, beside `profiles/` rather than
/// inside it, because the draft exists before any profile does.
///
/// Every failure lands the same way: the draft is not there. An unreadable draft means setup asks
/// again, which costs a minute; a half-decoded one would give the roster a wrong household, and
/// the engine attributes every document through the roster.
enum SetupDraftStore {

    /// Bumped if the shape changes. A foreign version is discarded, not migrated: the contents are
    /// one form away, and the file is deleted once setup finishes.
    static let currentSchema = 1

    private struct Document: Codable {
        var schemaVersion: Int
        var draft: SetupDraft
    }

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/setup-draft.json")
    }

    /// The draft on disk, or nil when there is none this build can read.
    ///
    /// Three states, and only absent is silent (as in ``FolderJumpStore/storedMap``):
    ///
    /// - Absent: the common case, since there is no draft until the user answers something. A
    ///   line per launch about a file not yet written would stop the log being read.
    /// - Present and unreadable (permissions, a truncated write, a hand edit): this file is the
    ///   only copy of the You and People answers, which is why ``clear(at:)`` runs only after they
    ///   reach a roster. The user is about to lose them, so the warning names the path.
    /// - Schema from another build: warned about too.
    ///
    /// The bytes are not stashed the way `FolderJumpStore` stashes pins: pins are curated over
    /// months, while a draft is one form away. Saying where it is beats keeping a copy.
    static func read(at url: URL) -> SetupDraft? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // `fileExists`, not the error code: the question is whether there is something here to
            // lose, not which error the read produced.
            if FileManager.default.fileExists(atPath: url.path) {
                Logger.shared.warning("Setup draft at \(url.path) could not be read "
                                      + "(\(error.localizedDescription)) — setup will ask again, and "
                                      + "the answers already given are only in that file")
            }
            return nil
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            Logger.shared.warning("Setup draft at \(url.path) is \(data.count) byte(s) this build "
                                  + "cannot decode — setup will ask again, and the answers already "
                                  + "given are only in that file")
            return nil
        }
        guard document.schemaVersion == currentSchema else {
            Logger.shared.warning("Setup draft has schema \(document.schemaVersion), not "
                                  + "\(currentSchema) — ignoring it and asking again")
            return nil
        }
        return document.draft
    }

    /// Writes the draft, creating the directory if it is not there.
    ///
    /// Atomic: the draft is read at launch, and setup would discard a half-written file, losing
    /// every answer given rather than just the last one typed.
    static func write(_ draft: SetupDraft, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Document(schemaVersion: currentSchema, draft: draft))
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.warning("Setup draft could not be saved (\(error.localizedDescription)) — "
                                  + "the answers are still in this window, but quitting will lose them")
        }
    }

    /// Removes the draft once its contents have reached a roster.
    ///
    /// **Call it only after a successful apply.** This file is the only copy: deleting it past the
    /// People step, before a profile exists to apply it into, throws away answers nothing else
    /// holds.
    static func clear(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            Logger.shared.warning("Setup draft could not be removed: \(error.localizedDescription)")
        }
    }
}
