import SwiftUI

/// **The selection's length, held where a write re-renders only what derives from it.**
///
/// A forward drag keeps the selection's location still and grows its length on every mouse tick.
/// Kept as the workspace's `@State`, each tick re-rendered the whole workspace for two answers
/// nobody reads until the drag rests — the status line's count (TE60) and the format bar's lit
/// state — and that cost 11 ms a tick on a 40 KB file (measured 2026-10-12, debug). The workspace
/// holds this in `@State` WITHOUT observing it, so its writes reach only
/// ``EditorSelectionDerivations``, which watches it and answers on the caret's debounce.
final class EditorLiveSelection: ObservableObject {
    /// The selection's UTF-16 length, beside the workspace's `caretOffset` (its location).
    @Published var length = 0

    /// **Whether more than one range is selected** (an ⌥-drag's column, a ⌘-drag). The status line
    /// then keeps the document's counts: it counts one selection, and a count of the first range
    /// alone, beside the others still highlighted, would be a number about something else.
    @Published var isMultiple = false

    /// Sets the length, publishing only a change — a tick that moved nothing re-renders nothing.
    func set(length: Int) {
        if self.length != length { self.length = length }
    }

    /// Sets how many ranges are selected, publishing only a change.
    func set(rangeCount: Int) {
        let isMultiple = rangeCount > 1
        if self.isMultiple != isMultiple { self.isMultiple = isMultiple }
    }
}

/// **The two answers a selection asks for, derived off the workspace's body** — the status line's
/// counts (TE60) and the format bar's lit state. Drawn as nothing; it exists so that the tasks below
/// are keyed on ``EditorLiveSelection/length`` without the workspace having to read it.
struct EditorSelectionDerivations: View {
    let document: EditorDocument
    @ObservedObject var live: EditorLiveSelection
    /// The document's version and path, as values: the document is a reference, and a view handed
    /// the same reference compares equal however much its text has moved.
    let version: Int
    let path: String?
    let caretOffset: Int
    let facts: EditorDocumentFacts
    /// The text version ``facts`` were counted at, or `nil` before the first count.
    let factsVersion: Int?
    let mode: EditorMode
    let showsFormatBar: Bool
    @Binding var selectionFacts: EditorSelectionFacts?
    @Binding var formatState: MarkupFormatState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // **The selection's counts (TE60), on the caret's debounce and off the main actor** — a
            // selection can be the whole of a 4 MiB file, and counting it walks every character in
            // it. A bare caret clears at once, with no wait: the line goes back to the document's
            // counts the moment the selection does. A drag restarts the wait on every tick, so it
            // counts once, where the drag rests.
            .task(id: SelectionKey(version: version, path: path, offset: caretOffset, length: live.length,
                                   isMultiple: live.isMultiple, factsVersion: factsVersion)) {
                // Several ranges are not counted — see ``EditorLiveSelection/isMultiple``.
                guard live.length > 0, !live.isMultiple else {
                    if selectionFacts != nil { selectionFacts = nil }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let source = document.text
                let current = document.textVersion
                // **Not beside counts of another text.** Just after an edit the document's counts
                // are still the last text's for their own debounce, and "13 of 12 words" is what a
                // fresh selection count beside them reads. The key carries their version, so this
                // runs again the moment they catch up.
                guard factsVersion == current else { return }
                let selection = NSRange(location: caretOffset, length: live.length)
                // The document's counts with the version they were taken at, so a select-all
                // reuses them rather than re-counting — and only while they are this text's.
                let whole = (facts: facts, version: factsVersion ?? current)
                let counted = await Task.detached(priority: .userInitiated) {
                    EditorSelectionFacts.of(source, selection: selection, facts: whole, version: current)
                }.value
                guard !Task.isCancelled else { return }
                if counted != selectionFacts { selectionFacts = counted }
            }
            // **The format bar's lit state, on the caret's debounce and for the caret's reason** —
            // it reads the lines the selection touches, and a body pass happens per keystroke.
            // Nothing is derived while the bar is not drawn; the key carries whether it is, so
            // turning the bar on derives at once rather than at the next caret move.
            .task(id: FormatKey(version: version, path: path, offset: caretOffset, length: live.length,
                                mode: mode, isShown: showsFormatBar)) {
                guard showsFormatBar else {
                    if formatState != .none { formatState = .none }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let source = document.text
                let selection = NSRange(location: caretOffset, length: live.length)
                let state = await Task.detached(priority: .userInitiated) {
                    MarkupFormatState.of(source, selection: selection)
                }.value
                guard !Task.isCancelled else { return }
                if state != formatState { formatState = state }
            }
    }

    /// What re-counts the selection (TE60): where it is, how long, and the text under it.
    private struct SelectionKey: Equatable {
        var version: Int
        var path: String?
        var offset: Int
        var length: Int
        var isMultiple: Bool
        var factsVersion: Int?
    }

    /// What re-derives the format bar's lit state: the selection, the text under it, the mode (a
    /// switch rebuilds the text view, with a bare caret), or the bar coming on.
    private struct FormatKey: Equatable {
        var version: Int
        var path: String?
        var offset: Int
        var length: Int
        var mode: EditorMode
        var isShown: Bool
    }
}
