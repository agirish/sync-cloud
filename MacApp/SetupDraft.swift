import Events
import Foundation
import Sync

/// The answers setup collects that it cannot write down yet.
///
/// **This exists because of an ordering problem, not as a convenience.** Two of the form's four
/// questions land in files that live *inside a profile* — `people.json` sits beside
/// `folder-profile.json` under `profiles/<id>/` — and a fresh machine has no profile until the
/// folder survey mints one. So on exactly the machine setup is for, the You and People steps have
/// nowhere to write. The answers are held here instead, and applied to the roster the moment one
/// exists: either straight away on a machine that already has a profile, or by the survey stage
/// after it writes the first one.
///
/// The other two questions need no draft — preferences are `@AppStorage` and the source list is
/// `SettingsManager`, both of which are perfectly happy on a machine with no profile. Nothing that
/// can be written immediately is routed through here; a draft that shadowed live settings would be
/// a second source of truth for them.
struct SetupDraft: Codable, Equatable, Sendable {

    /// One person as the form collected them, before they have a roster id.
    ///
    /// **No id field, deliberately.** `PeopleStore` derives ids from display names and keeps them
    /// unique within the roster (`Person.id` is a `let` precisely so a rename cannot orphan the
    /// folders and rules resolving through it). A draft that minted its own would be inventing
    /// identity for records that do not exist yet, and two drafts applied to one roster could
    /// collide on it — which is the failure `PersonRegistry` had to grow a collapse for.
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

    /// What your folders call you — the display name of your own roster record.
    var yourName: String = ""
    /// Every full form your documents might print. The field that does the work: a full name is
    /// matched before any single word, so a shared surname stops making two people out of one
    /// document.
    var yourFullNames: [String] = []
    /// The rest of the household.
    var others: [DraftPerson] = []

    /// Whether there is anything here worth applying.
    var isEmpty: Bool {
        yourName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && yourFullNames.isEmpty && others.isEmpty
    }

    /// Everyone in the draft, you first.
    ///
    /// **You lead, and the order is load-bearing rather than cosmetic.** `PeopleStore.add` derives
    /// an id from the display name and makes it unique *within the roster as it stands*, so the
    /// first record to claim a name gets the plain id and a later namesake gets the suffixed one.
    /// Your own record is the one every other surface resolves through, so it goes in first.
    var everyone: [DraftPerson] {
        var all: [DraftPerson] = []
        let name = yourName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            all.append(DraftPerson(displayName: name, relationship: "me", fullNames: yourFullNames))
        }
        all.append(contentsOf: others)
        return all
    }

    /// Writes the draft into a roster, adding what is missing and filling in what is thin.
    ///
    /// **Idempotent, because it is called more than once.** A machine with a profile applies on
    /// every step commit, and the survey stage applies again after minting a profile; a second
    /// application must not produce a second Abhishek. Matching is on the display name, compared
    /// the way the roster itself compares names, and a match is *updated* rather than replaced —
    /// setup adding a full name must never delete one the user typed in Settings.
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
            if let existing = store.people.first(where: {
                $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }) {
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
    /// Compared case- and diacritic-insensitively, which is the comparison the matcher itself uses:
    /// adding “Abhishek Girish” to a record that already carries “abhishek girish” would otherwise
    /// grow the list by a duplicate that matches exactly the same documents.
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
/// `~/Library/Application Support/SyncCloud/setup-draft.json` — beside `profiles/` rather than
/// inside it, because the whole point of the draft is that it exists before any profile does.
///
/// **Every failure is silent and lossless in the same direction: the draft simply is not there.**
/// A draft that cannot be read is one setup asks for again, which costs the user a minute; a draft
/// that half-decoded into a roster would cost them a wrong household, and the roster is the file
/// the engine attributes every document through.
enum SetupDraftStore {

    /// Bumped if the shape changes. A foreign version is discarded rather than migrated — the
    /// contents are one form away, and the file is deleted the moment setup finishes.
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
    static func read(at url: URL) -> SetupDraft? {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        guard document.schemaVersion == currentSchema else {
            Logger.shared.warning("Setup draft has schema \(document.schemaVersion), not "
                                  + "\(currentSchema) — ignoring it and asking again")
            return nil
        }
        return document.draft
    }

    /// Writes the draft, creating the directory if it is not there.
    ///
    /// **Atomic**, for the reason every other whole-file write in this app is: the draft is read at
    /// launch, and a half-written file is one setup would discard — losing answers the user has
    /// already given rather than the last one they typed.
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
    /// **Only ever called after a successful apply**, because this file is the only copy: deleting
    /// it on the way past the People step — before a profile exists to apply it into — would throw
    /// away answers nothing else holds.
    static func clear(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            Logger.shared.warning("Setup draft could not be removed: \(error.localizedDescription)")
        }
    }
}
