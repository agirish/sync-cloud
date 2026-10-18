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
/// what PDFKit says about every other item. While the toolbar is up this view takes the keyboard
/// whenever the reader would — it is inside the reader, so the pages still "have focus" for ⌘+ and
/// ⌘− — and keys it does not use go on up to the reader (⌥← and ⌥→).
///
/// Drawing matches the copy: words in the toolkit's own face at the item's point size, a drawn
/// signature as strokes of the toolkit's pen width — so what is on screen is what Save writes.
final class EditorPDFFillOverlay: NSView, NSTextFieldDelegate, NSMenuItemValidation {
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
        if fill.armed != nil, pageIndex(at: local) != nil { return self }
        if fill.selection != nil || fill.editing != nil { return self }
        return nil
    }

    override var acceptsFirstResponder: Bool { isActive }

    override func mouseDown(with event: NSEvent) {
        guard let fill else { return }
        window?.makeFirstResponder(self)
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
        } else if fill.armed != nil, let page = pageIndex(at: point), let at = displayPoint(view: point, page: page) {
            fill.place(at: at, page: page)
        } else {
            fill.endEditing()
            fill.select(nil)
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

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
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

    override var undoManager: UndoManager? { fill?.undoManager ?? super.undoManager }

    @objc func undo(_ sender: Any?) { fill?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { fill?.undoManager.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        EditorUndoCommands.validate(menuItem, on: fill?.undoManager) ?? false
    }

    // MARK: Typing

    func controlTextDidChange(_ note: Notification) {
        guard let field, let id = fill?.editing else { return }
        fill?.type(field.stringValue, into: id)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        fill?.endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
        field.font = PDFToolkit.scriptOrSystemFont(size: max(4, item.fontSize * reader.scaleFactor), script: false)
        field.textColor = item.color.nsColor
        field.frame = rect.insetBy(dx: 0, dy: -2).integral
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
    }

    func refresh() {
        guard isActive else {
            if field != nil { layoutField() }
            // Put away with the keyboard here: back to the pages, where ⌘Z is the window's again.
            if let reader, let window, window.firstResponder === self { window.makeFirstResponder(reader) }
            needsDisplay = true
            return
        }
        // **Turned on while the pages have the keyboard**: take it, or ⌘Z would reach the window's
        // stack — the file operations' — until the first click on the pages.
        if let reader, let window, window.firstResponder === reader { window.makeFirstResponder(self) }
        layoutField()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isActive, let fill, let reader else { return }
        let shown = shownPages
        let scale = reader.scaleFactor
        for item in fill.items where shown.contains(item.page) && item.id != fill.editing {
            guard let rect = viewRect(item) else { continue }
            if let words = item.words {
                let font = PDFToolkit.scriptOrSystemFont(size: max(4, item.fontSize * scale), script: words.script)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                NSAttributedString(string: words.string, attributes: [.font: font, .foregroundColor: item.color.nsColor,
                                                                      .paragraphStyle: paragraph]).draw(in: rect)
            } else if case .signature(let signature) = item.content, case .drawn(let strokes, _) = signature.look {
                drawStrokes(strokes, of: item, width: FillSignSignature.defaultPenWidthFraction
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
        } else if fill.armed != nil, pageIndex(at: point) != nil {
            (fill.armed == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        }
    }
}
