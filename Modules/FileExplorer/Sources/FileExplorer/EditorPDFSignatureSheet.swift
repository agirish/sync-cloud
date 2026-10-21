import AppKit
import PDFToolkitCore
import SwiftUI
import Design

/// **Add Signature / Add Initials** (mockup 18; Signature Styles TE88–TE91, TE94): drawn on a pad
/// or typed in one of the Mac's handwriting faces, in Blue or Black, and saved on this Mac unless
/// the box is unticked. Adding chooses it, so the next click places it.
///
/// **The pad, the preview and the face tiles are paper-white in either appearance** — the ink shows
/// as it will print, where blue on a dark pad was close to unreadable.
struct EditorPDFAddSignatureSheet: View {
    let fill: EditorPDFFillSign
    let kind: EditorPDFSignature.Kind
    @Environment(\.dismiss) private var dismiss
    /// **Opens on Type, the caret in the name field** (decision BC, 2026-10-20): on Draw, as it
    /// opened, there was no key to reach Type without the Mac's Keyboard navigation setting.
    @State private var typing = true
    @FocusState private var nameFocused: Bool
    @State private var strokes: [[CGPoint]] = []
    @State private var typed = ""
    @State private var keep = true
    @State private var ink: EditorPDFFillColor
    @State private var makeInitials = true
    /// The last face, pen and smoothing chosen — remembered in the store's defaults.
    @AppStorage private var faceRaw: String
    @AppStorage private var penRaw: String
    @AppStorage private var smooth: Bool
    /// The window's hue, for the Draw / Type picker — `accentedSegments` takes the hue itself.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    init(fill: EditorPDFFillSign, kind: EditorPDFSignature.Kind) {
        self.fill = fill
        self.kind = kind
        _ink = State(initialValue: fill.color)
        let defaults = fill.store.defaults
        _faceRaw = AppStorage(wrappedValue: EditorPDFSignatureFace.snellRoundhand.rawValue,
                              EditorPDFSignatureStore.faceKey, store: defaults)
        _penRaw = AppStorage(wrappedValue: EditorPDFPen.medium.rawValue, EditorPDFSignatureStore.penKey, store: defaults)
        _smooth = AppStorage(wrappedValue: true, EditorPDFSignatureStore.smoothKey, store: defaults)
    }

    static let privacy = "This places a picture of your signature on the page. It isn’t a certificate-based digital "
        + "signature. Saved signatures stay on this Mac — drawn ones as pen strokes, typed ones as their words — "
        + "and are never synced or written to the log."

    /// The sheet's floor and the width it opens at (TE134) — the 440 it always had.
    static let minWidth: CGFloat = 440
    static let idealWidth: CGFloat = 440

    /// What paper is: the pad, the preview and the face tiles in both appearances.
    static let paper = Color.white
    static let paperEdge = Color(white: 0.72)
    static let paperCaption = Color(white: 0.45)

    /// The window's hue: the Draw / Type and Pen pickers, and the ring on the chosen face and ink.
    private var hue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var face: EditorPDFSignatureFace { EditorPDFSignatureFace(rawValue: faceRaw) ?? .snellRoundhand }
    private var pen: EditorPDFPen { EditorPDFPen(rawValue: penRaw) ?? .medium }
    private var words: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var initials: String { EditorPDFSignature.initials(of: words) }

    private var offersInitials: Bool { typing && fill.offersInitials(with: kind) }

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
            .accentedSegments(hue)
            .fixedSize()
            if typing { typePane } else { drawPane }
            HStack(spacing: 8) {
                Text("Ink").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(EditorPDFFillColor.allCases, id: \.self) { swatch($0) }
            }
            Toggle("Save on this Mac for next time", isOn: $keep)
            if keep, let full = Self.fullCaption(kind, store: fill.store) {
                Text(full)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offersInitials {
                Toggle(isOn: $makeInitials) {
                    HStack(spacing: 4) {
                        Text("Also make initials")
                        // On a chip of paper, as the face tiles are: black ink on a dark sheet
                        // was close to unreadable (TE135).
                        Text(initials.isEmpty ? "—" : initials)
                            .font(Font(PDFToolkit.font(size: 17, script: true, font: face.toolkit)))
                            .foregroundStyle(Color(nsColor: ink.nsColor))
                            .padding(.horizontal, 5)
                            .background(Self.paper, in: RoundedRectangle(cornerRadius: Radius.chip))
                            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color(white: 0.84)))
                            .padding(.horizontal, 2)
                        Text("in this style")
                    }
                }
                .disabled(!keep)
                .help(keep ? "Saves initials from the first letter of each word, in the same face"
                           : "Initials are saved with the signature — tick Save on this Mac first")
            }
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
                    // The window's hue, deepened for its white label, as the tool sheets' default
                    // buttons wear it (TE101).
                    .accentedProminent(hue)
                    .disabled(made == nil)
            }
        }
        .padding(18)
        // A floor, not a fixed width, as the tool sheets have (TE134). Measured 2026-10-20, the
        // content needs 264pt at every text size — the pickers, toggles and buttons keep the
        // system's size — so this opens at 440 at all of them; the floor is for what is added next.
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth)
    }

    private var typePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(kind == .signature ? "Your name" : "Your initials", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
            Text(typed.isEmpty ? " " : typed)
                .font(Font(PDFToolkit.font(size: face == .zapfino ? 22 : 34, script: true, font: face.toolkit)))
                .foregroundStyle(Color(nsColor: ink.nsColor))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Self.paper, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Self.paperEdge, style: StrokeStyle(dash: [4])))
            Text("Style").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(EditorPDFSignatureFace.allCases, id: \.self) { tile($0) }
            }
        }
    }

    /// **A face, shown in the name as typed** (TE88) — chosen, and remembered for next time.
    private func tile(_ option: EditorPDFSignatureFace) -> some View {
        let chosen = option == face
        return Button { faceRaw = option.rawValue } label: {
            VStack(spacing: 2) {
                Text(words.isEmpty ? (kind == .signature ? "Your name" : "AB") : words)
                    .font(Font(PDFToolkit.font(size: option == .zapfino ? 9 : 16, script: true, font: option.toolkit)))
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, minHeight: 26)
                Text(option.title)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(Self.paperCaption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(Self.paper, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                .strokeBorder(chosen ? hue.accentColor : Color(white: 0.84), lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var drawPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                EditorPDFSignaturePad(strokes: $strokes, ink: ink, pen: pen, smooth: smooth)
                Text("Draw with the trackpad or mouse")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(Self.paperCaption)
                    .padding(.leading, 20)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .frame(height: 130)
            .background(Self.paper, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Self.paperEdge, style: StrokeStyle(dash: [4])))
            HStack(spacing: 10) {
                Text("Pen").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Pen", selection: $penRaw) {
                    ForEach(EditorPDFPen.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(hue)
                .fixedSize()
            }
            Toggle("Smooth out wobble", isOn: $smooth)
                .help("Draws the strokes in gentle curves rather than every jitter of the trackpad")
        }
    }

    private func swatch(_ option: EditorPDFFillColor) -> some View {
        let chosen = option == ink
        return Button { ink = option } label: {
            Circle()
                .fill(Color(nsColor: option.nsColor))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(chosen ? hue.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(option.inkTitle)
        .accessibilityLabel(option.inkTitle)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// **What the sheet says when one more lets the oldest go** (TE100) — `nil` with room to spare.
    static func fullCaption(_ kind: EditorPDFSignature.Kind, store: EditorPDFSignatureStore) -> String? {
        guard store.isFull(kind) else { return nil }
        let n = EditorPDFSignatureStore.limit
        return kind == .signature
            ? "You have \(n) saved signatures, the most Edit keeps. Adding this one replaces the oldest."
            : "You have \(n) saved initials, the most Edit keeps. Adding these replaces the oldest."
    }

    private var made: EditorPDFSignature? {
        if typing {
            return words.isEmpty ? nil : EditorPDFSignature(kind: kind, look: .typed(words), face: face)
        }
        return EditorPDFSignature.drawn(smooth ? EditorPDFSignature.smoothed(strokes) : strokes, kind: kind, pen: pen)
    }

    private func add() {
        guard let signature = made else { return }
        fill.add(signature, keep: keep, makeInitials: offersInitials && makeInitials, ink: ink)
        dismiss()
    }
}

/// The pad a signature is drawn on: a stroke per drag, in the pad's own points, y down — drawn in
/// the chosen ink and pen, smoothed as it will be saved when smoothing is on.
struct EditorPDFSignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    var ink: EditorPDFFillColor = .blue
    var pen: EditorPDFPen = .medium
    var smooth = false

    final class PadView: NSView {
        var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
        var ink = EditorPDFFillColor.blue { didSet { needsDisplay = true } }
        var pen = EditorPDFPen.medium { didSet { needsDisplay = true } }
        var smooth = false { didSet { needsDisplay = true } }
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
            // The paper's rule, not the window's separator: the pad is white in either appearance.
            NSColor(white: 0.8, alpha: 1).setStroke()
            let base = NSBezierPath()
            base.move(to: CGPoint(x: 20, y: bounds.maxY - 28))
            base.line(to: CGPoint(x: bounds.maxX - 20, y: bounds.maxY - 28))
            base.stroke()
            ink.nsColor.set()
            let width = pen.padWidth
            for stroke in smooth ? EditorPDFSignature.smoothed(strokes) : strokes {
                guard let first = stroke.first else { continue }
                if stroke.count == 1 {
                    NSBezierPath(ovalIn: CGRect(x: first.x - width / 2 - 0.1, y: first.y - width / 2 - 0.1,
                                                width: width + 0.2, height: width + 0.2)).fill()
                    continue
                }
                let path = NSBezierPath()
                path.lineWidth = width
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
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.onChange = { strokes = $0 }
        if view.strokes != strokes { view.strokes = strokes }
        if view.ink != ink { view.ink = ink }
        if view.pen != pen { view.pen = pen }
        if view.smooth != smooth { view.smooth = smooth }
    }
}
