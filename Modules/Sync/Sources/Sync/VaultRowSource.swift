import Foundation

/// Whose a number's papers are: the names corrected everywhere and the household's people. The
/// rows weigh it, and so does a waiting number rebuilt from its copies (VT7).
struct VaultHolders {
    /// Names corrected everywhere, by ``VaultReading/spellingKey(_:)`` of the name as read.
    let names: [String: String]
    /// The household's people, from Settings ▸ Organize.
    let people: [Person]
    /// Their names, tokenised once for every lookup these holders make (VT66): a rows rebuild
    /// asked for a new one per saved ID and per copy.
    let registry: PersonRegistry?

    init(names: [String: String], people: [Person]) {
        self.names = names
        self.people = people
        registry = people.isEmpty ? nil : PersonRegistry(people: people)
    }

    /// The name a number's document should say: its own correction, else one made everywhere for
    /// that reading; nil to go by what was read.
    func correctedName(_ read: String?, own: String?) -> String? {
        if let own { return own }
        return read.flatMap { names[VaultReading.spellingKey($0)] }
    }

    /// The household person a document's name answers to, as corrected everywhere when it was.
    func person(of copy: VaultFind) -> String? {
        VaultModel.person(named: correctedName(copy.facts.holder, own: nil) ?? copy.facts.holder, in: registry)
    }

    /// The person a saved ID is, by the choice made for it or its name (its own, else corrected).
    func person(of entry: VaultEntry) -> String? {
        if case .person(let id)? = entry.assignment { return id }
        if entry.assignment == .household { return nil }
        let holder = entry.facts?.holder
        return VaultModel.person(named: correctedName(holder, own: entry.holderName) ?? holder, in: registry)
    }

    /// One number's copies when they name more than one of the household's people, as a
    /// dependent's card printing only the subscriber's ID does: the copies of the number's own
    /// person, who speak for it, and the others, which only name it. Its person is `owner` when
    /// known (a saved ID's, or the one chosen for it); else the one person a paper printing the
    /// number as its member's own names (not ``VaultReadFacts/printedForSubscriber``). With none or
    /// two, whose it is cannot be told: every copy is kept, and `unknown` says so. A copy whose
    /// name matches no one is the owner's.
    func split(_ all: [VaultFind], owner: String?) -> (own: [VaultFind], others: [VaultFind], unknown: Bool) {
        let named = all.map { (copy: $0, person: person(of: $0)) }
        let people = Set(named.compactMap(\.person))
        guard people.count > 1 || (owner != nil && people.contains { $0 != owner }) else { return (all, [], false) }
        let printedOwn = Set(named.filter { $0.copy.facts.printedForSubscriber != true }.compactMap(\.person))
        guard let owner = owner ?? (printedOwn.count == 1 ? printedOwn.first : nil) else { return (all, [], true) }
        let own = named.filter { $0.person == nil || $0.person == owner }.map(\.copy)
        return (own, named.filter { $0.person != nil && $0.person != owner }.map(\.copy), false)
    }

    /// `facts` with each of `others`' documents listed as naming the number, never as its source.
    static func naming(_ facts: VaultReadFacts, _ others: [VaultFind]) -> VaultReadFacts {
        var facts = facts
        for other in others {
            for source in other.facts.sources {
                facts.add(VaultSource(path: source.path, role: source.role, rank: VaultReading.Rank.mention))
            }
        }
        return facts
    }
}

/// Everything the rows are worked out from, and the working out (VT7 d): the numbers saved and
/// waiting, what each document said about them, the user's corrections and lessons, the kinds,
/// the folders read, and the day. It reads no settings, file or clock, so the same source always
/// gives the same rows, and the rules are tested with no model.
struct VaultRowSource {
    var entries: [VaultEntry]
    var finds: [VaultFind]
    /// What each document said about a number, by the number, then by the document.
    var copies: [String: [String: VaultFind]]
    /// Documents that name a number without being its source, by the number.
    var mentions: [String: [VaultSource]]
    /// Documents not where they were read (``VaultModel/missingDocuments``).
    var missingDocuments: Set<String>
    var holders: VaultHolders
    /// What choosing a kind for a read account taught, by its folder.
    var lessons: [String: VaultCardID]
    var kinds: VaultKinds
    /// The folders Read Documents reads.
    var folders: [String]
    /// The time the rows stand at: a document runs out at midnight.
    var now: Date

    /// A number's facts as read from the copy in force, the Vault's own pick of copy, the user's
    /// while in force, and the copies it could be read from instead.
    typealias ChosenReading = (facts: VaultReadFacts?, app: String?, chosen: String?, choices: [String])

    /// A saved number's facts as its documents now say: a newer document of the same kind, such
    /// as a license renewed under the same number, speaks for it, keeping the kind it was saved
    /// as; otherwise what was saved stands, with every document read since listed under it.
    func readSince(_ entry: VaultEntry, merges: MergeMemo) -> VaultReadFacts? {
        guard var saved = entry.facts else { return nil }
        // Another person's paper carrying the number (a dependent's card printing only the
        // subscriber's ID) names it, and never speaks for it: its name and dates are not this ID's.
        let parts = holders.person(of: entry).map { holders.split(readCopies(of: entry.value), owner: $0) }
            ?? (own: readCopies(of: entry.value), others: [], unknown: false)
        guard let read = merges.merged(parts.own, value: entry.value) else { return VaultHolders.naming(saved, parts.others) }
        if VaultModel.supersedes(read.facts, saved) {
            var newer = read.facts
            newer.category = saved.category
            for source in saved.sources { newer.add(source, contacts: .existing) }
            return VaultHolders.naming(newer, parts.others)
        }
        // Saved before the Vault kept which document a reading is: the one today's reading of the
        // same document comes from.
        if saved.spokenBy == nil, VaultCopies.sameDocument(saved, read.facts) { saved.spokenBy = read.facts.spokenBy }
        for source in read.facts.sources { saved.add(source, contacts: .incoming) }
        return VaultHolders.naming(saved, parts.others)
    }

    /// What each document said about `value`, one reading per file.
    func readCopies(of value: String) -> [VaultFind] {
        Array((copies[VaultReading.normalized(value)] ?? [:]).values)
    }

    /// The copies `value` could be read from in place of the document it is read from now (``VaultCopies/choices(_:)``), and the reading with `chosen` speaking when it is one
    /// of them. None unless `shown`, what the number shows now, is today's reading of its copies,
    /// read from the same document with the same dates: a saved reading that stands apart from
    /// its copies is not changed by choosing one.
    func sourceChoices(of value: String, shown: VaultReadFacts?, chosen: String?,
                       merges: MergeMemo) -> (paths: [String], reading: VaultReadFacts?) {
        let all = readCopies(of: value).filter { !missingDocuments.contains($0.sourcePath) }
        guard let shown, let speaker = shown.primary?.path, all.count > 1, let auto = merges.merged(all, value: value),
              auto.facts.spokenBy == speaker, auto.facts.dated == shown.dated, auto.facts.validUntil == shown.validUntil
        else { return ([], nil) }
        let paths = VaultCopies.choices(all)
        guard let chosen, paths.contains(chosen), let read = merges.merged(all, value: value, speaking: chosen) else { return (paths, nil) }
        return (paths, read.facts)
    }

    /// Merged readings of one rows rebuild, each made once (VT66): a saved number's own copies
    /// and the copies it could be read from are most often the same files. Keyed by the number,
    /// the files and the copy chosen to speak; the copies cannot change within a rebuild, and two
    /// lists of the same files come in the same order, both taken from one table.
    final class MergeMemo {
        private var made: [String: VaultFind?] = [:]
        private(set) var merges = 0

        func merged(_ copies: [VaultFind], value: String, speaking chosen: String? = nil) -> VaultFind? {
            let key = ([VaultReading.normalized(value), chosen ?? ""] + copies.map(\.sourcePath)).joined(separator: "\u{0}")
            if let found = made[key] { return found }
            merges += 1
            let merged = VaultModel.merged(copies, speaking: chosen)
            made[key] = merged
            return merged
        }
    }

    /// Every number, saved and waiting, each with where it stands, and how many merges that
    /// took (VT66).
    func rows() -> (rows: [VaultModel.Row], merges: Int) {
        let people = holders.people
        // Made once for every row, not once per row (VT66).
        let registry = holders.registry
        let merges = MergeMemo()
        func withMentions(_ facts: VaultReadFacts?, _ value: String) -> VaultReadFacts? {
            guard var facts else { return nil }
            for source in mentions[VaultReading.normalized(value)] ?? [] { facts.add(source) }
            // A document that is not where it was is passed over while another carries the ID:
            // a scan moved and found again is simply read from where it is now.
            if !missingDocuments.isEmpty {
                let found = facts.sources.filter { !missingDocuments.contains($0.path) }
                if !found.isEmpty { facts.sources = found }
            }
            return facts
        }
        /// `facts` read from the copy the user chose, when it is one of the copies it could be
        /// read from (``sourceChoices(of:shown:chosen:merges:)``), keeping what it was saved as.
        func chosenReading(_ facts: VaultReadFacts?, value: String, chosen: String?) -> ChosenReading {
            let app = facts?.primary?.path
            let (paths, read) = sourceChoices(of: value, shown: facts, chosen: chosen, merges: merges)
            guard var read, let facts, read.dated == facts.dated, read.validUntil == facts.validUntil
            else { return (facts, app, nil, paths) }
            read.category = facts.category
            for source in facts.sources { read.add(source, contacts: .existing) }
            return (read, app, read.spokenBy, paths)
        }
        /// A number's facts with the name corrected, and the name read when a correction took
        /// its place: before anything matches it to a person, so the corrected name is the one
        /// matched.
        func corrected(_ facts: VaultReadFacts?, own: String?) -> (VaultReadFacts?, read: String?) {
            guard var facts, let fixed = holders.correctedName(facts.holder, own: own), fixed != facts.holder else { return (facts, nil) }
            let read = facts.holder
            facts.holder = fixed
            return (facts, read)
        }
        var all: [VaultModel.Row] = entries.map { entry in
            let reading = chosenReading(readSince(entry, merges: merges), value: entry.value, chosen: entry.chosenSource)
            var (facts, read) = corrected(withMentions(reading.facts, entry.value), own: entry.holderName)
            // Fields added by hand show with its details, after what was read.
            if let added = entry.fields, !added.isEmpty { facts?.details += added }
            // A saved number's person was chosen in the editor; with none, it goes by its name.
            let chosen = entry.assignment
            var personID: String?
            if case .person(let id)? = chosen { personID = id }
            if chosen == nil { personID = VaultModel.person(named: facts?.holder, in: registry) }
            return VaultModel.Row(entry: entry, facts: facts, personID: personID, readHolder: read, reading: reading)
        }
        all += finds.map { find in
            let reading = chosenReading(find.facts, value: find.value, chosen: find.chosenSource)
            let (facts, read) = corrected(withMentions(reading.facts, find.value), own: nil)
            var personID: String?
            switch find.assignment {
            case .person(let id)?: personID = id
            case .household?: personID = nil
            case nil: personID = VaultModel.person(named: facts?.holder, in: registry)
            }
            return VaultModel.Row(find: find, facts: facts, personID: personID, readHolder: read, reading: reading)
        }
        // The card each goes on (Kind), before anything weighs it: moved to another app kind, it is
        // weighed, and its household and country found, as that kind.
        for index in all.indices {
            let item = all[index]
            let (card, learned) = drawnCard(for: item.category, chosen: item.chosenCard, paths: VaultModel.lessonPaths(item.facts, app: item.appSource))
            all[index].readAs = item.category
            all[index].card = card
            all[index].learnedFrom = learned
            if case .builtIn(let category) = card, category != item.category {
                all[index].category = category
                all[index].facts?.category = category
            }
        }
        // A number whose name line was missed, but whose date of birth was read, is the same
        // person's as another number read with both: it borrows that one's name and person. Not
        // when two people share that birth date (twins): then it is nobody's in particular.
        var known: [String: (id: String?, holder: String)] = [:]
        var firstNames: [String: Set<String>] = [:]
        for item in all {
            guard let facts = item.facts, let key = facts.personKey, let holder = facts.holder else { continue }
            if known[key]?.id == nil { known[key] = (item.personID, holder) }
            if let first = holder.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init),
               !VaultPeopleClusters.noName.contains(first) {
                firstNames[key, default: []].insert(first)
            }
        }
        for index in all.indices where all[index].assignment == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let key = all[index].facts?.personKey, let match = known[key],
               !VaultPeopleClusters.differ(firstNames[key] ?? []) {
                all[index].personID = match.id
                all[index].facts?.holder = match.holder
            }
        }
        // A visa that prints no name, an Indian e-Visa, is whoever's passport it is in: the
        // passport's person, and its name when one was read.
        var passports: [String: (id: String?, holder: String?)] = [:]
        for item in all where item.category == .passport && (item.personID != nil || item.facts?.holder != nil) {
            passports[VaultReading.normalized(item.value)] = (item.personID, item.facts?.holder)
        }
        for index in all.indices where all[index].assignment == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let passport = all[index].facts?.inPassport, let match = passports[VaultReading.normalized(passport)] {
                all[index].personID = match.id
                all[index].facts?.holder = match.holder
            }
        }
        // A paper that prints no name is whoever's folder it is filed in: `Health/Medical/Sigrid`.
        for index in all.indices where all[index].assignment == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let path = all[index].appSource ?? all[index].facts?.primary?.path,
               let id = VaultModel.person(inPath: path, under: folders, in: registry) {
                all[index].personID = id
            }
        }
        // Grouped by whose it is as best known: the choice, else the matched person, else the
        // name or birth date read. A saved passport and a new read of the same person's meet.
        let standings = VaultStandings.compute(all.map { item in
            let grouping: VaultAssignment? = item.assignment ?? item.personID.map { .person($0) }
            return VaultStandingInput(id: item.id, value: item.value, category: item.category, facts: item.facts,
                                      pin: item.pin, assignment: grouping, isChosen: item.assignment != nil,
                                      card: item.card.key)
        }, now: now, readFolders: folders)
        let rows = all.map { item in
            var row = item
            // Nobody's in particular: typed in for no one, or read with no person as a kind that
            // is then the household's (a utility's or a loan's account).
            row.isHousehold = item.assignment == .household || (item.facts == nil && item.personID == nil)
                || (item.assignment == nil && item.personID == nil && item.facts?.holder == nil
                    && item.category.spec.isHouseholdsWhenNameless)
            let personName = item.personID.flatMap { id in people.first { $0.id == id }?.displayName }
            row.whose = row.isHousehold ? "Household"
                : personName ?? (item.personID != nil ? "Someone no longer in People" : nil)
                    ?? item.facts?.holder?.split(separator: " ").first.map(String.init) ?? "Unknown"
            let read = VaultGeo.read(item.category, facts: item.facts)
            row.standing = standings[item.id] ?? VaultStanding(tab: .current)
            row.geo = item.chosenGeo ?? read.geo
            row.geoReason = item.chosenGeo == nil ? read.reason : "You chose it"
            row.chosenCard = item.chosenCard.flatMap { kinds.canHold($0) ? $0 : nil }
            row.documentMissing = item.facts?.primary.map { missingDocuments.contains($0.path) } ?? false
            return row
        }
        return (rows, merges.merges)
    }

    /// The card a number goes on, and the folder that taught it when that did: its own choice,
    /// else its folder's lesson, else its own kind's card. Only an account's kind moves
    /// (``VaultKinds/changeable``), and a custom kind no longer kept is as if never chosen.
    func drawnCard(for category: VaultCategory, chosen: VaultCardID?, paths: [String]) -> (VaultCardID, String?) {
        guard VaultKinds.canChange(from: category) else { return (.builtIn(category), nil) }
        if let chosen, kinds.canHold(chosen) { return (chosen, nil) }
        for path in paths {
            let folder = VaultKinds.lessonFolder(of: path)
            if let lesson = lessons[folder], kinds.canHold(lesson) { return (lesson, folder) }
        }
        return (.builtIn(category), nil)
    }
}
