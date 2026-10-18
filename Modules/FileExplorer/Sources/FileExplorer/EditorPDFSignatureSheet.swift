import AppKit
import PDFToolkitCore
import SwiftUI
import Design

/// **Add Signature / Add Initials** (mockup 18): drawn on a pad or typed in a script face, and
/// saved on this Mac unless the box is unticked. Adding chooses it, so the next click places it.
struct EditorPDFAddSignatureSheet: View {
    let fill: EditorPDFFillSign
    let kind: EditorPDFSignature.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var strokes: [[CGPoint]] = []
    @State private var typed = ""
    @State private var keep = true
    /// The window's hue, for the Draw / Type picker — `accentedSegments` takes the hue itself.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    static let privacy = "This places a picture of your signature on the page. It isn’t a certificate-based digital "
        + "signature. Saved signatures stay on this Mac as pen strokes, and are never synced or written to the log."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(kind.title)")
                .scaledFont(.system(size: 13, weight: .semibold))
            Picker("", selection: $typing) {
                Text("Draw").tag(false)
                Text("Type").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accentedSegments(LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
            .fixedSize()
            if typing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(kind == .signature ? "Your name" : "Your initials", text: $typed)
                        .textFieldStyle(.roundedBorder)
                    Text(typed.isEmpty ? " " : typed)
                        .font(Font(PDFToolkit.scriptOrSystemFont(size: 32, script: true)))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(.tertiary, style: StrokeStyle(dash: [4])))
                }
            } else {
                ZStack(alignment: .bottomLeading) {
                    EditorPDFSignaturePad(strokes: $strokes)
                    Text("Draw with the trackpad or mouse")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(.tertiary, style: StrokeStyle(dash: [4])))
            }
            Toggle("Save on this Mac for next time", isOn: $keep)
            Text(Self.privacy)
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") { if typing { typed = "" } else { strokes = [] } }
                    .disabled(typing ? typed.isEmpty : strokes.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(made == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var made: EditorPDFSignature? {
        if typing {
            let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : EditorPDFSignature(kind: kind, look: .typed(words))
        }
        return EditorPDFSignature.drawn(strokes, kind: kind)
    }

    private func add() {
        guard let signature = made else { return }
        if keep { fill.store.add(signature) }
        fill.armed = .signature(signature)
        dismiss()
    }
}

/// The pad a signature is drawn on: a stroke per drag, in the pad's own points, y down.
struct EditorPDFSignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]

    final class PadView: NSView {
        var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
        var onChange: (([[CGPoint]]) -> Void)?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            strokes.append([convert(event.locationInWindow, from: nil)])
        }

        override func mouseDragged(with event: NSEvent) {
            guard !strokes.isEmpty else { return }
            strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) { onChange?(strokes) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setStroke()
            let base = NSBezierPath()
            base.move(to: CGPoint(x: 20, y: bounds.maxY - 28))
            base.line(to: CGPoint(x: bounds.maxX - 20, y: bounds.maxY - 28))
            base.stroke()
            EditorPDFFillColor.blue.nsColor.set()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                if stroke.count == 1 {
                    NSBezierPath(ovalIn: CGRect(x: first.x - 1.2, y: first.y - 1.2, width: 2.4, height: 2.4)).fill()
                    continue
                }
                let path = NSBezierPath()
                path.lineWidth = 2.2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: first)
                stroke.dropFirst().forEach(path.line(to:))
                path.stroke()
            }
        }
    }

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.onChange = { strokes = $0 }
        view.setAccessibilityLabel("Signature pad")
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.onChange = { strokes = $0 }
        if view.strokes != strokes { view.strokes = strokes }
    }
}
