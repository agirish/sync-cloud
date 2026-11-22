import Foundation
import Testing
@testable import Sync

/// Read Documents asks a file's size, date and whether it is there off the main actor (VT67): the
/// plan's dates, each file's stamp, and the documents saved IDs point at. Every number is made up.
@MainActor
@Suite struct VaultStatsOffMainTests {
    typealias Rig = VaultModelTests.Rig

    /// Notes each question asked on the main thread, by its name.
    final class OnMain: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        func note(_ name: String) { if Thread.isMainThread { lock.withLock { asked.append(name) } } }
        var all: [String] { lock.withLock { asked } }
    }

    struct Reader: VaultDocumentReading {
        let pages: [String: [String]]
        let onMain: OnMain
        func files() async -> [URL] { pages.keys.sorted().map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] { pages[file.path].map { [$0] } ?? [] }
        func stamp(of file: URL) -> String? { onMain.note("stamp"); return "1" }
        func modified(of file: URL) -> Date? { onMain.note("modified"); return nil }
        func size(of file: URL) -> Int? { onMain.note("size"); return 1 }
        func exists(_ file: URL) -> Bool { onMain.note("exists"); return false }
        var followsReadPlan: Bool { true }
    }

    static let root = "/Users/anna/Documents"

    @Test func noFileIsStattedOnTheMainActor() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let onMain = OnMain()
        let passport = Self.root + "/Immigration/Passport/Anna/passport.pdf"
        let bill = Self.root + "/Home/Utilities/EBMUD/water.pdf"
        let pages = [passport: ["P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", "L898902C36UTO7408122F1204159ZE184226B<<<<<10"],
                     bill: ["Account Number: 1234 5678 9012"]]
        await model.readDocuments(with: Reader(pages: pages, onMain: onMain))
        let find = try #require(model.finds.first { $0.value == "L898902C3" })
        _ = try #require(model.confirm(find.id, as: model.prepared(VaultModel.Draft(find), for: find.id)))
        // Read again with the passport gone: whether its document is still there is asked.
        await model.readDocuments(with: Reader(pages: [bill: pages[bill]!], onMain: onMain), again: true)
        #expect(model.rows.first { $0.value == "L898902C3" }?.documentMissing == true, "the gone document was looked for")
        #expect(onMain.all.isEmpty, "asked on the main actor: \(onMain.all)")
    }
}
