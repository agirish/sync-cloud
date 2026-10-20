import AppKit
import Combine
import PDFKit
import PDFToolkitCore

/// **Fill & Sign's items over the reader's pages** — drawn, placed, moved, resized and typed into.
///
/// It sits on top of the page view, above the find's highlights, the size of the view. **It takes
/// a click only when it has something to do with it** (``hitTest(_:)``): on an item, on a page while
/// a tool is chosen, or anywhere while something is selected (that click lets it go). Everything
/// else goes through to PDFKit, so the pages still scroll and their text still selects.
///
/// **It answers ⌘Z itself, with Fill & Sign's own stack.** `PDFView` validates menu items of its own
/// (it responds to `validateMenuItem:`), so undo cannot be answered on the reader without guessing
/// what PDFKit says about every other item. While the palette is up this view takes the keyboard
/// whenever the reader would — it is inside the reader, so the pages still "have focus" for ⌘+ and
/// ⌘− — and keys it does not use go on up to the reader (⌥← and ⌥→).
///
/// Drawing matches the copy: words in the toolkit's own face at the item's point size, a drawn
/// signature as strokes of the toolkit's pen width — so what is on screen is what Save writes.
///
/// **A PDF's own form fields are drawn here too, not by PDFKit** (Phase 5c, mockup 19): each widget
/// tinted from the rects pdf-toolkit read, a changed one covered and drawn with its new value, and
/// typed into through a field of this view's own. The reader's document never takes a value — its
/// widgets are read-only (``EditorPDFForm/lockWidgets(in:)``) — so the copy rule holds.
final class EditorPDFFillOverlay: NSView, NSTextFieldDelegate, NSMenuItemValidation, NSViewToolTipOwner {
    weak var reader: ReaderPDFView?
    weak var fill: EditorPDFFillSign? {
        didSet {
            guard fill !== oldValue else { return }
            watch = fill?.objectWillChange.sink { [weak self] _ in
                // Published before the change lands: look once it has.
                DispatchQueue.main.async { self?.refresh() }
            }
            refresh()
        }
    }
    private var watch: AnyCancellable?
    private(set) var field: NSTextField?
    /// The typing field over a form field being filled, and the field it is for.
    private(set) var formEditor: NSTextField?
    private var formEditorField: String?
    /// The focused field last scrolled into sight — Tab to one off screen brings it on.
    private var revealedField: String?
    /// Puts up a choice field's menu — `popUp` in the app; a test records the menu instead, since
    /// a real pop-up waits for a choice.
    var presentMenu: (NSMenu, NSRect, NSView) -> Void = { menu, rect, view in
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: view.isFlipped ? rect.maxY + 2 : rect.minY - 2), in: view)
    }
    private var drag: Drag?
    private var tracking: NSTrackingArea?

    private enum Drag {
        case move(id: UUID, page: Int, start: CGPoint, from: CGRect)
        case resize(id: UUID, page: Int, anchor: CGPoint)
    }

    static let handleRadius: CGFloat = 4.5

    var isActive: Bool { fill?.isOn == true }

    // MARK: Where things are

    /// `item`'s box in this view, or `nil` when its page is not in the document.
    func viewRect(_ item: EditorPDFFillItem) -> CGRect? {
        guard let reader, let fill, let page = reader.document?.page(at: item.page), let box = fill.box(item.page) else {
            return nil
        }
        return convert(reader.convert(box.pageRect(display: item.rect), from: page), from: reader)
    }

    func viewPoint(display point: CGPoint, page index: Int) -> CGPoint? {
        guard let reader, let fill, let page = reader.document?.page(at: index), let box = fill.box(index) else {
            return nil
        }
        return convert(reader.convert(box.pagePoint(display: point), from: page), from: reader)
    }

    func displayPoint(view point: CGPoint, page index: Int) -> CGPoint? {
        guard let reader, let fill, let page = reader.document?.page(at: index), let box = fill.box(index) else {
            return nil
        }
        return box.displayPoint(page: reader.convert(convert(point, to: reader), to: page))
    }

    /// The page under `point`, zero-based — only ON a page, not in the gap between two.
    func pageIndex(at point: CGPoint) -> Int? {
        guard let reader, let document = reader.document,
              let page = reader.page(for: convert(point, to: reader), nearest: false) else { return nil }
        return document.index(for: page)
    }

    /// The topmost item under `point` on a page on screen.
    func item(at point: CGPoint) -> EditorPDFFillItem? {
        guard let fill else { return nil }
        let shown = shownPages
        return fill.items.reversed().first { item in
            shown.contains(item.page) && (viewRect(item)?.insetBy(dx: -3, dy: -3).contains(point) ?? false)
        }
    }

    /// **The selected item's resize handle, just OUTSIDE its bottom-right corner** (in display
    /// space). On the corner itself, a check mark at 50% — 8pt square — was all handle, and every
    /// drag of it resized instead of moving it.
    func handle(of item: EditorPDFFillItem) -> CGPoint? {
        guard let corner = viewPoint(display: CGPoint(x: item.rect.maxX, y: item.rect.minY), page: item.page),
              let rect = viewRect(item) else { return nil }
        let dx = corner.x - rect.midX, dy = corner.y - rect.midY
        let length = max(hypot(dx, dy), 0.001)
        // Mostly outside: reachable from 3pt inside the corner, never from the item's middle.
        let out = Self.handleRadius - 1.5
        return CGPoint(x: corner.x + dx / length * out, y: corner.y + dy / length * out)
    }

    /// The handle under `point` — never a point inside the item, which always moves it.
    private func handleHit(_ point: CGPoint) -> EditorPDFFillItem? {
        guard let selected = fill?.selected, fill?.editing != selected.id, let handle = handle(of: selected),
              let rect = viewRect(selected), !rect.contains(point) else { return nil }
        return hypot(point.x - handle.x, point.y - handle.y) <= Self.handleRadius + 2 ? selected : nil
    }

    private var shownPages: Set<Int> {
        guard let reader, let document = reader.document else { return [] }
        return Set(reader.visiblePages.map { document.index(for: $0) })
    }

    // MARK: Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, let fill else { return nil }
        if let hit = super.hitTest(point), hit !== self { return hit }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if handleHit(local) != nil || item(at: local) != nil { return self }
        if takesFieldClicks, fieldHit(at: local) != nil { return self }
        if fill.armed != nil, fill.armed != .formFields, pageIndex(at: local) != nil { return self }
        if fill.selection != nil || fill.editing != nil { return self }
        if fill.focusedField != nil || fill.editingField != nil { return self }
        return nil
    }

    override var acceptsFirstResponder: Bool { isActive }

    override func mouseDown(with event: NSEvent) {
        guard let fill else { return }
        window?.makeFirstResponder(self)
        // ⌃-click is a right-click: this method never hands the event on, so the menu is put up here.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let item = handleHit(point) {
            fill.beginGesture()
            drag = .resize(id: item.id, page: item.page, anchor: CGPoint(x: item.rect.minX, y: item.rect.maxY))
        } else if let item = item(at: point) {
            if event.clickCount == 2, case .text = item.content {
                fill.beginEditing(item.id)
                return
            }
            fill.select(item.id)
            fill.beginGesture()
            if let start = displayPoint(view: point, page: item.page) {
                drag = .move(id: item.id, page: item.page, start: start, from: item.rect)
            }
        } else if takesFieldClicks, let hit = fieldHit(at: point) {
            click(hit)
        } else if fill.armed != nil, fill.armed != .formFields, let page = pageIndex(at: point),
                  let at = displayPoint(view: point, page: page) {
            fill.place(at: at, page: page)
        } else {
            fill.endEditing()
            fill.select(nil)
            fill.focusField(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fill, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let id, let page, let start, let from):
            guard let now = displayPoint(view: point, page: page) else { return }
            fill.moveLive(id, to: from.offsetBy(dx: now.x - start.x, dy: now.y - start.y))
        case .resize(let id, let page, let anchor):
            guard let now = displayPoint(view: point, page: page) else { return }
            fill.resizeLive(id, anchor: anchor, corner: now)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        if case .resize = drag { fill?.endGesture("Resize") } else { fill?.endGesture("Move") }
    }

    /// Scrolling and pinching over the pages while a tool is chosen still move the pages.
    override func scrollWheel(with event: NSEvent) {
        if let scroll = reader?.subviews.lazy.compactMap({ $0 as? NSScrollView }).first {
            scroll.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) { reader?.magnify(with: event) }

    /// **An item's right-click menu** (TE92): it is selected, and the menu offers what the palette's
    /// Aa tool would for it — then Delete.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isActive, let fill, let item = item(at: convert(event.locationInWindow, from: nil)) else { return nil }
        fill.endEditing()
        fill.select(item.id)
        return EditorPDFFillFlyouts.itemMenu(for: fill)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let fill, fill.form.hasFields, flags.subtracting(.shift).isEmpty {
            // Tab and ⇧Tab walk the form's fields; Space and Return act on the one the keyboard is on.
            if event.keyCode == Self.tabKeyCode, fill.offersFormFields {
                fill.focusNext(forward: !flags.contains(.shift))
                return
            }
            if flags.isEmpty, [Self.spaceKeyCode, Self.returnKeyCode].contains(event.keyCode),
               let name = fill.focusedField, fill.editingField == nil, let field = fill.form.field(named: name) {
                if case .choice = field.kind { openMenu(field) } else { fill.activateFocused() }
                return
            }
        }
        if let fill, flags.subtracting(.shift).isEmpty {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 51, 117 where fill.selection != nil:
                fill.deleteSelection()
                return
            case ReaderPDFView.escapeKeyCode where fill.escape():
                return
            case 123 where fill.selection != nil: fill.nudge(dx: -step, dy: 0); return
            case 124 where fill.selection != nil: fill.nudge(dx: step, dy: 0); return
            case 125 where fill.selection != nil: fill.nudge(dx: 0, dy: -step); return
            case 126 where fill.selection != nil: fill.nudge(dx: 0, dy: step); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    static let tabKeyCode: UInt16 = 48
    static let spaceKeyCode: UInt16 = 49
    static let returnKeyCode: UInt16 = 36

    override var undoManager: UndoManager? { fill?.undoManager ?? super.undoManager }

    @objc func undo(_ sender: Any?) { fill?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { fill?.undoManager.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        EditorUndoCommands.validate(menuItem, on: fill?.undoManager) ?? false
    }

    // MARK: Typing

    func controlTextDidChange(_ note: Notification) {
        if let formEditor, note.object as? NSTextField === formEditor {
            guard let fill, fill.editingField == formEditorField else { return }
            // What the field takes comes back — cut at its /MaxLen, on one line — and is shown.
            let accepted = fill.typeField(formEditor.stringValue)
            if accepted != formEditor.stringValue { formEditor.stringValue = accepted }
            return
        }
        guard let field, let id = fill?.editing else { return }
        fill?.type(field.stringValue, into: id)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        if let formEditor, note.object as? NSTextField === formEditor {
            // Only the typing this field was for: Tab may already have begun the next one.
            if let fill, fill.editingField != nil, fill.editingField == formEditorField { fill.endFieldEditing() }
            return
        }
        fill?.endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let formEditor, control === formEditor, let fill {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                fill.focusNext(forward: true)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                fill.focusNext(forward: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                fill.endFieldEditing()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if let name = fill.editingField, case .text(true)? = fill.form.field(named: name)?.kind {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    fill.endFieldEditing()
                }
                return true
            default:
                return false
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            fill?.endEditing()
            return true
        }
        return false
    }

    /// The typing field, over the item being typed into — its words at the page's scale, in the
    /// item's ink — or gone when nothing is.
    private func layoutField() {
        guard let fill, let id = fill.editing, let item = fill.items.first(where: { $0.id == id }),
              let rect = viewRect(item), let reader else {
            if let field {
                let hadKeyboard = window?.firstResponder === field.currentEditor()
                self.field = nil
                field.delegate = nil
                field.removeFromSuperview()
                if hadKeyboard { window?.makeFirstResponder(self) }
            }
            return
        }
        let field = self.field ?? {
            let made = NSTextField(string: "")
            made.isBordered = false
            made.drawsBackground = false
            made.focusRingType = .none
            made.lineBreakMode = .byClipping
            made.cell?.isScrollable = true
            made.delegate = self
            made.placeholderString = "Type"
            addSubview(made)
            self.field = made
            return made
        }()
        let text = item.words?.string ?? ""
        if field.stringValue != text { field.stringValue = text }
        field.font = item.nsFont(size: item.fontSize * reader.scaleFactor)
        field.textColor = item.color.nsColor
        field.frame = rect.insetBy(dx: 0, dy: -2).integral
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
    }

    func refresh() {
        guard isActive else {
            if field != nil { layoutField() }
            if formEditor != nil { layoutFormEditor() }
            removeAllToolTips()
            revealedField = nil
            // Put away with the keyboard here: back to the pages, where ⌘Z is the window's again.
            if let reader, let window, window.firstResponder === self { window.makeFirstResponder(reader) }
            needsDisplay = true
            return
        }
        // **Turned on while the pages have the keyboard**: take it, or ⌘Z would reach the window's
        // stack — the file operations' — until the first click on the pages.
        if let reader, let window, window.firstResponder === reader { window.makeFirstResponder(self) }
        revealFocusedField()
        layoutField()
        layoutFormEditor()
        layoutToolTips()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isActive, let fill, let reader else { return }
        let shown = shownPages
        let scale = reader.scaleFactor
        drawFields(dirtyRect)
        for item in fill.items where shown.contains(item.page) && item.id != fill.editing {
            guard let rect = viewRect(item) else { continue }
            if let words = item.words {
                let font = item.nsFont(size: item.fontSize * scale)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                NSAttributedString(string: words.string, attributes: [.font: font, .foregroundColor: item.color.nsColor,
                                                                      .paragraphStyle: paragraph]).draw(in: rect)
            } else if case .signature(let signature) = item.content, case .drawn(let strokes, _) = signature.look {
                drawStrokes(strokes, of: item, width: signature.pen.widthFraction
                            * min(item.rect.width, item.rect.height) * scale)
            }
        }
        if let selected = fill.selected, shown.contains(selected.page), let rect = viewRect(selected) {
            let accent = NSColor.controlAccentColor
            accent.setStroke()
            let ring = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 1.5
            ring.stroke()
            if fill.editing != selected.id, let handle = handle(of: selected) {
                let dot = NSBezierPath(ovalIn: CGRect(x: handle.x - Self.handleRadius, y: handle.y - Self.handleRadius,
                                                      width: 2 * Self.handleRadius, height: 2 * Self.handleRadius))
                NSColor.white.setFill()
                dot.fill()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        }
    }

    private func drawStrokes(_ strokes: [[CGPoint]], of item: EditorPDFFillItem, width: CGFloat) {
        item.color.nsColor.set()
        let r = item.rect
        for stroke in strokes {
            let points = stroke.compactMap {
                viewPoint(display: CGPoint(x: r.minX + $0.x * r.width, y: r.maxY - $0.y * r.height), page: item.page)
            }
            guard let first = points.first else { continue }
            if points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)).fill()
                continue
            }
            let path = NSBezierPath()
            path.lineWidth = max(0.5, width)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            points.dropFirst().forEach(path.line(to:))
            path.stroke()
        }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActive, let fill else { return }
        let point = convert(event.locationInWindow, from: nil)
        if handleHit(point) != nil {
            NSCursor.crosshair.set()
        } else if item(at: point) != nil {
            NSCursor.openHand.set()
        } else if takesFieldClicks, let hit = fieldHit(at: point) {
            switch fill.fieldRefusal(hit.field) == nil ? hit.field.kind : .pushButton {
            case .text: NSCursor.iBeam.set()
            case .checkbox, .radio, .choice: NSCursor.pointingHand.set()
            default: NSCursor.arrow.set()
            }
        } else if fill.armed != nil, fill.armed != .formFields, pageIndex(at: point) != nil {
            (fill.armed == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        }
    }
}

// MARK: - The PDF's own form fields (Phase 5c)

extension EditorPDFFillOverlay {
    /// A field's widget under the pointer.
    struct FieldHit {
        var field: FormField
        var widget: FormField.Widget
    }

    /// **Whether a click on a field fills it**: the Form Fields tool chosen, or no tool at all — a
    /// click on a field with Text chosen places text there, as anywhere else on the page.
    var takesFieldClicks: Bool {
        guard isActive, let fill, fill.form.hasFields else { return false }
        return fill.armed == .formFields || fill.armed == nil
    }

    /// A widget's rect in this view — `nil` when its page is not in the document.
    func widgetRect(_ widget: FormField.Widget) -> CGRect? {
        guard let reader, let page = reader.document?.page(at: widget.pageIndex) else { return nil }
        return convert(reader.convert(widget.rect, from: page), from: reader)
    }

    /// Every widget on a page on screen, in document order.
    var shownWidgets: [FieldHit] {
        guard let fill, fill.form.hasFields else { return [] }
        let shown = shownPages
        return fill.form.fields.flatMap { field in
            field.widgets.filter { shown.contains($0.pageIndex) }.map { FieldHit(field: field, widget: $0) }
        }
    }

    /// The topmost field widget under `point`, on a page on screen.
    func fieldHit(at point: CGPoint) -> FieldHit? {
        shownWidgets.reversed().first { widgetRect($0.widget)?.contains(point) == true }
    }

    /// What a click on a field does — by kind; a field that takes no value only lets the keyboard go.
    func click(_ hit: FieldHit) {
        guard let fill else { return }
        fill.endEditing()
        guard fill.fieldRefusal(hit.field) == nil else {
            fill.focusField(nil)
            return
        }
        switch hit.field.kind {
        case .text: fill.beginFieldEditing(hit.field.name)
        case .checkbox: fill.toggleCheckbox(hit.field.name)
        case .radio: hit.widget.exportValue.map { fill.selectRadio(hit.field.name, export: $0) }
        case .choice:
            fill.focusField(hit.field.name)
            openMenu(hit.field, at: hit.widget)
        case .signature, .pushButton: fill.focusField(nil)
        }
    }

    /// **A choice field's menu**: its options, the one it has ticked — and for a combo that takes a
    /// value of its own, a way to type one.
    func choiceMenu(for field: FormField) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let fill else { return menu }
        let current = fill.text(of: field)
        for option in field.options {
            let item = EditorClosureMenuItem(title: option.isEmpty ? "(none)" : option) { [weak fill] in
                fill?.choose(field.name, option: option)
            }
            item.state = option == current ? .on : .off
            menu.addItem(item)
        }
        if case .choice(_, true) = field.kind {
            if !field.options.isEmpty { menu.addItem(.separator()) }
            menu.addItem(EditorClosureMenuItem(title: "Type a Value…") { [weak fill] in
                fill?.beginFieldEditing(field.name)
            })
        }
        return menu
    }

    func openMenu(_ field: FormField, at widget: FormField.Widget? = nil) {
        let shown = Set(shownWidgets.filter { $0.field.name == field.name }.map(\.widget))
        guard let widget = widget ?? field.widgets.first(where: shown.contains) ?? field.widgets.first,
              let rect = widgetRect(widget) else { return }
        presentMenu(choiceMenu(for: field), rect, self)
    }

    /// Tab onto a field off screen scrolls it on — once per field the keyboard moves to.
    func revealFocusedField() {
        guard let fill, let reader, let name = fill.focusedField else { revealedField = nil; return }
        guard name != revealedField, let field = fill.form.field(named: name), let widget = field.widgets.first,
              let page = reader.document?.page(at: widget.pageIndex) else { return }
        revealedField = name
        if !EditorPDFPageView.isInSight(widget.rect, on: page, in: reader) {
            reader.go(to: widget.rect.insetBy(dx: -24, dy: -48), on: page)
        }
    }

    /// The typing field over the form field being filled — the field's words in a face sized to its
    /// box — or gone when none is.
    func layoutFormEditor() {
        guard let fill, isActive, let name = fill.editingField, let field = fill.form.field(named: name),
              let widget = field.widgets.first(where: { shownPages.contains($0.pageIndex) }) ?? field.widgets.first,
              let rect = widgetRect(widget) else {
            if let formEditor {
                let hadKeyboard = window?.firstResponder === formEditor.currentEditor()
                self.formEditor = nil
                formEditorField = nil
                formEditor.delegate = nil
                formEditor.removeFromSuperview()
                if hadKeyboard { window?.makeFirstResponder(self) }
            }
            return
        }
        let editor = formEditor ?? {
            let made = NSTextField(string: "")
            made.isBordered = false
            made.drawsBackground = true
            made.backgroundColor = .white
            made.textColor = .black
            made.focusRingType = .none
            made.delegate = self
            addSubview(made)
            formEditor = made
            return made
        }()
        let multiline: Bool = { if case .text(true) = field.kind { return true }; return false }()
        editor.usesSingleLineMode = !multiline
        editor.cell?.wraps = multiline
        editor.cell?.isScrollable = !multiline
        editor.lineBreakMode = multiline ? .byWordWrapping : .byClipping
        editor.font = .systemFont(ofSize: Self.valueFontSize(for: rect, multiline: multiline, scale: reader?.scaleFactor ?? 1))
        if formEditorField != name || editor.currentEditor() == nil {
            let text = fill.text(of: field)
            if editor.stringValue != text { editor.stringValue = text }
        }
        formEditorField = name
        editor.frame = rect.integral
        if editor.currentEditor() == nil { window?.makeFirstResponder(editor) }
    }

    /// A value's point size in a widget of `rect` (view points): the box's height less its margins,
    /// at most 12pt on the page — what Acrobat's auto size comes to on a one-line field.
    static func valueFontSize(for rect: CGRect, multiline: Bool, scale: CGFloat) -> CGFloat {
        let ceiling = 12 * scale
        if multiline { return max(4, min(10 * scale, ceiling)) }
        return max(4, min((rect.height - 3) * 0.72, ceiling))
    }

    /// The hover reason on every field that takes no value — signature, button, read-only.
    func layoutToolTips() {
        removeAllToolTips()
        guard let fill, isActive else { return }
        for hit in shownWidgets where fill.fieldRefusal(hit.field) != nil {
            if let rect = widgetRect(hit.widget) { addToolTip(rect, owner: self, userData: nil) }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        toolTip(at: point) ?? ""
    }

    /// Why the field under `point` takes no value, or `nil`.
    func toolTip(at point: CGPoint) -> String? {
        guard let fill, let hit = fieldHit(at: point) else { return nil }
        return fill.fieldRefusal(hit.field)
    }

    /// **Each widget tinted** — the accent where a value can go, grey where none can — a changed one
    /// covered and drawn with its new value, and the keyboard's field ringed.
    func drawFields(_ dirtyRect: NSRect) {
        guard let fill, fill.form.hasFields else { return }
        let accent = NSColor.controlAccentColor
        let scale = reader?.scaleFactor ?? 1
        for hit in shownWidgets {
            guard let rect = widgetRect(hit.widget), rect.intersects(dirtyRect.insetBy(dx: -4, dy: -4)) else { continue }
            let open = fill.fieldRefusal(hit.field) == nil
            let changed = fill.values[hit.field.name] != nil
            let box = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            if changed {
                // PDFKit still draws the file's own value underneath: cover it.
                NSColor.white.setFill()
                box.fill()
            }
            (open ? accent.withAlphaComponent(0.12) : NSColor.gray.withAlphaComponent(0.10)).setFill()
            box.fill()
            (open ? accent.withAlphaComponent(0.5) : NSColor.gray.withAlphaComponent(0.45)).setStroke()
            box.lineWidth = 1
            if !open { box.setLineDash([3, 2], count: 2, phase: 0) }
            box.stroke()
            if changed, hit.field.name != fill.editingField {
                drawValue(hit.field, widget: hit.widget, in: rect, scale: scale)
            }
            if hit.field.name == fill.focusedField {
                accent.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 2.5, yRadius: 2.5)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    /// A changed field's value, as the copy will show it.
    private func drawValue(_ field: FormField, widget: FormField.Widget, in rect: CGRect, scale: CGFloat) {
        guard let fill else { return }
        let ink = NSColor.black
        switch field.kind {
        case .text, .choice:
            let multiline: Bool = { if case .text(true) = field.kind { return true }; return false }()
            let font = NSFont.systemFont(ofSize: Self.valueFontSize(for: rect, multiline: multiline, scale: scale))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = multiline ? .byWordWrapping : .byClipping
            let words = NSAttributedString(string: fill.text(of: field),
                                           attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
            let inset = rect.insetBy(dx: 2, dy: 1)
            if multiline {
                words.draw(with: inset, options: [.usesLineFragmentOrigin], context: nil)
            } else {
                let height = font.ascender - font.descender
                words.draw(in: CGRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height))
            }
        case .checkbox:
            guard fill.isOn(field) else { return }
            let side = min(rect.width, rect.height)
            let font = NSFont.systemFont(ofSize: side * 0.8, weight: .semibold)
            let mark = NSAttributedString(string: "✓", attributes: [.font: font, .foregroundColor: ink])
            let size = mark.size()
            mark.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        case .radio:
            guard fill.isOn(field, widget: widget) else { return }
            let d = min(rect.width, rect.height) * 0.5
            ink.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
        case .signature, .pushButton:
            break
        }
    }
}
