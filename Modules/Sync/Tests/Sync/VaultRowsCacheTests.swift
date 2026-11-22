import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// The rows are worked out once per change to what they are made of (``VaultModel/rows``). Each
/// such change, made the way the app makes it, leaves the cached rows equal to rows worked out
/// afresh (VT71): a change that forgot to move the cache's revision would show stale rows.
@MainActor
@Suite struct VaultRowsCacheTests {
    typealias Rig = VaultModelTests.Rig

    @Test func everyChangeTheRowsAreMadeOfReachesThem() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(VaultNameCorrectionTests.root, in: rig.defaults)
        rig.auth.answer = .allowed
        let model = rig.model()
        model.people = [Person(id: "divit", displayName: "Divit")]
        await model.opened()
        #expect(await model.unlock())
        var pages = VaultNameCorrectionTests.pages
        let copy = VaultNameCorrectionTests.root + "/Health/Dental/ID Cards/copy.pdf"
        pages[copy] = ["Member Name: DLVIT GIRISH", "Member ID: XZB123456789", "Group Number: 0099999"]
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: pages))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        let waiting = try #require(model.finds.first { $0.value == "VSP99887766" })

        func check(_ change: String, sourceLocation: SourceLocation = #_sourceLocation) {
            _ = model.rows   // the cache as it stands, then compared with rows worked out afresh
            #expect(model.rows == model.rowsWorkedOutAfresh, "after \(change) the rows were stale", sourceLocation: sourceLocation)
        }
        check("the read")
        model.people = [Person(id: "divit", displayName: "Divit", fullNames: ["Dlvit Girish"])];   check("a change of people")
        model.assign(saved, to: .household);                                                       check("Belongs to")
        model.pin(saved, .older);                                                                  check("a pin")
        model.setGeo(saved, to: .india);                                                           check("a country")
        model.setKind(saved, to: .builtIn(.utilities));                                            check("a kind")
        model.readFrom(saved, copy: copy);                                                         check("Read from This Copy")
        model.assign(waiting.id, to: .person("divit"));                                            check("a waiting ID's owner")
        model.setGeo(waiting.id, to: .us);                                                         check("a waiting ID's country")
        let kind = try #require(model.addKind(named: "Dental plans"));                             check("a kind added")
        model.setKind(waiting.id, to: kind);                                                       check("a waiting ID's kind")
        var kinds = model.kinds
        if case .custom(let id) = kind, let index = kinds.custom.firstIndex(where: { $0.id == id }) { kinds.custom[index].name = "Dental cover" }
        model.setKinds(kinds);                                                                     check("a kind a row is on renamed")
        // A kind removed while a typed ID is on it: no lesson moves the rows, only the kinds.
        let typedID = try #require(model.add(.init(title: "Gym card", value: "GYM5550001", note: "", kind: .other)))
        let gym = try #require(model.addKind(named: "Gyms"))
        model.setKind(typedID, to: gym);                                                           check("a typed ID's kind")
        var fewer = model.kinds
        if case .custom(let id) = gym { fewer.custom.removeAll { $0.id == id } }
        model.setKinds(fewer);                                                                     check("a kind a row is on removed")
        var edit = model.prepared(VaultModel.Draft(try #require(model.entries.first { $0.id == saved })), for: saved)
        edit.holderName = "Divit Girish"
        edit.correctEverywhere = true
        #expect(await model.update(saved, to: edit));                                              check("a name corrected everywhere")
        _ = model.setRole(.misread, of: "Dlvit Girish", for: "divit");                             check("a Misread")
        model.setAside(waiting.id);                                                                check("Not This")
        // A document gone from where it was, found so by a refresh.
        pages[copy] = nil
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: pages), scope: .refresh())
        check("a document gone")
        #expect(await model.delete(saved));                                                        check("Remove")
    }
}
