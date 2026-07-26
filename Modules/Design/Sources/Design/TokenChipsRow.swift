import SwiftUI

/// The removable token-filter chips shared by every token search (Compare's Differences search,
/// Tidy's duplicate search, the Activity Log search): each recognized word as a capsule with a
/// monospaced label and a padded ✕ that edits that exact word back out of the raw query text.
/// A chip superseded by a later same-family word (the grammars parse last-wins) renders dimmed
/// and struck through, so the chips read as the query the filter actually runs.
///
/// Renders JUST the chips in a 6pt HStack — no surrounding spacers — so call sites keep their
/// own alignment (Compare/Log lead-align with a trailing Spacer; Tidy right-aligns the row under
/// its compact field and appends its suggestions).
public struct TokenChipsRow: View {

    /// One chip: the display label, the exact raw word the ✕ removes, and whether the chip is
    /// part of the effective query (superseded chips dim).
    public struct Item {
        public let label: String
        public let word: String
        public let isActive: Bool

        public init(label: String, word: String, isActive: Bool) {
            self.label = label
            self.word = word
            self.isActive = isActive
        }
    }

    private let items: [Item]
    private let tint: Color
    private let onRemove: (String) -> Void

    /// - Parameters:
    ///   - items: the chips, in typed order.
    ///   - tint: the ACTIVE chip tint (the surface's accent); inactive chips always dim to secondary.
    ///   - onRemove: called with the chip's exact raw word when its ✕ is clicked.
    public init(items: [Item], tint: Color, onRemove: @escaping (String) -> Void) {
        self.items = items
        self.tint = tint
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                chip(item)
            }
        }
    }

    private func chip(_ item: Item) -> some View {
        let tint = item.isActive ? tint : Color.secondary
        return HStack(spacing: 4) {
            Text(item.label)
                .scaledFont(.caption.monospaced())
                .strikethrough(!item.isActive)
            Button {
                onRemove(item.word)
            } label: {
                // The glyph stays 8 pt but the tappable area is padded well past it (then pulled
                // back with negative padding so the chip's visual size is unchanged) — an 8 pt
                // hit target is a misclick magnet.
                Image(systemName: "xmark").scaledFont(.system(size: 8, weight: .bold))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.inline))
            .padding(-6)
            .accessibilityLabel("Remove filter \(item.label)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(item.isActive ? 0.16 : 0.08)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .help(item.isActive ? "Active filter" : "Overridden by a later filter of the same kind")
    }
}
