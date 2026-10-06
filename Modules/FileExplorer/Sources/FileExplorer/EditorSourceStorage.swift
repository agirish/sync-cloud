import AppKit
import Events

/// **One document's text as AppKit holds it** — the `NSTextStorage` every Source text view of that
/// document is built around, kept by ``EditorUndoStore`` beside the document's undo stack (TE67.0).
///
/// **Why the storage outlives the text view.** `surfaces(for:)` mounts the Source view from a
/// different `switch` arm in Edit and in Split and none in Preview, so every mode switch builds a
/// new `NSTextView`. The undo stack was shared across that rebuild, and the text was not: an
/// `NSTextView` registers each undo action against the storage it was made in (measured 2026-10-04:
/// re-point a live view at another storage and ⌘Z still reverts the first). So a ⌘Z after a switch
/// reverted the discarded view's private storage — nothing on screen moved, the buffer kept the
/// typing, and the step was used up. Every view of a document now shares this one storage, so an
/// action registered by any of them edits the text that is on screen.
///
/// **They live and die together under the store's LRU, and that is the other half.** A stack whose
/// actions name this storage is only replayable against it, so the store keeps the two side by
/// side, refuses both when the fingerprint no longer fits, and drops both on eviction. Keeping a
/// storage costs no more than the stack did: its actions already held the storage they were made in
/// alive — one per rebuilt view, until now.
///
/// **The buffer follows the storage, not the view.** ``EditorBuffer/text`` is published from here,
/// on every character edit, whoever made it: typing, an undo replayed through a view that no longer
/// exists, or an edit from outside the text view through ``replace(_:with:undoManager:actionName:)``.
/// It used to come from the view's `textDidChange`, which an undo through a torn-down view never
/// sends.
@MainActor
public final class EditorSourceStorage: NSObject {

    /// The characters, as every Source text view of this document draws them.
    public let textStorage: NSTextStorage

    /// The text as last published to the buffer.
    ///
    /// **The storage's characters, except while an input method is composing** — see
    /// ``publishIfNeeded()``. Read this rather than `textStorage.string`, which bridges a fresh copy
    /// of the whole storage on every read.
    public private(set) var text: String

    /// The buffer this storage publishes to while it is the open document's. `nil` while put away,
    /// so a storage kept for a file nobody has open can never write into the one that is open.
    weak var buffer: EditorBuffer?

    /// The Source text view built around this storage now — for the marked-text check, for the
    /// typing attributes an insertion into an empty storage takes, and to end its run of typing
    /// before an edit from outside it.
    weak var textView: NSTextView?

    /// Bumped on every character edit; equal to ``publishedGeneration`` when ``text`` is current.
    private var generation = 0
    private var publishedGeneration = 0
    /// Set while the buffer is the one writing, so the edit is not published straight back to it.
    private var isTakingBufferText = false
    /// Set across ``replace(_:with:undoManager:actionName:)``'s own edit, whose marked range — if a
    /// word is being composed elsewhere — is the view's settled one.
    private var isReplacing = false

    public init(text: String = "") {
        textStorage = NSTextStorage(string: text)
        self.text = text
        super.init()
        textStorage.delegate = self
    }

    // MARK: Publishing to the buffer

    private func charactersDidChange() {
        generation &+= 1
        guard !isTakingBufferText else { return }
        publishIfNeeded(markedRangeIsSettled: isReplacing)
    }

    /// Brings ``text`` and the buffer up to the storage — **all of it but a half-composed word.**
    ///
    /// Marked text is in the storage the moment it is typed, and the view sends `textDidChange` only
    /// when it is committed (measured 2026-10-04). The buffer has always followed `textDidChange`,
    /// so it never held a half-composed word; published from here unguarded, autosave could write
    /// the kana reading of a word to disk before the kanji replaced it. So the composition is left
    /// out, two ways:
    ///
    /// - **Inside the composing edit itself, the edit is held back**, because the view has not yet
    ///   moved its marked range over the characters just stored (measured: `markedRange()` still
    ///   names the old place for the first marked character). The view's `textDidChange`, which
    ///   follows the commit, `unmarkText` included, publishes it.
    /// - **Anywhere the marked range is settled, the text is published without it**: the view's
    ///   `textDidChange`, and an edit from outside the text view (a tick in Split while a word is
    ///   being composed — after which AppKit ends the composition and keeps the word, measured).
    ///
    /// **An undo is never held back**, though on TextKit 2 it sends no `textDidChange` to publish it
    /// later: ⌘Z during a composition takes the composition itself back first (measured 2026-10-04),
    /// so no replay ever lands under marked text.
    func publishIfNeeded(markedRangeIsSettled: Bool = true) {
        guard generation != publishedGeneration else { return }
        var marked = NSRange(location: NSNotFound, length: 0)
        if let view = textView, view.textStorage === textStorage, view.hasMarkedText() {
            guard markedRangeIsSettled else { return }
            marked = view.markedRange()
        }
        publishedGeneration = generation
        if marked.location != NSNotFound, NSMaxRange(marked) <= textStorage.length {
            text = (textStorage.string as NSString).replacingCharacters(in: marked, with: "")
        } else {
            text = textStorage.string
        }
        buffer?.publish(text)
    }

    // MARK: Writing from outside the text view

    /// Replaces `range` with `string` **as one step ⌘Z can take back** — the one way to edit this
    /// document's text from anywhere but the text view itself.
    ///
    /// **Registered against this storage, not a view**, so it undoes the same whether the view that
    /// was on screen has since been rebuilt, or whether there is none (Preview). Undoing registers the
    /// inverse, which is the redo.
    ///
    /// **The view's run of typing is ended first**, so this step never joins the typing before it or
    /// after it. NSTextView already leaves an interleaved registration alone (measured: typing "ab",
    /// this, then "c" undoes as c, this, ab), so this is the boundary stated rather than relied on.
    ///
    /// **Writes LF only** (``EditorLineEndings``): a file still holding a carriage return is
    /// converted first, inside this step's undo, and `range` is mapped across the conversion — except
    /// while a word is being composed, which must not move under the input method. That check is belt
    /// and braces: this edit ends the composition, and the commit converts the file through the view
    /// either way (mutation-tested 2026-10-04 — removing it changes nothing a test or a probe can see).
    ///
    /// - Parameter range: UTF-16, in the storage as it stands.
    public func replace(_ range: NSRange, with string: String, undoManager: UndoManager?,
                        actionName: String? = nil) {
        let composing = textView.map { $0.textStorage === textStorage && $0.hasMarkedText() } ?? false
        let endings = composing ? [] : EditorLineEndings.carriageReturns(in: textStorage.mutableString)
        let range = EditorLineEndings.mapped(range, through: endings)
        let string = EditorLineEndings.normalized(string)
        textView?.breakUndoCoalescing()
        isReplacing = true
        textStorage.beginEditing()
        apply(endings, undoManager: undoManager)
        let removed = textStorage.mutableString.substring(with: range)
        insert(string, over: range)
        textStorage.endEditing()
        isReplacing = false
        textView?.breakUndoCoalescing()
        let inserted = NSRange(location: range.location, length: (string as NSString).length)
        // Weak: the manager holds this closure, and a strong capture would keep a dropped manager —
        // one the store refused, say — alive through its own registrations.
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] source in
            source.replace(inserted, with: removed, undoManager: undoManager, actionName: actionName)
        }
        if let actionName { undoManager?.setActionName(actionName) }
    }

    /// Turns every CRLF and lone CR into LF, as one step ⌘Z can take back — for an editor that must
    /// measure its edit on the converted text, which is any but the Source view (TE67's Preview).
    /// Call it in the same event as the edit, so the two share an undo group. `false` when there was
    /// nothing to convert, or a word is being composed.
    @discardableResult
    public func convertLineEndingsToLF(undoManager: UndoManager?) -> Bool {
        guard textView.map({ !($0.textStorage === textStorage && $0.hasMarkedText()) }) ?? true else { return false }
        let changes = EditorLineEndings.carriageReturns(in: textStorage.mutableString)
        guard !changes.isEmpty else { return false }
        textView?.breakUndoCoalescing()
        isReplacing = true
        apply(changes, undoManager: undoManager)
        isReplacing = false
        return true
    }

    /// Makes `changes` — ascending, not overlapping — and registers their exact inverse, which
    /// registers this again: ⌘Z puts the carriage returns back and ⌘⇧Z takes them out.
    private func apply(_ changes: [EditorLineEndings.Change], undoManager: UndoManager?) {
        guard !changes.isEmpty else { return }
        var inverse: [EditorLineEndings.Change] = []
        var shift = 0
        for change in changes {
            let length = (change.replacement as NSString).length
            inverse.append(.init(range: NSRange(location: change.range.location + shift, length: length),
                                 replacement: textStorage.mutableString.substring(with: change.range)))
            shift += length - change.range.length
        }
        textStorage.beginEditing()
        for change in changes.reversed() {
            textStorage.replaceCharacters(in: change.range, with: change.replacement)
        }
        textStorage.endEditing()
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] source in
            source.apply(inverse, undoManager: undoManager)
        }
    }

    /// Puts the storage in step with a buffer written from outside it — **with no undo**, which is
    /// what makes this a fallback rather than a way in.
    ///
    /// Whole-string, as `PlainTextEditor.pushIfChanged` was before it: the stack is not told, so
    /// its ranges go stale. After TE67.0 no route in the app reaches this — a load or a close puts the
    /// storage away before writing the buffer and hands it a fresh or matching one after, and the
    /// task tick goes through ``replace(_:with:undoManager:actionName:)`` — so it is logged, and any
    /// route that does reach it is a place where undo has gone stale and can be found.
    func takeBufferText(_ string: String) {
        guard !Self.sameBytes(string, text) else { return }
        if textView != nil {
            Logger.shared.info("[edit] storage resync — the buffer was written from outside the text, "
                               + "with no undo")
        }
        isTakingBufferText = true
        insert(string, over: NSRange(location: 0, length: textStorage.length))
        isTakingBufferText = false
        publishedGeneration = generation
        text = string
    }

    /// **Bytes, not `==`.** Swift compares strings for canonical equivalence, so an NFD buffer
    /// written over NFC text would read as "no change" and the screen would keep the other bytes —
    /// which a save then would not write. The undo store's fingerprint hashes bytes for the same
    /// reason.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }

    /// New characters take the attributes of the ones around them — `replaceCharacters`' own rule —
    /// and, in an empty storage with nothing around them, the view's typing attributes: the font and
    /// colour `view.string = text` used to apply.
    private func insert(_ string: String, over range: NSRange) {
        if textStorage.length > 0 {
            textStorage.replaceCharacters(in: range, with: string)
        } else {
            textStorage.replaceCharacters(
                in: range, with: NSAttributedString(string: string, attributes: textView?.typingAttributes ?? [:]))
        }
    }
}

extension EditorSourceStorage: NSTextStorageDelegate {
    nonisolated public func textStorage(_ textStorage: NSTextStorage,
                                        didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        // Characters only: a font change, or the attributes a mount applies, says nothing new.
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { charactersDidChange() }
    }
}
