import Foundation
import Testing
@testable import SyncCloud
import Sync
import AppKit
import SwiftUI

/// Reading a file for its name (TE328): which files are read, what each refusal says, and what
/// reaches the model. The model and the reader are stand-ins; `ContentNameTests` covers the name.
@MainActor @Suite struct AskClaudeNamingTests {

    private final class Asked: @unchecked Sendable {
        var pages: [String] = []
    }

    private func read(_ pages: [String], locked: Bool = false) -> @Sendable (String) async -> AskClaudeReading.Read? {
        { _ in
            var read = AskClaudeReading.Read(pages: pages, pageCount: pages.count)
            read.locked = locked
            return read
        }
    }

    private let named = AskClaudeNaming.Outcome.named(.init(year: 2025, month: 2, from: "Ally", what: "1099-INT"))

    @Test func eachFileThatIsntReadSaysWhy() async {
        let ready: @Sendable () async -> AskClaudeNaming.Availability = { .ready }
        let answer: @MainActor (String, String) async -> AskClaudeNaming.Outcome? = { _, _ in self.named }
        #expect(await AskClaudeNaming.facts(for: "/d/IMG_2231.HEIC", available: ready, read: read(["Receipt"]), ask: answer) == .picture)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0042.pdf", available: { .off }, read: read(["Ally"]), ask: answer) == .unavailable)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0044.pdf", available: ready, read: read([""], locked: true), ask: answer) == .locked)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0045.pdf", available: ready, read: read(["  ", "Page two words"]), ask: answer) == .noWords)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0045.pdf", available: ready, read: { _ in nil }, ask: answer) == .noWords)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0046.pdf", available: ready, read: read(["Some words on a page of plain text"]),
                                           ask: { _, _ in nil }) == .notSure)
        #expect(await AskClaudeNaming.facts(for: "/d/Scan 0042.pdf", available: ready, read: read(["Ally Bank Form 1099-INT for tax year 2025"]), ask: answer) == named)
    }

    /// Page 1 only, trimmed, and capped: page 2 never reaches the model.
    @Test func onlyPageOneReachesTheModel() async {
        let asked = Asked()
        let long = String(repeating: "x", count: 5_000)
        _ = await AskClaudeNaming.facts(for: "/d/Scan 0042.pdf", available: { .ready }, read: read(["  \(long)  ", "PAGE TWO"]),
                                        ask: { page, _ in asked.pages.append(page); return nil })
        #expect(asked.pages == [String(long.prefix(AskClaudeNaming.pageCharacters))])
    }

    @Test func theModelsAnswerIsCheckedBeforeItNamesAnything() {
        #expect(AskClaudeNaming.outcome(isDocument: false, year: 2025, month: 2, day: 0, from: "Ally", what: "1099-INT") == .notSure)
        #expect(AskClaudeNaming.outcome(isDocument: true, year: 0, month: 2, day: 0, from: "Ally", what: "1099-INT") == .notSure)
        #expect(AskClaudeNaming.outcome(isDocument: true, year: 2025, month: 2, day: 0, from: " ", what: "") == .notSure)
        #expect(AskClaudeNaming.outcome(isDocument: true, year: 2025, month: 13, day: 15, from: "Ally", what: "Statement")
                == .named(.init(year: 2025, from: "Ally", what: "Statement")))
        #expect(AskClaudeNaming.outcome(isDocument: true, year: 2025, month: 11, day: 15, from: " Acme ", what: "Earnings Statement")
                == .named(.init(year: 2025, month: 11, day: 15, from: "Acme", what: "Earnings Statement")))
    }

    /// What Claude hears names no word from inside the file.
    @Test func whatClaudeIsToldSaysNothingFromInside() {
        #expect(named.told == "a new name made on their Mac")
        #expect(AskClaudeNaming.Outcome.locked.told == "keeps its name: locked, so it couldn’t be read")
    }
}

/// The name views on the cards (TE328) fit the narrowest panel and draw. Pictures are written to
/// `ASK_CLAUDE_CARD_SHOTS` when it names a folder, for looking at.
@MainActor @Suite struct AskClaudeNamingViewTests {

    private func row(named: Bool) -> AskClaudePlan.Row {
        var row = AskClaudePlan.Row(id: 0, name: "Scan 0042.pdf", change: .move(from: "/d/Scan 0042.pdf", toFolder: "/r/Taxes"), ticked: true)
        if named {
            row.newName = "2025 Ally Bank 1099-INT Corrected.pdf"
            row.nameBasis = "Named like 2024 Ally Bank 1099-INT.pdf"
        } else {
            row.nameKept = AskClaudeNaming.Outcome.locked.keptReason
        }
        return row
    }

    private func views() -> [(String, AnyView)] {
        var folder = AskClaudeFilingCard.Folder(label: "iCloud › Taxes › 2025", path: "/r/Taxes/2025", confidence: "High", reason: "Like its neighbours", fromFile: false)
        folder.newName = "2025 Ally 1099-INT.pdf"
        folder.nameBasis = "Named like 2024 Ally 1099-INT.pdf"
        return [
            ("row-named", AnyView(AskClaudeRowNameLine(row: row(named: true)))),
            ("row-kept", AnyView(AskClaudeRowNameLine(row: row(named: false)))),
            ("details", AnyView(AskClaudeNameDetails(row: row(named: true), editable: true) { _ in })),
            ("folder", AnyView(AskClaudeFolderNameLine(folder: folder))),
            ("held", AnyView(AskClaudeHeldNamesStrip(names: .init(), count: 2, canShare: true) {})),
            ("shared", AnyView(AskClaudeHeldNamesStrip(names: .init(shared: true), count: 2, canShare: true) {})),
            ("shares-freely", AnyView(AskClaudeHeldNamesStrip(names: .init(shared: true, sharedBy: "Downloads"), count: 1, canShare: true) {})),
            ("off", AnyView(AskClaudeHeldNamesStrip(names: .init(unavailable: AskClaudeNaming.Availability.off.cardLine), count: 0, canShare: true) {})),
        ]
    }

    @Test func eachFitsTheNarrowestPanelAndDraws() throws {
        for (name, view) in views() {
            let controller = NSHostingController(rootView: view.frame(width: 240))
            let size = controller.sizeThatFits(in: CGSize(width: 240, height: 2_000))
            #expect(size.width <= 240 && size.height > 8, "\(name): \(size)")
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
            let rep = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            if let folder = ProcessInfo.processInfo.environment["ASK_CLAUDE_CARD_SHOTS"],
               let png = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("names-\(name).png"))
            }
        }
    }
}
