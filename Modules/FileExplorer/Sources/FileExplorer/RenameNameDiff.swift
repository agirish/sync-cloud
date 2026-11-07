import Design
import SwiftUI
import Sync

/// What actually changes between a file's name and its proposed one, so a row marks the change
/// instead of making the reader compare two whole names.
///
/// The plainest diff: strip the common head and tail, and the middle is what goes and what
/// arrives. That is exactly right for this pass's renames (a padded ordinal, a stripped vendor
/// prefix, a normalised separator), each one contiguous edit.
enum RenameNameDiff {

    /// The four parts of a rename, in order.
    struct Parts: Equatable {
        /// The head both names share.
        let prefix: String
        /// The run only the CURRENT name has — what disappears.
        let removed: String
        /// The run only the PROPOSED name has — what arrives.
        let inserted: String
        /// The tail both names share.
        let suffix: String

        /// Nothing in the middle either way: the two names are the same string. The lens never
        /// builds a step like that, and a row drawing it would highlight nothing.
        var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
    }

    /// The split, over `Character`, not `UnicodeScalar` or `UTF8`: splitting inside a grapheme
    /// cluster would highlight half of an é or a flag. Characters compare under canonical
    /// equivalence, so a decomposed name and a composed one match here as elsewhere in the app.
    static func parts(current: String, proposed: String) -> Parts {
        let a = Array(current), b = Array(proposed)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        // The tail walks inward from both ends but never back past the head, or a name like
        // `aa` → `aaa` would count the same character twice and produce a negative middle.
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        return Parts(prefix: String(a[..<head]),
                     removed: String(a[head..<(a.count - tail)]),
                     inserted: String(b[head..<(b.count - tail)]),
                     suffix: String(a[(a.count - tail)...]))
    }
}

/// What a whole folder's renames have in common, said once above them, so the reader learns what
/// is happening to the folder before the file list, and a shared reason isn't repeated per row.
///
/// Nothing here is invented: the edit is shared only when every step makes the same one, and the
/// sentence is a step's own `reason`, only when every step gives the same one.
enum RenamePlanSummary {

    /// The one edit every step in a plan makes, when there is one.
    struct SharedEdit: Equatable {
        /// The run every step removes — empty when the shared edit is a pure insertion.
        let removed: String
        /// The run every step inserts — empty when it is a pure removal.
        let inserted: String
        /// True when the edit sits at the very start of the name, which is what makes a pattern
        /// like `n.` → `0n.` readable rather than ambiguous about where it applies.
        let atStart: Bool
    }

    /// The edit shared by every step, or nil when they differ. Position matters to a reader too:
    /// two steps inserting `0`, one at the front and one before the extension, still return a
    /// `SharedEdit`, with `atStart == false`, and ``pattern(for:sample:)`` withholds the pattern.
    static func sharedEdit(_ steps: [RenameStep]) -> SharedEdit? {
        guard let first = steps.first else { return nil }
        let parts = steps.map { RenameNameDiff.parts(current: $0.currentName,
                                                     proposed: $0.proposedName) }
        let head = RenameNameDiff.parts(current: first.currentName,
                                        proposed: first.proposedName)
        guard !head.isEmpty else { return nil }
        let sameRuns = parts.allSatisfy {
            $0.removed == head.removed && $0.inserted == head.inserted
        }
        guard sameRuns else { return nil }
        let allAtStart = parts.allSatisfy { $0.prefix.isEmpty }
        return SharedEdit(removed: head.removed, inserted: head.inserted, atStart: allAtStart)
    }

    /// The sentence every step gives, or nil when they disagree — in which case the rows keep
    /// their own reasons and the banner says nothing rather than picking one.
    static func sharedReason(_ steps: [RenameStep]) -> String? {
        guard let first = steps.first?.reason, !first.isEmpty else { return nil }
        return steps.allSatisfy { $0.reason == first } ? first : nil
    }

    /// The edit as a pattern a reader can match against the rows: `1.` → `01.` for a padded
    /// ordinal. nil unless the edit is shared and at the start; anywhere else the two fragments
    /// would not say where they apply. The sample supplies the context, from a real name here.
    static func pattern(for edit: SharedEdit, sample: RenameStep) -> (before: String, after: String)? {
        guard edit.atStart else { return nil }
        let parts = RenameNameDiff.parts(current: sample.currentName,
                                         proposed: sample.proposedName)
        // Three characters of the shared tail for context: enough to see where the edit lands,
        // short enough not to become the name itself.
        let context = String(parts.suffix.prefix(3))
        return (edit.removed + context, edit.inserted + context)
    }
}

/// One name with its changed run marked. Two make a row: the current name with what goes, the
/// proposed name with what arrives. The unchanged parts stay quiet as context; the changed run
/// carries the colour.
struct RenameDiffLabel: View {
    let parts: RenameNameDiff.Parts
    /// `false` draws the current name (what is there now, with the removed run marked);
    /// `true` draws the proposed name (with the inserted run marked).
    let showsProposed: Bool

    @Environment(\.colorScheme) private var colorScheme

    /// The changed run for this side — empty when this side only loses or only gains.
    private var changed: String { showsProposed ? parts.inserted : parts.removed }

    /// Insertions take the success tint, removals the caution one, both through `ChromeInk` for
    /// the contrast tinted text requires. Not the app's accent: a gain and a loss are semantic,
    /// not decorative.
    private var changedInk: Color {
        ChromeInk.semantic(colorScheme, showsProposed ? SemanticColor.success : SemanticColor.caution)
    }

    var body: some View {
        // One `Text` built by concatenation rather than an HStack of three: the parts must wrap
        // and truncate as a single string, and three views in a row would break between them.
        (Text(parts.prefix).foregroundStyle(.secondary)
         + changedRun
         + Text(parts.suffix).foregroundStyle(.secondary))
            .scaledFont(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(showsProposed
                                ? "Renamed to \(parts.prefix)\(parts.inserted)\(parts.suffix)"
                                : "Currently \(parts.prefix)\(parts.removed)\(parts.suffix)")
    }

    private var changedRun: Text {
        guard !changed.isEmpty else { return Text("") }
        return Text(changed)
            .foregroundColor(changedInk)
            .fontWeight(.bold)
    }
}

/// A folder's renames as two aligned columns, the body of a card in the renames lens.
///
/// Two equal columns, not sized to their content, so After starts at the same x on every row of
/// every card. Capped at ``RenameColumnsTable/namesMeasure`` so a card alone on a wide pane does
/// not push the two columns to opposite edges.
struct RenameColumnsTable: View {

    /// The widest the two name columns get inside one card, so "Now" and "After" stay a glance
    /// apart on a wide pane.
    static let namesMeasure: CGFloat = 600

    let steps: [RenameStep]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                heading("Now", tint: nil)
                heading("After", tint: ChromeInk.semantic(colorScheme, SemanticColor.success))
            }
            ForEach(steps) { step in
                let parts = RenameNameDiff.parts(current: step.currentName,
                                                 proposed: step.proposedName)
                GridRow {
                    RenameDiffLabel(parts: parts, showsProposed: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RenameDiffLabel(parts: parts, showsProposed: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: Self.namesMeasure, alignment: .leading)
    }

    @ViewBuilder
    private func heading(_ text: String, tint: Color?) -> some View {
        Text(text)
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? Color.secondary.opacity(0.7))
            .gridColumnAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
