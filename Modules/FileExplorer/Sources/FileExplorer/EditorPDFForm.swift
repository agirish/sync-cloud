import CoreGraphics
import Foundation
import PDFKit
import PDFToolkitCore

/// **A PDF's own interactive form, as Fill & Sign's Form Fields tool sees it** (Phase 5c, mockup 19).
///
/// Read in the lane with the facts (``EditorPDFFacts/read(_:path:)``) by pdf-toolkit's
/// `formFields(at:)`: every field, in document order, with its kind, value, options, `/MaxLen`,
/// whether it can be filled, and each widget's page and rect in page space. Nothing here is drawn
/// by PDFKit or typed into the reader's document — the overlay draws the fields from these rects,
/// the values the reader types are draft state on ``EditorPDFFillSign``, and Save hands them to
/// `fillFormData` on a fresh open of the file in the lane, so the copy's form stays fillable.
public struct EditorPDFForm: Equatable, Sendable {
    /// Every field, signature and push-button fields included, in the toolkit's document order.
    public var fields: [FormField]
    /// Whether the form also carries XFA data. The toolkit fills the AcroForm only, and Acrobat may
    /// show the XFA data instead — said once, in the note card under the save pill.
    public var hasXFA: Bool

    public init(fields: [FormField] = [], hasXFA: Bool = false) {
        self.fields = fields
        self.hasXFA = hasXFA
    }

    public static let none = EditorPDFForm()

    /// Whether the file has a form at all — what sends Save down `fillFormData` rather than 5b's
    /// flattening `fillAndSignData`.
    public var hasFields: Bool { !fields.isEmpty }

    /// The fields Tab walks and a click fills: fillable ones, in document order.
    public var fillable: [FormField] { fields.filter(\.isFillable) }

    public func field(named name: String) -> FormField? { fields.first { $0.name == name } }

    // MARK: Reading, in the lane

    /// Called inside the lane only, on the document the load just opened. **Cheap for a file with no
    /// form**: the catalog is asked for a non-empty `/AcroForm /Fields` first, and only a file that
    /// has one is listed — `formFields(at:)` opens its own copy and walks every page's annotations,
    /// which a 900-page book with no form must not pay for.
    nonisolated static func read(_ document: PDFDocument, url: URL) -> EditorPDFForm {
        guard let acroForm = acroForm(of: document) else { return .none }
        var xfa: CGPDFObjectRef?
        let hasXFA = CGPDFDictionaryGetObject(acroForm, "XFA", &xfa)
        // A file locked to open throws `encryptedInput` here — and Fill & Sign is refused for it.
        let listed = (try? PDFToolkit.formFields(at: url)) ?? []
        return EditorPDFForm(fields: listed, hasXFA: hasXFA && !listed.isEmpty)
    }

    /// The catalog's `/AcroForm`, when it lists at least one field — or `nil`.
    nonisolated private static func acroForm(of document: PDFDocument) -> CGPDFDictionaryRef? {
        guard let catalog = document.documentRef?.catalog else { return nil }
        var acroForm: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
              CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields, CGPDFArrayGetCount(fields) > 0
        else { return nil }
        return acroForm
    }

    /// Whether the document declares form fields — the catalog alone, no page walked.
    nonisolated static func declaresFields(_ document: PDFDocument) -> Bool { acroForm(of: document) != nil }

    /// **The reader never edits a field itself.** A click in a `PDFView` on a text widget puts
    /// PDFKit's own editor in it, and typing changes the ON-SCREEN document — measured 2026-10-18:
    /// "Ada Quill" became "Ada QuillXYZ", and a click toggled a checkbox — which the copy rule never
    /// sees and File ▸ Print would print. Marking every widget read-only on the reader's copy turns
    /// that off for the mouse, the keyboard and VoiceOver alike, and draws the same pixels (compared
    /// on the corpus form and a 535-field I-539). Called in the lane, before the document crosses to
    /// the main thread; the file itself is never touched.
    nonisolated static func lockWidgets(in document: PDFDocument) {
        // An owner who forbids form entry has done it already — and PDFKit logs every refused set.
        guard document.allowsFormFieldEntry else { return }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                annotation.isReadOnly = true
            }
        }
    }

    // MARK: What a field says and takes

    /// Why a field takes no value, or `nil` for one that does — the overlay's hover words.
    public static func refusal(_ field: FormField, allowsFormEntry: Bool) -> String? {
        switch field.kind {
        case .signature: return "Signature field — use Signature in the Fill & Sign tools to sign the page"
        case .pushButton: return "Button — it does nothing in a saved copy"
        default: break
        }
        if field.isReadOnly { return "Read-only — the form doesn’t let this field be changed" }
        if !field.isFillable { return "This list’s items have separate export values, which can’t be filled here" }
        if !allowsFormEntry { return EditorPDFFillSign.noFormEntryReason }
        return nil
    }

    /// The field's value as the file has it, in the toolkit's terms — what a draft is compared with.
    static func original(_ field: FormField) -> FormFieldValue? {
        switch field.kind {
        case .text: return .text(field.value ?? "")
        case .checkbox: return .checked(isOn(field.value))
        case .radio: return isOn(field.value) ? .radio(field.value ?? "") : nil
        case .choice: return .choice(field.value ?? "")
        case .signature, .pushButton: return nil
        }
    }

    static func isOn(_ state: String?) -> Bool {
        guard let state, !state.isEmpty else { return false }
        return state != "Off"
    }

    // MARK: Before Save — the toolkit's refusals, said up front

    /// **Why `fillFormData` would refuse these values and items, or `nil`** — the toolkit's own
    /// checks, in its order and with its errors, so the reader hears it before Save rather than
    /// after a lane turn: permissions, then each value by name (unknown, read-only, not fillable,
    /// wrong kind, over `/MaxLen`, not an option), then typed text on a rotated page.
    /// `EditorPDFFormRefusalTests` holds each answer to what the toolkit actually throws.
    static func problem(values: [String: FormFieldValue], items: [EditorPDFFillItem], form: EditorPDFForm,
                        boxes: [EditorPDFPageBox], allowsFormEntry: Bool, allowsCommenting: Bool,
                        file: URL) -> PDFOperationError? {
        let inked = items.filter(\.hasInk)
        guard !values.isEmpty || !inked.isEmpty else { return .noFormValues }
        if !values.isEmpty, !allowsFormEntry { return .permissionsForbidEditing(file) }
        if !inked.isEmpty {
            if !allowsCommenting { return .permissionsForbidEditing(file) }
            for item in inked {
                guard boxes.indices.contains(item.page) else { return .pageOutOfBounds(item.page + 1) }
                // The toolkit's `isText`: words, typed signatures included. A drawn one is fine.
                if item.words != nil, boxes[item.page].rotation != 0 { return .textOnRotatedPage(pageNumber: item.page + 1) }
            }
        }
        for name in values.keys.sorted() {
            guard let field = form.field(named: name) else { return .unknownFormField(name) }
            if let refusal = check(values[name]!, for: field) { return refusal }
        }
        return nil
    }

    /// One value against its field — the toolkit's `validate`, case for case.
    static func check(_ value: FormFieldValue, for field: FormField) -> PDFOperationError? {
        switch field.kind {
        case .signature, .pushButton: return .formFieldNotFillable(field.name)
        default: break
        }
        if field.isReadOnly { return .formFieldReadOnly(field.name) }
        if !field.isFillable { return .formFieldNotFillable(field.name) }
        switch (field.kind, value) {
        case (.text, .text(let string)):
            if let max = field.maxLength, string.count > max {
                return .formValueNotAccepted(field: field.name, value: string)
            }
        case (.checkbox, .checked):
            break
        case (.radio, .radio(let export)):
            if !field.options.contains(export) { return .formValueNotAccepted(field: field.name, value: export) }
        case (.choice(_, let allowsCustom), .choice(let choice)):
            if !allowsCustom, !field.options.contains(choice) {
                return .formValueNotAccepted(field: field.name, value: choice)
            }
        default:
            return .formValueNotAccepted(field: field.name, value: describe(value))
        }
        return nil
    }

    /// The toolkit's `describe`: a value as its refusal names it.
    static func describe(_ value: FormFieldValue) -> String {
        switch value {
        case .text(let s), .radio(let s), .choice(let s): return s
        case .checked(let on): return on ? "checked" : "unchecked"
        }
    }
}
