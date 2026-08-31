import AppKit
import Design
import SwiftUI

/// The read-only side-by-side text diff.
///
/// **Read-only, deliberately, and this is the one that answers ROADMAP §11.** The Compare
/// workspace has been asking for exactly this pane — "for a selected pair in the Differences
/// list… a read-only side-by-side or unified diff" — and it is the same component, because the
/// question is the same one: what is different between these two files. Nothing here can write.
struct TextPairDiffView: View {

    let diff: TextPairDiff
    /// A line above the rows when something about the files, rather than their content, differs —
    /// mixed line endings, a lossy decode. Absent when there is nothing to say.
    let notes: [String]
    let accent: Color

    /// The region ↑/↓ last stepped to, or nil while nothing has been stepped to yet — the pane is
    /// then showing the top of the file rather than any change. See
    /// ``TextPairDiff/steppedRegion(from:direction:count:)``.
    @Binding var focusedRegion: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.rows) { row in
                            self.row(row).id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // **No animation, and none suppressed either.** `proxy.scrollTo` outside a
                // transaction does not animate, so a `withAnimation(nil)` wrapper here would be a
                // motion site that has to be classified in `WithAnimationCoverageScanTests` while
                // doing nothing — the scan is right to ask, and the honest answer is to not write
                // one. Stepping to a change should land instantly: a reader pressing ↓ four times
                // must not wait out four scrolls.
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
                    // **Drawn at rest, invisibly.** The counter says nothing until a change has
                    // been stepped to — "1 of 5" would name a change the pane has not scrolled to,
                    // and the summary beside it already carries the count. Hiding it with
                    // `opacity` rather than an `if` keeps its width in the bar, so the stepper
                    // does not jump sideways under the reader's cursor on the first press.
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
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next change")
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .controlSize(.small)
    }

    /// Wraps around, both ways. A stepper that stops at the last change leaves the reader to
    /// scroll back to the first by hand — and the count beside it already says where they are, so
    /// wrapping cannot be mistaken for "nothing happened". The rule itself is
    /// ``TextPairDiff/steppedRegion(from:direction:count:)``, shared with the ↑/↓ keys.
    private func step(_ direction: Int) {
        focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion, direction: direction,
                                                   count: diff.regions.count)
    }

    // MARK: One row

    @ViewBuilder
    private func row(_ row: TextPairDiff.Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            side(number: row.leftNumber, text: row.left, segments: row.leftSegments)
            Divider()
            side(number: row.rightNumber, text: row.right, segments: row.rightSegments)
        }
        .background(row.kind == .same ? Color.clear : tintRow(row.kind))
    }

    private func side(number: Int?, text: String?,
                      segments: [TextPairDiff.Segment]?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .scaledFont(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            lineText(text, segments: segments)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line, with its changed runs picked out.
    ///
    /// **Built by concatenating `Text`s, which is a single laid-out string** — not an `HStack` of
    /// them. An HStack cannot wrap or truncate as one line: each run would be its own view, so a
    /// long line would push the row and the stack would wrap between runs at arbitrary points.
    /// That is the same trap the duplicates card's breadcrumb was rebuilt to avoid.
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
            Text(text.isEmpty ? " " : text)
                .scaledFont(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            // No line on this side at all — a marker, not an empty cell, so the reader can see
            // that the file simply ends (or has not started) here rather than holding a blank.
            Text("—")
                .scaledFont(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: Tints

    /// **The row's meaning is carried by its position and its line numbers, and only reinforced by
    /// colour.** A removed row has a left line number and no right one; an added row the reverse.
    /// That is what a reader who cannot separate the two tints reads it by.
    ///
    /// The row's ground is the only place colour is spent. There were per-side text tints here too
    /// — red on a removed line, green on an added one — computed, threaded through two functions,
    /// and never applied: `lineText` paints from the segments and the row's presence, and took the
    /// colour only to drop it. Deleted rather than wired up, because the ground already carries the
    /// same distinction and a second, stronger statement of it would fight the intra-line
    /// highlight, which is the one thing on the row that has to stand out.
    private func tintRow(_ kind: TextPairDiff.RowKind) -> Color {
        switch kind {
        case .same: return .clear
        case .removed: return Color.red.opacity(0.07)
        case .added: return Color.green.opacity(0.07)
        case .changed: return accent.opacity(0.07)
        }
    }
}
