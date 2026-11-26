import Foundation
import Testing
@testable import Sync

/// The v7.2 stored shape (VT1, VT6): ``VaultRecord``, ``VaultDocument`` and ``VaultCache``, and
/// that an entry or a find made into a record and back is what it was. Every number is made up.
@Suite struct VaultRecordTests {
    static let day = VaultFormatTests.day

    static func encoder() -> JSONEncoder { VaultFile.jsonEncoder() }
    static func decoder() -> JSONDecoder { VaultFile.jsonDecoder() }

    /// Every field an entry can hold, set, as this build makes them.
    static func fullEntry() -> VaultEntry {
        let facts = VaultReadFacts(
            category: .passport, holder: "PAT EXAMPLE", born: day.addingTimeInterval(-900_000_000), issuer: "USA",
            form: "Passport", dated: day, validUntil: day.addingTimeInterval(300_000_000), pending: true, inPassport: "Z0000000",
            details: [VaultDetail("Expires", .date(day.addingTimeInterval(300_000_000))),
                      VaultDetail("Issued by", .text("United States")), VaultDetail("Book", .number("B000000"))],
            sources: [VaultSource(path: "Immigration/Copies/Passport.pdf", role: "Copy", rank: 10),
                      VaultSource(path: "Immigration/Passport/Pat/Passport 2030.pdf", role: "Passport photo page", rank: 50,
                                  address: VaultPrintedAddress(VaultAddress(street: "1 Example Way", city: "Sampletown", state: "CA", zip: "00000"), dated: day),
                                  phones: [VaultPrintedPhone(number: "(000) 555-0100", person: "pat", dated: day)])])
        var entry = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, title: "Passport",
                               value: "Z0000001", note: "Pat · runs out 2036",
                               savedFrom: "Immigration/Passport/Pat/Passport 2030.pdf",
                               addedAt: day, updatedAt: day.addingTimeInterval(60), category: .passport, facts: facts)
        entry.facts?.spokenBy = "Immigration/Passport/Pat/Passport 2030.pdf"
        entry.facts?.printedForSubscriber = true
        entry.assignment = .person("pat")
        entry.pin = .older
        entry.geo = .india
        entry.card = .custom("kind-1")
        entry.holderName = "Pat Q Example"
        entry.chosenSource = "Immigration/Copies/Passport.pdf"
        entry.readAs = [VaultReadAs(contents: "2048-" + String(repeating: "ab", count: 32), reads: "Z0000007")]
        entry.notOn = ["1024-" + String(repeating: "ef", count: 32)]
        entry.fields = [VaultDetail("RxBIN", .text("610502")), VaultDetail("Payer ID", .number("60054")),
                        VaultDetail("Renewed", .date(day))]
        entry.notFields = ["111111111", "9416925"]
        return entry
    }

    static func fullFind() -> VaultFind {
        VaultFind(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!, title: "Health plan member ID",
                  value: "XX000000001", note: "Pat",
                  facts: VaultReadFacts(category: .health, holder: "Pat", dated: day,
                                        details: [VaultDetail("Group", .text("G-1")), VaultDetail("Since", .date(day)),
                                                  VaultDetail("Subscriber", .number("XX000000009"))],
                                        sources: [VaultSource(path: "Health/Plan/Card.pdf", role: "Member card", rank: 30),
                                                  VaultSource(path: "Health/Plan/Letter.pdf", role: "Letter", rank: 5)]),
                  pin: .current, assignment: .household, geo: .us, card: .builtIn(.utilities), chosenSource: "Health/Plan/Letter.pdf")
    }

    // MARK: Entries

    @Test func anEntryWithEveryFieldSetComesBackTheSame() throws {
        let entry = Self.fullEntry()
        let record = VaultRecord(entry)
        let back = try VaultEntry(record: record)
        #expect(back == entry)
        // Field by field, so a failure names which.
        #expect(back.id == entry.id && back.title == entry.title && back.value == entry.value && back.note == entry.note)
        #expect(back.category == entry.category)
        #expect(back.facts == entry.facts)
        #expect(back.facts?.details == entry.facts?.details, "details order")
        #expect(back.facts?.sources == entry.facts?.sources, "sources order")
        #expect(back.facts?.spokenBy == entry.facts?.spokenBy)
        #expect(back.fields == entry.fields, "hand fields")
        #expect(back.choices == entry.choices)
        #expect(back.holderName == entry.holderName && back.readAs == entry.readAs)
        #expect(back.notOn == entry.notOn && back.notFields == entry.notFields)
        #expect(back.addedAt == entry.addedAt && back.updatedAt == entry.updatedAt)
        #expect(back.savedFrom == entry.savedFrom)
    }

    @Test func theRecordHoldsTheNumberFirstThenWhatWasReadThenWhatWasTyped() throws {
        let record = VaultRecord(Self.fullEntry())
        #expect(record.state == .saved)
        #expect(record.fields.filter(\.isMain).count == 1)
        #expect(record.fields[0] == VaultRecord.Field(label: "Number", kind: .number, value: .text("Z0000001"),
                                                      isMain: true, hidesEnding: false, from: .read))
        #expect(record.fields.dropFirst().map(\.label) == ["Expires", "Issued by", "Book", "RxBIN", "Payer ID", "Renewed"])
        #expect(record.fields.dropFirst().map(\.from) == [.read, .read, .read, .typed, .typed, .typed])
        #expect(record.fields.dropFirst().map(\.kind) == [.date, .text, .number, .text, .number, .date])
        guard case .read(let savedFrom, let facts?) = record.origin else { Issue.record("not read"); return }
        #expect(savedFrom == "Immigration/Passport/Pat/Passport 2030.pdf")
        #expect(facts.details.isEmpty, "the details are the record's fields, not its facts'")
        #expect(record.owner == .person("pat"))
        #expect(record.choices == VaultRecord.Choices(pin: .older, geo: .india, card: .custom("kind-1"),
                                                      source: "Immigration/Copies/Passport.pdf"))
    }

    @Test func aKindWhoseEndingIsSecretMarksItsNumber() {
        let ssn = VaultEntry(title: "Social Security number", value: "000-00-0000", addedAt: Self.day, category: .ssn)
        let main = VaultRecord(ssn).fields[0]
        #expect(main.hidesEnding == VaultCategory.ssn.hidesEnding)
        #expect(main.from == .typed)
    }

    @Test func whereANumberCameFromIsKeptEveryWay() throws {
        let facts = VaultReadFacts(category: .health, details: [VaultDetail("Group", .text("G-1"))],
                                   sources: [VaultSource(path: "Health/Card.pdf", role: "Card", rank: 30)])
        // Typed: neither.
        let typed = VaultEntry(title: "Library card", value: "LIB00001", addedAt: Self.day, category: .other)
        #expect(VaultRecord(typed).origin == .typed)
        #expect(try VaultEntry(record: VaultRecord(typed)) == typed)

        // Read, saved from a document other than the one its facts now put first.
        let other = VaultEntry(title: "Plan", value: "XX0000001", savedFrom: "Health/Old card.pdf", addedAt: Self.day,
                               category: .health, facts: facts)
        #expect(try VaultEntry(record: VaultRecord(other)) == other)

        // Facts and no document it was saved from.
        let noPath = VaultEntry(title: "Plan", value: "XX0000002", addedAt: Self.day, category: .health, facts: facts)
        guard case .read(nil, _?) = VaultRecord(noPath).origin else { Issue.record("facts were dropped"); return }
        #expect(try VaultEntry(record: VaultRecord(noPath)) == noPath)

        // A document it was saved from and no facts.
        let noFacts = VaultEntry(title: "Plan", value: "XX0000003", savedFrom: "Health/Card.pdf", addedAt: Self.day,
                                 category: .health)
        #expect(VaultRecord(noFacts).origin == .read(savedFrom: "Health/Card.pdf", facts: nil))
        #expect(try VaultEntry(record: VaultRecord(noFacts)) == noFacts)
    }

    @Test func everyOwnerAndEveryChoiceComesBack() throws {
        for assignment in [VaultAssignment?.none, .person("sam"), .household] {
            for pin in [VaultPin?.none, .current, .older] {
                for geo in [VaultGeo?.none, .us, .india, .anywhere] {
                    var entry = VaultEntry(title: "Plan", value: "XX0000004", addedAt: Self.day, category: .health)
                    entry.assignment = assignment
                    entry.pin = pin
                    entry.geo = geo
                    entry.card = geo == nil ? nil : .builtIn(.utilities)
                    #expect(try VaultEntry(record: VaultRecord(entry)) == entry)
                    var find = Self.fullFind()
                    find.choices = VaultChoices(pin: pin, assignment: assignment, geo: geo, card: entry.card,
                                                source: geo == nil ? nil : "Health/Plan/Card.pdf")
                    #expect(try VaultFind(record: VaultRecord(find)) == find)
                }
            }
        }
    }

    /// What older builds stored, read from a v1 file (``VaultLegacyFormat/Entry``), comes back
    /// the same: it was read for what it meant.
    @Test func anOlderBuildsEntryComesBackTheSame() throws {
        for entry in try VaultFormatTests.formatEntries6() {
            #expect(try VaultEntry(record: VaultRecord(entry)) == entry)
        }
        // A pin from before pins, and a person kept beside the household.
        let json = #"{"id":"00000000-0000-0000-0000-000000000009","title":"Old","value":"Z9","note":"","kind":"identity","addedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","older":true,"household":true,"personID":"pat"}"#
        let legacy = try Self.decoder().decode(VaultLegacyFormat.Entry.self, from: Data(json.utf8)).entry
        #expect(legacy.pin == .older && legacy.assignment == .household && legacy.personID == nil)
        #expect(try VaultEntry(record: VaultRecord(legacy)) == legacy)
        // No hand fields is no hand fields.
        var empty = Self.fullEntry()
        empty.fields = []
        #expect(empty.fields == nil)
        #expect(try VaultEntry(record: VaultRecord(empty)) == empty)
        // What was read says which card, whatever was chosen before it.
        var chosen = VaultEntry(title: "Plan", value: "XX0000005", addedAt: Self.day, category: .other)
        chosen.facts = VaultReadFacts(category: .health)
        #expect(chosen.category == .health)
        #expect(try VaultEntry(record: VaultRecord(chosen)) == chosen)
    }

    // MARK: Finds

    @Test func aFindComesBackTheSame() throws {
        let find = Self.fullFind()
        let record = VaultRecord(find)
        #expect(record.state == .toConfirm)
        #expect(record.addedAt == nil && record.updatedAt == nil)
        #expect(record.fields.map(\.from) == [.read, .read, .read, .read])
        #expect(record.owner == .household)
        let back = try VaultFind(record: record)
        #expect(back == find)
        #expect(back.facts.details == find.facts.details && back.facts.sources == find.facts.sources)
        #expect(back.choices == find.choices)
    }

    @Test func aRecordNotInItsShapeIsRefused() throws {
        let entry = Self.fullEntry()
        var twoMains = VaultRecord(entry)
        twoMains.fields.append(twoMains.fields[0])
        #expect(throws: VaultRecordError.mainField) { try VaultEntry(record: twoMains) }

        var mainLast = VaultRecord(entry)
        mainLast.fields.append(mainLast.fields.removeFirst())
        #expect(throws: VaultRecordError.mainField) { try VaultEntry(record: mainLast) }

        var readAfterTyped = VaultRecord(entry)
        readAfterTyped.fields.append(VaultRecord.Field(label: "Late", kind: .text, value: .text("x"), from: .read))
        #expect(throws: VaultRecordError.fieldOrder) { try VaultEntry(record: readAfterTyped) }

        var wrongValue = VaultRecord(entry)
        wrongValue.fields[1].value = .text("not a date")
        #expect(throws: VaultRecordError.fieldValue) { try VaultEntry(record: wrongValue) }

        var undated = VaultRecord(entry)
        undated.addedAt = nil
        #expect(throws: VaultRecordError.notASavedRecord) { try VaultEntry(record: undated) }

        var typedWithRead = VaultRecord(entry)
        typedWithRead.origin = .typed
        #expect(throws: VaultRecordError.readFieldsWithoutFacts) { try VaultEntry(record: typedWithRead) }

        #expect(throws: VaultRecordError.notASavedRecord) { try VaultEntry(record: VaultRecord(Self.fullFind())) }
        #expect(throws: VaultRecordError.notAWaitingRecord) { try VaultFind(record: VaultRecord(entry)) }
        var named = VaultRecord(Self.fullFind())
        named.holderName = "Pat"
        #expect(throws: VaultRecordError.notAWaitingRecord) { try VaultFind(record: named) }
    }

    // MARK: On disk

    @Test func aRecordIsStoredInTheSpecsShape() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Self.encoder().encode(VaultRecord(Self.fullEntry()))) as? [String: Any])
        #expect(Set(json.keys) == VaultRecord.storedKeys)
        #expect((json["owner"] as? [String: Any])?["person"] as? String == "pat")
        let read = try #require((json["origin"] as? [String: Any])?["read"] as? [String: Any])
        #expect(read["savedFrom"] as? String == "Immigration/Passport/Pat/Passport 2030.pdf")
        #expect(((read["facts"] as? [String: Any])?["details"] as? [Any])?.isEmpty == true)
        let main = try #require((json["fields"] as? [[String: Any]])?.first)
        #expect(main["isMain"] as? Bool == true && main["kind"] as? String == "number")
        #expect((main["value"] as? [String: Any])?["text"] as? String == "Z0000001")

        var household = VaultRecord(Self.fullFind())
        household.owner = .household
        let waiting = try #require(JSONSerialization.jsonObject(with: Self.encoder().encode(household)) as? [String: Any])
        #expect(((waiting["owner"] as? [String: Any])?["household"] as? [String: Any])?.isEmpty == true)
        #expect(waiting["addedAt"] == nil && waiting["updatedAt"] == nil)
        let typed = VaultEntry(title: "Library card", value: "LIB00001", addedAt: Self.day, category: .other)
        let typedJSON = try #require(JSONSerialization.jsonObject(with: Self.encoder().encode(VaultRecord(typed))) as? [String: Any])
        #expect(((typedJSON["origin"] as? [String: Any])?["typed"] as? [String: Any])?.isEmpty == true)
        #expect(typedJSON["owner"] == nil)
        #expect((typedJSON["choices"] as? [String: Any])?.isEmpty == true)
    }

    @Test func recordsSurviveTheDiskWhole() throws {
        for record in [VaultRecord(Self.fullEntry()), VaultRecord(Self.fullFind())]
            + (try VaultFormatTests.formatEntries6()).map(VaultRecord.init) {
            let back = try Self.decoder().decode(VaultRecord.self, from: Self.encoder().encode(record))
            #expect(back == record)
        }
    }

    @Test func aKeyThisBuildDoesNotWriteIsRefusedUnlessALaterBuildsFormat() throws {
        let plain = try Self.encoder().encode(VaultRecord(Self.fullEntry()))
        for path in [[] as [String], ["owner"], ["origin"], ["origin", "read"], ["choices"]] {
            var object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            func adding(_ value: inout [String: Any], at path: ArraySlice<String>) {
                guard let first = path.first else { value["later"] = 1; return }
                var inner = value[first] as? [String: Any] ?? [:]
                adding(&inner, at: path.dropFirst())
                value[first] = inner
            }
            adding(&object, at: path[...])
            let changed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self, "a key at \(path)") { try Self.decoder().decode(VaultRecord.self, from: changed) }
            let tolerant = Self.decoder()
            tolerant.userInfo[.vaultTolerant] = true
            #expect(try tolerant.decode(VaultRecord.self, from: changed) == VaultRecord(Self.fullEntry()))
        }
        // A field's key too.
        var object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        var fields = try #require(object["fields"] as? [[String: Any]])
        fields[0]["later"] = true
        object["fields"] = fields
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try Self.decoder().decode(VaultRecord.self, from: changed) }
    }

    // MARK: The document and the cache

    static func fullState() throws -> VaultReadingState {
        var state = try VaultFormatTests.formatReading2()
        state.finds.append(fullFind())
        state.contacts = ["pat": VaultContacts(phones: [.init("(000) 555-0101", label: "Mobile", added: day)])]
        state.copyNumbers = ["Immigration/Petition/Packet.pdf": VaultCopyNumbers(stamp: "10 1", numbers: ["Z0000001"])]
        state.copiesChanged = true
        return state
    }

    @Test func theDocumentAndCacheHoldEverythingTheTwoV1FilesDid() throws {
        let entries = [Self.fullEntry()] + (try VaultFormatTests.formatEntries6())
        let state = try Self.fullState()
        let setAside = VaultDocument.SetAside(generation: 3, keyID: "0123456789abcdef", fingerprints: ["aa", "bb"])
        let kinds = [VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")]
        let document = VaultDocument(entries: entries, state: state, setAside: setAside, kinds: kinds, savedAt: Self.day)
        let cache = VaultCache(state)

        #expect(document.records.map(\.state) == Array(repeating: .saved, count: entries.count) + [.toConfirm, .toConfirm])
        #expect(try document.entries() == entries)
        #expect(try document.finds() == state.finds)
        #expect(try document.readingState(cache: cache) == state)
        #expect(document.setAside == setAside && document.kinds == kinds)

        // Through the disk.
        let opened = try VaultDocument.open(plain: Self.encoder().encode(document))
        #expect(opened.document == document && !opened.readOnly)
        let cacheBack = try Self.decoder().decode(VaultCache.self, from: Self.encoder().encode(cache))
        #expect(cacheBack == cache)
        #expect(try opened.document.readingState(cache: cacheBack) == state)
    }

    /// Every key a document of this format can hold, as a path ("*" a map's key, "[]" a list's
    /// items). The document's strict reading (``VaultStrictKeys``) covers its own keys and a
    /// record's, not what is nested deeper (a reading's facts, a person's contacts), which read
    /// leniently: a field added there without raising ``VaultDocument/format`` is dropped by the
    /// build before it at its next save. This list fails at any new key, to have it decided: raise
    /// the format if an older build must not write over it, then list it here (the final review).
    @Test func everyKeyADocumentHoldsIsListedForTheFormat() throws {
        let entries = [Self.fullEntry()] + (try VaultFormatTests.formatEntries6())
        let document = VaultDocument(entries: entries, state: try Self.fullState(),
                                     setAside: .init(generation: 3, keyID: "0123456789abcdef", fingerprints: ["aa"]),
                                     kinds: [VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")],
                                     savedAt: Self.day)
        let object = try JSONSerialization.jsonObject(with: Self.encoder().encode(document))
        let maps: Set<String> = Self.documentMaps
        var paths: Set<String> = []
        func walk(_ value: Any, _ path: String) {
            switch value {
            case let dictionary as [String: Any]:
                for (key, inner) in dictionary {
                    let next = maps.contains(path) ? path + ".*" : (path.isEmpty ? key : path + "." + key)
                    paths.insert(next)
                    walk(inner, next)
                }
            case let list as [Any]:
                for inner in list { walk(inner, path + "[]") }
            default:
                break
            }
        }
        walk(object, "")
        #expect(VaultDocument.format == 1, "a new format: list its keys anew")
        let listed = Self.documentKeys
        #expect(paths.subtracting(listed).sorted() == [], "a key the document holds now: decide the format, then list it")
        #expect(listed.subtracting(paths).sorted() == [], "a listed key the full document no longer holds")
    }

    @Test func aCacheFromOtherRulesOrNoneLeavesWhatReadingFindsAgainEmpty() throws {
        let state = try Self.fullState()
        let document = VaultDocument(entries: [], state: state, setAside: .init(generation: 5), kinds: [], savedAt: Self.day)
        var stale = VaultCache(state)
        stale.readerVersion += 1
        for cache in [nil, stale] {
            let opened = try document.readingState(cache: cache)
            #expect(opened.finds == state.finds && opened.names == state.names && opened.lessons == state.lessons)
            #expect(opened.read.isEmpty && opened.copies.isEmpty && opened.mentions.isEmpty && opened.copyNumbers == nil)
            #expect(opened.generation == 5, "the document's generation, with no read index to belong to another")
        }
    }

    @Test func theFormatStampSaysHowADocumentOpens() throws {
        let document = VaultDocument(entries: [Self.fullEntry()], state: VaultReadingState(finds: [Self.fullFind()]),
                                     setAside: .init(), kinds: [], savedAt: Self.day)
        var object = try #require(JSONSerialization.jsonObject(with: Self.encoder().encode(document)) as? [String: Any])
        #expect(object["format"] as? Int == VaultDocument.format)
        #expect(object["savedBy"] as? String == VaultDocument.thisBuild)

        // This build's, with a key it does not write: not this build's at all.
        object["later"] = ["x": 1]
        #expect(throws: VaultError.unreadableFile) { try VaultDocument.open(plain: JSONSerialization.data(withJSONObject: object)) }

        // A later build's: read as far as it goes, the key let pass, a record it cannot read counted.
        object["format"] = VaultDocument.format + 1
        var records = try #require(object["records"] as? [[String: Any]])
        var later = records[0]
        later["category"] = "bankAccount"
        later["id"] = UUID().uuidString
        records.append(later)
        object["records"] = records
        let opened = try VaultDocument.open(plain: JSONSerialization.data(withJSONObject: object))
        #expect(opened.readOnly && opened.unread == 1)
        #expect(try opened.document.entries() == [Self.fullEntry()])
        #expect(try opened.document.finds() == [Self.fullFind()])

        for format in [0, -1] {
            object["format"] = format
            #expect(throws: VaultError.unreadableFile) { try VaultDocument.open(plain: JSONSerialization.data(withJSONObject: object)) }
        }
        object["format"] = nil
        #expect(throws: VaultError.unreadableFile) { try VaultDocument.open(plain: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func aBackupIsOwedOnlyWhenSavedRecordsOrTheUsersOwnDataChange() {
        let base = VaultDocument(entries: [Self.fullEntry()], state: VaultReadingState(finds: [Self.fullFind()]),
                                 setAside: .init(), kinds: [], savedAt: Self.day)
        var waitingOnly = base
        waitingOnly.records.removeLast()
        waitingOnly.reading.needsReadAgain = true
        waitingOnly.savedAt = Self.day.addingTimeInterval(5)
        #expect(base.sameSavedData(as: waitingOnly))
        #expect(!base.sameContents(as: waitingOnly))
        var named = base
        named.names["PATEXAMPIE"] = "Pat Example"
        #expect(!base.sameSavedData(as: named))
        var setAside = base
        setAside.setAside.fingerprints = ["aa"]
        #expect(!base.sameSavedData(as: setAside))
        var saved = base
        saved.records[0].title = "Passport (renewed)"
        #expect(!base.sameSavedData(as: saved))
    }

    @Test func theKeyIDIsSixteenHexDigitsOfTheKeysOwn() {
        let id = VaultDocument.keyID(for: VaultFormatTests.key)
        #expect(id.count == 16 && id.allSatisfy(\.isHexDigit))
        #expect(id == VaultDocument.keyID(for: VaultFormatTests.key))
        #expect(id != VaultDocument.keyID(for: .init(size: .bits256)))
    }

    @Test func nothingPrintsANumber() {
        let record = VaultRecord(Self.fullEntry())
        #expect(!String(describing: record).contains("Z0000001"))
        #expect(!String(reflecting: record).contains("Z0000001"))
        let document = VaultDocument(entries: [Self.fullEntry()], state: VaultReadingState(), setAside: .init(), kinds: [],
                                     savedAt: Self.day)
        #expect(!String(describing: document).contains("Z0000001"))
    }
}

extension VaultRecordTests {
    /// The document's keys whose own keys are data (an id, a path, a spelling), not its shape.
    static let documentMaps: Set<String> = ["choices", "contacts", "lessons", "nameRoles", "names"]
    /// Every key path a document of format 1 holds (``everyKeyADocumentHoldsIsListedForTheFormat()``).
    static let documentKeys: Set<String> = [
        "choices", "choices.*", "choices.*.assignment", "choices.*.assignment.household", "choices.*.card",
        "choices.*.geo", "choices.*.id", "choices.*.pin", "contacts", "contacts.*", "contacts.*.addresses",
        "contacts.*.emails", "contacts.*.notTheirPhones", "contacts.*.notTheirs", "contacts.*.phones",
        "contacts.*.phones[].added", "contacts.*.phones[].label", "contacts.*.phones[].value", "format",
        "kinds", "kinds[].group", "kinds[].id", "kinds[].name", "lessons", "lessons.*", "nameRoles",
        "nameRoles.*", "nameRoles.*.goesBy", "nameRoles.*.kept", "nameRoles.*.legal", "names", "names.*",
        "reading", "reading.needsReadAgain", "reading.readerVersion", "reading.staleSources", "records",
        "records[].addedAt", "records[].category", "records[].choices", "records[].choices.card",
        "records[].choices.geo", "records[].choices.pin", "records[].choices.source", "records[].fields",
        "records[].fields[].from", "records[].fields[].hidesEnding", "records[].fields[].isMain",
        "records[].fields[].kind", "records[].fields[].label", "records[].fields[].value",
        "records[].fields[].value.date", "records[].fields[].value.text", "records[].holderName",
        "records[].id", "records[].notFields", "records[].notOn", "records[].note", "records[].origin",
        "records[].origin.read", "records[].origin.read.facts", "records[].origin.read.facts.born",
        "records[].origin.read.facts.category", "records[].origin.read.facts.dated",
        "records[].origin.read.facts.details", "records[].origin.read.facts.form",
        "records[].origin.read.facts.holder", "records[].origin.read.facts.inPassport",
        "records[].origin.read.facts.issuer", "records[].origin.read.facts.pending",
        "records[].origin.read.facts.printedForSubscriber", "records[].origin.read.facts.sources",
        "records[].origin.read.facts.sources[].address",
        "records[].origin.read.facts.sources[].address.address",
        "records[].origin.read.facts.sources[].address.address.city",
        "records[].origin.read.facts.sources[].address.address.state",
        "records[].origin.read.facts.sources[].address.address.street",
        "records[].origin.read.facts.sources[].address.address.zip",
        "records[].origin.read.facts.sources[].address.dated", "records[].origin.read.facts.sources[].path",
        "records[].origin.read.facts.sources[].phones",
        "records[].origin.read.facts.sources[].phones[].dated",
        "records[].origin.read.facts.sources[].phones[].number",
        "records[].origin.read.facts.sources[].phones[].person",
        "records[].origin.read.facts.sources[].rank", "records[].origin.read.facts.sources[].role",
        "records[].origin.read.facts.spokenBy", "records[].origin.read.facts.validUntil",
        "records[].origin.read.savedFrom", "records[].origin.typed", "records[].owner",
        "records[].owner.household", "records[].owner.person", "records[].readAs",
        "records[].readAs[].contents", "records[].readAs[].reads", "records[].state", "records[].title",
        "records[].updatedAt", "savedAt", "savedBy", "setAside", "setAside.fingerprints",
        "setAside.generation", "setAside.keyID"
    ]
}
