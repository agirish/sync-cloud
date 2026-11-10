import Foundation
import Testing
@testable import Sync

/// TE327: a new folder named like its siblings, for a file no folder holds well.
@Suite struct FilingNewHomeTests {

    private let root = "/never-on-disk-new-home/Documents"
    private var trips: String { root + "/Travel/Trips" }
    private var inUS: String { trips + "/IN-US" }

    /// Folders by parent, as a survey would list them.
    private func children(_ tree: [String: [String]]) -> (String) -> [String] { { tree[$0] ?? [] } }

    private func dated(_ file: String, near candidates: [String], _ tree: [String: [String]],
                       onDisk: Set<String> = [], hidden: (String) -> Bool = { _ in false }) -> FilingNewHome.Offer? {
        FilingNewHome.dated(fileName: file, candidates: candidates, within: root, childFolders: children(tree),
                            exists: { onDisk.contains($0) }, isHidden: hidden, latestYear: 2031)
    }

    @Test func aYearPastTheLastGetsItsOwnFolderBesideTheYears() throws {
        let tree = [inUS: ["2012", "2024", "2025", "2026", "Family"]]
        // The best folder is the trip itself, or one of its years: either way the year goes in the trip.
        for best in [inUS, inUS + "/2026"] {
            let offer = try #require(dated("Air India eTicket - Jan 2027.pdf", near: [best], tree))
            #expect(offer.path == inUS + "/2027")
            #expect(offer.siblings == ["2024", "2025", "2026"])
            #expect(offer.reason == "Named like 2024, 2025, 2026")
        }
    }

    /// Each refusal against the same tree, so the control above is what changes.
    @Test func noYearFolderWithoutAPatternAYearOrRoom() {
        let tree = [inUS: ["2024", "2025", "2026"]]
        #expect(dated("Air India eTicket.pdf", near: [inUS], tree) == nil, "no year in the name")
        #expect(dated("Air India eTicket - 2026.pdf", near: [inUS], tree) == nil, "2026 is already there")
        #expect(dated("Trip 2026 to 2027.pdf", near: [inUS], tree) == nil, "two years have no one home")
        #expect(dated("Air India - 2027.pdf", near: [inUS], tree, onDisk: [inUS + "/2027"]) == nil, "made since the survey")
        #expect(dated("Air India - 2027.pdf", near: [inUS], [inUS: ["2025", "2026", "Family", "Kids", "Misc"]]) == nil,
                "two years among five folders aren't a pattern")
        #expect(dated("Air India - 2027.pdf", near: [inUS], tree) != nil)
    }

    /// Never inside a hidden folder, and never named after the folders hidden in it.
    @Test func aHiddenFolderNeverGetsANewOne() {
        let tree = [inUS: ["2024", "2025", "2026"]]
        let hideTrip: (String) -> Bool = { $0 == self.inUS || $0.hasPrefix(self.inUS + "/") }
        #expect(dated("Air India - 2027.pdf", near: [inUS], tree, hidden: hideTrip) == nil)
        let hideYears: (String) -> Bool = { ["2024", "2025"].contains(($0 as NSString).lastPathComponent) }
        #expect(dated("Air India - 2027.pdf", near: [inUS], tree, hidden: hideYears) == nil,
                "one year left shown is no pattern")
        #expect(dated("Air India - 2027.pdf", near: [inUS], tree, hidden: { $0 == self.inUS + "/2027" }) == nil)
    }

    @Test func neverOutsideTheSurveyOrANamedPlace() {
        let top = root + "/Taxes"
        let tree = [root: ["2024", "2025", "2026"], top: []]
        // The root's own children count; its parent never does.
        #expect(dated("W-2 2027.pdf", near: [top], tree)?.path == root + "/2027")
        #expect(FilingNewHome.dated(fileName: "W-2 2027.pdf", candidates: [top], within: top, childFolders: children(tree),
                                    exists: { _ in false }, isHidden: { _ in false }, latestYear: 2031) == nil)
    }

    @Test func aRangeBesideRangesOfTheSameLength() throws {
        let tax = root + "/Finance/IN/Income Tax"
        let tree = [tax: ["2023-2024", "2024-2025", "2025-2026"]]
        let offer = try #require(dated("Form 16 FY 2026-27.pdf", near: [tax], tree))
        #expect(offer.name == "2026-2027")
        #expect(offer.siblings == ["2023-2024", "2024-2025", "2025-2026"])
        #expect(dated("Form 16 FY 2026-2027.pdf", near: [tax], tree)?.name == "2026-2027")
        #expect(dated("Form 16 FY 2025-26.pdf", near: [tax], tree) == nil, "already there")
        #expect(dated("Form 16 2026.pdf", near: [tax], tree) == nil, "a year isn't a range")
        // H-1B's periods differ in length, so no next one can be read off a date.
        let h1b = root + "/Immigration/Authorization/H-1B"
        #expect(dated("I-797A 2029-2032.pdf", near: [h1b], [h1b: ["2021-2024", "2024-2026", "2026-2029"]]) == nil)
    }

    @Test func plainNamesGoToClaudeAndNothingElseDoes() throws {
        let tree = [trips: ["India", "IN-US", "Mauritius", "Singapore", "United States"],
                    root + "/Home": ["Accessories", "HOA", "2024 Refi"]]
        let named = try #require(FilingNewHome.named(parent: trips, within: root, childFolders: children(tree), isHidden: { _ in false }))
        #expect(Set(named.names) == ["India", "IN-US", "Mauritius", "Singapore", "United States"])
        let hidden = FilingNewHome.named(parent: trips, within: root, childFolders: children(tree),
                                         isHidden: { $0.hasSuffix("/Singapore") })
        #expect(hidden?.names.contains("Singapore") == false, "a hidden folder's name is never said")
        #expect(FilingNewHome.named(parent: trips, within: root, childFolders: children(tree), isHidden: { $0 == self.trips }) == nil)
        #expect(FilingNewHome.named(parent: root + "/Home", within: root, childFolders: children(tree), isHidden: { _ in false }) == nil,
                "two names beside a dated one: under three")
        #expect(FilingNewHome.named(parent: root, within: root, childFolders: children([root: ["A", "B", "C"]]), isHidden: { _ in false }) == nil,
                "never the survey's top level")
    }
}

/// TE327 through filing help: the new folder leads and the closest folder is the other choice.
@MainActor
@Suite struct FilingNewHomeHelpTests {

    private let root = "/never-on-disk-new-home-help/Documents"

    private func manager(_ id: String, folders: [String], anchors: [String: [String]]) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("FilingNewHome-\(id)")
        let entries = folders.map {
            FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [], acceptsNewFiles: nil,
                               fileCount: 2, subfolderCount: 0, axes: [:])
        }
        m.filingFolderProfile = FolderProfile(profileId: id, root: root,
                                              folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                                              personTokens: [])
        m.filingMemory = FilingMemory(profileId: id, salt: "s", folders: anchors.mapValues { words in
            FilingMemoryEntry(docs: 4, anchors: words.map { FilingMemoryToken(token: $0, weight: 4.0) }, idHashes: [])
        })
        return m
    }

    private let trip = "Travel/Trips/IN-US"
    private var years: [String] { ["2024", "2025", "2026"].map { "\(trip)/\($0)" } }

    @Test func theNewYearLeadsAndTheTripIsTheOtherChoice() async throws {
        let m = manager("lead", folders: [trip] + years, anchors: [trip: ["india", "eticket"], "Home/Utilities": ["meter"]])
        let answer = await m.whereToFile("/Users/someone/Downloads/Air India eTicket - Jan 2027.pdf", snippet: nil,
                                         isHidden: { _ in false })
        guard case .suggested(let list) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        #expect(list.count == 2)
        let new = try #require(list.first)
        #expect(new.isNew && new.relativePath == "\(trip)/2027" && new.confidence == .medium)
        #expect(new.siblings == ["2024", "2025", "2026"])
        #expect(list[1].relativePath == trip && !list[1].isNew)
        // The control: the same file without a year gets the trip alone.
        let plain = await m.whereToFile("/Users/someone/Downloads/Air India eTicket.pdf", snippet: nil, isHidden: { _ in false })
        guard case .suggested(let without) = plain.outcome else { Issue.record("no suggestion"); return }
        #expect(without.first?.relativePath == trip && without.allSatisfy { !$0.isNew })
    }

    @Test func aHiddenTripGetsNoNewYear() async {
        let m = manager("hidden", folders: [trip] + years + ["Travel/Trips"],
                        anchors: [trip: ["india", "eticket"], "Travel/Trips": ["eticket"]])
        let hidden = root + "/" + trip
        let answer = await m.whereToFile("/x/Air India eTicket - Jan 2027.pdf", snippet: nil,
                                         isHidden: { $0 == hidden || $0.hasPrefix(hidden + "/") })
        guard case .suggested(let list) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        #expect(list.allSatisfy { !$0.isNew && !$0.relativePath.hasPrefix(trip) })
    }

    @Test func namedTripsAreOfferedToClaudeWhenNoYearIs() async throws {
        let trips = ["India", "IN-US", "Mauritius", "Singapore"].map { "Travel/Trips/\($0)" }
        let m = manager("named", folders: ["Travel/Trips"] + trips, anchors: ["Travel/Trips/IN-US": ["eticket", "airline"]])
        let answer = await m.whereToFile("/x/JAL eTicket - Tokyo.pdf", snippet: nil, isHidden: { _ in false })
        let named = try #require(answer.namedSiblings)
        #expect(named.parent == root + "/Travel/Trips")
        #expect(Set(named.names) == ["India", "IN-US", "Mauritius", "Singapore"])
    }
}

/// TE327 on the card: renaming a new folder carries its files.
@Suite struct AskClaudeNewFolderRenameTests {

    private func card() -> AskClaudePlan {
        var folder = AskClaudePlan.Row(id: 0, name: "New folder “Japan”", change: .newFolder(in: "/d/Trips", name: "Japan"),
                                       ticked: true, folderLabel: "Travel › Trips")
        folder.forMoves = true
        let choices = [AskClaudePlan.Choice(label: "Travel › Trips › Japan", path: "/d/Trips/Japan"),
                       AskClaudePlan.Choice(label: "Travel › Trips › IN-US", path: "/d/Trips/IN-US")]
        return AskClaudePlan(title: "File 2", subtitle: "", rows: [
            folder,
            AskClaudePlan.Row(id: 1, name: "jal.pdf", change: .move(from: "/x/jal.pdf", toFolder: "/d/Trips/Japan"), ticked: true,
                              folderLabel: "Travel › Trips › Japan", choices: choices),
            AskClaudePlan.Row(id: 2, name: "rail.pdf", change: .move(from: "/x/rail.pdf", toFolder: "/d/Trips/Japan/Rail"), ticked: true,
                              folderLabel: "Travel › Trips › Japan › Rail"),
            AskClaudePlan.Row(id: 3, name: "w2.pdf", change: .move(from: "/x/w2.pdf", toFolder: "/d/Taxes"), ticked: true,
                              folderLabel: "Taxes")])
    }

    @Test func itsFilesFollowTheNewName() {
        var plan = card()
        #expect(plan.renameNewFolder(0, to: " Japan 2026 ", existing: { _ in nil }) == nil)
        #expect(plan.rows[0].change == .newFolder(in: "/d/Trips", name: "Japan 2026"))
        #expect(plan.rows[0].name == "New folder “Japan 2026”" && plan.rows[0].ticked)
        #expect(plan.rows[1].change == .move(from: "/x/jal.pdf", toFolder: "/d/Trips/Japan 2026"))
        #expect(plan.rows[1].folderLabel == "Travel › Trips › Japan 2026")
        #expect(plan.rows[1].choices.map(\.path) == ["/d/Trips/Japan 2026", "/d/Trips/IN-US"])
        #expect(plan.rows[2].change == .move(from: "/x/rail.pdf", toFolder: "/d/Trips/Japan 2026/Rail"))
        #expect(plan.rows[2].folderLabel == "Travel › Trips › Japan 2026 › Rail")
        #expect(plan.rows[3].change == .move(from: "/x/w2.pdf", toFolder: "/d/Taxes"), "another folder's file stays")
    }

    @Test func aTakenNameSendsTheFilesIntoThatFolder() {
        var plan = card()
        #expect(plan.renameNewFolder(0, to: "india", existing: { $0 == "/d/Trips/india" ? "/d/Trips/India" : nil }) == nil)
        #expect(plan.rows[0].refusal == "India is already there; the files go into it")
        #expect(!plan.rows[0].ticked)
        #expect(plan.rows[1].change == .move(from: "/x/jal.pdf", toFolder: "/d/Trips/India"))
        #expect(plan.runnable.allSatisfy { if case .newFolder = $0.change { false } else { true } })
    }

    @Test func aBadNameChangesNothing() {
        let before = card()
        for bad in ["", "  ", "Japan/Tokyo", "Japan: Tokyo", ".Japan", String(repeating: "a", count: 256)] {
            var plan = before
            #expect(plan.renameNewFolder(0, to: bad, existing: { _ in nil }) != nil, "\(bad)")
            #expect(plan == before)
        }
        var applied = before
        applied.state = .applied
        #expect(applied.renameNewFolder(0, to: "Japan 2026", existing: { _ in nil }) != nil)
        var move = before
        #expect(move.renameNewFolder(1, to: "x", existing: { _ in nil }) == "That row makes no folder.")
    }
}

/// TE327: what Claude is told about a new folder.
@Suite struct AskClaudeNewFolderResultTests {

    @Test func aNewFolderIsSaidToBeNewAndWhatTheCardOffers() {
        let card = AskClaudeFilingCard(fileName: "Air India - 2027.pdf", filePath: "/x/a.pdf", kind: .suggestions, folders: [
            .init(label: "iCloud › Documents › Travel › Trips › IN-US › 2027", path: "/d/IN-US/2027", confidence: "Medium",
                  reason: "Named like 2024, 2025, 2026", fromFile: false, isNew: true),
            .init(label: "iCloud › Documents › Travel › Trips › IN-US", path: "/d/IN-US", confidence: "Needs your pick",
                  reason: "Fits how this folder is used", fromFile: false)])
        let text = AskClaudeFiling.result(card, sharesFreely: false)
        #expect(text.contains("best: a new folder, iCloud › Documents › Travel › Trips › IN-US › 2027, not made yet · Medium · Named like 2024, 2025, 2026"))
        #expect(text.contains("runner-up: iCloud › Documents › Travel › Trips › IN-US · Needs your pick"))
        #expect(text.contains("Make and Move Here for the new folder"))
        #expect(text.contains("Nothing was moved or made."))
        #expect(!text.contains("/d/"))
    }

    @Test func namedSiblingsInviteANewOneOnlyOfTheSameKind() {
        let card = AskClaudeFilingCard(fileName: "jal.pdf", filePath: "/x/jal.pdf", kind: .suggestions, folders: [
            .init(label: "Travel › Trips › IN-US", path: "/d/IN-US", confidence: "Medium", reason: "Fits", fromFile: false)],
            namedSiblings: .init(label: "Travel › Trips", path: "/d/Trips", names: ["India", "Singapore"]))
        let text = AskClaudeFiling.result(card, sharesFreely: false)
        #expect(text.contains("The folders in Travel › Trips are named India, Singapore."))
        #expect(text.contains("one propose_changes card"))
        #expect(text.contains("Otherwise don’t offer one."))
        #expect(!text.contains("/d/Trips"))
    }

    @Test func aMoveIntoAFolderTheCardMakesIsSaidSo() {
        var made = AskClaudePlan.Row(id: 1, name: "New folder “2027”", change: .newFolder(in: "/d/IN-US", name: "2027"),
                                     ticked: false, folderLabel: "Travel › IN-US")
        made.forMoves = true
        let plan = AskClaudePlan(title: "File 2", subtitle: "into iCloud", rows: [
            AskClaudePlan.Row(id: 0, name: "ai.pdf", change: .move(from: "/x/ai.pdf", toFolder: "/d/IN-US/2027"), ticked: false,
                              confidence: "Medium", folderLabel: "Travel › IN-US › 2027"),
            AskClaudePlan.Row(id: 2, name: "w2.pdf", change: .move(from: "/x/w2.pdf", toFolder: "/d/Taxes"), ticked: true,
                              confidence: "High", folderLabel: "Taxes"),
            made])
        let text = AskClaudeLooseFiles.result(plan, leftHereCount: 0, nextFrom: nil)
        #expect(text.contains("ai.pdf|new folder: Travel › IN-US › 2027|Medium|not ticked|"))
        #expect(text.contains("w2.pdf|Taxes|High|ticked|"))
    }
}
