import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import Sync
import EventsTestSupport
import SwiftUI
import Design
@testable import FileExplorer

extension PDFFixtures {
    /// pdf-toolkit's corpus form (`Fixtures/acroform-fieldkinds.pdf`), copied to `path`: a nested
    /// text field, a multiline one with `/MaxLen` 200, a read-only one, a checkbox, a three-way radio
    /// group, a combo, a list, an editable combo, a signature, a push button — and `initials`, one
    /// field with a widget on each of its two pages.
    static func writeForm(_ path: String) throws {
        let source = try #require(Bundle.module.url(forResource: "acroform-fieldkinds", withExtension: "pdf",
                                                    subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
    }

    /// The corpus form re-encrypted by its owner with `permissions` — PDFKit's in-place write keeps
    /// the `/AcroForm`.
    static func writeForm(_ path: String, permissions: [PDFAccessPermissions]) throws {
        let plain = path + ".plain.pdf"
        try writeForm(plain)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: plain)))
        let bits = permissions.reduce(UInt(0)) { $0 | $1.rawValue }
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner-secret",
            .accessPermissionsOption: NSNumber(value: bits),
        ]
        try #require(document.dataRepresentation(options: options)).write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: plain)
    }

    /// The corpus form with its first page turned a quarter (`/Rotate 90`).
    static func writeRotatedForm(_ path: String) throws {
        let plain = path + ".plain.pdf"
        try writeForm(plain)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: plain)))
        document.page(at: 0)?.rotation = 90
        try #require(document.dataRepresentation()).write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: plain)
    }

    /// The corpus form with an `/XFA` entry added to its `/AcroForm`, by an appended update that
    /// rewrites the catalog (object 1) — the hybrid shape older government forms ship in.
    static func writeXFAForm(_ path: String) throws {
        let plain = path + ".plain.pdf"
        try writeForm(plain)
        var data = try Data(contentsOf: URL(fileURLWithPath: plain))
        try? FileManager.default.removeItem(atPath: plain)
        let text = String(decoding: data, as: UTF8.self)
        let catalog = try #require(text.range(of: "<< /Type /Catalog")).lowerBound
        let line = text[catalog...].prefix { $0 != "\n" }
        let withXFA = line.replacingOccurrences(of: "/AcroForm << ", with: "/AcroForm << /XFA [] ")
        try #require(withXFA != String(line))
        let startxref = try #require(text.range(of: "startxref", options: .backwards))
        let previous = text[startxref.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }
        let objectAt = data.count
        data.append(Data("1 0 obj\n\(withXFA)\nendobj\n".utf8))
        let xrefAt = data.count
        data.append(Data(("xref\n0 1\n0000000000 65535 f \n1 1\n" + String(format: "%010d", objectAt) + " 00000 n \n"
                          + "trailer\n<< /Size 83 /Root 1 0 R /Info 10 0 R /Prev \(previous) >>\nstartxref\n\(xrefAt)\n%%EOF\n").utf8))
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// **Fill & Sign on a PDF with its own form (Phase 5c)** — the fields read in the lane, filled as
/// draft state on `EditorPDFFillSign`, and saved through pdf-toolkit 0.2.0's `fillFormData` so the
/// copy's form stays fillable. A flat file keeps 5b's flattening path; `EditorPDFFillSignTests`
/// holds that, unchanged.
///
/// Serialized, because the opens and the saves take `PDFKitSerialAccess`'s one lane; every wait is
/// bounded in lane turns.
@MainActor
@Suite(.serialized) final class EditorPDFFormFieldsTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-form-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFormFieldsTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func open(_ file: String) async throws -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        // **A form is filled in place, so nothing here is ever asked "this will flatten the form".**
        // Asked anyway, the answer is no and the test says why — a real alert would wait forever.
        pdf.tools.confirm = { warning, _ in
            Issue.record("a form fill asked “\(warning.confirmationTitle)” — it took the flattening path")
            return false
        }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        return pdf
    }

    private func form(_ name: String = "W-9.pdf") async throws -> (EditorPDFDocument, String) {
        let file = path(name)
        try PDFFixtures.writeForm(file)
        return (try await open(file), file)
    }

    private func fields(at file: String) throws -> [String: FormField] {
        Dictionary(uniqueKeysWithValues: try PDFToolkit.formFields(at: URL(fileURLWithPath: file)).map { ($0.name, $0) })
    }

    // MARK: The engine

    /// **pdf-toolkit is pinned at 0.3.0 (Signature Styles' `FillSignText.font`), and every tracked
    /// `Package.resolved` that resolves it was regenerated to that tag's commit** — not hand-edited to
    /// a version a resolve would not write.
    @Test func theEngineIsPinnedAt030Everywhere() throws {
        let modules = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // FileExplorer
            .deletingLastPathComponent()                                                           // Modules
        let manifest = try String(contentsOf: modules.appendingPathComponent("FileExplorer/Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.3.0")"#))
        for package in ["FileExplorer", "Dashboard"] {
            let resolved = try String(contentsOf: modules.appendingPathComponent("\(package)/Package.resolved"), encoding: .utf8)
            let pin = try #require(resolved.range(of: "\"identity\" : \"pdf-toolkit\""), "\(package) does not resolve pdf-toolkit")
            let entry = resolved[pin.lowerBound...].prefix(400)
            #expect(entry.contains("\"version\" : \"0.3.0\""), "\(package) resolves \(entry)")
            #expect(entry.contains("3ce5d9e8ad745dbadd582d0d47121b47dac3f3fc"), "\(package) is not at 0.3.0's commit")
        }
    }

    /// **Every refusal the form path can meet reads in Edit's words.** The switch that maps them is
    /// exhaustive, so a toolkit case it does not name fails to build; this holds what each says —
    /// nothing sends the reader to PDF Utils' Password Protect or to a Fill & Sign that flattens.
    @Test func everyFormRefusalHasAReasonInEditsWords() {
        let file = URL(fileURLWithPath: "/tmp/W-9.pdf")
        let fill = EditorPDFTool.fillForm(values: ["a": .text("x")], items: [])
        let placing = EditorPDFTool.fillForm(values: [:], items: [])
        let cases: [(PDFOperationError, EditorPDFTool)] = [
            (.noFormValues, fill), (.unknownFormField("a"), fill), (.formFieldReadOnly("a"), fill),
            (.formFieldNotFillable("a"), fill), (.formValueNotAccepted(field: "a", value: "b"), fill),
            (.formFillFailed("a"), fill), (.textOnRotatedPage(pageNumber: 2), fill),
            (.permissionsForbidEditing(file), fill), (.permissionsForbidEditing(file), placing),
            // The tools' own: a restricted file's Rotate and Delete, a locked file, Clean Metadata.
            (.permissionsForbidEditing(file), .rotate(pages: [0], quarterTurns: 1)),
            (.permissionsForbidEditing(file), .deletePages([0])),
            (.encryptedInput(file), .compress(.quality(0.5))), (.metadataEncrypted, .cleanMetadata(.cleared)),
        ]
        for (error, tool) in cases {
            let reason = EditorPDFToolEngine.reason(error, tool: tool)
            #expect(!reason.isEmpty, "\(error) says nothing")
            #expect(!reason.contains("Password Protect →") && !reason.contains("Use Fill & Sign"),
                    "\(error) sends the reader to PDF Utils: \(reason)")
        }
        #expect(EditorPDFToolEngine.reason(.textOnRotatedPage(pageNumber: 2), tool: fill).contains("page 2"))
        #expect(EditorPDFToolEngine.reason(.permissionsForbidEditing(file), tool: fill).contains("doesn’t allow filling its form"))
        #expect(EditorPDFToolEngine.reason(.permissionsForbidEditing(file), tool: placing).contains("not adding text or signatures"))
        // Every other tool says what its owner forbids, and the menu that writes an unrestricted copy.
        #expect(EditorPDFToolEngine.reason(.permissionsForbidEditing(file), tool: .rotate(pages: [0], quarterTurns: 1))
                .contains("PDF Tools ▸ Remove Password…"))
        // A long value is not quoted whole.
        let long = String(repeating: "x", count: 300)
        #expect(EditorPDFToolEngine.reason(.formValueNotAccepted(field: "a", value: long), tool: fill).count < 120)
    }

    /// **The log never names a field or quotes a value** — counts and the file, as 5b's never quote words.
    @Test func theFormRefusalsLogNeitherNamesNorValues() {
        let fill = EditorPDFTool.fillForm(values: ["ssn": .text("123-45-6789")], items: [])
        let refusals: [PDFOperationError] = [
            .formValueNotAccepted(field: "ssn", value: "123-45-6789"), .unknownFormField("ssn"),
            .formFieldReadOnly("ssn"), .formFieldNotFillable("ssn"), .formFillFailed("ssn"),
        ]
        for error in refusals {
            let logged = EditorPDFToolEngine.logReason(error, tool: fill)
            #expect(!logged.contains("ssn") && !logged.contains("6789"), "\(error) logs \(logged)")
        }
        #expect(fill.logDetail == "fill form (1 field)")
        #expect(!fill.logDetail.contains("ssn"))
        #expect(fill.formLoss == nil && !fill.rebuildsDocument, "an in-place fill was said to lose the form")
    }

    // MARK: Reading the fields

    /// **The fields are read in the lane with the load, and are the toolkit's own list.**
    @Test func theFieldsAreReadInTheLaneAndAreTheToolkitsList() async throws {
        let (pdf, file) = try await form()
        let facts = try #require(pdf.facts)
        let listed = try PDFToolkit.formFields(at: URL(fileURLWithPath: file))
        #expect(facts.form.fields == listed)
        #expect(facts.form.fields.map(\.name) == [
            "applicant.name", "initials", "notes", "account", "subscribe", "plan",
            "country", "colour", "title", "size", "signature", "reset",
        ])
        #expect(!facts.form.hasXFA)
        #expect(pdf.fill.form == facts.form)
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
    }

    /// **A flat file has no form, and opens on Text as it did in 5b**; a form opens on Form Fields.
    @Test func aFormOpensOnFormFieldsAndAFlatFileOnText() async throws {
        let flat = path("Lease.pdf")
        PDFFixtures.write(flat, pages: 2)
        let lease = try await open(flat)
        #expect(lease.facts?.form == EditorPDFForm.none)
        lease.fill.toggle()
        #expect(lease.fill.armed == .text)
        #expect(!lease.fill.offersFormFields && lease.fill.offersPlacing)

        let (pdf, _) = try await form()
        pdf.fill.toggle()
        #expect(pdf.fill.armed == .formFields)
        // The twelve fields less a read-only one, a signature, a button and a list of export pairs.
        #expect(pdf.fill.form.fillable.count == 8, "\(pdf.fill.form.fillable.map(\.name))")
        #expect(pdf.fill.place(at: CGPoint(x: 100, y: 100), page: 0) == nil, "Form Fields placed an item")
    }

    @Test func anXFAFormSaysAcrobatMayShowOtherData() async throws {
        let file = path("1040.pdf")
        try PDFFixtures.writeXFAForm(file)
        let pdf = try await open(file)
        #expect(pdf.facts?.form.hasXFA == true)
        #expect(pdf.facts?.form.fields.count == 12, "the update broke the form")
        #expect(pdf.fill.formNotes == [EditorPDFFillSign.xfaNote])

        let (plain, _) = try await form()
        #expect(plain.fill.formNotes.isEmpty)
    }

    // MARK: Editing

    /// **A reload whose pages changed drops the filled fields with the items — and says so.** It
    /// used to log and announce only the items, while `clear()` took the fields too, unmentioned.
    @Test func aPageChangeThatDropsTheItemsNamesTheFieldsItClearsToo() async throws {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        let tools = EditorPDFTools()
        fill.tools = tools
        let field = FormField(name: "name", kind: .text(multiline: false), value: nil,
                              widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 20))])
        let form = EditorPDFForm(fields: [field])
        let page = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        fill.attach(path: "/tmp/reload.pdf", boxes: [page], encryption: .none, allowsFilling: true, form: form)
        fill.toggle()
        fill.beginFieldEditing("name")
        fill.typeField("Ada")
        fill.endFieldEditing()
        fill.armed = .mark(.check)
        try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0) != nil)
        try #require(fill.values.count == 1 && fill.items.count == 1)

        let log = LogCapture()
        let turned = EditorPDFPageBox(cropBox: page.cropBox, rotation: 90)
        fill.attach(path: "/tmp/reload.pdf", boxes: [turned], encryption: .none, allowsFilling: true, form: form)
        #expect(fill.values.isEmpty && fill.items.isEmpty)
        #expect(tools.banner?.message == "The file changed on disk, so the items you placed and the fields you filled were cleared.")
        #expect(await log.holds(containing: "Edit dropped 1 item placed and 1 field filled with Fill & Sign on reload.pdf in /tmp"))
    }

    /// **A reload that changed the form and the pages both says both** — the fields went first,
    /// with a banner of their own, and the items' banner then replaced it with "the items you
    /// placed" alone. And a text box opened and left empty is no work to report.
    @Test func aReloadThatChangesTheFormAndThePagesNamesBoth() throws {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        let tools = EditorPDFTools()
        fill.tools = tools
        func form(_ page: Int) -> EditorPDFForm {
            EditorPDFForm(fields: [FormField(name: "name", kind: .text(multiline: false), value: nil,
                                             widgets: [FormField.Widget(pageIndex: page, rect: CGRect(x: 10, y: 10, width: 100, height: 20))])])
        }
        let page = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        fill.attach(path: "/tmp/both.pdf", boxes: [page, page], encryption: .none, allowsFilling: true, form: form(1))
        fill.toggle()
        fill.beginFieldEditing("name")
        fill.typeField("Ada")
        fill.endFieldEditing()
        fill.armed = .mark(.check)
        try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0) != nil)
        // Page 1 removed elsewhere: the field's widget moves to page 0, and the pages change.
        fill.attach(path: "/tmp/both.pdf", boxes: [page], encryption: .none, allowsFilling: true, form: form(0))
        #expect(fill.values.isEmpty && fill.items.isEmpty)
        #expect(tools.banner?.message == "The file changed on disk, so the items you placed and the fields you filled were cleared.")

        // An empty text box alone: dropped with the pages, and nothing said about it.
        tools.banner = nil
        fill.armed = .text
        try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0) != nil)
        try #require(fill.unsaved.isEmpty && !fill.items.isEmpty, "the open box is not an empty item")
        fill.attach(path: "/tmp/both.pdf", boxes: [page, page], encryption: .none, allowsFilling: true, form: form(1))
        #expect(fill.items.isEmpty)
        #expect(tools.banner == nil, "an empty text box was reported as lost work: \(tools.banner?.message ?? "")")
    }

    /// **Every kind takes its value**: text, multiline, checkbox, radio, combo, list, and an
    /// editable combo's own words.
    @Test func everyKindEdits() async throws {
        let (pdf, _) = try await form()
        let fill = pdf.fill
        fill.toggle()
        fill.beginFieldEditing("applicant.name")
        fill.typeField("Grace Hopper")
        fill.beginFieldEditing("notes")
        fill.typeField("Line one\nLine two")
        fill.toggleCheckbox("subscribe")
        fill.selectRadio("plan", export: "pro")
        fill.choose("country", option: "Japan")
        fill.choose("colour", option: "Blue")
        fill.beginFieldEditing("title")
        fill.typeField("Prof")
        fill.endFieldEditing()
        #expect(fill.values == [
            "applicant.name": .text("Grace Hopper"), "notes": .text("Line one\nLine two"),
            "subscribe": .checked(true), "plan": .radio("pro"), "country": .choice("Japan"),
            "colour": .choice("Blue"), "title": .choice("Prof"),
        ])
        // A value typed back to the file's own is no change.
        fill.toggleCheckbox("subscribe")
        #expect(fill.values["subscribe"] == nil)
        #expect(fill.unsavedCaption == "6 fields changed")
        // A choice that is not one of a fixed list's options is not taken.
        fill.choose("country", option: "Atlantis")
        #expect(fill.values["country"] == .choice("Japan"))
    }

    /// **Tab and ⇧Tab walk the fillable fields in document order**, round the ends, and a text
    /// field takes the typing as the keyboard lands on it.
    @Test func tabFollowsTheDocument() async throws {
        let (pdf, _) = try await form()
        let fill = pdf.fill
        fill.toggle()
        var visited: [String] = []
        for _ in 0..<fill.form.fillable.count {
            fill.focusNext()
            visited.append(try #require(fill.focusedField))
        }
        #expect(visited == ["applicant.name", "initials", "notes", "subscribe", "plan", "country", "colour", "title"])
        #expect(visited == fill.form.fillable.map(\.name))
        fill.focusNext()
        #expect(fill.focusedField == "applicant.name", "Tab did not go round")
        #expect(fill.editingField == "applicant.name", "Tab onto a text field did not start the typing")
        fill.focusNext(forward: false)
        #expect(fill.focusedField == "title")
        #expect(fill.editingField == nil)
    }

    /// **A read-only field, a signature and a push button take nothing** — and say why.
    @Test func fieldsThatTakeNoValueRefuseAndSayWhy() async throws {
        let (pdf, _) = try await form()
        let fill = pdf.fill
        fill.toggle()
        fill.beginFieldEditing("account")
        fill.typeField("HACKED")
        fill.toggleCheckbox("reset")
        fill.beginFieldEditing("signature")
        #expect(fill.values.isEmpty && fill.editingField == nil)
        for name in ["account", "signature", "reset", "size"] {
            let field = try #require(fill.form.field(named: name))
            #expect(fill.fieldRefusal(field) != nil, "\(name) says nothing")
        }
        #expect(fill.fieldRefusal(try #require(fill.form.field(named: "account")))?.contains("Read-only") == true)
        #expect(fill.fieldRefusal(try #require(fill.form.field(named: "applicant.name"))) == nil)
    }

    /// **`/MaxLen` holds while typing**, and a one-line field keeps to one line.
    @Test func theMaxLengthHoldsWhileTyping() async throws {
        let (pdf, _) = try await form()
        let fill = pdf.fill
        fill.toggle()
        let notes = try #require(fill.form.field(named: "notes"))
        #expect(notes.maxLength == 200)
        fill.beginFieldEditing("notes")
        let accepted = fill.typeField(String(repeating: "a", count: 250))
        #expect(accepted.count == 200)
        #expect(fill.values["notes"] == .text(String(repeating: "a", count: 200)))
        fill.beginFieldEditing("applicant.name")
        #expect(fill.typeField("Grace\nHopper") == "Grace Hopper")
        #expect(fill.formProblem == nil, "a value the field took is one Save would refuse")
    }

    /// **Fields and placed items share the one ⌘Z stack**, step by step.
    @Test func undoTakesBackFieldsAndItemsInTurn() async throws {
        let (pdf, _) = try await form()
        let fill = pdf.fill
        fill.toggle()
        fill.beginFieldEditing("applicant.name")
        fill.typeField("Gr")
        fill.typeField("Grace")
        fill.endFieldEditing()
        fill.toggleCheckbox("subscribe")
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 300, y: 100), page: 1)
        #expect(fill.items.count == 1 && fill.values.count == 2)

        #expect(fill.undoManager.undoActionName == "Place Mark")
        fill.undoManager.undo()
        #expect(fill.items.isEmpty && fill.values.count == 2)
        #expect(fill.undoManager.undoActionName == "Check Box")
        fill.undoManager.undo()
        #expect(fill.values == ["applicant.name": .text("Grace")])
        #expect(fill.undoManager.undoActionName == "Typing", "the typing was more than one step")
        fill.undoManager.undo()
        #expect(fill.values.isEmpty)
        fill.undoManager.redo()
        #expect(fill.values == ["applicant.name": .text("Grace")])

        fill.undoManager.redo()
        fill.discard()
        #expect(fill.values.isEmpty)
        fill.undoManager.undo()
        #expect(fill.values.count == 2, "Discard's undo did not bring the fields back")
    }

    /// **The leave question counts changed fields with the placed items.**
    @Test func theLeaveQuestionCountsChangedFields() async throws {
        let (pdf, _) = try await form("Lease form.pdf")
        let fill = pdf.fill
        fill.toggle()
        fill.toggleCheckbox("subscribe")
        fill.selectRadio("plan", export: "pro")
        #expect(pdf.tools.hasWorkToLose, "changed fields are not work to lose")
        #expect(fill.unsavedCaption == "2 fields changed")
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 300, y: 100), page: 1)
        #expect(fill.unsavedCaption == "2 fields changed · 1 item not saved")

        var asked: [(String, Int)] = []
        fill.askLeaving = { asked.append(($0, $1)); return .cancel }
        #expect(!pdf.tools.mayLeave())
        #expect(asked.count == 1 && asked[0].0 == "Lease form.pdf" && asked[0].1 == 3)
        #expect(EditorPDFFillSign.leaveQuestion(name: "Lease form.pdf", count: 3, fields: 2).detail
                == "2 fields you filled and 1 item you placed aren’t saved. The original file hasn’t been changed.")
        #expect(EditorPDFFillSign.leaveQuestion(name: "x", count: 1, fields: 1).detail.hasPrefix("1 field you filled isn’t saved."))
        #expect(EditorPDFTools.leaveQuestion(running: .init(.compress(.quality(0.6))), hasArrangement: false, placedItems: 1, filledFields: 2)
                .detail.contains("The 2 fields filled with Fill & Sign are cleared too."))
    }

    // MARK: Saving a form

    /// **A form's copy is still a form**: the same fields and widgets, the values read back by the
    /// toolkit, placed items as annotations rather than page content — and the original untouched.
    @Test func savingAFormKeepsItFillable() async throws {
        let (pdf, file) = try await form()
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        let modified = try #require(EditorFileStore.stamp(ofPath: file))
        let fill = pdf.fill
        fill.toggle()
        fill.beginFieldEditing("applicant.name")
        fill.typeField("Grace Hopper")
        fill.endFieldEditing()
        fill.toggleCheckbox("subscribe")
        fill.selectRadio("plan", export: "pro")
        fill.choose("country", option: "Japan")
        fill.armed = .text
        let id = try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0))
        fill.type("NUMBAT-7", into: id)
        fill.armed = .signature(EditorPDFSignature(kind: .signature,
                                                   look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3)))
        fill.place(at: CGPoint(x: 300, y: 150), page: 1)
        #expect(fill.canSave)

        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "W-9 (signed).pdf")

        let before = try fields(at: file), after = try fields(at: copy)
        #expect(after.keys.sorted() == before.keys.sorted(), "the copy's form lost or gained fields")
        let widgetsBefore: Int = before.values.reduce(0) { $0 + $1.widgets.count }
        let widgetsAfter: Int = after.values.reduce(0) { $0 + $1.widgets.count }
        #expect(widgetsAfter == widgetsBefore, "the copy has \(widgetsAfter) widgets, the original \(widgetsBefore)")
        #expect(after["applicant.name"]?.value == "Grace Hopper")
        #expect(after["subscribe"]?.value == "Yes")
        #expect(after["plan"]?.value == "pro")
        #expect(after["country"]?.value == "Japan")
        #expect(after["notes"]?.value == before["notes"]?.value, "an untouched field changed")
        #expect(PDFToolkit.hasInteractiveForm(at: URL(fileURLWithPath: copy)), "the copy is no longer a form")

        let document = try #require(PDFDocument(url: URL(fileURLWithPath: copy)))
        let annotations = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
        #expect(annotations.contains { $0.type == "FreeText" && $0.contents == "NUMBAT-7" }, "the placed text is not an annotation")
        #expect(annotations.contains { $0.type == "Ink" }, "the signature is not an annotation")

        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original, "the original was written")
        #expect(EditorFileStore.stamp(ofPath: file) == modified, "the original's stamp moved")
        #expect(fill.values.isEmpty && fill.items.isEmpty && !fill.isOn)
        #expect(pdf.tools.banner?.kind == .wrote(copy))
    }

    /// **Fields alone make a "(filled)" copy, and a field's value never reaches the log.**
    @Test func fieldsAloneAreFilledAndNeverLogged() async throws {
        let log = LogCapture()
        let stem = "Form-\(UUID().uuidString.prefix(8))"
        let (pdf, _) = try await form("\(stem).pdf")
        pdf.fill.toggle()
        pdf.fill.beginFieldEditing("applicant.name")
        pdf.fill.typeField("QUOLL-4471")
        let outcome = await pdf.fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "\(stem) (filled).pdf")
        let entries = await log.entries
        #expect(entries.contains { $0.message.contains("Edit wrote \(stem) (filled).pdf") && $0.message.contains("fill form (1 field)") },
                "the save was not logged — the absence below would be vacuous")
        #expect(!entries.contains { $0.message.contains("QUOLL") || $0.message.contains("applicant") },
                "a value or a field's name reached the log")
    }

    // MARK: Permissions

    /// **A form whose owner forbids editing but allows filling still fills** — its fields, not marks
    /// on its pages, which it forbids — and the copy keeps the owner's restrictions.
    @Test func aRestrictedButFillableFormFills() async throws {
        let file = path("Restricted.pdf")
        try PDFFixtures.writeForm(file, permissions: [.allowsFormFieldEntry, .allowsHighQualityPrinting,
                                                      .allowsLowQualityPrinting, .allowsContentAccessibility])
        let pdf = try await open(file)
        let fill = pdf.fill
        #expect(pdf.tools.encryption == .restrictedOnly)
        #expect(fill.allowsFormEntry && !fill.allowsCommenting)
        fill.toggle()
        #expect(fill.isOn && fill.armed == .formFields)
        #expect(fill.offersFormFields && !fill.offersPlacing)
        #expect(fill.formNotes.contains(EditorPDFFillSign.noCommentingReason + "."))
        fill.armed = .text
        #expect(fill.place(at: CGPoint(x: 100, y: 100), page: 0) == nil, "text was placed on a page the owner forbids")

        fill.beginFieldEditing("applicant.name")
        fill.typeField("Grace Hopper")
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try fields(at: copy)["applicant.name"]?.value == "Grace Hopper")
        let result = try #require(PDFDocument(url: URL(fileURLWithPath: copy)))
        #expect(result.isEncrypted && !result.allowsDocumentAssembly, "the copy dropped the owner's restrictions")
        #expect(pdf.tools.banner?.message.contains("no editing restrictions") == false,
                "the banner says the copy is unrestricted when it is not")
    }

    /// **Without form entry, filling is refused with the reason** — before the lane in the model,
    /// and by the toolkit if a run is asked for anyway.
    @Test func withoutFormEntryTheFillIsRefused() async throws {
        let file = path("Locked down.pdf")
        try PDFFixtures.writeForm(file, permissions: [.allowsHighQualityPrinting, .allowsLowQualityPrinting])
        let pdf = try await open(file)
        #expect(!pdf.fill.allowsFormEntry)
        var said: [String] = []
        pdf.fill.presentRefusal = { said.append($0) }
        pdf.fill.toggle()
        #expect(!pdf.fill.isOn && said == [EditorPDFFillSign.restrictedReason])

        let tool = EditorPDFTool.fillForm(values: ["applicant.name": .text("x")], items: [])
        let outcome = await pdf.tools.run(tool)
        #expect(outcome == .failed(EditorPDFToolEngine.reason(.permissionsForbidEditing(URL(fileURLWithPath: file)), tool: tool)))
        #expect(!FileManager.default.fileExists(atPath: path("Locked down (filled).pdf")))

        // The model's own check says the same before any lane turn.
        let form = try #require(pdf.facts?.form)
        let problem = EditorPDFForm.problem(values: ["applicant.name": .text("x")], items: [], form: form,
                                            boxes: pdf.fill.boxes, allowsFormEntry: false, allowsCommenting: false,
                                            file: URL(fileURLWithPath: file))
        if case .permissionsForbidEditing? = problem {} else { Issue.record("\(String(describing: problem))") }
    }

    /// **A form with nothing to fill whose owner forbids commenting is refused** — every field
    /// read-only or a signature. It used to flatten placed items into its pages, against the "no
    /// commenting" that a form WITH a fillable field already honours by refusing them. With
    /// commenting allowed the same form keeps its form and takes the items as annotations.
    @Test(arguments: [false, true])
    func aFormWithNothingToFillTakesItemsOnlyWhereCommentingIsAllowed(commenting: Bool) async throws {
        let file = path("Signed-\(commenting)-\(UUID().uuidString.prefix(6)).pdf")
        PDFFixtures.write(file, pages: 1)
        let pdf = try await open(file)
        let fill = pdf.fill
        var said: [String] = []
        fill.presentRefusal = { said.append($0) }
        let signature = FormField(name: "sig", kind: .signature, value: nil, isFillable: false,
                                  widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 72, y: 72, width: 200, height: 30))])
        fill.attach(path: file, boxes: fill.boxes, encryption: .none, allowsFilling: true,
                    form: EditorPDFForm(fields: [signature]), allowsFormEntry: true, allowsCommenting: commenting)
        fill.toggle()
        if !commenting {
            #expect(!fill.isOn, "a form that forbids commenting and has nothing to fill took Fill & Sign")
            #expect(said == [EditorPDFFillSign.nothingToFillReason])
            #expect(fill.menuReason == EditorPDFFillSign.restrictedTitle, "the menu line is the alert's long reason")
            return
        }
        #expect(said.isEmpty && fill.isOn)
        #expect(fill.usesFormPath && fill.offersPlacing && !fill.offersFormFields)
        #expect(fill.armed == .text)
        #expect(fill.form.fields.count == 1 && fill.form.fillable.isEmpty)
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 300, y: 300), page: 0)
        #expect(fill.canSave && fill.formProblem == nil)
    }

    /// **A checkbox whose boxes carry different values is not ticked** — a Yes box and a No box
    /// under one name. A click ticked every box on screen while the copy turned on only the first
    /// value; a click on "Yes" over a "No" already on unticked the field. A one-value checkbox ticks.
    @Test func aCheckboxWhoseBoxesHaveSeparateValuesIsRefused() async throws {
        let file = path("YesNo-\(UUID().uuidString.prefix(6)).pdf")
        PDFFixtures.write(file, pages: 1)
        let pdf = try await open(file)
        let fill = pdf.fill
        let boxes = [FormField.Widget(pageIndex: 0, rect: CGRect(x: 72, y: 72, width: 12, height: 12), exportValue: "Yes"),
                     FormField.Widget(pageIndex: 0, rect: CGRect(x: 120, y: 72, width: 12, height: 12), exportValue: "No")]
        let pair = FormField(name: "agree", kind: .checkbox, value: "Off", options: ["Yes", "No"], widgets: boxes)
        let single = FormField(name: "single", kind: .checkbox, value: "Off", options: ["Yes"], widgets: [boxes[0]])
        fill.attach(path: file, boxes: fill.boxes, encryption: .none, allowsFilling: true,
                    form: EditorPDFForm(fields: [pair, single]))
        fill.toggle()
        #expect(fill.fieldRefusal(pair) == EditorPDFForm.separateBoxValuesReason)
        fill.toggleCheckbox("agree")
        #expect(fill.values.isEmpty, "a checkbox with separate values was ticked")
        #expect(fill.fieldRefusal(single) == nil)
        fill.toggleCheckbox("single")
        #expect(fill.values == ["single": .checked(true)])
        // Tab and the count leave it out too, so a form with nothing else to fill offers no fields.
        #expect(EditorPDFForm(fields: [pair, single]).fillable.map(\.name) == ["single"])
        #expect(EditorPDFForm(fields: [pair]).fillable.isEmpty)
    }

    /// **A file with no form whose owner allows only form entry is refused** — the permission covers
    /// fields it does not have, and it used to take placed items flattened into an unrestricted
    /// copy, against the "no commenting" a form already honours. Commenting allowed, it fills.
    @Test(arguments: [false, true])
    func aFileWithNoFormTakesItemsOnlyWhereCommentingIsAllowed(commenting: Bool) async throws {
        let file = path("Flat-\(commenting)-\(UUID().uuidString.prefix(6)).pdf")
        PDFFixtures.write(file, pages: 1)
        let pdf = try await open(file)
        let fill = pdf.fill
        var said: [String] = []
        fill.presentRefusal = { said.append($0) }
        fill.attach(path: file, boxes: fill.boxes, encryption: .restrictedOnly, allowsFilling: true,
                    form: .none, allowsFormEntry: true, allowsCommenting: commenting)
        fill.toggle()
        if commenting {
            #expect(said.isEmpty && fill.isOn)
        } else {
            #expect(!fill.isOn && said == [EditorPDFFillSign.restrictedReason])
            #expect(fill.menuReason == EditorPDFFillSign.restrictedTitle)
        }
    }

    /// **The real file: restricted by its owner to filling only, with every field read-only.** No
    /// synthetic form — the corpus form re-encrypted, its fields made read-only by the facts read.
    @Test func aRestrictedFormWhoseFieldsAreAllReadOnlyIsRefused() async throws {
        let file = path("Read-only restricted.pdf")
        try PDFFixtures.writeForm(file, permissions: [.allowsFormFieldEntry, .allowsHighQualityPrinting])
        let pdf = try await open(file)
        let fill = pdf.fill
        let form = try #require(pdf.facts?.form)
        let readOnly = EditorPDFForm(fields: form.fields.map { var f = $0; f.isFillable = false; return f })
        fill.attach(path: file, boxes: fill.boxes, encryption: .restrictedOnly, allowsFilling: true,
                    form: readOnly, allowsFormEntry: true, allowsCommenting: false)
        var said: [String] = []
        fill.presentRefusal = { said.append($0) }
        fill.toggle()
        #expect(!fill.isOn && said == [EditorPDFFillSign.nothingToFillReason])
        // The control: the same file with its fields as they are fills, as `aRestrictedButFillableFormFills` says.
        fill.attach(path: file, boxes: fill.boxes, encryption: .restrictedOnly, allowsFilling: true,
                    form: form, allowsFormEntry: true, allowsCommenting: false)
        #expect(fill.refusal == nil)
    }

    // MARK: Refused before the lane

    /// **Typed text on a rotated page of a form is refused up front** — said as it is placed, Save
    /// greyed, and a save asked for anyway writes nothing and takes no lane turn. A drawn signature
    /// there is fine.
    @Test func typedTextOnARotatedPageIsRefusedBeforeRunning() async throws {
        let file = path("Turned form.pdf")
        try PDFFixtures.writeRotatedForm(file)
        let pdf = try await open(file)
        let fill = pdf.fill
        #expect(fill.box(0)?.rotation == 90 && fill.form.hasFields)
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 200, y: 200), page: 0)
        let reason = EditorPDFToolEngine.reason(PDFOperationError.textOnRotatedPage(pageNumber: 1),
                                                tool: .fillForm(values: [:], items: []))
        #expect(fill.formNotes.first == reason)
        #expect(!fill.canSave)

        let log = LogCapture()
        let outcome = await fill.save()
        #expect(outcome == .failed(reason))
        #expect(pdf.tools.banner?.message == reason)
        #expect(!FileManager.default.fileExists(atPath: path("Turned form (filled).pdf")))
        let entries = await log.entries
        #expect(entries.contains { $0.message.contains("Edit refused fill form") }, "the refusal was not logged")
        #expect(fill.items.count == 1, "a refused save dropped the items")

        // The toolkit agrees, so the up-front check is its refusal and not a guess.
        let thrown = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.fillFormData(inputURL: URL(fileURLWithPath: file), values: [:],
                                        items: fill.unsaved.map { $0.toolkitItem(on: fill.box(0)!) })
        }
        if case .textOnRotatedPage(1)? = thrown {} else { Issue.record("the toolkit threw \(String(describing: thrown))") }

        fill.undoManager.undo()
        fill.armed = .signature(EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3)))
        fill.place(at: CGPoint(x: 200, y: 200), page: 0)
        #expect(fill.formNotes.isEmpty && fill.canSave, "a drawn signature on a turned page was refused")
    }

    /// **The up-front check says what the toolkit throws**, value by value.
    @Test func theUpFrontCheckIsTheToolkitsRefusal() async throws {
        let (pdf, file) = try await form()
        let form = try #require(pdf.facts?.form)
        let bad: [[String: FormFieldValue]] = [
            ["nope": .text("x")], ["account": .text("x")], ["signature": .text("x")],
            ["subscribe": .text("x")], ["notes": .text(String(repeating: "n", count: 201))],
            ["country": .choice("Atlantis")], ["plan": .radio("gold")], ["size": .choice("Large")],
        ]
        for values in bad {
            let ours = EditorPDFForm.problem(values: values, items: [], form: form, boxes: pdf.fill.boxes,
                                             allowsFormEntry: true, allowsCommenting: true, file: URL(fileURLWithPath: file))
            var theirs: PDFOperationError?
            do { _ = try PDFToolkit.fillFormData(inputURL: URL(fileURLWithPath: file), values: values) }
            catch let error as PDFOperationError { theirs = error }
            #expect(ours != nil && ours?.errorDescription == theirs?.errorDescription,
                    "\(values.keys.first!): ours \(String(describing: ours)), the toolkit's \(String(describing: theirs))")
        }
        #expect(EditorPDFForm.problem(values: ["title": .choice("Prof")], items: [], form: form, boxes: pdf.fill.boxes,
                                      allowsFormEntry: true, allowsCommenting: true, file: URL(fileURLWithPath: file)) == nil,
                "an editable combo's own words were refused")
    }

    // MARK: The menu bar

    /// File ▸ Fill & Sign's lines as AppKit builds them — `NSHostingMenu`, as the menu bar does.
    private func menuLines(_ pdf: EditorPDFDocument) -> [String] {
        let menu = NSHostingMenu(rootView: EditorPDFFillSignMenuItems(fill: pdf.fill, tools: pdf.tools))
        menu.update()
        return menu.items.map { item in
            let title = (item.state == .on ? "✓ " : "") + item.title
            return item.isEnabled ? title : "(\(title))"
        }
    }

    /// **File ▸ Save Filled Copy is live exactly where the toolbar's is** — for fields changed and
    /// nothing placed, and not while Save would be refused.
    @Test func theMenuBarsSaveFollowsTheToolbarsForAForm() async throws {
        let (pdf, _) = try await form()
        pdf.fill.toggle()
        #expect(menuLines(pdf) == ["✓ Fill & Sign", "(Save Filled Copy)"])
        pdf.fill.toggleCheckbox("subscribe")
        #expect(menuLines(pdf) == ["✓ Fill & Sign", "Save Filled Copy"], "a changed field left Save greyed")

        let file = path("Turned.pdf")
        try PDFFixtures.writeRotatedForm(file)
        let turned = try await open(file)
        turned.fill.toggle()
        turned.fill.armed = .mark(.check)
        turned.fill.place(at: CGPoint(x: 200, y: 200), page: 0)
        #expect(menuLines(turned) == ["✓ Fill & Sign", "(Save Filled Copy)"], "Save is live for what it would refuse")
    }

    /// **A greyed Save says why** — the note card's sentence as the button's tooltip, where it said
    /// what it would write. With nothing refused it says what it writes.
    @Test func aRefusedSaveSaysWhyInItsTooltip() async throws {
        let file = path("Turned help.pdf")
        try PDFFixtures.writeRotatedForm(file)
        let turned = try await open(file)
        turned.fill.toggle()
        #expect(turned.fill.saveHelp.hasPrefix("Write a copy"), "\(turned.fill.saveHelp)")
        turned.fill.armed = .text
        let id = try #require(turned.fill.place(at: CGPoint(x: 200, y: 200), page: 0))
        turned.fill.type("Ada", into: id)
        turned.fill.endEditing()
        try #require(!turned.fill.canSave, "the turned page's text was not refused, so this proves nothing")
        #expect(turned.fill.saveHelp == turned.fill.formNotes.first, "the tooltip is not the refusal: \(turned.fill.saveHelp)")
        // And the pill uses it, in the app's accent, deepened for Save's white label.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/EditorPDFFillPalette.swift"), encoding: .utf8)
        #expect(source.contains(".help(fill.saveHelp)") && source.contains(".tint(accentFill)"))
    }

    // MARK: The reader

    /// **A click in the reader never edits a field.** Before 5c a click on a text widget put
    /// PDFKit's own editor in it and typing changed the on-screen document; a click toggled a
    /// checkbox. The reader's widgets are read-only now, and draw the same.
    @Test func aClickInTheReaderNoLongerEditsAField() async throws {
        let (pdf, _) = try await form()
        let document = try #require(pdf.document)
        let page = try #require(document.page(at: 0))
        let name = try #require(page.annotations.first { $0.fieldName == "applicant.name" })
        let box = try #require(page.annotations.first { $0.fieldName == "subscribe" })
        #expect(name.isReadOnly && box.isReadOnly)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        window.contentView = reader
        reader.autoScales = false
        reader.fit = nil
        reader.document = document
        reader.scaleFactor = 1
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.go(to: name.bounds, on: page)

        func click(_ annotation: PDFAnnotation) {
            let point = reader.convert(reader.convert(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: page), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1)!)
            }
        }
        click(name)
        for _ in 0..<10 { await Task.yield() }
        for character in "XYZ" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: String(character), charactersIgnoringModifiers: String(character),
                                                  isARepeat: false, keyCode: 0)!)
            }
        }
        click(box)
        for _ in 0..<10 { await Task.yield() }
        #expect(!(window.firstResponder.map { String(describing: type(of: $0)) } ?? "").contains("Widget"),
                "PDFKit's own field editor took the keyboard")
        #expect(name.widgetStringValue == "Ada Quill", "a click and typing changed the reader's field")
        #expect(box.buttonWidgetState == .offState, "a click toggled the reader's checkbox")
        reader.document = nil
    }

    /// **A form's widgets are locked even where the catalog lost its `/AcroForm`** — the file
    /// Extract Pages… makes of a form: a page copy keeps the widgets and drops the catalog's form,
    /// PDFKit still edits them on a click, and the reader skipped such a file as having none.
    @Test func widgetsWithoutACatalogFormAreLockedToo() async throws {
        let source = path("W-9 source.pdf")
        try PDFFixtures.writeForm(source)
        let extracted = path("W-9 (page 1).pdf")
        let original = try #require(PDFDocument(url: URL(fileURLWithPath: source)))
        let copy = PDFDocument()
        copy.insert(try #require(original.page(at: 0)?.copy() as? PDFPage), at: 0)
        try #require(copy.write(to: URL(fileURLWithPath: extracted)))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: extracted))
        try #require(bytes.range(of: Data("/AcroForm".utf8)) == nil, "the copy kept its catalog form, so this proves nothing")

        let pdf = try await open(extracted)
        let page = try #require(pdf.document?.page(at: 0))
        let widgets = page.annotations.filter { $0.type == "Widget" }
        try #require(!widgets.isEmpty, "the copy lost its widgets, so this proves nothing")
        let editable = widgets.filter { !$0.isReadOnly }.count
        #expect(editable == 0, "\(editable) of \(widgets.count) widgets are still editable in the reader")
        let document = try #require(pdf.document)
        #expect(EditorPDFForm.pagesWithWidgets(document) == [0])
    }

    // MARK: The overlay

    /// **Over a real page view, the overlay fills fields**: it takes a click on a field, ticks a
    /// checkbox, opens a text field's typing field with what /MaxLen allows, offers a choice's menu,
    /// walks Tab — and says why on a field that takes nothing.
    @Test func theOverlayFillsFieldsAndSaysWhyNot() async throws {
        let (pdf, _) = try await form()
        let document = try #require(pdf.document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        window.contentView = reader
        reader.autoScales = false
        reader.fit = nil
        reader.document = document
        reader.scaleFactor = 1
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        let overlay = reader.fillOverlay
        let fill = pdf.fill

        func center(_ name: String) throws -> CGPoint {
            let widget = try #require(fill.form.field(named: name)?.widgets.first)
            reader.go(to: widget.rect, on: try #require(document.page(at: widget.pageIndex)))
            reader.layoutSubtreeIfNeeded()
            let rect = try #require(overlay.widgetRect(widget))
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint, key: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            if type == .keyDown {
                return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\t",
                                        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: key)!
            }
            return NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let box = try center("subscribe")
        #expect(overlay.hitTest(overlay.convert(box, to: reader)) == nil, "the overlay took a field's click with Fill & Sign off")

        fill.toggle()
        for _ in 0..<20 { await Task.yield() }
        #expect(overlay.hitTest(overlay.convert(box, to: reader)) === overlay)
        overlay.mouseDown(with: event(.leftMouseDown, at: box))
        #expect(fill.values["subscribe"] == .checked(true))

        // A choice offers its options, the current one ticked; picking one chooses it.
        var menus: [NSMenu] = []
        overlay.presentMenu = { menu, _, _ in menus.append(menu) }
        overlay.mouseDown(with: event(.leftMouseDown, at: try center("country")))
        let menu = try #require(menus.last)
        let country = try #require(fill.form.field(named: "country"))
        #expect(menu.items.map(\.title) == country.options)
        let japan = try #require(menu.items.first { $0.title == "Japan" })
        _ = (japan.target as AnyObject).perform(japan.action, with: japan)
        #expect(fill.values["country"] == .choice("Japan"))

        // A text field's click opens the typing field over it, and /MaxLen holds there too.
        overlay.mouseDown(with: event(.leftMouseDown, at: try center("notes")))
        for _ in 0..<20 where overlay.formEditor == nil { await Task.yield() }
        let editor = try #require(overlay.formEditor)
        #expect(fill.editingField == "notes")
        editor.stringValue = String(repeating: "b", count: 230)
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
        #expect(editor.stringValue.count == 200, "the typing field shows more than /MaxLen")

        // Tab from the typing field goes on to the next field in document order.
        let textView = NSTextView()
        #expect(overlay.control(editor, textView: textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(fill.focusedField == "subscribe" && fill.editingField == nil)
        overlay.keyDown(with: event(.keyDown, at: .zero, key: EditorPDFFillOverlay.tabKeyCode, flags: .shift))
        #expect(fill.focusedField == "notes")

        // A field that takes nothing says why on hover, and a click on it changes nothing.
        let signature = try center("signature")
        #expect(overlay.toolTip(at: signature) == fill.fieldRefusal(try #require(fill.form.field(named: "signature"))))
        #expect(overlay.toolTip(at: try center("applicant.name")) == nil)
        let before = fill.values
        overlay.mouseDown(with: event(.leftMouseDown, at: try center("account")))
        #expect(fill.values == before && fill.editingField == nil)

        reader.fillSign = nil
        reader.document = nil
    }
}
