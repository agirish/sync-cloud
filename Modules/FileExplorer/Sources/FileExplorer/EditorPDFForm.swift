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
    /// **Each field's own description, by its full name** — the `/TU` a form gives a field for
    /// screen readers and tooltips ("Name (as shown on your income tax return)"). The toolkit lists
    /// none, and a full name like `topmostSubform[0].Page1[0].f1_1[0]` says nothing to VoiceOver.
    public var descriptions: [String: String]

    public init(fields: [FormField] = [], hasXFA: Bool = false, descriptions: [String: String] = [:]) {
        self.fields = fields
        self.hasXFA = hasXFA
        self.descriptions = descriptions
    }

    public static let none = EditorPDFForm()

    /// Whether the file has a form at all — what sends Save down `fillFormData` rather than 5b's
    /// flattening `fillAndSignData`.
    public var hasFields: Bool { !fields.isEmpty }

    /// The fields Tab walks and a click fills: fillable ones, in document order.
    /// A checkbox whose boxes carry separate values is left out with them (``refusal(_:allowsFormEntry:)``),
    /// so Tab, the count and whether the form offers fields at all agree with what a click does.
    public var fillable: [FormField] { fields.filter { $0.isFillable && !($0.kind == .checkbox && $0.options.count > 1) } }

    public func field(named name: String) -> FormField? { fields.first { $0.name == name } }

    /// **What VoiceOver calls a field**: its description, else the last part of its name without
    /// the `[0]` a designer's tool adds — "f1_1", "name".
    public func label(of field: FormField) -> String {
        if let description = descriptions[field.name] { return description }
        let last = field.name.split(separator: ".").last.map(String.init) ?? field.name
        return last.replacingOccurrences(of: #"\[\d+\]$"#, with: "", options: .regularExpression)
    }

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
        return EditorPDFForm(fields: listed, hasXFA: hasXFA && !listed.isEmpty,
                             descriptions: listed.isEmpty ? [:] : descriptions(in: acroForm))
    }

    /// Every field's `/TU`, by the full name the toolkit gives it — the partial `/T`s from the top
    /// of `/Fields` down, joined by periods. A kid without a `/T` is a widget of its parent.
    nonisolated static func descriptions(in acroForm: CGPDFDictionaryRef) -> [String: String] {
        var out: [String: String] = [:]
        func text(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var string: CGPDFStringRef?
            guard CGPDFDictionaryGetString(dictionary, key, &string), let string else { return nil }
            return CGPDFStringCopyTextString(string) as String?
        }
        // Each node once: a `/Kids` that names a node twice, looping back, doubled the walk at every
        // level down to the depth cap — 2^32 visits, in the lane.
        var visited: Set<UInt> = []      // each node's address: CGPDF hands one object the same reference
        func walk(_ array: CGPDFArrayRef, parent: String?, depth: Int) {
            // A form whose kids loop back on themselves stops here.
            guard depth < 32 else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var node: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &node), let node, visited.insert(unsafeBitCast(node, to: UInt.self)).inserted else { continue }
                let name = text(node, "T").map { partial in parent.map { "\($0).\(partial)" } ?? partial } ?? parent
                if let name, out[name] == nil,
                   let description = text(node, "TU")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    out[name] = description
                }
                var kids: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids { walk(kids, parent: name, depth: depth + 1) }
            }
        }
        var fields: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields { walk(fields, parent: nil, depth: 0) }
        return out
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


    /// **The reader never edits a field itself.** A click in a `PDFView` on a text widget puts
    /// PDFKit's own editor in it, and typing changes the ON-SCREEN document — measured 2026-10-18:
    /// "Ada Quill" became "Ada QuillXYZ", and a click toggled a checkbox — which the copy rule never
    /// sees and File ▸ Print would print. Marking every widget read-only on the reader's copy turns
    /// that off for the mouse, the keyboard and VoiceOver alike, and draws the same pixels (compared
    /// on the corpus form and a 535-field I-539). Called in the lane, before the document crosses to
    /// the main thread; the file itself is never touched.
    ///
    /// **Every widget, whatever the catalog says.** A page copy keeps its widgets and drops the
    /// catalog's `/AcroForm` — Extract Pages… on a form makes exactly that file — and PDFKit still
    /// reads each widget's field type and edits it on a click; the reader skipped such a file as
    /// having no form. Only pages whose `/Annots` hold a widget are walked, found from the page
    /// dictionaries without making PDFKit's annotation objects, so a long book with no form pays
    /// one dictionary look per page.
    nonisolated static func lockWidgets(in document: PDFDocument) {
        // An owner who forbids form entry has done it already — and PDFKit logs every refused set.
        guard document.allowsFormFieldEntry else { return }
        for index in pagesWithWidgets(document) {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                annotation.isReadOnly = true
            }
        }
    }

    /// The zero-based pages whose `/Annots` hold a `/Widget` — read from CoreGraphics' page
    /// dictionaries, which builds none of PDFKit's annotation objects.
    nonisolated static func pagesWithWidgets(_ document: PDFDocument) -> [Int] {
        guard let pdf = document.documentRef else { return [] }
        return (0..<pdf.numberOfPages).filter { index in
            guard let page = pdf.page(at: index + 1)?.dictionary else { return false }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { return false }
            for item in 0..<CGPDFArrayGetCount(annots) {
                var annot: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(annots, item, &annot), let annot,
                   CGPDFDictionaryGetName(annot, "Subtype", &subtype), let subtype,
                   strcmp(subtype, "Widget") == 0 { return true }
            }
            return false
        }
    }

    // MARK: What a field says and takes

    static let signFieldHint = "Signature field — click to sign it"
    static let signFieldRefusal = "Signature field — this PDF’s owner doesn’t allow adding a signature to its pages"
    static let separateBoxValuesReason = "These boxes share one name with separate values, which can’t be set here"

    /// Why a field takes no value, or `nil` for one that does — the overlay's hover words. A
    /// signature field takes none, but a click signs it where the owner lets signatures be placed
    /// (TE107), and its words say so.
    public static func refusal(_ field: FormField, allowsFormEntry: Bool, allowsPlacing: Bool = true) -> String? {
        switch field.kind {
        case .signature: return allowsPlacing ? signFieldHint : signFieldRefusal
        case .pushButton: return "Button — it does nothing in a saved copy"
        default: break
        }
        if field.isReadOnly { return "Read-only — the form doesn’t let this field be changed" }
        // **Boxes under one name with different values** — a Yes and a No box. A click cannot say
        // which box it meant, the overlay ticks every box of the field, and the toolkit turns on
        // only the first value: the screen and the copy disagreed. Refused, as such a list is.
        if field.kind == .checkbox, field.options.count > 1 { return separateBoxValuesReason }
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
