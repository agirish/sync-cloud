import SwiftUI

/// The selection's length, held where a write re-renders only what derives from it.
///
/// A forward drag grows the length on every mouse tick. As the workspace's own `@State`, each tick
/// would re-render the whole workspace for two answers nobody reads until the drag rests (the
/// status line's count and the format bar's lit state). The workspace holds this in `@State`
/// **without observing it**, so its writes reach only ``EditorSelectionDerivations``, which
/// answers on the caret's debounce.
final class EditorLiveSelection: ObservableObject {
    /// The selection's UTF-16 length, beside the workspace's `caretOffset` (its location).
    @Published var length = 0

    /// Whether more than one range is selected (an ⌥-drag's column, a ⌘-drag). The status line then
    /// keeps the document's counts, since counting only the first range would mislead.
    @Published var isMultiple = false

    /// Sets the length, publishing only a change, so a tick that moved nothing re-renders nothing.
    func set(length: Int) {
        if self.length != length { self.length = length }
    }

    /// Sets how many ranges are selected, publishing only a change.
    func set(rangeCount: Int) {
        let isMultiple = rangeCount > 1
        if self.isMultiple != isMultiple { self.isMultiple = isMultiple }
    }
}

/// The two answers a selection asks for, derived off the workspace's body: the status line's counts
/// and the format bar's lit state. Drawn as nothing; it exists so the tasks below are keyed on
/// ``EditorLiveSelection/length`` without the workspace reading it.
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
            // The selection's counts, on the caret's debounce and off the main actor: a selection
            // can be a whole 4 MiB file. A bare caret clears at once, back to the document's counts.
            // A drag restarts the wait on every tick, so it counts once, where the drag rests.
            .task(id: SelectionKey(version: version, path: path, offset: caretOffset, length: live.length,
                                   isMultiple: live.isMultiple, factsVersion: factsVersion)) {
                // Several ranges aren't counted; see ``EditorLiveSelection/isMultiple``.
                guard live.length > 0, !live.isMultiple else {
                    if selectionFacts != nil { selectionFacts = nil }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let source = document.text
                let current = document.textVersion
                // Not beside counts of another text: just after an edit the document's counts are
                // still the last text's, which could read "13 of 12 words". The key carries their
                // version, so this runs again when they catch up.
                guard factsVersion == current else { return }
                let selection = NSRange(location: caretOffset, length: live.length)
                // The document's counts with the version they were taken at, so a select-all
                // reuses them rather than re-counting, only while they are this text's.
                let whole = (facts: facts, version: factsVersion ?? current)
                let counted = await Task.detached(priority: .userInitiated) {
                    EditorSelectionFacts.of(source, selection: selection, facts: whole, version: current)
                }.value
                guard !Task.isCancelled else { return }
                if counted != selectionFacts { selectionFacts = counted }
            }
            // The format bar's lit state, on the caret's debounce: it reads the lines the selection
            // touches, and a body pass happens per keystroke. Nothing is derived while the bar is
            // hidden; the key carries whether it shows, so turning it on derives at once.
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

    /// What re-counts the selection: where it is, how long, and the text under it.
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
