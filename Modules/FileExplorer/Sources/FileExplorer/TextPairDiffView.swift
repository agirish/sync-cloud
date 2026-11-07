import AppKit
import Design
import SwiftUI

/// The read-only side-by-side text diff of two files. Nothing here can write.
struct TextPairDiffView: View {

    let diff: TextPairDiff
    /// Lines above the rows when something about the files, not their content, differs: mixed
    /// line endings, a lossy decode. Empty when there is nothing to say.
    let notes: [String]
    let accent: Color

    /// The region ↑/↓ last stepped to, or nil while the pane still shows the top of the file. See
    /// ``TextPairDiff/steppedRegion(from:direction:count:)``.
    @Binding var focusedRegion: Int?

    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        let gutter = Self.gutterWidth(largestNumber: diff.largestLineNumber, scale: fontScale)
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.rows) { row in
                            self.row(row, gutter: gutter).id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // No animation, and no `withAnimation(nil)`: `proxy.scrollTo` outside a
                // transaction doesn't animate, so a wrapper would only be a site for
                // `WithAnimationCoverageScanTests` to classify. Steps land instantly.
                .onChange(of: focusedRegion) { _, index in
                    guard let index, diff.regions.indices.contains(index) else { return }
                    proxy.scrollTo(diff.regions[index].lowerBound, anchor: .center)
                }
            }
        }
    }

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(diff.summary)
                    .scaledFont(.system(size: 11.5, weight: diff.isIdentical ? .regular : .semibold))
                    .foregroundStyle(diff.isIdentical ? Color.secondary : Color.primary)
                Spacer(minLength: 8)
                if !diff.regions.isEmpty {
                    // Invisible until a change is stepped to, since "1 of 5" would name one not
                    // scrolled to. `opacity`, not `if`, keeps its width so the stepper doesn't
                    // jump on the first press.
                    Text("\(min((focusedRegion ?? 0) + 1, diff.regions.count)) of \(diff.regions.count)")
                        .scaledFont(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .opacity(focusedRegion == nil ? 0 : 1)
                        .accessibilityHidden(focusedRegion == nil)
                    stepper
                }
            }
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous change")
                .help(ShortcutHint.tooltip("Previous change", "↑"))
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next change")
                .help(ShortcutHint.tooltip("Next change", "↓"))
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .controlSize(.small)
    }

    /// Wraps around both ways; the count beside it shows where the reader is. The rule is
    /// ``TextPairDiff/steppedRegion(from:direction:count:)``, shared with the ↑/↓ keys.
    private func step(_ direction: Int) {
        focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion, direction: direction,
                                                   count: diff.regions.count)
    }

    // MARK: One row

    @ViewBuilder
    private func row(_ row: TextPairDiff.Row, gutter: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            side(number: row.leftNumber, text: row.left, segments: row.leftSegments, gutter: gutter)
            Divider()
            side(number: row.rightNumber, text: row.right, segments: row.rightSegments, gutter: gutter)
        }
        .background(row.kind == .same ? Color.clear : tintRow(row.kind))
    }

    private func side(number: Int?, text: String?,
                      segments: [TextPairDiff.Segment]?, gutter: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .scaledFont(.system(size: Self.gutterPointSize, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            lineText(text, segments: segments)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line, with its changed runs picked out. Concatenated `Text`s, one laid-out string, not
    /// an `HStack`, which would push the row on a long line and wrap between runs at random.
    @ViewBuilder
    private func lineText(_ text: String?, segments: [TextPairDiff.Segment]?) -> some View {
        if let segments, !segments.isEmpty {
            segments.reduce(Text("")) { partial, segment in
                partial + Text(segment.text)
                    .foregroundColor(segment.changed ? Color.primary : Color.secondary)
                    .fontWeight(segment.changed ? .semibold : .regular)
            }
            .scaledFont(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
        } else if let text {
            Text(Self.rendered(text))
                .scaledFont(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            // No line on this side: a marker, not an empty cell, so it can't be read as a blank
            // line.
            Text("—")
                .scaledFont(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: The line numbers

    /// The line numbers' size at the default text size.
    static let gutterPointSize: CGFloat = 10

    /// The line-number column, as wide as the largest number at the drawn text size, so a long
    /// file's numbers are never cut. At least three digits wide; monospaced, so one digit's width
    /// times the count, plus a point for rounding.
    static func gutterWidth(largestNumber: Int, scale: CGFloat) -> CGFloat {
        let size = FontSize.scaledPointSize(gutterPointSize, scale: scale)
        let font = NSFont.checkedMonospacedSystemFont(ofSize: size, weight: .regular)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        let digits = max(String(max(largestNumber, 0)).count, 3)
        return (CGFloat(digits) * digit).rounded(.up) + 1
    }

    // MARK: How much of a line is drawn

    /// The most characters one side of one row will lay out. A row whose word pass was refused
    /// (``TextPairDiff/maxIntraLineWork``) is drawn whole, and laying out a 4 MiB line would spend
    /// in layout the cost the refusal avoided. 4,000 is far past any line a person reads.
    static let maxRenderedCharacters = 4_000

    /// The line as the pane will draw it: itself, or its head with a note saying how much was left
    /// off, since a bare ellipsis reads as the line's end.
    ///
    /// Measured in UTF-8 bytes, which is free; `String.count` walks the whole line for grapheme
    /// breaks on every render.
    static func rendered(_ text: String) -> String {
        guard text.utf8.count > maxRenderedCharacters else { return text.isEmpty ? " " : text }
        let head = String(text.prefix(maxRenderedCharacters))
        let rest = text.utf8.count - head.utf8.count
        guard rest > 0 else { return head }
        let size = FileSizeFormat.byteCount.string(fromByteCount: Int64(rest))
        return head + "… (\(size) more on this line)"
    }

    // MARK: Tints

    /// The row's ground tint. Meaning is carried by position and line numbers (a removed row has
    /// only a left number, an added row only a right one), and colour only reinforces it.
    ///
    /// The ground is the only place colour is spent: tinted text would fight the intra-line
    /// highlight, which is what has to stand out.
    private func tintRow(_ kind: TextPairDiff.RowKind) -> Color {
        switch kind {
        case .same: return .clear
        case .removed: return Color.red.opacity(0.07)
        case .added: return Color.green.opacity(0.07)
        case .changed: return accent.opacity(0.07)
        }
    }
}
