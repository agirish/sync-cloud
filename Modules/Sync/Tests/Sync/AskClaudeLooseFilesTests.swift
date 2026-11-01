import Foundation
import Testing
@testable import Sync

/// A folder's loose files for Ask Claude's filing card (TE267), on a real folder.
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

    /// Decision FZ: files at the top and in subfolders, newest first; hidden, unfinished and
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

    /// Decision GA: only a folder whose every file is on the card, and the outermost of those.
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

    /// Decision GF: the same bytes, never only the same size or name.
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

    /// Decision GE: a taken name lands numbered, as filing's own move names it.
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

    /// Decision GD: a pick from the menu moves the row to that folder's group and ticks it.
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
                                 leftHere: "Left here: 1 app or installer", more: "1–50 of 80 · 30 more: ask for the next 30")
        let text = AskClaudeLooseFiles.result(plan, leftHereCount: 1, nextFrom: 50)
        #expect(!text.contains("Boarding"))
        #expect(text.contains("jal.pdf|Travel › Trips|High|ticked|"))
        #expect(text.contains("scan.pdf|needs their pick: Health or Work|Needs your pick|not ticked|"))
        #expect(text.contains("call again with from 50"))
        #expect(text.contains("Left here: 1 app or installer"))
    }
}
