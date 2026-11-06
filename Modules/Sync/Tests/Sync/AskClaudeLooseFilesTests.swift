import Foundation
import Testing
@testable import Sync

/// A folder's loose files for Ask Claude's filing card, on a real folder.
@Suite struct AskClaudeLooseFilesTests {

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ path: String, _ text: String = "x", modified: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
    }

    /// Files at the top and in subfolders, newest first; hidden, unfinished and
    /// inside-a-package skipped; installers kept apart.
    @Test func looseFilesAreEveryFileAtAnyDepthLessTheSkipped() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try write(dir + "/Old.pdf", modified: day)
        try write(dir + "/New.pdf", modified: day.addingTimeInterval(86_400))
        try write(dir + "/Scans/scan1.pdf", modified: day.addingTimeInterval(3_600))
        try write(dir + "/Scans/Deeper/scan2.pdf", modified: day.addingTimeInterval(7_200))
        try write(dir + "/.hidden.pdf")
        try write(dir + "/.git/config")
        try write(dir + "/movie.mp4.crdownload")
        try write(dir + "/Installer.dmg")
        try write(dir + "/Notes.rtfd/TXT.rtf")
        try write(dir + "/Private/secret.pdf")
        try FileManager.default.setAttributes([.modificationDate: day.addingTimeInterval(1_800)], ofItemAtPath: dir + "/Notes.rtfd")
        let found = AskClaudeLooseFiles.collect(in: dir, isHidden: { $0 == dir + "/Private" })
        #expect(found.files.map(\.name) == ["New.pdf", "scan2.pdf", "scan1.pdf", "Notes.rtfd", "Old.pdf"])
        #expect(found.files.contains { $0.path == dir + "/Scans/Deeper/scan2.pdf" }, "spelled as walked")
        #expect(found.installers.map(\.name) == ["Installer.dmg"])
        #expect(found.unfinished == 1 && found.hidden == 1)
        #expect(found.topLevel == 3 && found.subfolders == 1)
        #expect(found.emptiable[dir + "/Scans"] == true)
        #expect(found.emptiable[dir + "/Private"] == nil, "a hidden folder isn’t walked")
    }

    @Test func theWalkStopsAtItsLimitAndSaysSo() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for i in 0..<5 { try write(dir + "/f\(i).txt") }
        let found = AskClaudeLooseFiles.collect(in: dir, isHidden: { _ in false }, limit: 3)
        #expect(found.files.count == 3 && found.truncated)
    }

    /// Only a folder whose every file is on the card, and the outermost of those.
    @Test func emptiedFoldersAreThoseWhoseEveryFileIsOnTheCard() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/Trip/a.pdf")
        try write(dir + "/Trip/Inner/b.pdf")
        try write(dir + "/Mixed/c.pdf")
        try write(dir + "/Mixed/setup.pkg")
        try write(dir + "/Half/d.pdf")
        try write(dir + "/Half/e.pdf")
        let found = AskClaudeLooseFiles.collect(in: dir, isHidden: { _ in false })
        let onCard: Set<String> = [dir + "/Trip/a.pdf", dir + "/Trip/Inner/b.pdf", dir + "/Mixed/c.pdf", dir + "/Half/d.pdf"]
        #expect(AskClaudeLooseFiles.emptiedFolders(found, onCard: onCard) == [dir + "/Trip"])
        #expect(AskClaudeLooseFiles.emptiedFolders(found, onCard: onCard.union([dir + "/Half/e.pdf"])) == [dir + "/Half", dir + "/Trip"])
    }

    /// The same bytes, never only the same size or name.
    @Test func theSameFileIsFoundByItsBytes() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/Downloads/Statement.pdf", "statement-september")
        try write(dir + "/Bank/Chase Sep.pdf", "statement-september")
        try write(dir + "/Bank/Statement.pdf", "statement-august!!!")
        let size = "statement-september".utf8.count
        #expect(AskClaudeLooseFiles.sameFile(as: dir + "/Downloads/Statement.pdf", in: dir + "/Bank", size: size,
                                             isCloudOnly: { _ in false }) == dir + "/Bank/Chase Sep.pdf")
        try write(dir + "/Other/x.pdf", "statement-septembeR")
        #expect(AskClaudeLooseFiles.sameFile(as: dir + "/Downloads/Statement.pdf", in: dir + "/Other", size: size,
                                             isCloudOnly: { _ in false }) == nil, "same size, other bytes")
        #expect(AskClaudeLooseFiles.sameFile(as: dir + "/Downloads/Statement.pdf", in: dir + "/Bank", size: size,
                                             isCloudOnly: { $0.hasSuffix("Chase Sep.pdf") }) == nil, "a cloud-only file is never read")
    }

    /// The file itself under another spelling (iCloud's Documents is a link to ~/Documents) is
    /// never its own copy, and its own folder offers none.
    @Test func aFileIsNeverItsOwnCopyThroughALink() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/Documents/Scans/scan.pdf", "scan")
        try write(dir + "/Documents/Scans/scan copy.pdf", "scan")
        try FileManager.default.createSymbolicLink(atPath: dir + "/CloudDocs", withDestinationPath: dir + "/Documents")
        let viaLink = dir + "/CloudDocs/Scans/scan.pdf"
        #expect(AskClaudeLooseFiles.sameFile(as: viaLink, in: dir + "/Documents/Scans", size: 4, isCloudOnly: { _ in false }) == nil)
        #expect(AskClaudeLooseFiles.sameFile(as: viaLink, in: dir + "/CloudDocs/Scans", size: 4, isCloudOnly: { _ in false }) == nil)
        try write(dir + "/Documents/Filed/scan.pdf", "scan")
        try FileManager.default.linkItem(atPath: dir + "/Documents/Scans/scan.pdf", toPath: dir + "/Documents/Filed/hard.pdf")
        #expect(AskClaudeLooseFiles.sameFile(as: viaLink, in: dir + "/Documents/Filed", size: 4, isCloudOnly: { _ in false })
                == dir + "/Documents/Filed/scan.pdf", "a hard link is the file itself; the real copy is found")
    }

    /// After a card is applied, the next card is the files no card showed, however many moved.
    @Test func theNextCardIsTheFilesNoCardShowed() {
        let files = (0..<25).map { AskClaudeLooseFiles.File(path: "/d/f\($0)", name: "f\($0)", size: 1, modified: nil) }
        let first = AskClaudeLooseFiles.page(files, from: 0, shown: [])
        #expect(first.files.map(\.name) == (0..<10).map { "f\($0)" } && first.total == 25)
        // Three of the first ten moved away; the list is collected again without them.
        let left = files.filter { !["f1", "f4", "f7"].contains($0.name) }
        let next = AskClaudeLooseFiles.page(left, from: 10, shown: Set(first.files.map(\.path)))
        #expect(next.files.map(\.name) == (10..<20).map { "f\($0)" } && next.total == 25)
        // No card showed any: from counts from the start.
        #expect(AskClaudeLooseFiles.page(files, from: 20, shown: []).files.map(\.name) == (20..<25).map { "f\($0)" })
    }

    /// Two files of one name going to one folder both land under their own name, said on each
    /// row, and a pick from the menu says the new folder's.
    @Test func eachRowSaysTheNameItLandsUnderAfterTheRowsAbove() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/Trips/Ticket.pdf")
        try FileManager.default.createDirectory(atPath: dir + "/Work", withIntermediateDirectories: true)
        func move(_ id: Int, _ from: String, to: String) -> AskClaudePlan.Row {
            AskClaudePlan.Row(id: id, name: "Ticket.pdf", change: .move(from: from, toFolder: to), ticked: true,
                              note: "Outside Travel", folderLabel: (to as NSString).lastPathComponent)
        }
        var plan = AskClaudePlan(title: "", subtitle: "", rows: [move(0, dir + "/a/Ticket.pdf", to: dir + "/Work"),
                                                                 move(1, dir + "/b/Ticket.pdf", to: dir + "/Work"),
                                                                 move(2, dir + "/c/Ticket.pdf", to: dir + "/Trips")])
        plan.noteLandingNames()
        #expect(plan.rows.map(\.note) == ["Outside Travel", "Kept as Ticket 2.pdf: the name is taken · Outside Travel",
                                          "Kept as Ticket 2.pdf: the name is taken · Outside Travel"])
        plan.choose(.init(label: "Trips", path: dir + "/Trips"), forRow: 0)
        #expect(plan.rows.map(\.note) == ["Kept as Ticket 2.pdf: the name is taken", "Outside Travel",
                                          "Kept as Ticket 3.pdf: the name is taken · Outside Travel"])
        plan.setTicked(false, row: 0)
        #expect(plan.rows[2].note == "Kept as Ticket 2.pdf: the name is taken · Outside Travel", "an unticked row takes no name")
    }

    /// A folder the card makes for its moves is ticked only while a ticked move goes into it.
    @Test func aNewFolderForTheMovesFollowsTheirTicks() {
        var made = AskClaudePlan.Row(id: 1, name: "New folder “Oct”", change: .newFolder(in: "/t/2026", name: "Oct"), ticked: true)
        made.forMoves = true
        var plan = AskClaudePlan(title: "", subtitle: "", rows: [
            AskClaudePlan.Row(id: 0, name: "a.pdf", change: .move(from: "/d/a.pdf", toFolder: "/t/2026/Oct"), ticked: true), made])
        plan.setTicked(false, row: 0)
        #expect(plan.rows[1].ticked == false)
        plan.setTicked(true, row: 0)
        #expect(plan.rows[1].ticked == true)
        plan.choose(.init(label: "Work", path: "/t/Work"), forRow: 0)
        #expect(plan.rows[1].ticked == false, "no move goes into it now")
    }

    /// A card saved before a copy named its twin still reads.
    @Test func aSavedTrashRowWithoutItsTwinStillReads() throws {
        let old = #"{"trash":{"path":"\/d\/s.pdf"}}"#
        let change = try JSONDecoder().decode(AskClaudePlan.Change.self, from: Data(old.utf8))
        #expect(change == .trash(path: "/d/s.pdf"))
        let twin = AskClaudePlan.Change.trash(path: "/d/s.pdf", copyOf: "/b/s.pdf")
        #expect(try JSONDecoder().decode(AskClaudePlan.Change.self, from: JSONEncoder().encode(twin)) == twin)
    }

    /// A taken name lands numbered, as filing's own move names it.
    @Test func aTakenNameLandsNumbered() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/Trips/Ticket.pdf")
        #expect(AskClaudeLooseFiles.landingName(for: "Ticket.pdf", in: dir + "/Trips") == "Ticket 2.pdf")
        #expect(AskClaudeLooseFiles.landingName(for: "Hotel.pdf", in: dir + "/Trips") == "Hotel.pdf")
    }

    private func row(_ id: Int, _ name: String, to label: String, confidence: FilingConfidence, ticked: Bool) -> AskClaudePlan.Row {
        AskClaudePlan.Row(id: id, name: name, change: .move(from: "/d/" + name, toFolder: "/docs/" + label), ticked: ticked,
                          confidence: AskClaudeFiling.label(confidence), reason: "Matched “Boarding” read from the file",
                          folderLabel: label,
                          choices: [.init(label: label, path: "/docs/" + label), .init(label: "Work", path: "/docs/Work", confidence: "Medium")])
    }

    @Test func rowsAreGroupedByFolderThenPickThenTrash() {
        let plan = AskClaudePlan(title: "File 5", subtitle: "into Documents", rows: [
            row(0, "a.pdf", to: "Taxes", confidence: .high, ticked: true),
            row(1, "b.pdf", to: "Trips", confidence: .high, ticked: true),
            row(2, "c.pdf", to: "Trips", confidence: .medium, ticked: false),
            row(3, "d.pdf", to: "Health", confidence: .low, ticked: false),
            AskClaudePlan.Row(id: 4, name: "Move 1 emptied folder to Trash", change: .trashIfEmptied(folders: ["/d/X"]), ticked: false),
            AskClaudePlan.Row(id: 5, name: "s.pdf", change: .trash(path: "/d/s.pdf"), ticked: false, alreadyFiled: true),
        ])
        #expect(plan.groups.map(\.group) == [.folder("Trips"), .folder("Taxes"), .needsPick, .alreadyFiled, .emptied])
        #expect(plan.tickedCount == 2)
    }

    /// A pick from the menu moves the row to that folder's group and ticks it.
    @Test func choosingAFolderMovesTheRowAndTicksIt() {
        var plan = AskClaudePlan(title: "", subtitle: "", rows: [row(0, "d.pdf", to: "Health", confidence: .low, ticked: false)])
        #expect(plan.groups.map(\.group) == [.needsPick])
        plan.choose(.init(label: "Work", path: "/docs/Work", confidence: "Medium"), forRow: 0)
        #expect(plan.rows[0].change == .move(from: "/d/d.pdf", toFolder: "/docs/Work"))
        #expect(plan.rows[0].ticked && plan.groups.map(\.group) == [.folder("Work")])
    }

    /// Claude hears folders, confidence and ticks; never a reason, which can name a word read
    /// from the file.
    @Test func claudeIsToldTheRowsWithoutTheirReasons() {
        let plan = AskClaudePlan(title: "File 2 Loose Files", subtitle: "into iCloud › Documents",
                                 rows: [row(0, "jal.pdf", to: "Travel › Trips", confidence: .high, ticked: true),
                                        row(1, "scan.pdf", to: "Health", confidence: .low, ticked: false)],
                                 leftHere: "Left here: 1 app or installer", more: "1–50 of 80 · 30 more")
        let text = AskClaudeLooseFiles.result(plan, leftHereCount: 1, nextFrom: 50)
        #expect(!text.contains("Boarding"))
        #expect(text.contains("jal.pdf|Travel › Trips|High|ticked|"))
        #expect(text.contains("scan.pdf|needs their pick: Health or Work|Needs your pick|not ticked|"))
        #expect(text.contains("call again with the same folder and into, and from 50"))
        #expect(text.contains("Left here: 1 app or installer"))
    }
}
