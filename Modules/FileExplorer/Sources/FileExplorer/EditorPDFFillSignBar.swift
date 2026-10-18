import AppKit
import PDFToolkitCore
import SwiftUI
import Design

/// **The header's Fill & Sign button** — beside the layout menu and before Tools (mockup 17). It
/// turns the toolbar under the header on and off, and is lit while it is on.
///
/// **It sheds its word on the narrow rungs** (``EditorPDFHeaderControls/Rung/wordsFillAndSign``):
/// the glyph alone is the layout button's 18pt, so the header's width test counts it as Tools is
/// counted.
struct EditorPDFFillSignButton: View {
    @ObservedObject var fill: EditorPDFFillSign
    let accent: Color
    var worded: Bool

    var body: some View {
        Button { fill.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "signature")
                    .scaledFont(.system(size: 11, weight: .semibold))
                if worded {
                    Text("Fill & Sign")
                        .scaledFont(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, worded ? 5 : 0)
            .frame(width: worded ? nil : 18, height: 18)
            .foregroundStyle(fill.isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
            .background(fill.isOn ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .accessibilityLabel("Fill & Sign")
        .accessibilityValue(fill.isOn ? "On" : "Off")
        .help(fill.refusal == nil
              ? (fill.isOn ? "Put Fill & Sign away" : "Fill & Sign — place text, dates, marks and signatures, then save a filled copy")
              : "Fill & Sign isn’t available for this PDF")
    }
}

/// **Fill & Sign's toolbar, under the header** (mockup 17): what to place, its size and ink, and
/// Discard and Save Filled Copy. Nothing it does writes until Save Filled Copy.
///
/// **It narrows in steps, as the header does**: worded, then its tools as glyphs, then on two rows
/// — what to place on the first, size, ink and the buttons on the second — which is what the
/// narrowest column gets (`EditorPDFFillSignBarWidthTests`).
struct EditorPDFFillSignBar: View {
    @ObservedObject var fill: EditorPDFFillSign
    @ObservedObject var tools: EditorPDFTools
    let accent: Color
    private let signatureAnchor = EditorHeadingMenuAnchor()
    private let initialsAnchor = EditorHeadingMenuAnchor()

    enum Rung: CaseIterable {
        case worded
        case glyphs
        case twoRows

        var wordsTools: Bool { self == .worded }
    }

    var body: some View {
        if fill.isOn {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    ForEach(Rung.allCases, id: \.self) { rung in
                        content(rung)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }
            .sheet(item: $fill.addingSignature) { kind in
                EditorPDFAddSignatureSheet(fill: fill, kind: kind)
            }
        }
    }

    @ViewBuilder
    func content(_ rung: Rung) -> some View {
        if rung == .twoRows {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) { placing(rung) }
                HStack(spacing: 4) {
                    styling
                    Spacer(minLength: 6)
                    actions
                }
            }
        } else {
            HStack(spacing: 4) {
                placing(rung)
                separator
                styling
                Spacer(minLength: 6)
                actions
            }
        }
    }

    @ViewBuilder
    private func placing(_ rung: Rung) -> some View {
        toolButton("Text", symbol: "textformat", tool: .text, worded: rung.wordsTools)
        toolButton("Date", symbol: "calendar", tool: .date, worded: rung.wordsTools)
        separator
        ForEach(EditorPDFFillMark.allCases, id: \.self) { mark in
            markButton(mark)
        }
        separator
        signatureButton(.signature, worded: rung.wordsTools, anchor: signatureAnchor)
        signatureButton(.initials, worded: rung.wordsTools, anchor: initialsAnchor)
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 3)
    }

    private func isArmed(_ tool: EditorPDFFillTool) -> Bool { fill.armed == tool }

    private func toolButton(_ title: String, symbol: String, tool: EditorPDFFillTool, worded: Bool) -> some View {
        Button { fill.armed = isArmed(tool) ? nil : tool } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if worded { Text(title).lineLimit(1).fixedSize() }
            }
            .scaledFont(.system(size: 11, weight: .medium))
            .modifier(Lit(on: isArmed(tool), accent: accent, worded: worded))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isArmed(tool) ? .isSelected : [])
        .help(EditorPDFFillTool.text == tool ? "Text — click on the page to type" : tool.hint)
    }

    private func markButton(_ mark: EditorPDFFillMark) -> some View {
        Button { fill.armed = isArmed(.mark(mark)) ? nil : .mark(mark) } label: {
            Text(mark.rawValue)
                .scaledFont(.system(size: 12, weight: .bold))
                .modifier(Lit(on: isArmed(.mark(mark)), accent: accent, worded: false))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .accessibilityLabel(mark.title)
        .accessibilityAddTraits(isArmed(.mark(mark)) ? .isSelected : [])
        .help("\(mark.title) — click on the page to place it")
    }

    private func signatureButton(_ kind: EditorPDFSignature.Kind, worded: Bool,
                                 anchor: EditorHeadingMenuAnchor) -> some View {
        let lit: Bool = {
            if case .signature(let signature) = fill.armed { return signature.kind == kind }
            return false
        }()
        return Button {
            EditorPDFSignatureMenu.present(EditorPDFSignatureMenu.menu(for: fill, kind: kind), from: anchor.view)
        } label: {
            HStack(spacing: 3) {
                if kind == .signature {
                    Image(systemName: "signature")
                } else if !worded {
                    Text("AB").scaledFont(.system(size: 9, weight: .bold))
                }
                if worded { Text(kind.title).lineLimit(1).fixedSize() }
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .scaledFont(.system(size: 11, weight: .medium))
            .modifier(Lit(on: lit, accent: accent, worded: true))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .background(EditorHeadingMenuAnchor.Probe(anchor: anchor))
        .accessibilityLabel(kind.title)
        .help("\(kind.title) — choose a saved one, or add one")
    }

    @ViewBuilder
    private var styling: some View {
        Button { fill.stepFontSize(bigger: false) } label: {
            Image(systemName: "textformat.size.smaller").scaledFont(.system(size: 11, weight: .medium))
                .modifier(Lit(on: false, accent: accent, worded: false))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!fill.canStepFontSize(bigger: false))
        .accessibilityLabel("Smaller text")
        .help("Smaller text")
        Button { fill.stepFontSize(bigger: true) } label: {
            Image(systemName: "textformat.size.larger").scaledFont(.system(size: 11, weight: .medium))
                .modifier(Lit(on: false, accent: accent, worded: false))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!fill.canStepFontSize(bigger: true))
        .accessibilityLabel("Bigger text")
        .help("Bigger text")
        ForEach(EditorPDFFillColor.allCases, id: \.self) { ink in
            Button { fill.setColor(ink) } label: {
                Circle()
                    .fill(Color(nsColor: ink.nsColor))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                    .padding(2)
                    .overlay(Circle().strokeBorder(fill.color == ink ? accent : .clear, lineWidth: 1.5))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.glyph, tint: accent))
            .accessibilityLabel(ink.title)
            .accessibilityAddTraits(fill.color == ink ? .isSelected : [])
            .help(ink.title)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Discard") { fill.discard() }
            .controlSize(.small)
            .disabled(fill.items.isEmpty)
            .help("Remove everything placed — ⌘Z brings it back")
        Button("Save Filled Copy") { Task { await fill.save() } }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!fill.hasUnsavedItems || tools.running != nil)
            .help("Write a copy with these items beside the original — the original isn’t changed")
    }

    /// A chosen tool's wash, the header button's.
    private struct Lit: ViewModifier {
        let on: Bool
        let accent: Color
        let worded: Bool

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, worded ? 5 : 0)
                .frame(minWidth: 20, minHeight: 20)
                .foregroundStyle(on ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                .background(on ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
    }
}

/// **The Signature and Initials menus** (mockup 18): the saved ones, drawn — choosing one makes the
/// next click place it — then Add…, and a submenu to delete a saved one. Built when pressed, as the
/// zoom's menu is.
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
                string: string, attributes: [.font: PDFToolkit.scriptOrSystemFont(size: 18, script: true)])
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
                path.lineWidth = 1.4
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

    static func present(_ menu: NSMenu, from view: NSView?) {
        guard let view else { return }
        let below = view.isFlipped ? NSPoint(x: 0, y: view.bounds.maxY + 2) : NSPoint(x: 0, y: -2)
        menu.popUp(positioning: nil, at: below, in: view)
    }
}

/// The header's second row while Fill & Sign holds unsaved items — "4 items not saved" where the
/// Read only tag sits, which comes back once they are saved or discarded.
struct EditorPDFFillCaption<Tag: View>: View {
    @ObservedObject var fill: EditorPDFFillSign
    @ViewBuilder let tag: Tag

    var body: some View {
        if let caption = fill.unsavedCaption {
            Text(caption).lineLimit(1).help("Nothing is written until Save Filled Copy — the original stays as it is")
        } else {
            tag
        }
    }
}
