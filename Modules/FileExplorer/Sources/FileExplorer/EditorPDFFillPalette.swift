import AppKit
import PDFToolkitCore
import SwiftUI
import Design

/// **Fill & Sign's palette** (Phase 6b, mockup F): the tools, floating in glass over the canvas as
/// Acrobat's do, instead of a toolbar row that pushed the pages down. Turning Fill & Sign on leaves
/// the page where it was.
///
/// Select, Text, Replace, Date, Marks, Signature and Initials, then style, size and ink — with Form Fields first on
/// a file that has fields of its own. A tool with a corner triangle opens a flyout beside it, lined
/// up with it, and that tool is the one lit while its flyout is open (``isLit(_:armed:flyout:)``).
/// What a tool does is its tooltip; the toolbar's line of words went with the toolbar (decided
/// 2026-10-19).
///
/// **It moves as the capsule does**: the same grip, the same eight places and Move To, remembered
/// under its own key (``EditorPDFViewState/palettePlace``), and the same shape rule — a column in
/// the middle of a side, a row along the top or bottom edge.
struct EditorPDFFillPalette: View {
    @ObservedObject var fill: EditorPDFFillSign
    /// Not observed: the palette reads only its own place, which the canvas hands it.
    let state: EditorPDFViewState
    let place: EditorPDFCapsulePlace
    /// The tools' hover tint.
    let accent: Color
    /// The lit tool's fill — see ``EditorWorkspaceView/accentFill`` — and the ink on it.
    let accentFill: Color
    let onAccent: Color
    var onDrag: (CGSize) -> Void = { _ in }
    var onDrop: (CGSize) -> Void = { _ in }
    /// The palette's size as drawn, and `.zero` once it goes — what the canvas keeps the other
    /// floating pieces clear of.
    var onSize: (CGSize) -> Void = { _ in }

    /// The flyout open now, or `nil`.
    @State private var flyout: Flyout?
    /// The mark the Marks tool shows when no mark is chosen: the last one that was.
    @State private var lastMark = EditorPDFFillMark.check
    private let anchors = Anchors()

    /// One per tool that opens a flyout — where its menu opens from.
    private final class Anchors {
        let marks = EditorHeadingMenuAnchor()
        let signature = EditorHeadingMenuAnchor()
        let initials = EditorHeadingMenuAnchor()
        let style = EditorHeadingMenuAnchor()
        let size = EditorHeadingMenuAnchor()
        let ink = EditorHeadingMenuAnchor()

        func anchor(_ flyout: Flyout) -> EditorHeadingMenuAnchor {
            switch flyout {
            case .marks: return marks
            case .signature: return signature
            case .initials: return initials
            case .style: return style
            case .size: return size
            case .ink: return ink
            }
        }
    }

    /// The palette's tools, in its order.
    enum Tool: CaseIterable, Hashable {
        case formFields
        case select
        case text
        /// **Replace** (TE82): a click picks the line of words under it to retype.
        case replace
        case date
        case marks
        case signature
        case initials
        /// **Aa** (TE92, TE93): the selected text's font, typed signature's face or drawn
        /// signature's pen — or the next text's font.
        case style
        case size
        case ink

        /// The flyout this tool opens, or `nil` for a tool a click arms.
        var flyout: Flyout? {
            switch self {
            case .marks: return .marks
            case .signature: return .signature
            case .initials: return .initials
            case .style: return .style
            case .size: return .size
            case .ink: return .ink
            case .formFields, .select, .text, .replace, .date: return nil
            }
        }

        var title: String {
            switch self {
            case .formFields: return "Form Fields"
            case .select: return "Select"
            case .text: return "Text"
            case .replace: return "Replace"
            case .date: return "Date"
            case .marks: return "Marks"
            case .signature: return EditorPDFSignature.Kind.signature.title
            case .initials: return EditorPDFSignature.Kind.initials.title
            case .style: return "Style"
            case .size: return "Text Size"
            case .ink: return "Ink"
            }
        }

        /// Whether the file's owner lets this tool put something on the page.
        var places: Bool {
            self == .text || self == .replace || self == .date || self == .marks || self == .signature || self == .initials
        }
    }

    enum Flyout: Hashable {
        case marks
        case signature
        case initials
        case style
        case size
        case ink
    }

    /// **The tools this file gets**: Form Fields first, only on a file with fields of its own
    /// (mockup 19), then the rest. Replace is off on a form (decision AV): in a column it is there,
    /// greyed, its tooltip saying why; in a row along the top or bottom it is left out, since the
    /// row with Form Fields and Replace both is wider than the narrowest column
    /// (`theRowFitsTheNarrowestColumnAtEveryTextSize`). Right-click ▸ Replace Text… still says why.
    static func tools(for fill: EditorPDFFillSign, upright: Bool = true) -> [Tool] {
        Tool.allCases.filter { $0 != .formFields || fill.form.hasFields }
            .filter { $0 != .replace || upright || !fill.form.hasFields }
    }

    /// **Which tool is lit.** While a flyout is open its tool, and no other — the chosen tool goes
    /// dark until it closes. Otherwise the armed one; Select when nothing is armed. Size and ink are
    /// lit only while their flyouts are open, as is style.
    static func isLit(_ tool: Tool, armed: EditorPDFFillTool?, flyout: Flyout?) -> Bool {
        if let flyout { return tool.flyout == flyout }
        switch (tool, armed) {
        case (.select, nil): return true
        case (.formFields, .formFields?), (.text, .text?), (.replace, .replace?), (.date, .date?), (.marks, .mark?): return true
        case (.signature, .signature(let signature)?): return signature.kind == .signature
        case (.initials, .signature(let signature)?): return signature.kind == .initials
        default: return false
        }
    }

    var body: some View {
        if fill.isOn {
            tools
                .padding(4)
                .modifier(EditorPDFFloatingGround(shape: .roundedRect(Radius.card)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Fill & Sign tools")
                .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
                .onDisappear { onSize(.zero) }
                .sheet(item: $fill.addingSignature) { kind in
                    EditorPDFAddSignatureSheet(fill: fill, kind: kind).presentedNativeControlAccent()
                }
        }
    }

    /// A column in the middle of a side, a row everywhere else — the capsule's rule.
    private var tools: some View {
        let upright = place.isVertical
        let layout = upright ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            EditorPDFGripHandle(state: state, piece: .palette, upright: upright, onDrag: onDrag, onDrop: onDrop)
            ForEach(Self.tools(for: fill, upright: upright), id: \.self) { tool in
                if tool == .style { divider(upright) }
                button(tool)
                if tool == .formFields { divider(upright) }
            }
        }
    }

    private func divider(_ upright: Bool) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: upright ? 20 : 1, height: upright ? 1 : 20)
            .padding(upright ? .vertical : .horizontal, 3)
            .accessibilityHidden(true)
    }

    // MARK: A tool

    /// The side of a tool, in points before the text size scales its glyph.
    static let toolSide: CGFloat = 28

    private func button(_ tool: Tool) -> some View {
        let lit = Self.isLit(tool, armed: fill.armed, flyout: flyout)
        return Button { act(tool) } label: {
            face(tool)
                .frame(width: Self.toolSide, height: Self.toolSide)
                .foregroundStyle(lit ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
                .background(lit ? accentFill : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .bottomTrailing) {
                    if tool.flyout != nil { FlyoutCorner(lit: lit, onAccent: onAccent) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent, shape: .roundedRect(Radius.control)))
        .background(tool.flyout.map { EditorHeadingMenuAnchor.Probe(anchor: anchors.anchor($0)) })
        .disabled(Self.refusal(tool, fill: fill) != nil)
        .accessibilityLabel(tool.title)
        .accessibilityValue(Self.spokenValue(tool, color: fill.color, mark: shownMark))
        .accessibilityAddTraits(lit ? .isSelected : [])
        .help(Self.refusal(tool, fill: fill) ?? Self.hint(tool))
    }

    /// **What a tool's face shows that its name does not (PD6)**: Ink's swatch is the colour, and
    /// Marks wears the mark — "Ink, Blue", "Marks, Check Mark" — where VoiceOver said only the name.
    static func spokenValue(_ tool: Tool, color: EditorPDFFillColor, mark: EditorPDFFillMark) -> String {
        switch tool {
        case .ink: return color.title
        case .marks: return mark.title
        default: return ""
        }
    }

    @ViewBuilder
    private func face(_ tool: Tool) -> some View {
        switch tool {
        case .formFields: glyph("character.textbox")
        case .select: glyph("cursorarrow")
        case .text: glyph("character.cursor.ibeam")
        case .replace: glyph("rectangle.and.pencil.and.ellipsis")
        case .date: glyph("calendar")
        case .marks:
            Text(shownMark.rawValue).scaledFont(.system(size: 14, weight: .bold))
        case .signature: glyph("signature")
        case .initials: Text("AB").scaledFont(.system(size: 10, weight: .bold))
        case .style: Text("Aa").scaledFont(.system(size: 13, weight: .semibold))
        case .size: glyph("textformat.size")
        case .ink:
            Circle()
                .fill(Color(nsColor: fill.color.nsColor))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5).padding(-1))
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).scaledFont(.system(size: 13, weight: .medium))
    }

    /// The mark the Marks tool wears: the one chosen, else the last one that was.
    private var shownMark: EditorPDFFillMark {
        if case .mark(let mark)? = fill.armed { return mark }
        return lastMark
    }

    /// **Why `tool` is greyed now, in its tooltip's words — or `nil` while it is live.** Style, Text
    /// Size and Ink grey out where they could change nothing (TE108): a form field keeps the form's
    /// own text style, a drawn signature has no text size, Replace's next correction starts in the
    /// covered words' own style, and on a form whose owner forbids adding to its pages there is
    /// nothing they could style. File ▸ Fill & Sign Tool greys its Ink and Text Size by this too.
    static func refusal(_ tool: Tool, fill: EditorPDFFillSign) -> String? {
        switch tool {
        case .formFields:
            guard !fill.offersFormFields else { return nil }
            return fill.allowsFormEntry ? "This form has no fields that can be filled here" : EditorPDFFillSign.noFormEntryReason
        case .style, .size, .ink:
            if !fill.offersPlacing { return EditorPDFFillSign.noCommentingReason }
            // An item clicked keeps the field's focus ring; the tools are then the item's.
            if fill.focusedField != nil, fill.selected == nil {
                return "\(tool.title) — a form field keeps the form’s own text style"
            }
            // A correction starts in the covered words' face (or its stand-in), size and ink; once
            // one is selected, the tools change it.
            if fill.armed == .replace, fill.selected == nil { return replaceRefusal(tool) }
            if tool == .style, fill.styleTarget == .mark { return "Style — a mark keeps its own font" }
            if tool == .size, case .drawnSignature = fill.styleTarget { return "Text Size — a drawn signature has no text size" }
            return nil
        case .replace:
            // Off on a form (decision AV), and wherever Fill & Sign may not add to the pages.
            return fill.replaceRefusal.map { "Replace — \($0)" }
        case .select, .text, .date, .marks, .signature, .initials:
            return tool.places && !fill.offersPlacing ? EditorPDFFillSign.noCommentingReason : nil
        }
    }

    /// Why Style, Text Size or Ink is greyed with Replace chosen and nothing selected.
    static func replaceRefusal(_ tool: Tool) -> String {
        switch tool {
        case .style: return "Style — a correction starts in the covered words’ font, or a stand-in for it; select one to change it"
        case .size: return "Text Size — a correction starts at the covered words’ size; select one to change it"
        default: return "\(tool.title) — a correction starts in the covered words’ ink; select one to change it"
        }
    }

    /// What a live tool does, in its tooltip.
    static func hint(_ tool: Tool) -> String {
        switch tool {
        case .formFields: return "Form Fields — click a field to fill it; Tab moves to the next"
        case .select: return "Select — click what you placed to move it; Delete removes it"
        case .text: return "Text — click on the page, or press Return, to type"
        case .replace:
            return "Replace — click a line of words, or drag across some, to retype them. The copy covers the old words with a patch."
        case .date: return "Date — click, or press Return, to place today’s date"
        case .marks: return "Marks — ✓, ✗ or •, then click on the page, or press Return, to place it"
        case .signature, .initials: return "\(tool.title) — choose a saved one, or add one; then click, or press Return, to place it"
        case .style: return "Style — the font of the selected text, the face of a typed signature, the pen of a drawn one"
        case .size: return "Text Size — of the selected text, and of the next"
        case .ink: return "Ink — of the selected item, and of the next"
        }
    }

    private func act(_ tool: Tool) {
        Self.press(tool, fill: fill, choseMark: { lastMark = $0 }, open: open)
    }

    /// **What pressing `tool` does**: arms it, or opens its flyout through `open` — except Signature
    /// and Initials with none saved, which go straight to the Add sheet (TE141).
    static func press(_ tool: Tool, fill: EditorPDFFillSign, choseMark: @escaping (EditorPDFFillMark) -> Void = { _ in },
                      open: (Flyout, NSMenu) -> Void) {
        switch tool {
        case .formFields: fill.armed = .formFields
        case .select: fill.armed = nil
        case .text: fill.armed = .text
        case .replace: fill.armed = .replace
        case .date: fill.armed = .date
        case .marks: open(.marks, EditorPDFFillFlyouts.marks(for: fill, chose: choseMark))
        case .signature, .initials:
            let kind: EditorPDFSignature.Kind = tool == .signature ? .signature : .initials
            if !fill.addFirst(kind) { open(tool == .signature ? .signature : .initials, EditorPDFSignatureMenu.menu(for: fill, kind: kind)) }
        case .style: open(.style, EditorPDFFillFlyouts.style(for: fill))
        case .size: open(.size, EditorPDFFillFlyouts.size(for: fill))
        case .ink: open(.ink, EditorPDFFillFlyouts.ink(for: fill))
        }
    }

    /// **Opens a flyout beside its tool, lit while it is open.** The tool lights first and the menu
    /// opens on the next turn of the run loop, so the light is drawn before the menu's tracking
    /// takes over; it goes out when the menu closes. Away from the edge the palette is docked to:
    /// to the right of a column on the left, above a row at the bottom.
    private func open(_ flyout: Flyout, _ menu: NSMenu) {
        self.flyout = flyout
        let view = anchors.anchor(flyout).view
        let place = place
        DispatchQueue.main.async {
            EditorPDFCapsule.present(menu, from: view, place: place)
            self.flyout = nil
        }
    }

    /// The small triangle in a flyout tool's corner, as Acrobat's and the mockup's.
    private struct FlyoutCorner: View {
        let lit: Bool
        let onAccent: Color

        var body: some View {
            Path { path in
                path.move(to: CGPoint(x: 5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 5))
                path.addLine(to: CGPoint(x: 0, y: 5))
                path.closeSubpath()
            }
            .fill(lit ? AnyShapeStyle(onAccent) : AnyShapeStyle(.secondary))
            .frame(width: 5, height: 5)
            .padding(3)
            .accessibilityHidden(true)
        }
    }
}

/// **The palette's flyouts**: Marks, Style, Text Size and Ink, each an `NSMenu` built when its tool is
/// pressed, as the zoom's and the signatures' menus are — so a test can read and fire them.
@MainActor
enum EditorPDFFillFlyouts {
    /// ✓ Check Mark, ✗ Cross, • Dot — the chosen one ticked. Choosing one makes the next click on a
    /// page place it; `chose` hears which.
    static func marks(for fill: EditorPDFFillSign, chose: @escaping (EditorPDFFillMark) -> Void = { _ in }) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mark in EditorPDFFillMark.allCases {
            let item = EditorClosureMenuItem(title: "\(mark.rawValue)  \(mark.title)") {
                fill.armed = .mark(mark)
                chose(mark)
            }
            item.state = fill.armed == .mark(mark) ? .on : .off
            item.isEnabled = fill.offersPlacing
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Style (TE92, TE93)

    static let changesSavedLine = "Also changes your saved signature"
    static let changesSavedInitialsLine = "Also changes your saved initials"

    /// **The Aa tool's flyout, by what is selected**: a typed signature's faces, each in its own
    /// words; a drawn one's pens; text's fonts, each drawn in itself — and with nothing selected,
    /// the next text's font. A saved signature's list ends with the line saying the saved one
    /// changes too (decision AS).
    static func style(for fill: EditorPDFFillSign) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in styleItems(for: fill) { menu.addItem(item) }
        return menu
    }

    /// **An item's right-click menu** (TE140) — what the palette's tools would change for it, each in
    /// a submenu named as the tool is, then Delete. Text: Edit Text, then Font, Text Size and Ink; a
    /// typed signature: Face and Ink; a drawn one: Pen and Ink; a mark: Ink.
    static func itemMenu(for fill: EditorPDFFillSign) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            items.forEach(sub.addItem)
            line.submenu = sub
            menu.addItem(line)
        }
        switch fill.styleTarget {
        case .text(let id):
            menu.addItem(EditorClosureMenuItem(title: editTextTitle) { fill.beginEditing(id) })
            menu.addItem(.separator())
            submenu("Font", styleItems(for: fill, headed: false))
            submenu("Text Size", lines(of: size(for: fill)))
        case .correction(let id):
            menu.addItem(EditorClosureMenuItem(title: retypeTitle) { fill.beginEditing(id) })
            menu.addItem(.separator())
            submenu("Font", styleItems(for: fill, headed: false))
            submenu("Text Size", lines(of: size(for: fill)))
        case .typedSignature:
            submenu("Face", styleItems(for: fill, headed: false))
        case .drawnSignature:
            submenu("Pen", styleItems(for: fill, headed: false))
        case .mark, .nextText:
            break
        }
        if fill.styleTarget != .nextText { submenu("Ink", lines(of: ink(for: fill))) }
        menu.addItem(.separator())
        menu.addItem(EditorClosureMenuItem(title: "Delete") { fill.deleteSelection() })
        return menu
    }

    static let editTextTitle = "Edit Text"
    /// A correction's: its words, retyped in the box over them.
    static let retypeTitle = "Retype"

    /// A flyout's lines, taken out of it so another menu can hold them.
    private static func lines(of menu: NSMenu) -> [NSMenuItem] {
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// The Aa tool's lines for what is selected — under a heading saying what they change, unless
    /// they are a submenu whose name already does.
    private static func styleItems(for fill: EditorPDFFillSign, headed: Bool = true) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        switch fill.styleTarget {
        case .typedSignature:
            guard let item = fill.selected, let signature = item.signature,
                  case .typed(let words) = signature.look else { return [] }
            if headed { out.append(heading("Face of \(kindWord(signature.kind))")) }
            for face in EditorPDFSignatureFace.allCases {
                let line = EditorClosureMenuItem(title: face.title) { fill.setFace(face) }
                line.attributedTitle = faceTitle(words, face: face)
                line.state = signature.face == face ? .on : .off
                out.append(line)
            }
            out += savedNote(fill, kind: signature.kind)
        case .drawnSignature:
            guard let signature = fill.selected?.signature else { return [] }
            if headed { out.append(heading("Pen of \(kindWord(signature.kind))")) }
            for pen in EditorPDFPen.allCases {
                let line = EditorClosureMenuItem(title: pen.title) { fill.setPen(pen) }
                line.image = penImage(pen)
                line.state = signature.pen == pen ? .on : .off
                out.append(line)
            }
            out += savedNote(fill, kind: signature.kind)
        case .text, .nextText:
            if headed { out.append(heading(fill.styleTarget == .nextText ? "Font of the next text" : "Font of this text")) }
            let current = fill.currentTextFont
            for font in EditorPDFTextFont.allCases {
                let line = EditorClosureMenuItem(title: font.title) { fill.setTextFont(font) }
                line.attributedTitle = NSAttributedString(string: font.title, attributes: [.font: font.font(size: 14)])
                line.state = current == font ? .on : .off
                out.append(line)
            }
        case .correction:
            guard let item = fill.selected, let correction = item.correction else { return [] }
            if headed { out.append(heading("Font of this correction")) }
            if let installed = correction.installedFont {
                let name = EditorPDFFontMatch.shownName(installed)
                let line = EditorClosureMenuItem(title: "Original — \(name)") { fill.useOriginalFont() }
                if let face = NSFont(name: installed, size: 14) {
                    line.attributedTitle = NSAttributedString(string: "Original — \(name)", attributes: [.font: face])
                }
                line.state = correction.isSameFont ? .on : .off
                out.append(line)
            }
            for font in EditorPDFTextFont.allCases {
                let line = EditorClosureMenuItem(title: font.title) { fill.setTextFont(font) }
                line.attributedTitle = NSAttributedString(string: font.title, attributes: [.font: font.font(size: 14)])
                line.state = !correction.isSameFont && item.font == font ? .on : .off
                out.append(line)
            }
        case .mark:
            break
        }
        return out
    }

    private static func kindWord(_ kind: EditorPDFSignature.Kind) -> String {
        kind == .signature ? "this signature" : "these initials"
    }

    private static func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func savedNote(_ fill: EditorPDFFillSign, kind: EditorPDFSignature.Kind) -> [NSMenuItem] {
        guard fill.restyleChangesSaved else { return [] }
        return [.separator(), heading(kind == .signature ? changesSavedLine : changesSavedInitialsLine)]
    }

    /// The signature's own words in `face`, then the face's name, small — Zapfino a size down, its
    /// loops are tall.
    static func faceTitle(_ words: String, face: EditorPDFSignatureFace) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: words, attributes: [.font: PDFToolkit.font(size: face == .zapfino ? 12 : 18, script: true, font: face.toolkit)])
        title.append(NSAttributedString(string: "   \(face.title)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    /// A short stroke as thick as the pen draws on the pad.
    static func penImage(_ pen: EditorPDFPen) -> NSImage {
        NSImage(size: CGSize(width: 28, height: 12), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = pen.padWidth
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: 3, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
            NSColor.labelColor.setStroke()
            path.stroke()
            return true
        }
    }

    static let smallerTitle = "Smaller"
    static let biggerTitle = "Bigger"

    /// Smaller and Bigger, the steps A− and A+ were, then every size with the current one ticked —
    /// of the selected text, else of the next.
    static func size(for fill: EditorPDFFillSign) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let smaller = EditorClosureMenuItem(title: smallerTitle) { fill.stepFontSize(bigger: false) }
        smaller.isEnabled = fill.canStepFontSize(bigger: false)
        menu.addItem(smaller)
        let bigger = EditorClosureMenuItem(title: biggerTitle) { fill.stepFontSize(bigger: true) }
        bigger.isEnabled = fill.canStepFontSize(bigger: true)
        menu.addItem(bigger)
        menu.addItem(.separator())
        let current = fill.currentFontSize
        for size in EditorPDFFillSign.fontSizes {
            let item = EditorClosureMenuItem(title: "\(Int(size)) pt") { fill.setFontSize(size) }
            item.state = abs(size - current) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// The two inks, each with its swatch, the current one ticked.
    static func ink(for fill: EditorPDFFillSign) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A correction's own ink first: the covered words' (TE83).
        let correction = fill.selected?.correction
        if let correction {
            let item = EditorClosureMenuItem(title: originalInkTitle) { fill.useOriginalInk() }
            item.image = swatch(correction.ink.nsColor)
            item.state = correction.keepsOriginalInk ? .on : .off
            menu.addItem(item)
        }
        for ink in EditorPDFFillColor.allCases {
            let item = EditorClosureMenuItem(title: ink.title) { fill.setColor(ink) }
            item.image = swatch(ink.nsColor)
            // A correction's palette ink is ticked only once chosen over its own.
            let current: EditorPDFFillColor?
            if let correction { current = correction.keepsOriginalInk ? nil : fill.selected?.color } else { current = fill.color }
            item.state = current == ink ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    static let originalInkTitle = "Original Ink"

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

/// **The save pill and the note card, at the top of the canvas** (Phase 6b, mockup F): "3 items not
/// saved", Discard and Save Filled Copy, in a glass pill that appears with the first mark and goes
/// when nothing is left to save — and under it, while there is one, a card of what Save would
/// refuse and the file's own caveats (decided 2026-10-19). Neither moves the page.
struct EditorPDFFillSaveStack: View {
    @ObservedObject var fill: EditorPDFFillSign
    @ObservedObject var tools: EditorPDFTools
    /// The stack's size as drawn, and `.zero` once it goes.
    var onSize: (CGSize) -> Void = { _ in }

    /// The widest the note card grows before its lines wrap.
    static let noteWidth: CGFloat = 360
    static let doneTitle = "Done"

    var body: some View {
        let showsPill = fill.isOn && fill.hasUnsavedChanges
        let notes = fill.isOn ? fill.formNotes + fill.replaceNotes : []
        let corrections = fill.isOn ? fill.correctionNotes : []
        if showsPill || !notes.isEmpty || !corrections.isEmpty {
            VStack(spacing: EditorPDFFloating.gap) {
                if showsPill { pill }
                if !notes.isEmpty || !corrections.isEmpty { card(notes, corrections: corrections) }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .onDisappear { onSize(.zero) }
        }
    }

    /// **The pill gives way before it overflows** — "2 fields changed · 1 item not saved", then
    /// "2 fields · 1 item", then no words, the count kept in its tooltip. Its words were fixed, so in
    /// the narrowest column, or at a large text size, the pill ran past the canvas, where the rule
    /// that keeps it clear of the find card found no place for it and drew it over the card.
    private var pill: some View {
        ViewThatFits(in: .horizontal) {
            pill(caption: fill.unsavedCaption)
            pill(caption: fill.unsavedShortCaption)
            pill(caption: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fill & Sign changes not saved")
        .accessibilityValue(fill.unsavedCaption ?? "")
    }

    private func pill(caption: String?) -> some View {
        HStack(spacing: 8) {
            if let caption {
                Text(caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Nothing is written until \(fill.saveTitle) — the original stays as it is")
            }
            Button("Discard") { fill.discard() }
                .disabled(fill.items.isEmpty && fill.values.isEmpty)
                .help(fill.usesFormPath ? "Remove everything placed and clear the fields you filled — ⌘Z brings it back"
                                          : "Remove everything placed — ⌘Z brings it back")
            Button(fill.saveTitle) { Task { await fill.save() } }
                .buttonStyle(.borderedProminent)
                // The app's accent, deepened, as the Pages tab's Save Reordered Copy has it — not
                // the system's, and not the raw one, which leaves the white label at 2.7:1 on Green.
                .accentedProminent()
                .disabled(!fill.canSave || tools.running != nil)
                .help(fill.saveHelp)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
            // **A way out from where the work is** (TE98) — the header's button's own toggle, which
            // asks about what isn't saved. The tooltip says Esc's order (TE98, `escape(first:)`):
            // Fill & Sign opens with a tool chosen, and the first Esc lets go of that, not of Fill
            // & Sign — after ending any typing, and before an open Find card closes.
            Button(Self.doneTitle) { fill.toggle() }
                .help("Put Fill & Sign away — asks first about what isn’t saved. "
                      + "Esc does it too, once nothing is being typed, selected or chosen and Find is closed")
        }
        .controlSize(.small)
        .scaledFont(.system(size: 11))
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .modifier(EditorPDFFloatingGround(shape: .capsule))
        .help(caption == nil ? (fill.unsavedCaption ?? "") : "")
    }

    /// The card: what Save would refuse and the file's caveats, then each corrected page's line —
    /// the covered words are still in the copy — with the button that makes the page a picture
    /// (TE85, decision AK), then the save's two choices: the links under corrections (FR56) and
    /// the file's comments (FR57).
    private func card(_ notes: [String], corrections: [EditorPDFCorrectionNote]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(corrections) { note in
                VStack(alignment: .leading, spacing: 5) {
                    Label(note.line, systemImage: note.pictured ? "photo" : "eye")
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(note.button) { fill.setPicture(note.page, !note.pictured) }
                        .controlSize(.small)
                        .help(note.pictured
                              ? "Save this page with its text, the covered words still under their patches"
                              : "Save this page as a picture: the covered words go, and so does its selectable text")
                }
                .padding(.top, notes.isEmpty && note.id == corrections.first?.id ? 0 : 4)
            }
            // **A link under a patch, kept unless chosen otherwise** (FR56, decided 2026-10-25) —
            // for this save only.
            if fill.offersUnlinking {
                Toggle(EditorPDFFillSign.unlinkTitle, isOn: $fill.unlinksCorrections)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(EditorPDFFillSign.unlinkHelp)
                    .padding(.top, 4)
            }
            // **The file's comments, drawn in unless chosen otherwise** (FR57, decided 2026-10-25) —
            // for this save only. Greyed, unticked and saying why while a page is saved as a
            // picture or the links under corrections are removed, rather than vanishing from under
            // a reader who ticked it.
            if fill.offersKeepingComments {
                let refusal = fill.keepCommentsRefusal
                Toggle(EditorPDFFillSign.keepCommentsTitle,
                       isOn: Binding(get: { fill.keepsComments && refusal == nil }, set: { fill.keepsComments = $0 }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(refusal != nil)
                    .help(EditorPDFFillSign.keepCommentsHelp)
                    .padding(.top, 4)
                if let refusal {
                    Text(refusal).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(maxWidth: Self.noteWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(EditorPDFFloatingGround(shape: .roundedRect(Radius.card)))
        .accessibilityElement(children: .combine)
    }
}

/// **The Signature and Initials menus** (mockup 18): the saved ones, drawn — choosing one makes the
/// next click place it — then Add…, and a submenu to delete a saved one. Built when pressed, as the
/// zoom's menu is — the Signature and Initials tools' flyouts in the palette.
///
/// **Opened from a form's signature field** (`signing`, TE107) it signs that field: choosing one, or
/// adding one, places it there.
@MainActor
enum EditorPDFSignatureMenu {
    static func menu(for fill: EditorPDFFillSign, kind: EditorPDFSignature.Kind,
                     signing target: EditorPDFFillSign.SigningTarget? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let saved = fill.store.saved(kind)
        let heading = target != nil ? signFieldTitle
            : saved.isEmpty ? "No saved \(kind.title.lowercased()) yet" : "Saved on this Mac"
        let label = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        for signature in saved {
            menu.addItem(item(signature, among: saved) {
                if let target { fill.place(signature, in: target) } else { fill.armed = .signature(signature) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(EditorClosureMenuItem(title: "Add \(kind.title)…") { fill.startAdding(kind, signing: target) })
        if !saved.isEmpty, target == nil {
            let delete = NSMenuItem(title: deleteTitle(kind), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for signature in saved {
                // Asks first (decision BE).
                submenu.addItem(item(signature, among: saved) { fill.deleteSaved(signature) })
            }
            delete.submenu = submenu
            menu.addItem(delete)
        }
        return menu
    }

    static let signFieldTitle = "Sign this field"

    /// "Delete a Saved Signature", "Delete Saved Initials" (TE100) — initials are a plural.
    static func deleteTitle(_ kind: EditorPDFSignature.Kind) -> String {
        kind == .signature ? "Delete a Saved Signature" : "Delete Saved Initials"
    }

    /// A saved signature as a menu line: typed ones in the script face, drawn ones as a picture
    /// that VoiceOver reads by its number and pen among `saved` (decision BD).
    static func item(_ signature: EditorPDFSignature, among saved: [EditorPDFSignature],
                     act: @escaping () -> Void) -> NSMenuItem {
        let item = EditorClosureMenuItem(title: signature.kind.title, act: act)
        switch signature.look {
        case .typed(let string):
            item.attributedTitle = NSAttributedString(
                string: string, attributes: [.font: PDFToolkit.font(size: signature.face == .zapfino ? 12 : 18, script: true,
                                                                    font: signature.face.toolkit)])
        case .drawn:
            item.image = image(signature, height: 24)
            item.title = ""
            item.setAccessibilityLabel(signature.spokenName(among: saved))
            item.toolTip = signature.spokenName(among: saved)
        }
        return item
    }

    /// A drawn signature, in the menu's own ink so it reads in both appearances.
    static func image(_ signature: EditorPDFSignature, height: CGFloat) -> NSImage? {
        guard case .drawn(let strokes, let aspect) = signature.look else { return nil }
        let size = CGSize(width: min(max(height * aspect, height), height * 6), height: height)
        return NSImage(size: size, flipped: true) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            NSColor.labelColor.setStroke()
            for stroke in strokes where !stroke.isEmpty {
                let path = NSBezierPath()
                path.lineWidth = 1.4 * signature.pen.widthFraction / FillSignSignature.defaultPenWidthFraction
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let points = stroke.map { CGPoint(x: inset.minX + $0.x * inset.width, y: inset.minY + $0.y * inset.height) }
                path.move(to: points[0])
                points.dropFirst().forEach(path.line(to:))
                if points.count == 1 { path.line(to: CGPoint(x: points[0].x + 0.5, y: points[0].y)) }
                path.stroke()
            }
            return true
        }
    }
}
