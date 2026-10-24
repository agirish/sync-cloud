import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
@testable import FileExplorer

/// **Fill & Sign's small fixes (the 2026-10-21 Edit audit, TE165–TE193)** — the pill's and the
/// palette's words, the leave question's count and buttons, Remove Password… on the refusals, a
/// copy of a copy's name, a placed date's year, and Undo Stroke on the Draw pad. TE164 (signature
/// fields by keyboard and VoiceOver) is in `EditorPDFFillKeyboardTests`, TE189 there too, TE191 in
/// `EditorPDFFillPolishTests`.
///
/// Serialized: the PDF tests open files in `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class EditorPDFFillSmallFixesTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-small-fixes-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFillSmallFixesTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private static func source(_ file: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: TE165 — the pill's count names the button

    /// **The pill's count says the button's own words** — Save Corrected Copy with only corrections.
    @Test func thePillsCountNamesItsOwnButton() throws {
        let palette = try Self.source("EditorPDFFillPalette.swift")
        #expect(palette.contains(".help(\"Nothing is written until \\(fill.saveTitle) — the original stays as it is\")"))
        #expect(!palette.contains("Nothing is written until Save Filled Copy"))
    }

    // MARK: TE166 — the leave question

    /// **The leave question counts as the pill does** — corrections apart from items — and says
    /// "isn't" for one.
    @Test func theLeaveQuestionCountsAsThePillDoes() {
        func detail(fields: Int = 0, _ placed: [String] = []) -> String {
            EditorPDFFillSign.leaveQuestion(name: "Lease.pdf", fields: fields, placed: placed).detail
        }
        let tail = " saved. The original file hasn’t been changed."
        #expect(detail(["2 items", "1 correction"]) == "2 items and 1 correction aren’t" + tail)
        #expect(detail(["1 item"]) == "1 item isn’t" + tail)
        #expect(detail(["1 correction"]) == "1 correction isn’t" + tail)
        #expect(detail(fields: 1) == "1 field you filled isn’t" + tail)
        #expect(detail(fields: 2, ["1 item"]) == "2 fields you filled and 1 item aren’t" + tail)
        #expect(detail(fields: 1, ["2 items", "1 correction"]) == "1 field you filled, 2 items and 1 correction aren’t" + tail)
        #expect(EditorPDFFillSign.leaveQuestion(name: "Invoice.pdf", placed: ["1 correction"], corrected: true).title
                == "Save the corrected copy of “Invoice.pdf”?")
    }

    /// **The close alert's buttons** — shown top to bottom Save Filled Copy, Don't Save, Cancel;
    /// Return saves, Esc cancels, Don't Save takes ⌘D and is destructive, and only it discards.
    @Test(arguments: [false, true])
    func theLeaveAlertHasTheCloseAlertsButtons(corrected: Bool) throws {
        let alert = EditorPDFFillSign.leaveAlert(name: "Lease.pdf", placed: ["1 item"], corrected: corrected)
        let save = corrected ? "Save Corrected Copy" : "Save Filled Copy"
        #expect(alert.buttons.map(\.title) == [save, "Cancel", "Don’t Save"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        let dontSave = alert.buttons[2]
        #expect(dontSave.keyEquivalent == "d" && dontSave.keyEquivalentModifierMask == .command)
        #expect(dontSave.hasDestructiveAction && !alert.buttons[0].hasDestructiveAction)
        // As AppKit lays them out: Cancel at the foot of the stack.
        alert.layout()
        let shown = alert.buttons.sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
        #expect(shown.map(\.title) == [save, "Don’t Save", "Cancel"], "\(shown.map(\.title))")

        #expect(EditorPDFFillSign.leaveAnswer(for: .alertFirstButtonReturn) == .save)
        #expect(EditorPDFFillSign.leaveAnswer(for: .alertSecondButtonReturn) == .cancel, "Cancel discarded")
        #expect(EditorPDFFillSign.leaveAnswer(for: .alertThirdButtonReturn) == .discard)
        #expect(EditorPDFFillSign.leaveAnswer(for: .abort) == .cancel)
    }

    // MARK: TE167 — Remove Password… on the refusals

    /// **Each refusal offers Remove Password…** — Return on it, Esc on OK — unless a tool runs; and
    /// a restricted file is told no password is needed.
    @Test func theRefusalsOfferRemovePassword() throws {
        for reason in [EditorPDFFillSign.restrictedReason, EditorPDFFillSign.nothingToFillReason, EditorPDFTools.lockedReason] {
            let alert = EditorPDFFillSign.refusalAlert(reason, offersRemovePassword: true)
            #expect(alert.buttons.map(\.title) == ["Remove Password…", "OK"])
            #expect(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent == "\u{1b}")
            #expect(EditorPDFFillSign.refusalAlert(reason, offersRemovePassword: false).buttons.map(\.title) == ["OK"])
        }
        #expect(EditorPDFFillSign.refusalAlert(EditorPDFFillSign.restrictedReason, offersRemovePassword: true).messageText
                == "This PDF doesn’t allow filling")
        #expect(EditorPDFFillSign.refusalAlert(EditorPDFTools.lockedReason, offersRemovePassword: true).messageText
                == "Fill & Sign isn’t available for this PDF")
        #expect(EditorPDFFillSign.restrictedReason
                == "Its owner restricted editing, so Fill & Sign is off for it. PDF Tools ▸ Remove Password… writes a copy without the restrictions.")
        #expect(EditorPDFFillSign.nothingToFillReason.hasSuffix(". PDF Tools ▸ Remove Password… writes a copy without the restrictions."))
        #expect(EditorPDFTools.lockedReason == "Remove the password first. That writes an unlocked copy.")
        let fillBanner = EditorPDFToolEngine.reason(.permissionsForbidEditing(URL(fileURLWithPath: "/a/Lease.pdf")),
                                                    tool: .fillForm(values: ["name": .text("Ada")], items: []))
        #expect(fillBanner == "“Lease.pdf”’s owner doesn’t allow filling its form. PDF Tools ▸ Remove Password… writes a copy without the restrictions.")
        let pageBanner = EditorPDFToolEngine.reason(.permissionsForbidEditing(URL(fileURLWithPath: "/a/Lease.pdf")),
                                                    tool: .rotate(pages: [0], quarterTurns: 1))
        #expect(!pageBanner.contains("if you know the password"), "\(pageBanner)")
    }

    /// **A restricted file's Fill & Sign offers Remove Password…** — the file takes it and nothing
    /// is running; with no PDF there is nothing to offer.
    @Test func aRestrictedFileOffersRemovePassword() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.writeRestricted(file)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        var said: [String] = []
        pdf.fill.presentRefusal = { said.append($0) }
        pdf.fill.toggle()
        #expect(said == [EditorPDFFillSign.restrictedReason] && !pdf.fill.isOn)
        #expect(pdf.fill.offersRemovePassword)
        #expect(!EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults)).offersRemovePassword)
        pdf.close()
    }

    // MARK: TE168 — the palette's tooltips say Return places

    @Test func thePlacingToolsSayReturnPlacesToo() {
        typealias Palette = EditorPDFFillPalette
        #expect(Palette.hint(.text) == "Text — click on the page, or press Return, to type")
        #expect(Palette.hint(.date) == "Date — click, or press Return, to place today’s date")
        #expect(Palette.hint(.marks) == "Marks — ✓, ✗ or •, then click on the page, or press Return, to place it")
        #expect(Palette.hint(.signature) == "Signature — choose a saved one, or add one; then click, or press Return, to place it")
        #expect(Palette.hint(.initials) == "Initials — choose a saved one, or add one; then click, or press Return, to place it")
        #expect(!Palette.hint(.replace).contains("Return"), "Replace places nothing by Return")
    }

    // MARK: TE190 — a copy of a copy

    /// **A name that already says the word is not told again** — the keep-both rule numbers it.
    @Test func aCopyOfACopyIsNumberedNotSuffixedTwice() {
        func first(_ name: String, _ suffix: String = "signed") -> String {
            (EditorPDFCopyName.firstChoice(for: "/a/" + name, suffix: suffix) as NSString).lastPathComponent
        }
        #expect(first("Lease (signed).pdf") == "Lease (signed).pdf")
        #expect(first("Lease (signed) 2.pdf") == "Lease (signed).pdf")
        #expect(first("Lease (signed) 12.pdf") == "Lease (signed).pdf")
        #expect(first("Lease (rotated).pdf") == "Lease (rotated) (signed).pdf")
        #expect(first("Lease (signed) (rotated).pdf") == "Lease (signed) (rotated) (signed).pdf")
        #expect(first("Lease 2.pdf") == "Lease 2 (signed).pdf")
        #expect(first("Lease (signed)2.pdf") == "Lease (signed)2 (signed).pdf")
        #expect(first("Lease (signed) x.pdf") == "Lease (signed) x (signed).pdf")
        #expect(first("(signed).pdf") == "(signed) (signed).pdf")
        #expect(first("Invoice (reordered, rotated).pdf", "reordered, rotated") == "Invoice (reordered, rotated).pdf")
        #expect(first("Lease (pages removed) 3.pdf", "pages removed") == "Lease (pages removed).pdf")
        // Delete's word by count is one word: either spelling is replaced, not told again (Y6).
        let one = EditorPDFTool.deletePages([0]).suffix, two = EditorPDFTool.deletePages([0, 1]).suffix
        #expect((one, two) == ("page removed", "pages removed"))
        #expect(first("Lease (pages removed).pdf", one) == "Lease (page removed).pdf")
        #expect(first("Lease (page removed).pdf", two) == "Lease (pages removed).pdf")
        #expect(first("Lease (pages removed) 2.pdf", one) == "Lease (page removed).pdf")
        #expect(first("Four (reordered, pages removed).pdf", "reordered, page removed") == "Four (reordered, page removed).pdf")
        #expect(first("Four (reordered, page removed).pdf", "reordered, pages removed") == "Four (reordered, pages removed).pdf")
        // Only Delete's word has two spellings, and only as a whole word.
        #expect(first("Lease (pages removed).pdf", "rotated") == "Lease (pages removed) (rotated).pdf")
        #expect(first("Lease (unpages removed).pdf", one) == "Lease (unpages removed) (page removed).pdf")
    }

    /// **On disk: signing "Lease (signed).pdf" writes "Lease (signed) 2.pdf", then "… 3.pdf"** —
    /// the original is never written over.
    @Test func signingASignedCopyTakesTheNextFreeNumber() throws {
        let original = path("Lease (signed).pdf")
        try Data("original".utf8).write(to: URL(fileURLWithPath: original))
        let second = try EditorPDFCopyWriter.write(Data("2".utf8), besides: original, suffix: "signed")
        #expect((second as NSString).lastPathComponent == "Lease (signed) 2.pdf")
        let third = try EditorPDFCopyWriter.write(Data("3".utf8), besides: second, suffix: "signed")
        #expect((third as NSString).lastPathComponent == "Lease (signed) 3.pdf")
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "original")
    }

    // MARK: TE192 — a four-digit year

    /// **Only a two-letter year widens** — outside quotes; "yyyy", "y" and quoted text stay.
    @Test func onlyATwoDigitYearWidens() {
        let widen = EditorPDFFillSign.fourDigitYear
        #expect(widen("M/d/yy") == "M/d/yyyy")
        #expect(widen("dd.MM.yy") == "dd.MM.yyyy")
        #expect(widen("dd/MM/yyyy") == "dd/MM/yyyy")
        #expect(widen("d/M/y") == "d/M/y")
        #expect(widen("yy-MM-dd 'yy' yy") == "yyyy-MM-dd 'yy' yyyy")
        #expect(widen("d 'o''clock' yy") == "d 'o''clock' yyyy")
        #expect(widen("yyy") == "yyy")
    }

    /// **"10/17/2026" in the US** — the short format, which gives "10/17/26", with its year widened;
    /// another country keeps its own order.
    @Test func aPlacedDateHasAFourDigitYear() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: utc,
                                               year: 2026, month: 10, day: 17, hour: 12).date)
        let short = DateFormatter()
        short.locale = Locale(identifier: "en_US")
        short.timeZone = utc
        short.dateStyle = .short
        try #require(short.string(from: date) == "10/17/26", "the US short format no longer has a two-digit year")
        #expect(EditorPDFFillSign.placedDate(date, locale: Locale(identifier: "en_US"), timeZone: utc) == "10/17/2026")
        #expect(EditorPDFFillSign.placedDate(date, locale: Locale(identifier: "de_DE"), timeZone: utc) == "17.10.2026")
        #expect(EditorPDFFillSign.placedDate(date, locale: Locale(identifier: "en_GB"), timeZone: utc) == "17/10/2026")
        #expect(EditorPDFFillSign.placedDate(date, locale: Locale(identifier: "ja_JP"), timeZone: utc) == "2026/10/17")
    }

    // MARK: TE193 — Undo Stroke

    /// **⌘Z takes back the last stroke on Draw** — one at a time, and nothing once none is left.
    /// The button's own state is read from the source: SwiftUI builds no accessibility tree for a
    /// hosted view under `swift test` (`ColumnPreviewEditorButtonTests`), so its buttons can't be
    /// found or pressed here.
    @Test func undoStrokeTakesBackTheLastStroke() async throws {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        let host = NSHostingView(rootView: EditorPDFAddSignatureSheet(fill: fill, kind: .signature, drawing: true))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.buryUnderEverything()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func pads(in view: NSView) -> [EditorPDFSignaturePad.PadView] {
            ((view as? EditorPDFSignaturePad.PadView).map { [$0] } ?? []) + view.subviews.flatMap(pads(in:))
        }
        func settle() async throws {
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let commandZ = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "z",
                                                     charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        try await settle()
        let pad = try #require(pads(in: host).first, "the sheet didn't open on Draw")
        for x: CGFloat in [20, 80, 140] {
            pad.strokes.append([CGPoint(x: x, y: 40), CGPoint(x: x + 20, y: 60)])
            pad.onChange?(pad.strokes)
        }
        try await settle()
        #expect(window.performKeyEquivalent(with: commandZ), "⌘Z did nothing on Draw")
        try await settle()
        #expect(pad.strokes.map { $0[0].x } == [20, 80], "⌘Z didn't take back the last stroke: \(pad.strokes)")
        _ = window.performKeyEquivalent(with: commandZ)
        _ = window.performKeyEquivalent(with: commandZ)
        try await settle()
        #expect(pad.strokes.isEmpty)
        _ = window.performKeyEquivalent(with: commandZ)
        try await settle()
        #expect(pad.strokes.isEmpty, "⌘Z with no strokes brought something back")

        // Only on Draw, greyed with no strokes; Clear keeps no history for it to bring back.
        let sheet = try Self.source("EditorPDFSignatureSheet.swift")
        // Compared with the whitespace folded, so a re-indent doesn't fail it.
        let folded = sheet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(folded.contains("if !typing { Button(Self.undoStrokeTitle) { _ = strokes.popLast() } "
                                + ".keyboardShortcut(\"z\", modifiers: .command) .disabled(strokes.isEmpty)"),
                "Undo Stroke isn't Draw-only, ⌘Z and greyed with no strokes")
        #expect(sheet.contains("Button(\"Clear\") { if typing { typed = \"\" } else { strokes = [] } }"),
                "Clear changed — Undo Stroke must not bring a cleared drawing back")
    }
}
