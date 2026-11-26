import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// Refresh and Discover More as the panel says and draws them. Every ID is made up.
@MainActor
@Suite struct VaultRefreshPanelTests {
    // MARK: Words

    @Test func theFooterSaysWhatARefreshDid() {
        typealias Summary = VaultModel.ReadingSummary
        #expect(VaultCard.summary(Summary(documents: 212, opened: 3, newNumbers: 0, scope: .refresh(), updated: 2, missing: 1))
                == "Refreshed 212 documents: 2 IDs updated, 1 file not found.")
        #expect(VaultCard.summary(Summary(documents: 1, opened: 0, newNumbers: 0, scope: .refresh()))
                == "Refreshed 1 document: nothing changed.")
        #expect(VaultCard.summary(Summary(documents: 40, opened: 40, newNumbers: 1, scope: .refresh(), updated: 1, gone: 2))
                == "Refreshed 40 documents: 1 ID updated, 1 new ID to confirm, 2 waiting IDs no longer read.")
        // A read of the folders keeps its own words.
        #expect(VaultCard.summary(Summary(documents: 812, opened: 3, newNumbers: 1))
                == "Read 3 new or changed of 812 documents: 1 new ID to confirm.")
    }

    @Test func theFooterSaysWhichReadIsRunning() {
        typealias Progress = VaultModel.ReadingProgress
        #expect(VaultCard.progress(Progress(done: 0, total: 0, scope: .refresh())) == "Checking your documents…")
        #expect(VaultCard.progress(Progress(done: 64, total: 212, scope: .refresh())) == "Refreshing 64 of 212 documents…")
        #expect(VaultCard.progress(Progress(done: 0, total: 0, scope: .discover)) == "Finding documents…")
        #expect(VaultCard.progress(Progress(done: 5, total: 9, scope: .everything)) == "Reading 5 of 9 documents…")
    }

    @Test func theMenuSaysWhereEachLooks() {
        #expect(VaultCard.discoverLine(folders: 0) == "No folders chosen yet")
        #expect(VaultCard.discoverLine(folders: 1) == "New and changed files in 1 folder")
        #expect(VaultCard.discoverLine(folders: 3) == "New and changed files in 3 folders")
        #expect(VaultCard.refreshLine(documents: 0) == "No ID has been read from a document yet")
        #expect(VaultCard.refreshLine(documents: 212) == "The 212 documents your IDs are read from")
        // Discover More's banner says what it is offered for (VT107).
        #expect(VaultCard.discoverBanner(copiesChanged: true).hasPrefix("Other documents your IDs were also read from have changed."))
        #expect(VaultCard.discoverBanner(copiesChanged: false).hasPrefix("Your IDs are up to date."))
    }

    @Test func atRestTheFooterSaysWhenEachLastRan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func back(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        #expect(VaultCard.lastRuns(refreshed: nil, discovered: nil, now: now) == nil)
        #expect(VaultCard.lastRuns(refreshed: back(20), discovered: nil, now: now) == "Refreshed just now")
        #expect(VaultCard.lastRuns(refreshed: back(300), discovered: back(3 * 86_400 + 60), now: now)
                == "Refreshed 5 minutes ago · Discovered 3 days ago")
        #expect(VaultCard.ago(back(4000), now: now) == "1 hour ago")
        #expect(VaultCard.ago(back(3 * 3600), now: now) == "3 hours ago")
        #expect(VaultCard.ago(back(30 * 3600), now: now) == "yesterday")
        #expect(VaultCard.ago(now.addingTimeInterval(60), now: now) == "just now", "a clock set back never reads as the future")
    }

    /// The panel redraws for "how long ago" only when the model's step moves (VT9): wherever the
    /// wording changes, second by second over three days, so must the step.
    @Test func theWordingNeverChangesWithinOneStep() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var missed: [Int] = []
        var wording = VaultCard.ago(now, now: now), step = VaultModel.agoStep(0)
        for second in 1...(3 * 86_400) {
            let (w, s) = (VaultCard.ago(now.addingTimeInterval(-Double(second)), now: now), VaultModel.agoStep(Double(second)))
            if w != wording, s == step { missed.append(second) }
            (wording, step) = (w, s)
        }
        #expect(missed.isEmpty, "the wording changed within a step at \(missed.prefix(5)) s")
    }

    @Test func aChangeSaysWhatFromAndToAndHidesANumberUntilShown() {
        let day = { (y: Int, m: Int, d: Int) in Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d))! }
        let moved = VaultChange(label: "Valid until", was: .date(day(2027, 3, 14)), now: .date(day(2031, 3, 14)))
        #expect(VaultCard.changeLine(moved, shown: false) == "Valid until: 14 March 2027 → 14 March 2031")
        let new = VaultChange(label: "Class", was: nil, now: .text("C"))
        #expect(VaultCard.changeLine(new, shown: true) == "Class: C (new)")
        let group = VaultChange(label: "Group number", was: .number("0012345"), now: .number("0099999"))
        #expect(VaultCard.changeLine(group, shown: false) == "Group number: •••2345 → •••9999")
        #expect(VaultCard.changeLine(group, shown: true) == "Group number: 0012345 → 0099999")
    }

    // MARK: Drawn

    typealias Shelf = VaultShelf

    static let root = "/Users/anna/Documents"
    static let dental = root + "/Health/Dental/ID Cards/card.pdf"
    static let vision = root + "/Health/Vision/ID Cards/card.pdf"
    static func card(_ plan: String, id: String, group: String) -> [String] {
        [plan, "Member Name: ANNA ERIKSSON", "Member ID: \(id)", "Group Number: \(group)"]
    }

    /// A Vault that has read a dental and a vision card; with `refreshed`, the dental card's group
    /// then changed and the vision card went, and a refresh ran. Drawn once: a hosted panel that
    /// goes away closes its Vault, so a model is never drawn, changed and drawn again.
    static func drawn(refreshed: Bool, name: String) async throws -> (model: VaultModel, picture: NSBitmapImageRep, cleanUp: () -> Void) {
        let rig = try await VaultPanelRenderTests.rig()
        VaultReadFolders.add(root, in: rig.defaults)
        let shelf = Shelf([dental: card("Delta Dental", id: "XZB123456789", group: "0012345"),
                           vision: card("Clear Vision", id: "VSP99887766", group: "0044")])
        await rig.model.readDocuments(with: shelf)
        if refreshed {
            shelf.write(dental, card("Delta Dental", id: "XZB123456789", group: "0099999"))
            shelf.remove(vision)
            await rig.model.readDocuments(with: shelf, scope: .refresh())
        }
        rig.model.selection = rig.model.rows.first { $0.value == "XZB123456789" }?.id
        return (rig.model, try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: name), rig.cleanUp)
    }

    @Test func aRefreshedIDIsMarkedAndAMovedDocumentIsSaidSo() async throws {
        let before = try await Self.drawn(refreshed: false, name: "refresh-before"); defer { before.cleanUp() }
        let after = try await Self.drawn(refreshed: true, name: "refresh-after"); defer { after.cleanUp() }
        #expect(differingPixels(before.picture, after.picture) > 4000, "the Updated mark, the File not found mark and what changed are drawn")
    }

    @Test func aRefreshMarksWhatChangedAndWhatWentInTheModelThePanelDraws() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let shelf = Shelf([Self.dental: Self.card("Delta Dental", id: "XZB123456789", group: "0012345"),
                           Self.vision: Self.card("Clear Vision", id: "VSP99887766", group: "0044")])
        await rig.model.readDocuments(with: shelf)
        shelf.write(Self.dental, Self.card("Delta Dental", id: "XZB123456789", group: "0099999"))
        shelf.remove(Self.vision)
        await rig.model.readDocuments(with: shelf, scope: .refresh())
        let dental = try #require(rig.model.rows.first { $0.value == "XZB123456789" })
        #expect(rig.model.changes[dental.id] != nil)
        #expect(rig.model.rows.first { $0.value == "VSP99887766" }?.documentMissing == true)
    }

    /// VT34: what a refresh read differently is hidden as the saved ID's row hides it.
    @Test func aDifferentReadingHidesASocialSecurityNumberWhole() {
        #expect(VaultCard.readsDifferently("123-45-6789", saved: .ssn, read: .ssn).contains("6789") == false)
        #expect(VaultCard.readsDifferently("123-45-6789", saved: .ssn, read: .other).contains("6789") == false,
                "saved as a Social Security number, its ending stays hidden")
        #expect(VaultCard.readsDifferently("123-45-6789", saved: .other, read: .ssn).contains("6789") == false,
                "read as one, too")
        #expect(VaultCard.readsDifferently("0482917365", saved: .loans, read: .loans).contains("7365"))
        #expect(!VaultCard.lockedOnCard("123-45-6789", as: .ssn).contains("6789"), "on the editor's card list too")
        #expect(VaultCard.lockedOnCard("0482917365", as: .loans).hasSuffix("7365"))
    }

    @Test func afterAnUpdateTheBannerOffersDiscoverMoreUntilNotNow() async throws {
        // A refresh that follows a change of rules leaves the folders to be looked at.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // No other copy: in the app's test host the check would see the owner's SyncCloud running.
        let store = VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultFakeKeychain(),
                               anotherCopyRunning: { false })
        try store.saveReading(VaultReadingState(needsDiscover: true))
        let scratch = TestDefaults()
        let model = VaultModel(store: store, authenticator: VaultFakeAuthenticator(), defaults: scratch.defaults, copyToPasteboard: { _ in })
        await model.opened()
        #expect(model.needsDiscover)
        _ = model.add(VaultModel.Draft(title: "Passport", value: "A38291647", category: .passport))
        let offered = try VaultPanelRenderTests.render(model, defaults: scratch.defaults, name: "banner-discover")
        model.dismissDiscover()
        let dismissed = try VaultPanelRenderTests.render(model, defaults: scratch.defaults, name: "banner-dismissed")
        #expect(differingPixels(offered, dismissed) > 4000, "the banner is drawn, and Not Now takes it away")
    }
}
