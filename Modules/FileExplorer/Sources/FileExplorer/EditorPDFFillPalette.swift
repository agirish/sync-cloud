import AppKit
import PDFToolkitCore
import SwiftUI
import Design

/// **Fill & Sign's palette** (Phase 6b, mockup F): the tools, floating in glass over the canvas as
/// Acrobat's do, instead of a toolbar row that pushed the pages down. Turning Fill & Sign on leaves
/// the page where it was.
///
/// Select, Text, Date, Marks, Signature and Initials, then style, size and ink — with Form Fields first on
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
    let accent: Color
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
            case .formFields, .select, .text, .date: return nil
            }
        }

        var title: String {
            switch self {
            case .formFields: return "Form Fields"
            case .select: return "Select"
            case .text: return "Text"
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
        var places: Bool { self == .text || self == .date || self == .marks || self == .signature || self == .initials }
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
    /// (mockup 19), then the rest.
    static func tools(for fill: EditorPDFFillSign) -> [Tool] {
        Tool.allCases.filter { $0 != .formFields || fill.form.hasFields }
    }

    /// **Which tool is lit.** While a flyout is open its tool, and no other — the chosen tool goes
    /// dark until it closes. Otherwise the armed one; Select when nothing is armed. Size and ink are
    /// lit only while their flyouts are open, as is style.
    static func isLit(_ tool: Tool, armed: EditorPDFFillTool?, flyout: Flyout?) -> Bool {
        if let flyout { return tool.flyout == flyout }
        switch (tool, armed) {
        case (.select, nil): return true
        case (.formFields, .formFields?), (.text, .text?), (.date, .date?), (.marks, .mark?): return true
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
                    EditorPDFAddSignatureSheet(fill: fill, kind: kind)
                }
        }
    }

    /// A column in the middle of a side, a row everywhere else — the capsule's rule.
    private var tools: some View {
        let upright = place.isVertical
        let layout = upright ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            EditorPDFGripHandle(state: state, piece: .palette, upright: upright, onDrag: onDrag, onDrop: onDrop)
            ForEach(Self.tools(for: fill), id: \.self) { tool in
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
                .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(lit ? accent : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .bottomTrailing) {
                    if tool.flyout != nil { FlyoutCorner(lit: lit) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent, shape: .roundedRect(Radius.control)))
        .background(tool.flyout.map { EditorHeadingMenuAnchor.Probe(anchor: anchors.anchor($0)) })
        .disabled(isDisabled(tool))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(lit ? .isSelected : [])
        .help(help(for: tool))
    }

    @ViewBuilder
    private func face(_ tool: Tool) -> some View {
        switch tool {
        case .formFields: glyph("character.textbox")
        case .select: glyph("cursorarrow")
        case .text: glyph("character.cursor.ibeam")
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

    private func isDisabled(_ tool: Tool) -> Bool {
        if tool == .formFields { return !fill.offersFormFields }
        if tool == .style, fill.styleTarget == .mark { return true }
        return tool.places && !fill.offersPlacing
    }

    private func help(for tool: Tool) -> String {
        if tool == .formFields, !fill.offersFormFields {
            return fill.allowsFormEntry ? "This form has no fields that can be filled here" : EditorPDFFillSign.noFormEntryReason
        }
        if tool.places, !fill.offersPlacing { return EditorPDFFillSign.noCommentingReason }
        if tool == .style, fill.styleTarget == .mark { return "Style — a mark keeps its own font" }
        switch tool {
        case .formFields: return "Form Fields — click a field to fill it; Tab moves to the next"
        case .select: return "Select — click what you placed to move it; Delete removes it"
        case .text: return "Text — click on the page to type"
        case .date: return EditorPDFFillTool.date.hint
        case .marks: return "Marks — ✓, ✗ or •, then click on the page to place it"
        case .signature, .initials: return "\(tool.title) — choose a saved one, or add one"
        case .style: return "Style — the font of the selected text, the face of a typed signature, the pen of a drawn one"
        case .size: return "Text size — of the selected text, and of the next"
        case .ink: return "Ink — of the selected item, and of the next"
        }
    }

    private func act(_ tool: Tool) {
        switch tool {
        case .formFields: fill.armed = .formFields
        case .select: fill.armed = nil
        case .text: fill.armed = .text
        case .date: fill.armed = .date
        case .marks: open(.marks, EditorPDFFillFlyouts.marks(for: fill) { lastMark = $0 })
        case .signature: open(.signature, EditorPDFSignatureMenu.menu(for: fill, kind: .signature))
        case .initials: open(.initials, EditorPDFSignatureMenu.menu(for: fill, kind: .initials))
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

        var body: some View {
            Path { path in
                path.move(to: CGPoint(x: 5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 5))
                path.addLine(to: CGPoint(x: 0, y: 5))
                path.closeSubpath()
            }
            .fill(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
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

    /// **An item's right-click menu**: its style choices, then Delete.
    static func itemMenu(for fill: EditorPDFFillSign) -> NSMenu {
        let menu = style(for: fill)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(EditorClosureMenuItem(title: "Delete") { fill.deleteSelection() })
        return menu
    }

    private static func styleItems(for fill: EditorPDFFillSign) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        switch fill.styleTarget {
        case .typedSignature:
            guard let item = fill.selected, let signature = item.signature,
                  case .typed(let words) = signature.look else { return [] }
            out.append(heading("Face of \(kindWord(signature.kind))"))
            for face in EditorPDFSignatureFace.allCases {
                let line = EditorClosureMenuItem(title: face.title) { fill.setFace(face) }
                line.attributedTitle = faceTitle(words, face: face)
                line.state = signature.face == face ? .on : .off
                out.append(line)
            }
            out += savedNote(fill, kind: signature.kind)
        case .drawnSignature:
            guard let signature = fill.selected?.signature else { return [] }
            out.append(heading("Pen of \(kindWord(signature.kind))"))
            for pen in EditorPDFPen.allCases {
                let line = EditorClosureMenuItem(title: pen.title) { fill.setPen(pen) }
                line.image = penImage(pen)
                line.state = signature.pen == pen ? .on : .off
                out.append(line)
            }
            out += savedNote(fill, kind: signature.kind)
        case .text, .nextText:
            out.append(heading(fill.styleTarget == .nextText ? "Font of the next text" : "Font of this text"))
            let current = fill.currentTextFont
            for font in EditorPDFTextFont.allCases {
                let line = EditorClosureMenuItem(title: font.title) { fill.setTextFont(font) }
                line.attributedTitle = NSAttributedString(string: font.title, attributes: [.font: font.font(size: 14)])
                line.state = current == font ? .on : .off
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
        for ink in EditorPDFFillColor.allCases {
            let item = EditorClosureMenuItem(title: ink.title) { fill.setColor(ink) }
            item.image = swatch(ink)
            item.state = fill.color == ink ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private static func swatch(_ ink: EditorPDFFillColor) -> NSImage {
        NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
            ink.nsColor.setFill()
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
    let accent: Color
    /// The stack's size as drawn, and `.zero` once it goes.
    var onSize: (CGSize) -> Void = { _ in }

    /// The widest the note card grows before its lines wrap.
    static let noteWidth: CGFloat = 360

    var body: some View {
        let showsPill = fill.isOn && fill.hasUnsavedChanges
        let notes = fill.isOn ? fill.formNotes : []
        if showsPill || !notes.isEmpty {
            VStack(spacing: EditorPDFFloating.gap) {
                if showsPill { pill }
                if !notes.isEmpty { card(notes) }
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
                    .help("Nothing is written until Save Filled Copy — the original stays as it is")
            }
            Button("Discard") { fill.discard() }
                .disabled(fill.items.isEmpty && fill.values.isEmpty)
                .help(fill.usesFormPath ? "Remove everything placed and clear the fields you filled — ⌘Z brings it back"
                                          : "Remove everything placed — ⌘Z brings it back")
            Button("Save Filled Copy") { Task { await fill.save() } }
                .buttonStyle(.borderedProminent)
                .disabled(!fill.canSave || tools.running != nil)
                .help(fill.usesFormPath
                      ? "Write a copy beside the original with these values — its form stays fillable, and the original isn’t changed"
                      : "Write a copy with these items beside the original — the original isn’t changed")
        }
        .controlSize(.small)
        .scaledFont(.system(size: 11))
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .modifier(EditorPDFFloatingGround(shape: .capsule))
        .help(caption == nil ? (fill.unsavedCaption ?? "") : "")
    }

    private func card(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
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
@MainActor
enum EditorPDFSignatureMenu {
    static func menu(for fill: EditorPDFFillSign, kind: EditorPDFSignature.Kind) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let saved = fill.store.saved(kind)
        let label = NSMenuItem(title: saved.isEmpty ? "No saved \(kind.title.lowercased()) yet" : "Saved on this Mac",
                               action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        for signature in saved {
            menu.addItem(item(signature) { fill.armed = .signature(signature) })
        }
        menu.addItem(.separator())
        menu.addItem(EditorClosureMenuItem(title: "Add \(kind.title)…") { fill.addingSignature = kind })
        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete a Saved \(kind.title)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for signature in saved {
                submenu.addItem(item(signature) { fill.store.delete(signature.id) })
            }
            delete.submenu = submenu
            menu.addItem(delete)
        }
        return menu
    }

    /// A saved signature as a menu line: typed ones in the script face, drawn ones as a picture.
    static func item(_ signature: EditorPDFSignature, act: @escaping () -> Void) -> NSMenuItem {
        let item = EditorClosureMenuItem(title: signature.kind.title, act: act)
        switch signature.look {
        case .typed(let string):
            item.attributedTitle = NSAttributedString(
                string: string, attributes: [.font: PDFToolkit.font(size: signature.face == .zapfino ? 12 : 18, script: true,
                                                                    font: signature.face.toolkit)])
        case .drawn:
            item.image = image(signature, height: 24)
            item.title = ""
            item.setAccessibilityLabel("Drawn \(signature.kind.title.lowercased())")
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
