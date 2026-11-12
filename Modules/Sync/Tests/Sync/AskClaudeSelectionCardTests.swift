import Foundation
import Testing
@testable import Sync

/// TE342: File with Claude's card for a selection: its rows' states, what carries over when the
/// card is updated, Claude's folders and Refine's picks on it, and what Claude is told.
@Suite struct AskClaudeSelectionCardTests {
    /// Real folders, so a folder the card makes is the missing leaf alone, never every level up to
    /// a home folder this Mac doesn't have.
    static let home: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selection-card-\(UUID().uuidString)").path
        for sub in ["Downloads", "Documents/Taxes/2025", "Documents/Insurance/Car", "Documents/Insurance/Home",
                    "Documents/Travel/Trips", "Documents/Medical"] {
            try? FileManager.default.createDirectory(atPath: dir + "/" + sub, withIntermediateDirectories: true)
        }
        return dir
    }()
    static let downloads = home + "/Downloads"
    static let docs = home + "/Documents"

    static func choice(_ rel: String, _ confidence: FilingConfidence, fromFile: Bool? = nil, isNew: Bool? = nil) -> AskClaudePlan.Choice {
        AskClaudePlan.Choice(label: "Home › Documents › " + rel.split(separator: "/").joined(separator: " › "), path: docs + "/" + rel,
                             confidence: AskClaudeFiling.label(confidence), reason: "Fits", isNew: isNew, fromFile: fromFile)
    }

    static func move(_ id: Int, _ file: String, _ choices: [AskClaudePlan.Choice], ticked: Bool? = nil) -> AskClaudePlan.Row {
        var row = AskClaudePlan.Row(id: id, name: file, change: .move(from: downloads + "/" + file, toFolder: choices[0].path),
                                    ticked: ticked ?? (choices[0].confidence == "High"), confidence: choices[0].confidence,
                                    reason: choices[0].reason, folderLabel: choices[0].label, choices: choices)
        row.offer = FilingScorecard.Offer(path: choices[0].path, confidence: choices[0].confidence == "High" ? .high : .low,
                                          evidence: .survey, picker: .mac, runnerUp: choices.dropFirst().first?.path, root: docs)
        return row
    }

    static func noFit(_ id: Int, _ file: String) -> AskClaudePlan.Row {
        var row = AskClaudePlan.Row(id: id, name: file, change: .move(from: downloads + "/" + file, toFolder: downloads),
                                    ticked: false, reason: AskClaudePlan.noFitReason)
        row.noFit = true
        return row
    }

    static func card() -> AskClaudePlan {
        var plan = AskClaudePlan(title: "File 3 Files", subtitle: "selected in Downloads", rows: [
            move(0, "W-2.pdf", [choice("Taxes/2025", .high)]),
            move(1, "Geico.pdf", [choice("Insurance/Car", .low), choice("Insurance/Home", .low)]),
            noFit(2, "IMG_4410.HEIC"),
        ])
        plan.selection = true
        return plan
    }

    // MARK: No Folder Fits (decision NP)

    /// A file no folder fits has its own group, no tick and no landing note, until a folder is
    /// chosen; then it's an ordinary move, and that first choice teaches no rule: the Mac offered
    /// nothing to correct. Mutation: without the `noFit` check in `group`, it falls into a folder
    /// group named "".
    @Test func aFileNoFolderFitsWaitsForAChosenFolderAndTeachesNothing() {
        var plan = Self.card()
        plan.noteLandingNames()
        let row = plan.rows[2]
        #expect(row.group == .noFit && row.note == nil && !row.ticked)
        #expect(plan.groups.map(\.group).last == .noFit)
        plan.setTicked(true, row: 2)
        #expect(!plan.rows[2].ticked, "a row with nowhere to go can't be ticked")
        plan.choose(AskClaudePlan.Choice(label: "Home › Documents › Photos", path: Self.docs + "/Photos"), forRow: 2)
        #expect(plan.rows[2].noFit == nil && plan.rows[2].ticked && plan.rows[2].group == .folder("Home › Documents › Photos"))
        #expect(!plan.rows[2].teaches)
    }

    // MARK: Ticking an unsure row

    /// Ticking a Needs Your Pick row takes the Mac's unsure folder as theirs: it teaches at Apply
    /// (decision JC, as Move Here does on one file), yet stays in its group and isn't "chosen".
    @Test func tickingAnUnsureRowTeachesWithoutMovingIt() {
        var plan = Self.card()
        plan.setTicked(true, row: 1)
        #expect(plan.rows[1].teaches && !plan.rows[1].chosen && plan.rows[1].group == .needsPick)
        plan.setTicked(false, row: 1)
        #expect(!plan.rows[1].teaches, "unticked, it teaches nothing")
        plan.setTicked(true, row: 0)
        #expect(!plan.rows[0].teaches, "a sure row ticked is the Mac's pick")
    }

    // MARK: Updating the card

    /// A card made again for the same files keeps a folder they chose, Claude's folder with its
    /// Undo Refine state, a name they typed, and their ticks on rows still going where they went.
    @Test func aCardMadeAgainKeepsWhatTheyDid() {
        var old = Self.card()
        old.choose(Self.choice("Insurance/Home", .low), forRow: 1)
        old.setTicked(false, row: 0)
        old.setName("Tax form", row: 0)
        var fresh = Self.card()
        fresh.carryPicks(from: old)
        #expect(fresh.rows[1].chosen && fresh.rows[1].change == old.rows[1].change && fresh.rows[1].ticked)
        #expect(!fresh.rows[0].ticked && fresh.rows[0].newName == "Tax form.pdf")
        #expect(fresh.rows[2].noFit == true)

        var refined = Self.card()
        refined.refined([Self.downloads + "/Geico.pdf": .folder(path: Self.docs + "/Insurance/Auto", label: "Auto", reason: nil)])
        var again = Self.card()
        again.carryPicks(from: refined)
        #expect(again.rows[1].claudePick == true && again.rows[1].folderLabel == "Auto" && again.rows[1].beforeRefine != nil)
        #expect(again.rows.contains { $0.change == .newFolder(in: Self.docs + "/Insurance", name: "Auto") })
        again.refineUndone()
        #expect(again.rows[1].folderLabel == "Home › Documents › Insurance › Car", "Undo Refine still works on the new card")
    }

    /// A file filed elsewhere since is left at Apply, and so is a folder only it needed.
    @Test func aFileMovedSinceIsLeftAtApply() {
        var plan = Self.card()
        _ = plan.claudeFolder(forFile: Self.downloads + "/W-2.pdf", folder: Self.docs + "/Taxes/2026", label: "Home › Documents › Taxes › 2026", reason: "x")
        plan.setTicked(true, row: 0)
        #expect(plan.rows.contains { $0.forMoves == true && $0.ticked })
        plan.untickMoved(exists: { $0 != Self.downloads + "/W-2.pdf" && FileManager.default.fileExists(atPath: $0) })
        #expect(!plan.rows[0].ticked && !plan.rows.contains { $0.forMoves == true && $0.ticked })
        #expect(plan.runnable.isEmpty)
    }

    // MARK: Claude's folder (decision NR)

    /// Claude's new folder leads the row, unticked, with the Mac's folders after it; the card
    /// makes it once the row is ticked; the scorecard counts it as Claude's. A row they chose is
    /// never changed, nor a card already applied.
    @Test func claudesFolderLeadsTheRowUntilTheyTickIt() throws {
        var plan = Self.card()
        let japan = Self.docs + "/Travel/Trips/Japan"
        #expect(plan.claudeFolder(forFile: Self.downloads + "/W-2.pdf", folder: japan, label: "Home › Documents › Travel › Trips › Japan",
                                  reason: "A new folder named like India") == nil)
        let row = plan.rows[0]
        #expect(row.change == .move(from: Self.downloads + "/W-2.pdf", toFolder: japan) && !row.ticked && row.claudePick == true)
        #expect(row.choices.first?.path == japan && row.choices.first?.isNew == true && row.choices.count == 2)
        #expect(row.offer?.picker == .claude && row.offer?.runnerUp == Self.docs + "/Taxes/2025" && row.offer?.offeredNew == [japan])
        let made = try #require(plan.rows.first { $0.change == .newFolder(in: Self.docs + "/Travel/Trips", name: "Japan") })
        #expect(made.forMoves == true && !made.ticked && made.folderLabel == "Home › Documents › Travel › Trips")
        #expect(plan.rows.filter { if case .newFolder = $0.change { true } else { false } }.count == 1, "only the missing leaf is made")
        plan.setTicked(true, row: 0)
        #expect(plan.rows.first { $0.id == made.id }?.ticked == true, "ticking the row ticks the folder it needs")
        #expect(!plan.rows[0].teaches, "Claude's folder taken is no correction of the Mac's")

        plan.choose(Self.choice("Insurance/Home", .low), forRow: 1)
        #expect(plan.claudeFolder(forFile: Self.downloads + "/Geico.pdf", folder: japan, label: "Japan", reason: "x") != nil)
        plan.state = .applied
        #expect(plan.claudeFolder(forFile: Self.downloads + "/IMG_4410.HEIC", folder: japan, label: "Japan", reason: "x") != nil)
    }

    // MARK: Refine's picks (decision NS)

    /// Refine's pick moves an untouched row, unticked, into Claude's folder's group, and counts as
    /// Claude's; a row it kept says so, and neither is offered to Refine again; a row they ticked
    /// keeps its folder; Undo Refine puts back each row they haven't touched since, and the folder
    /// rows Refine's picks needed go.
    @Test func refinesPicksComeBackOntoTheCardAndUndoPutsThemBack() {
        var plan = Self.card()
        plan.rows.append(Self.move(3, "Lab.pdf", [Self.choice("Medical", .medium)], ticked: false))
        let car = Self.docs + "/Insurance/Car"
        plan.refined([Self.downloads + "/Geico.pdf": .folder(path: Self.docs + "/Insurance/Auto", label: "Auto", reason: "Policy for a car"),
                      Self.downloads + "/Lab.pdf": .agrees])
        #expect(plan.rows[1].claudePick == true && plan.rows[1].folderLabel == "Auto" && !plan.rows[1].ticked)
        #expect(plan.rows[1].choices.map(\.path) == [Self.docs + "/Insurance/Auto", car, Self.docs + "/Insurance/Home"])
        #expect(plan.rows[1].offer?.picker == .claude && plan.rows[1].offer?.runnerUp == car)
        #expect(plan.rows[1].group == .folder("Auto"))
        #expect(plan.rows[3].claudeAgrees == true && plan.rows[3].claudePick == nil)
        plan.refineFolder = Self.downloads
        #expect(plan.refinable.isEmpty, "both were answered")
        #expect(plan.rows.contains { $0.change == .newFolder(in: Self.docs + "/Insurance", name: "Auto") })
        plan.refineUndone()
        #expect(plan.rows[1].change == .move(from: Self.downloads + "/Geico.pdf", toFolder: car) && plan.rows[1].claudePick == nil)
        #expect(plan.rows[3].claudeAgrees == nil)
        #expect(!plan.rows.contains { if case .newFolder = $0.change { true } else { false } }, "Auto isn't needed any more")
        // Ticked before Refine answers, a row keeps the folder they approved.
        var ticked = Self.card()
        ticked.setTicked(true, row: 1)
        ticked.refined([Self.downloads + "/Geico.pdf": .folder(path: Self.docs + "/Insurance/Auto", label: "Auto", reason: nil)])
        #expect(ticked.rows[1].change == .move(from: Self.downloads + "/Geico.pdf", toFolder: car))

        // Ticked since, it stays: they approved Claude's folder.
        plan.refined([Self.downloads + "/Geico.pdf": .folder(path: Self.docs + "/Insurance/Auto", label: "Auto", reason: nil)])
        plan.setTicked(true, row: 1)
        plan.refineUndone()
        #expect(plan.rows[1].folderLabel == "Auto")
    }

    // MARK: Saved chats

    /// A card saved before TE342 still opens, and saving it again writes none of the new fields:
    /// every one is optional (synthesized decoding refuses a missing non-optional key).
    @Test func aCardSavedBeforeThisChangeStillOpens() throws {
        let old = #"{"title":"File 2 Loose Files","subtitle":"into Documents","state":"proposed","rows":[{"id":0,"name":"a.pdf","change":{"move":{"from":"/d/a.pdf","toFolder":"/D/T"}},"ticked":true,"choices":[{"label":"T","path":"/D/T"}],"chosen":false,"alreadyFiled":false}]}"#
        let plan = try JSONDecoder().decode(AskClaudePlan.self, from: Data(old.utf8))
        #expect(plan.rows[0].noFit == nil && plan.rows[0].choices[0].fromFile == nil && plan.remaining == nil && plan.selection == nil)
        let again = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        for key in ["noFit", "claudePick", "remaining", "selection", "refineFolder", "fromFile", "folderHeld", "replaces"] {
            #expect(!again.contains("\"\(key)\""), "\(key) written for a card that never had it")
        }
        // And the new ones survive a round trip, but `replaces` never does: it is one tool call's.
        var card = Self.card()
        card.remaining = ["/d/x.pdf"]
        card.refineFolder = Self.downloads
        card.replaces = UUID()
        let back = try JSONDecoder().decode(AskClaudePlan.self, from: JSONEncoder().encode(card))
        #expect(back.remaining == ["/d/x.pdf"] && back.selection == true && back.refineFolder == Self.downloads && back.rows[2].noFit == true)
        #expect(back.replaces == nil)
    }

    // MARK: What Claude is told

    /// Rows go by handle. A folder a word on page 1 picked stays on their card unless the file's
    /// folder shares, and so do a held new name and the "Kept as" note that would spell it.
    @Test func claudeGetsEachRowByHandleAndNothingPageOnePicked() {
        var plan = Self.card()
        plan.rows[0].folderHeld = true
        plan.rows[0].newName = "2025 Ally 1099-INT.pdf"
        plan.rows[0].note = "Kept as 2025 Ally 1099-INT 2.pdf: the name is taken"
        plan.rows[1].namedSiblings = .init(label: "Home › Documents › Insurance", path: Self.docs + "/Insurance", names: ["Car", "Home"])
        let handles = [Self.downloads + "/W-2.pdf": "r4", Self.downloads + "/Geico.pdf": "r5", Self.downloads + "/IMG_4410.HEIC": "r6"]
        let text = AskClaudeSelectionCard.result(plan, handle: { handles[$0] ?? "?" }, namesShared: false)
        #expect(text.contains("r4|a folder picked by a word read from the file"))
        #expect(!text.contains("Taxes") && !text.contains("Ally") && !text.contains("W-2.pdf"), "\(text)")
        #expect(text.contains("r5|needs their pick: Home › Documents › Insurance › Car or Home › Documents › Insurance › Home"))
        #expect(text.contains("r6|no folder fits"))
        #expect(text.contains("For r5: the folders in Home › Documents › Insurance are named Car, Home."))
        let shared = AskClaudeSelectionCard.result(plan, handle: { handles[$0] ?? "?" }, namesShared: true)
        #expect(shared.contains("renamed to 2025 Ally 1099-INT.pdf"))
    }
}

/// Decision NJ: what filing_scorecard tells Claude.
@Suite struct FilingScorecardForClaudeTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func record(_ area: String, _ verdict: FilingScorecard.Verdict, file: String = "f.pdf", daysAgo: Double = 1,
                       picker: FilingScorecard.Picker = .mac, confidence: FilingConfidence = .high) -> FilingScorecard.Record {
        FilingScorecard.Record(at: now.addingTimeInterval(-daysAgo * 86_400), picker: picker, confidence: confidence, evidence: .survey,
                               offered: "/R/\(area)/Offered", landed: "/R/\(area)/Landed", file: "/R/\(area)/Landed/\(file)", root: "/R",
                               verdict: verdict, change: verdict == .changed ? .runnerUp : nil)
    }

    /// Counts and top-level areas only, in range; a filing in a folder hidden from Claude is
    /// dropped before anything is counted, so no total says it happened. Mutation: filtering
    /// after `summary` leaves the hidden filing in "kept … of".
    @Test func claudeGetsCountsAndAreasButNothingHidden() {
        var records = (0..<5).map { Self.record("School", $0 < 4 ? .kept : .changed, file: "s\($0).pdf") }
        records.append(Self.record("Medical", .kept, file: "secret-diagnosis.pdf"))
        records.append(Self.record("School", .kept, daysAgo: 60))
        records.append(Self.record("School", .kept, picker: .claude))
        let text = FilingScorecard.forClaude(records, range: .days30, isHidden: { $0.hasPrefix("/R/Medical") }, now: Self.now)
        #expect(text.contains("Last 30 days: kept the first folder offered 4 of 5, one folder deeper 0, changed 1 (1 to the runner-up)."), "\(text)")
        #expect(text.contains("Kept by top-level area, with 5 or more: School 4 of 5."))
        #expect(text.contains("Your picks (Refine’s, and new folders you named): kept 1 of 1."))
        #expect(text.contains("Kept by what picked the folder: Folder survey 4 of 5."))
        #expect(!text.contains("Medical") && !text.contains("secret") && !text.contains(".pdf") && !text.contains("/R"))
        let all = FilingScorecard.forClaude(records, range: FilingScorecard.range(named: "all"), isHidden: { _ in false }, now: Self.now)
        #expect(all.hasPrefix("Since counting began: kept the first folder offered 6 of 7"), "\(all)")
        #expect(FilingScorecard.forClaude([], range: .days30, isHidden: { _ in false }, now: Self.now).hasPrefix("Last 30 days: no filing"))
    }
}
