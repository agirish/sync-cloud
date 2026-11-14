import Foundation
import Testing
@testable import Sync

/// A loose-files card takes the sure files first, from a light read of the next files; a
/// heading ticks a folder's sure rows; files a card left are skipped by Next for that place.
@Suite struct AskClaudeSureFirstTests {

    private func files(_ count: Int) -> [AskClaudeLooseFiles.File] {
        (0..<count).map { AskClaudeLooseFiles.File(path: "/d/f\($0)", name: "f\($0)", size: 1, modified: nil) }
    }

    /// A sure file deep in the look-ahead leads card 1; those to check follow, then those with no
    /// folder, then any not read, each newest first.
    @Test func sureFilesLeadThenThoseToCheckThenTheRest() {
        let all = files(60)
        let ahead: [String: AskClaudeLooseFiles.Ahead] = ["/d/f47": .sure, "/d/f3": .sure, "/d/f1": .check,
                                                          "/d/f0": .noFolder, "/d/f2": .noFolder]
        let ordered = AskClaudeLooseFiles.sureFirst(all, path: \.path, ahead: ahead).map(\.name)
        #expect(Array(ordered.prefix(3)) == ["f3", "f47", "f1"])
        #expect(Array(ordered[3...4]) == ["f0", "f2"])
        #expect(ordered[5] == "f4" && ordered.count == 60, "files not read keep their order, after those read")
        let rest = AskClaudeLooseFiles.unshown(all, from: 0, shown: [])
        let page = AskClaudeLooseFiles.sureFirst(rest, path: \.path, ahead: ahead).prefix(AskClaudeLooseFiles.perCard)
        #expect(page.first?.name == "f3" && page.map(\.name).contains("f47") && rest.count == 60)
    }

    /// Nothing read ahead: the newest first.
    @Test func withNothingReadAheadTheCardHoldsTheNewest() {
        let all = files(25)
        #expect(AskClaudeLooseFiles.sureFirst(all, path: \.path, ahead: [:]).map(\.name) == all.map(\.name))
        let rest = AskClaudeLooseFiles.unshown(all, from: 0, shown: [])
        #expect(AskClaudeLooseFiles.sureFirst(rest, path: \.path, ahead: [:]).prefix(AskClaudeLooseFiles.perCard).map(\.name)
                == (0..<10).map { "f\($0)" })
    }

    /// More sure files than a card holds: the rest lead the next card.
    @Test func sureFilesPastTenLeadTheNextCard() {
        let all = files(40)
        var ahead: [String: AskClaudeLooseFiles.Ahead] = [:]
        for i in 0..<40 { ahead["/d/f\(i)"] = i % 3 == 0 ? .sure : .check }
        let card = { (from: Int, shown: Set<String>) in
            Array(AskClaudeLooseFiles.sureFirst(AskClaudeLooseFiles.unshown(all, from: from, shown: shown),
                                                path: \.path, ahead: ahead).prefix(AskClaudeLooseFiles.perCard))
        }
        let first = card(0, [])
        let sure = (0..<40).filter { $0 % 3 == 0 }.map { "f\($0)" }
        #expect(first.map(\.name) == Array(sure.prefix(10)))
        let second = card(10, Set(first.map(\.path)))
        #expect(Array(second.map(\.name).prefix(4)) == Array(sure.dropFirst(10)))
        #expect(second[4].name == "f1", "then the newest to check")
    }

    /// From 0 is a fresh ask: every file, those shown before included.
    @Test func aFreshAskLooksAtEveryFileAgain() {
        let all = files(15)
        let shown = Set(all.prefix(10).map(\.path))
        #expect(AskClaudeLooseFiles.unshown(all, from: 0, shown: shown).count == 15)
        #expect(AskClaudeLooseFiles.unshown(all, from: 10, shown: shown).map(\.name) == (10..<15).map { "f\($0)" })
    }

    @Test func claudeHearsHowManyLookedSureAndHowManyAreTicked() {
        #expect(AskClaudeLooseFiles.sureFirstLine(lookedSure: 6, lookedAt: 40, sureOnCard: 5)
                == "Sure ones first: 6 of the next 40 loose files looked sure on a first read; they lead this card. 5 sure rows are ticked.")
        #expect(AskClaudeLooseFiles.sureFirstLine(lookedSure: 14, lookedAt: 50, sureOnCard: 10)
                == "Sure ones first: 14 of the next 50 loose files looked sure on a first read; the first 10 are on this card and the other 4 lead the next. 10 sure rows are ticked.")
        #expect(AskClaudeLooseFiles.sureFirstLine(lookedSure: 0, lookedAt: 12, sureOnCard: 1)
                == "None of the next 12 loose files looked sure on a first read, so the card holds the newest; 1 sure row is ticked.")
        #expect(AskClaudeLooseFiles.sureFirstLine(lookedSure: 0, lookedAt: 0, sureOnCard: 0) == nil)
        let plan = AskClaudePlan(title: "File 1 Loose File", subtitle: "into Documents", rows: [])
        let line = "Sure ones first: 1 of the next 20 loose files looked sure on a first read; they lead this card. 1 sure row is ticked."
        #expect(AskClaudeLooseFiles.result(plan, leftHereCount: 0, nextFrom: nil, rows: false, sureFirst: line).contains(line))
        #expect(AskClaudeLooseFiles.result(plan, leftHereCount: 0, nextFrom: nil, rows: true, sureFirst: line).contains(line))
    }

    // MARK: The card

    private func row(_ id: Int, to label: String, _ confidence: FilingConfidence, ticked: Bool,
                     offered: FilingConfidence? = nil) -> AskClaudePlan.Row {
        var row = AskClaudePlan.Row(id: id, name: "f\(id).pdf", change: .move(from: "/d/f\(id).pdf", toFolder: "/docs/" + label),
                                    ticked: ticked, confidence: AskClaudeFiling.label(confidence), folderLabel: label,
                                    choices: [.init(label: label, path: "/docs/" + label, confidence: AskClaudeFiling.label(confidence)),
                                              .init(label: "Work", path: "/docs/Work", confidence: "Medium")])
        row.offer = FilingScorecard.Offer(path: "/docs/" + label, confidence: offered ?? confidence, evidence: .survey, picker: .mac)
        return row
    }

    /// A folder's tick box covers its sure rows alone: a Medium row stays unticked (GC), a refused
    /// one is left out, and a new folder follows the moves once.
    @Test func aHeadingTicksOnlyItsFoldersSureRows() {
        var refused = row(3, to: "Trips", .high, ticked: false)
        refused.refusal = "Trips is hidden from Claude"
        var made = AskClaudePlan.Row(id: 4, name: "New folder “2027”", change: .newFolder(in: "/docs", name: "Sep"), ticked: true,
                                     folderLabel: "")
        made.forMoves = true
        var plan = AskClaudePlan(title: "File 4", subtitle: "", rows: [
            row(0, to: "Sep", .high, ticked: true), row(1, to: "Sep", .high, ticked: true),
            row(2, to: "Sep", .medium, ticked: false), refused, made])
        #expect(plan.sureRows(inFolder: "Sep").map(\.id) == [0, 1])
        plan.setSureTicked(false, inFolder: "Sep")
        #expect(plan.rows.filter(\.ticked).map(\.id).isEmpty, "the new folder unticks once no move goes into it")
        plan.setSureTicked(true, inFolder: "Sep")
        #expect(plan.rows.filter(\.ticked).map(\.id) == [0, 1, 4])
        #expect(plan.rows[2].ticked == false && plan.rows[3].ticked == false)
    }

    /// Groups the card offered a sure file lead, by what was offered: ticking or sending a row
    /// elsewhere never moves a group. A card with no offers keeps the plain order.
    @Test func groupsOfferedASureFileLeadAndStayPut() {
        var plan = AskClaudePlan(title: "File 4", subtitle: "", rows: [
            row(0, to: "Health", .medium, ticked: false), row(1, to: "Health", .medium, ticked: false),
            row(2, to: "Health", .medium, ticked: false), row(3, to: "Sep", .high, ticked: true)])
        #expect(plan.groups.map(\.group) == [.folder("Sep"), .folder("Health")])
        plan.setTicked(false, row: 3)
        #expect(plan.groups.map(\.group) == [.folder("Sep"), .folder("Health")])
        plan.choose(.init(label: "Work", path: "/docs/Work", confidence: "Medium"), forRow: 3)
        #expect(plan.groups.map(\.group) == [.folder("Work"), .folder("Health")], "its offer stays with the row")
        var plain = plan
        for index in plain.rows.indices { plain.rows[index].offer = nil }
        #expect(plain.groups.map(\.group) == [.folder("Health"), .folder("Work")])
    }

    /// The files a card left are saved with the chat; a chat saved without them still opens.
    @Test func leftFilesAreSavedAndOldChatsStillOpen() throws {
        var plan = AskClaudePlan(title: "File 1", subtitle: "into Documents", rows: [row(0, to: "Sep", .high, ticked: true)])
        plan.leftPaths = .init(place: "/docs", paths: ["/d/x.png", "/d/y.pdf"])
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(AskClaudePlan.self, from: data).leftPaths == plan.leftPaths)
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["leftPaths"] = nil
        let decoded = try JSONDecoder().decode(AskClaudePlan.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.leftPaths == nil && decoded.rows.count == 1)
    }
}
