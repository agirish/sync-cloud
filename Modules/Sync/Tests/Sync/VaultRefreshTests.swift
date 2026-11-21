import Foundation
import Testing
@testable import Sync

/// Refresh: only the documents IDs came from, what it changes and what it never does. Every
/// number is made up.
@MainActor
@Suite struct VaultRefreshTests {
    typealias Rig = VaultModelTests.Rig

    /// Documents the test can change, move away and count the opening of.
    final class Shelf: VaultDocumentReading, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: [String]]
        private var stamps: [String: Int] = [:]
        private var opens: [String] = []
        private var walks = 0

        init(_ pages: [String: [String]]) { self.pages = pages }

        /// Replaces a document's page, as a new scan saved over the old one would.
        func write(_ path: String, _ page: [String]) {
            lock.withLock { pages[path] = page; stamps[path, default: 1] += 1 }
        }
        func remove(_ path: String) { lock.withLock { pages[path] = nil } }
        var opened: [String] { lock.withLock { opens } }
        var walked: Int { lock.withLock { walks } }
        func forgetOpened() { lock.withLock { opens = [] } }

        func files() async -> [URL] { lock.withLock { walks += 1; return pages.keys.sorted().map { URL(fileURLWithPath: $0) } } }
        func pages(in file: URL) async -> [[String]] {
            lock.withLock { opens.append(file.path); return pages[file.path].map { [$0] } ?? [] }
        }
        func stamp(of file: URL) -> String? { lock.withLock { pages[file.path] == nil ? nil : String(stamps[file.path, default: 1]) } }
        func modified(of file: URL) -> Date? { nil }
        func exists(_ file: URL) -> Bool { lock.withLock { pages[file.path] != nil } }
    }

    static let root = "/Users/anna/Documents"
    static let dental = root + "/Health/Dental/ID Cards/card.pdf"
    static let passport = root + "/Immigration/Passport/Anna/scan.pdf"
    static let letter = root + "/Immigration/Letters/cover.pdf"
    static func card(group: String) -> [String] {
        ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789", "Group Number: \(group)"]
    }

    /// A Vault that has read a dental card and a passport, and a letter that gives nothing.
    static func rig() async throws -> (rig: Rig, model: VaultModel, shelf: Shelf) {
        let rig = try Rig()
        VaultReadFolders.add(root, in: rig.defaults)
        let shelf = Shelf([dental: card(group: "0012345"), passport: VaultToConfirmTests.passportPage,
                           letter: ["Nothing to see here"]])
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: shelf)
        shelf.forgetOpened()
        return (rig, model, shelf)
    }

    static func row(_ model: VaultModel, _ value: String) -> VaultModel.Row? { model.rows.first { $0.value == value } }

    /// A shelf that says what the model showed as it opened each document.
    final class Watched: VaultDocumentReading, @unchecked Sendable {
        let shelf: Shelf
        let onOpen: @MainActor @Sendable () -> Void
        init(_ shelf: Shelf, onOpen: @escaping @MainActor @Sendable () -> Void) {
            self.shelf = shelf
            self.onOpen = onOpen
        }
        func files() async -> [URL] { await shelf.files() }
        func pages(in file: URL) async -> [[String]] {
            await onOpen()
            return await shelf.pages(in: file)
        }
        func stamp(of file: URL) -> String? { shelf.stamp(of: file) }
        func modified(of file: URL) -> Date? { nil }
        func exists(_ file: URL) -> Bool { shelf.exists(file) }
    }

    /// The panel's "Updating… Stop" line shows while a refresh is what is running. The progress
    /// was rebuilt after each document without saying so, and from the second document on a
    /// refresh looked like Discover More: the line and its Stop went, and the read carried on.
    @Test func aRefreshIsStillARefreshAfterItsFirstDocument() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        shelf.write(Self.dental, Self.card(group: "0099999"))
        shelf.write(Self.passport, VaultToConfirmTests.passportPage)
        var seen: [VaultModel.ReadingProgress] = []
        let watched = Watched(shelf) { if let reading = model.reading { seen.append(reading) } }
        await model.readDocuments(with: watched, scope: .refresh())
        #expect(seen.map(\.done) == [0, 1] && seen.map(\.total) == [2, 2], "two changed documents, one at a time")
        #expect(seen.allSatisfy { $0.scope.isRefresh }, "a refresh, for as long as it runs")
        #expect(model.reading == nil)
        // Discover More says what it is all the way through too.
        seen = []
        shelf.write(Self.dental, Self.card(group: "0011111"))
        shelf.write(Self.letter, ["Member ID: NEW000111222"])
        await model.readDocuments(with: watched)
        #expect(seen.count >= 2 && seen.allSatisfy { $0.scope == .discover })
    }

    // MARK: What it opens

    @Test func refreshOpensOnlyChangedDocumentsThatGaveAnIDAndWalksNoFolder() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        #expect(model.refreshSources == [Self.dental, Self.passport], "the letter gave nothing: it is not a source")
        let walksBefore = shelf.walked

        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(shelf.opened.isEmpty, "nothing changed, so nothing is opened")
        #expect(model.reading == nil)

        shelf.write(Self.dental, Self.card(group: "0099999"))
        shelf.write(Self.letter, ["Member ID: NEW000111222"])   // a number in a file that is not a source
        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(shelf.opened == [Self.dental], "only the changed source; never the letter")
        #expect(shelf.walked == walksBefore, "and no folder was walked")
        #expect(Self.row(model, "NEW000111222") == nil, "an ID in another file waits for Discover More")
    }

    @Test func refreshingOneIDReadsItsDocumentsWhetherOrNotTheyChanged() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let id = try #require(Self.row(model, "XZB123456789")?.id)
        await model.readDocuments(with: shelf, scope: .refresh(only: id))
        #expect(shelf.opened == [Self.dental])
    }

    // MARK: What it changes

    @Test func aDetailThatReadsDifferentlyIsMarkedWithWhatItWas() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let id = try #require(Self.row(model, "XZB123456789")?.id)
        #expect(model.changes.isEmpty)

        shelf.write(Self.dental, Self.card(group: "0099999"))
        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(model.changes[id] == [VaultChange(label: "Group number", was: .number("0012345"), now: .number("0099999"))])
        #expect(model.lastReading?.updated == 1)
        #expect(model.lastReading?.scope == .refresh())
        #expect(model.lastReading?.documents == 2, "two documents IDs came from")
        #expect(model.lastReading?.opened == 1)
        let other = try #require(model.rows.first { $0.value != "XZB123456789" })
        #expect(model.changes[other.id] == nil, "the passport was not touched")
    }

    @Test func whatARefreshChangedIsLetGoWithTheNumbers() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        shelf.write(Self.dental, Self.card(group: "0099999"))
        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(!model.changes.isEmpty)
        model.systemLocked()
        #expect(model.changes.isEmpty, "a change holds the detail in full")
    }

    @Test func aSavedIDWhoseDocumentNowReadsAsAnotherIsAskedAboutNotChanged() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))

        var misread = Self.card(group: "0012345")
        misread[2] = "Member ID: XZB123456780"
        shelf.write(Self.dental, misread)
        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(model.entries.first { $0.id == saved }?.value == "XZB123456789", "the saved ID stands")
        let waiting = try #require(model.finds.first { $0.value == "XZB123456780" })
        #expect(model.rereads[saved] == waiting.id, "and the panel is told which reading to ask about")

        model.keepSaved(saved)
        #expect(model.rereads[saved] == nil)
        #expect(!model.finds.contains { $0.value == "XZB123456780" }, "Keep Mine sets the other reading aside")
    }

    @Test func useTheNewReadingChangesTheSavedIDAfterItsProof() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        var reread = Self.card(group: "0012345")
        reread[2] = "Member ID: XZB123456780"
        shelf.write(Self.dental, reread)
        await model.readDocuments(with: shelf, scope: .refresh())

        #expect(await model.useReread(saved))
        #expect(model.entries.first { $0.id == saved }?.value == "XZB123456780")
        #expect(model.rereads.isEmpty)
        #expect(!model.finds.contains { $0.value == "XZB123456780" }, "it is saved now, not waiting")
    }

    // MARK: What it never does

    @Test func aDocumentThatMovedIsMarkedAndItsIDKept() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        shelf.remove(Self.dental)
        await model.readDocuments(with: shelf, scope: .refresh())
        let row = try #require(Self.row(model, "XZB123456789"), "a refresh never lets an ID go for a missing file")
        #expect(row.documentMissing)
        #expect(model.missingDocuments == [Self.dental])
        #expect(model.lastReading?.missing == 1)

        // Put back: the next refresh finds it, and the mark goes.
        shelf.write(Self.dental, Self.card(group: "0012345"))
        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(model.missingDocuments.isEmpty)
        #expect(Self.row(model, "XZB123456789")?.documentMissing == false)
    }

    @Test func discoverMoreFindsAMovedDocumentAgainByItsNumber() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        _ = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        let moved = Self.root + "/Health/Dental/ID Cards/2026 card.pdf"
        shelf.remove(Self.dental)
        shelf.write(moved, Self.card(group: "0012345"))

        await model.readDocuments(with: shelf, scope: .refresh())
        #expect(Self.row(model, "XZB123456789")?.documentMissing == true)

        await model.readDocuments(with: shelf)
        let row = try #require(Self.row(model, "XZB123456789"))
        #expect(!row.documentMissing, "read from where it is now")
        #expect(row.documents.first?.path == moved)
    }

    // MARK: After a change of rules

    @Test func afterAChangeOfRulesRefreshReadsEverySourceThenOffersDiscoverOnce() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        // Seal what was read as an older build would have, and open the Vault again.
        model.systemLocked()
        var state = try #require(rig.store.loadReading())
        state.version = VaultReading.version - 1
        try rig.store.saveReading(state)
        let again = rig.model()
        await again.opened()
        #expect(again.needsReadAgain)
        #expect(again.finds.isEmpty, "what the older rules read is let go")
        #expect(again.refreshSources == [Self.dental, Self.passport], "but where they read it is kept")

        await again.readDocuments(with: shelf, scope: .refresh())
        #expect(Set(shelf.opened) == [Self.dental, Self.passport], "every source, changed or not; never the letter")
        #expect(again.finds.count == 2, "the IDs are back")
        #expect(again.changes.isEmpty, "with nothing to compare against, nothing is called changed")
        #expect(!again.needsReadAgain)
        #expect(again.needsDiscover, "the rest of the folders have not been read with the new rules")

        again.dismissDiscover()
        #expect(!again.needsDiscover)
        again.systemLocked()
        let third = rig.model()
        await third.opened()
        #expect(!third.needsDiscover && !third.needsReadAgain, "Not Now is kept")
    }

    @Test func aFullReadSettlesWhatARefreshLeftToOffer() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        model.systemLocked()
        var state = try #require(rig.store.loadReading())
        state.version = VaultReading.version - 1
        try rig.store.saveReading(state)
        let again = rig.model()
        await again.opened()
        await again.readDocuments(with: shelf, scope: .refresh())
        #expect(again.needsDiscover)
        await again.readDocuments(with: shelf)
        #expect(!again.needsDiscover)
        #expect(again.lastDiscovered != nil && again.lastRefreshed != nil)
    }

    // MARK: By itself

    @Test func refreshRunsByItselfUnlessTurnedOff() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        shelf.write(Self.dental, Self.card(group: "0099999"))
        rig.defaults.set(false, forKey: VaultRefresh.automaticKey)
        model.refreshIfWanted(with: shelf)
        #expect(model.readingTask == nil, "off: nothing starts")

        rig.defaults.removeObject(forKey: VaultRefresh.automaticKey)
        model.refreshIfWanted(with: shelf)
        await model.readingTask?.value
        #expect(shelf.opened == [Self.dental])
    }

    // MARK: The pure rule

    @Test func aChangeIsADetailThatReadsDifferentlyOrIsNewNeverOneThatWent() {
        let old = VaultReadFacts(category: .driversLicense, details: [
            VaultDetail("State", .text("California")), VaultDetail("Class", .text("C")),
            VaultDetail("Valid until", .date(VaultReadingTests.day(2027, 3, 14)))])
        let new = VaultReadFacts(category: .driversLicense, details: [
            VaultDetail("State", .text("California")),
            VaultDetail("Valid until", .date(VaultReadingTests.day(2031, 3, 14))),
            VaultDetail("Issued", .date(VaultReadingTests.day(2026, 11, 12)))])
        #expect(VaultRefresh.changes(from: old, to: new) == [
            VaultChange(label: "Valid until", was: .date(VaultReadingTests.day(2027, 3, 14)), now: .date(VaultReadingTests.day(2031, 3, 14))),
            VaultChange(label: "Issued", was: nil, now: .date(VaultReadingTests.day(2026, 11, 12)))])
        #expect(VaultRefresh.changes(from: nil, to: new).isEmpty, "a first read is not a change")
        #expect(VaultRefresh.changes(from: old, to: nil).isEmpty)
        #expect(VaultRefresh.changes(from: old, to: old).isEmpty)
    }
}
